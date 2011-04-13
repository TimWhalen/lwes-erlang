-module (lwes_channel).

-behaviour (gen_server).

-include_lib ("lwes.hrl").
-include ("lwes_internal.hrl").

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export ([ start_link/1,
           open/2,
           register_callback/4,
           send_to/2,
           close/1
         ]).

%% gen_server callbacks
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           terminate/2,
           code_change/3
         ]).

-record (state, {socket, channel, type, callback}).
-record (callback, {function, format, state}).

%%====================================================================
%% API functions
%%====================================================================
start_link (Channel) ->
  gen_server:start_link (?MODULE, [Channel], []).

open (Type, {Ip, Port}) ->
  Channel = #lwes_channel {
              ip = Ip,
              port = Port,
              is_multicast = is_multicast (Ip),
              type = Type,
              ref = make_ref ()
            },
  { ok, _Pid } = lwes_channel_manager:open_channel (Channel),
  { ok, Channel}.

register_callback (Channel, CallbackFunction, EventType, CallbackState) ->
  find_and_call ( Channel,
                  { register, CallbackFunction, EventType, CallbackState }).

send_to (Channel, Msg) ->
  find_and_call (Channel, { send, Msg }).

close (Channel) ->
  find_and_cast (Channel, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init ([ Channel = #lwes_channel {
                    ip = Ip,
                    port = Port,
                    is_multicast = IsMulticast,
                    type = Type
                 }
      ]) ->
  { ok, Socket }=
    case {Type, IsMulticast} of
      {listener, true} ->
        gen_udp:open ( Port,
                       [ { reuseaddr, true },
                         { ip, Ip },
                         { multicast_ttl, 4 },
                         { multicast_loop, false },
                         { add_membership, {Ip, {0,0,0,0}}},
                         { recbuf, 100 * 65535 },
                         binary
                       ]);
      {listener, false} ->
        gen_udp:open ( Port,
                       [ { recbuf, 100 * 65535 },
                         binary
                       ]);
      {_, _} ->
        gen_udp:open ( 0,
                       [ { recbuf, 100 * 65535 },
                         binary
                       ])
    end,
  lwes_channel_manager:register_channel (Channel, self()),
  { ok, #state { socket = Socket,
                 channel = Channel,
                 type = Type
               }
  }.

handle_call ({ register, Function, Format, Accum },
             _From,
             State = #state {
               channel = #lwes_channel {type = listener }
             }) ->
  { reply,
    ok,
    State#state { callback = #callback { function = Function,
                                         format   = Format,
                                         state    = Accum } } };

handle_call ({ send, Packet },
             _From,
             State = #state {
               socket = Socket,
               channel = #lwes_channel { ip = Ip, port = Port }
             }) ->
  { reply,
    gen_udp:send (Socket, Ip, Port, Packet),
    State };

handle_call (Request, From, State) ->
  error_logger:warning_msg ("unrecognized call ~p from ~p~n",[Request, From]),
  { reply, ok, State }.

handle_cast (stop, State) ->
  {stop, normal, State};
handle_cast (Request, State) ->
  error_logger:warning_msg ("unrecognized cast ~p~n",[Request]),
  { noreply, State }.

% skip if we don't have a handler
handle_info ( {udp, _, _, _, _},
              State = #state {
                type = listener,
                callback = undefined
              } ) ->
  { noreply, State };

handle_info ( Packet = {udp, _, _, _, _},
              State = #state {
                type = listener,
                callback = #callback { function = Function,
                                       format   = Format,
                                       state    = CbState }
              } ) ->
  Event =
    case Format of
      raw -> Packet;
      _ -> lwes_event:from_udp_packet (Packet, Format)
    end,
  NewCbState = Function (Event, CbState),
  { noreply,
    State#state { callback = #callback { function = Function,
                                         format   = Format,
                                         state    = NewCbState } }
  };

handle_info ( Request, State) ->
  error_logger:warning_msg ("unrecognized info ~p~n",[Request]),
  {noreply, State}.

terminate (_Reason, #state {socket = Socket, channel = Channel}) ->
  gen_udp:close (Socket),
  lwes_channel_manager:unregister_channel (Channel).

code_change (_OldVsn, State, _Extra) ->
  {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================
is_multicast ({N1, _, _, _}) when N1 >= 224, N1 =< 239 ->
  true;
is_multicast (_) ->
  false.

find_and_call (Channel, Msg) ->
  case lwes_channel_manager:find_channel (Channel) of
    {error, not_open} ->
      {error, not_open};
    Pid ->
      gen_server:call ( Pid, Msg )
  end.

find_and_cast (Channel, Msg) ->
  case lwes_channel_manager:find_channel (Channel) of
    {error, not_open} ->
      {error, not_open};
    Pid ->
      gen_server:cast ( Pid, Msg )
  end.

%%====================================================================
%% Test functions
%%====================================================================
-ifdef(EUNIT).

-endif.