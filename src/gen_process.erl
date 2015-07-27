-module(gen_process).

-export([start_link/2, init/2]).

-export([system_continue/3, system_terminate/4, system_get_state/1, system_replace_state/2, behaviour_info/1]).

behaviour_info(callbacks) ->
	[
		{init, 1},
		{handle_msg, 2},
		{terminate, 2}
	].

start_link(Module, Args) ->
	proc_lib:start_link(?MODULE, init, [self(), {Module, Args}]).

init(Parent, {Module, Args}) ->
	Deb = sys:debug_options([]),
	case catch Module:init(Args) of
		{ok, State} ->
			proc_lib:init_ack(Parent, {ok, self()}),
			loop(#{module => Module, parent => Parent, deb => Deb, state => State, awaiting => queue:new(), processed => queue:new()});
		Result ->
			Error = {error, {bad_return, {?MODULE, ?LINE, init, {{Module, init, Args}, Result}}}},
			proc_lib:init_ack(Parent, Error),
			erlang:exit(Error)
	end.

loop(Params) ->
	receive
		{system, From, Request} = _Msg ->
			#{parent := Parent, deb := Deb} = Params,
			sys:handle_system_msg(Request, From, Parent, ?MODULE, Deb, Params);
		Message ->
			handle(Message, Params)
	end.

handle(Message, #{module := Module, state := State} = Params) ->
	case catch Module:handle_msg(Message, State) of
		ok ->
			#{awaiting := Awaiting, processed := Processed} = Params,
			process(Params#{awaiting => queue:join(Awaiting, Processed), processed => queue:new()});
		{ok, NewState} ->
			#{awaiting := Awaiting, processed := Processed} = Params,
			process(Params#{state => NewState, awaiting => queue:join(Awaiting, Processed), processed => queue:new()});
		put ->
			#{processed := Processed} = Params,
			process(Params#{processed => queue:in(Message, Processed)});
		{put, NewState} ->
			#{processed := Processed} = Params,
			process(Params#{state => NewState, processed => queue:in(Message, Processed)});
		ignore ->
			process(Params);
		{ignore, NewState} ->
			process(Params#{state => NewState});
		stop ->
			terminate(normal, Params);
		{stop, Reason} ->
			terminate(Reason, Params);
		{stop, Reason, NewState} ->
			terminate(Reason, Params#{state => NewState});
		Result ->
			Error = {error, {bad_return, {?MODULE, ?LINE, handle, {{Module, handle_msg, [Message, State]}, Result}}}},
			terminate(Error, Params)
	end.


process(#{awaiting := Awaiting} = Params) ->	
	case queue:out(Awaiting) of
		{{value, Message}, Rest} ->
			handle(Message, Params#{awaiting => Rest});
		{empty, _} ->
			loop(Params)
	end.

terminate(Reason, #{module := Module, state := State}) ->
	case catch Module:terminate(Reason, State) of
		{'EXIT', R} ->
			exit(R);
		_ ->
		    case Reason of
				normal ->
					erlang:exit(normal);
				shutdown ->
					erlang:exit(shutdown);
				{shutdown, _} = Shutdown ->
					erlang:exit(Shutdown);
				Reason ->
					erlang:exit(Reason)
			end
	end.

system_continue(Parent, Deb, Params) ->
	loop(Params#{parent => Parent, deb => Deb}).

system_terminate(Reason, _Parent, _Deb, Params) ->
	terminate(Reason, Params).

system_get_state(Params) ->
	{ok, Params, Params}.

system_replace_state(ParamsFun, Params) ->
	NewParams = ParamsFun(Params),
	{ok, NewParams, NewParams}.