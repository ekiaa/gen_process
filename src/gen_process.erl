-module(gen_process).

-compile({no_auto_import,[put/2]}).

-export([start_link/2, init/2]).

-export([system_continue/3, system_terminate/4, system_get_state/1, system_replace_state/2, behaviour_info/1]).

behaviour_info(callbacks) ->
	[
		{init, 1},
		{handle_msg, 3},
		{terminate, 3}
	].

start_link(Module, Args) ->
	proc_lib:start_link(?MODULE, init, [self(), {Module, Args}]).

init(Parent, {Module, Args}) ->
	Deb = sys:debug_options([]),
	case catch Module:init(Args) of
		{ok, State, Params} ->
			proc_lib:init_ack(Parent, {ok, self()}),
			loop(
				#{
					module => Module, 
					parent => Parent, 
					deb => Deb, 
					state => State, 
					params => Params, 
					awaiting => queue:new(), 
					processed => queue:new()
				});
		Result ->
			Error = {error, {bad_return, {?MODULE, ?LINE, init, {{Module, init, Args}, Result}}}},
			proc_lib:init_ack(Parent, Error),
			erlang:exit(Error)
	end.

loop(Process) ->
	receive
		{system, From, Request} = _Msg ->
			#{parent := Parent, deb := Deb} = Process,
			sys:handle_system_msg(Request, From, Parent, ?MODULE, Deb, Process);
		Message ->
			handle(Message, Process)
	end.

handle(Message, #{module := Module, state := State, params := Params} = Process) ->
	case catch Module:handle_msg(State, Message, Params) of
		ok ->
			join(Process);
		{ok, NewState} ->
			join(Process#{state => NewState});
		{ok, NewState, NewParams} ->
			join(Process#{state => NewState, params => NewParams});
		put ->
			put(Message, Process);
		{put, NewState} ->
			put(Message, Process#{state => NewState});
		{put, NewState, NewParams} ->
			put(Message, Process#{state => NewState, params => NewParams});
		ignore ->
			process(Process);
		{ignore, NewState} ->
			process(Process#{state => NewState});
		{ignore, NewState, NewParams} ->
			process(Process#{state => NewState, params => NewParams});
		stop ->
			terminate(normal, Process);
		{stop, Reason} ->
			terminate(Reason, Process);
		{stop, Reason, NewState} ->
			terminate(Reason, Process#{state => NewState});
		{stop, Reason, NewState, NewParams} ->
			terminate(Reason, Process#{state => NewState, params => NewParams});
		Result ->
			Error = {error, {bad_return, {?MODULE, ?LINE, handle, {{Module, handle_msg, [State, Message, Params]}, Result}}}},
			terminate(Error, Process)
	end.

join(#{awaiting := Awaiting, processed := Processed} = Process) ->
	case queue:is_empty(Processed) of
		true ->
			process(Process);
		false ->
			process(Process#{awaiting => queue:join(Awaiting, Processed), processed => queue:new()})
	end.

put(Message, #{processed := Processed} = Process) ->
	process(Process#{processed => queue:in(Message, Processed)}).

process(#{awaiting := Awaiting} = Process) ->	
	case queue:out(Awaiting) of
		{{value, Message}, Rest} ->
			handle(Message, Process#{awaiting => Rest});
		{empty, _} ->
			loop(Process)
	end.

terminate(Reason, #{module := Module, state := State, params := Params}) ->
	case catch Module:terminate(State, Reason, Params) of
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

system_continue(Parent, Deb, Process) ->
	loop(Process#{parent => Parent, deb => Deb}).

system_terminate(Reason, _Parent, _Deb, Process) ->
	terminate(Reason, Process).

system_get_state(Process) ->
	{ok, Process, Process}.

system_replace_state(ProcessFun, Process) ->
	NewProcess = ProcessFun(Process),
	{ok, NewProcess, NewProcess}.