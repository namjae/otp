%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2015. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%

-module(ssl_sni_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("public_key/include/public_key.hrl").

%%--------------------------------------------------------------------
%% Common Test interface functions -----------------------------------
%%--------------------------------------------------------------------
suite() -> [{ct_hooks,[ts_install_cth]}].

all() -> [no_sni_header, sni_match, sni_no_match].

init_per_suite(Config0) ->
    catch crypto:stop(),
    try crypto:start() of
        ok ->
            ssl:start(),
            Result =
            (catch make_certs:all(?config(data_dir, Config0),
                                  ?config(priv_dir, Config0))),
            ct:log("Make certs  ~p~n", [Result]),
            ssl_test_lib:cert_options(Config0)
        catch _:_  ->
            {skip, "Crypto did not start"}
    end.

end_per_suite(_) ->
    ssl:stop(),
    application:stop(crypto).

%%--------------------------------------------------------------------
%% Test Cases --------------------------------------------------------
%%--------------------------------------------------------------------
no_sni_header(Config) ->
    run_handshake(Config, undefined, undefined, "server").

sni_match(Config) ->
    run_handshake(Config, "a.server", "a.server", "a.server").

sni_no_match(Config) ->
    run_handshake(Config, "c.server", undefined, "server").



%%--------------------------------------------------------------------
%% Internal Functions ------------------------------------------------
%%--------------------------------------------------------------------


ssl_recv(SSLSocket, Expect) ->
    ssl_recv(SSLSocket, "", Expect).

ssl_recv(SSLSocket, CurrentData, ExpectedData) ->
    receive
        {ssl, SSLSocket, Data} ->
            NeweData = CurrentData ++ Data,
            case NeweData of
                ExpectedData ->
                    ok;
                _  ->
                    ssl_recv(SSLSocket, NeweData, ExpectedData)
            end;
        Other ->
            ct:fail({unexpected_message, Other})
        after 4000 ->
            ct:fail({timeout, CurrentData, ExpectedData})
    end.



send_and_hostname(SSLSocket) ->
    ssl:send(SSLSocket, "OK"),
    {ok, [{sni_hostname, Hostname}]} = ssl:connection_information(SSLSocket, [sni_hostname]),
    Hostname.

rdnPart([[#'AttributeTypeAndValue'{type=Type, value=Value} | _] | _], Type) -> Value;
rdnPart([_ | Tail], Type) -> rdnPart(Tail, Type);
rdnPart([], _) -> unknown.

rdn_to_string({utf8String, Binary}) ->
    erlang:binary_to_list(Binary);
rdn_to_string({printableString, String}) ->
    String.

recv_and_certificate(SSLSocket) ->
    ssl_recv(SSLSocket, "OK"),
    {ok, PeerCert} = ssl:peercert(SSLSocket),
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subject = {rdnSequence, Subject}}} = public_key:pkix_decode_cert(PeerCert, otp),
    ct:log("Subject of certificate received from server: ~p", [Subject]),
    rdn_to_string(rdnPart(Subject, ?'id-at-commonName')).


run_handshake(Config, SNIHostname, ExpectedSNIHostname, ExpectedCN) ->
    ct:log("Start running handshake, Config: ~p, SNIHostname: ~p, ExpectedSNIHostname: ~p, ExpectedCN: ~p", [Config, SNIHostname, ExpectedSNIHostname, ExpectedCN]),
    ServerOptions = ?config(sni_server_opts, Config) ++ ?config(server_opts, Config),
    ClientOptions = 
    case SNIHostname of
        undefined ->
            ?config(client_opts, Config);
        _ ->
            [{server_name_indication, SNIHostname}] ++ ?config(client_opts, Config)
    end,
    ct:log("Options: ~p", [[ServerOptions, ClientOptions]]),
    {ClientNode, ServerNode, Hostname} = ssl_test_lib:run_where(Config),
    Server = ssl_test_lib:start_server([{node, ServerNode}, {port, 0},
                                        {from, self()}, {mfa, {?MODULE, send_and_hostname, []}},
                                        {options, ServerOptions}]),
    Port = ssl_test_lib:inet_port(Server),
    Client = ssl_test_lib:start_client([{node, ClientNode}, {port, Port},
                                        {host, Hostname}, {from, self()},
                                        {mfa, {?MODULE, recv_and_certificate, []}},
                                        {options, ClientOptions}]),
    ssl_test_lib:check_result(Server, ExpectedSNIHostname, Client, ExpectedCN).