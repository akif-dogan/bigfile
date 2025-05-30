%%% @doc Utilities for manipulating wallets.
-module(big_wallet).

-export([new/0, new_ecdsa/0, new/1, sign/2, verify/3, verify_pre_fork_2_4/3,
		to_address/1, to_address/2, hash_pub_key/1,
		load_key/1, load_keyfile/1, new_keyfile/0, new_keyfile/1,
		new_keyfile/2, base64_address_with_optional_checksum_to_decoded_address/1,
		base64_address_with_optional_checksum_to_decoded_address_safe/1, wallet_filepath/1,
		wallet_filepath/3,
		get_or_create_wallet/1, recover_key/3]).

-include("../include/big.hrl").
-include("../include/big_config.hrl").

-include_lib("public_key/include/public_key.hrl").

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Generate a new wallet public key and private key.
new() ->
	new(?DEFAULT_KEY_TYPE).
new(KeyType = {KeyAlg, PublicExpnt}) when KeyType =:= {?RSA_SIGN_ALG, 65537} ->
    {[_, Pub], [_, Pub, Priv|_]} = {[_, Pub], [_, Pub, Priv|_]}
		= crypto:generate_key(KeyAlg, {?RSA_PRIV_KEY_SZ, PublicExpnt}),
    {{KeyType, Priv, Pub}, {KeyType, Pub}};
new(KeyType = {KeyAlg, KeyCrv}) when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
    {OrigPub, Priv} = crypto:generate_key(ecdh, KeyCrv),
	Pub = compress_ecdsa_pubkey(OrigPub),
    {{KeyType, Priv, Pub}, {KeyType, Pub}};
new(KeyType = {KeyAlg, KeyCrv}) when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
    {Pub, Priv} = crypto:generate_key(KeyAlg, KeyCrv),
    {{KeyType, Priv, Pub}, {KeyType, Pub}}.

%% @doc Generate a new ECDSA key, store it in a keyfile.
new_ecdsa() ->
	new_keyfile({?ECDSA_SIGN_ALG, secp256k1}).

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
new_keyfile() ->
    new_keyfile(?DEFAULT_KEY_TYPE, wallet_address).

new_keyfile(KeyType) ->
    new_keyfile(KeyType, wallet_address).

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
%% The provided key is used as part of the file name.
new_keyfile(KeyType, WalletName) ->
	{Pub, Priv, Key} =
		case KeyType of
			{?RSA_SIGN_ALG, PublicExpnt} ->
				{[Expnt, Pb], [Expnt, Pb, Prv, P1, P2, E1, E2, C]} =
					crypto:generate_key(rsa, {?RSA_PRIV_KEY_SZ, PublicExpnt}),
				Ky =
					big_serialize:jsonify(
						{
							[
								{kty, <<"RSA">>},
								{ext, true},
								{e, big_util:encode(Expnt)},
								{n, big_util:encode(Pb)},
								{d, big_util:encode(Prv)},
								{p, big_util:encode(P1)},
								{q, big_util:encode(P2)},
								{dp, big_util:encode(E1)},
								{dq, big_util:encode(E2)},
								{qi, big_util:encode(C)}
							]
						}
					),
				{Pb, Prv, Ky};
			{?ECDSA_SIGN_ALG, secp256k1} ->
				{OrigPub, Prv} = crypto:generate_key(ecdh, secp256k1),
				<<4:8, PubPoint/binary>> = OrigPub,
				PubPointMid = byte_size(PubPoint) div 2,
				<<X:PubPointMid/binary, Y:PubPointMid/binary>> = PubPoint,
				Ky =
					big_serialize:jsonify(
						{
							[
								{kty, <<"EC">>},
								{crv, <<"secp256k1">>},
								{x, big_util:encode(X)},
								{y, big_util:encode(Y)},
								{d, big_util:encode(Prv)}
							]
						}
					),
				{compress_ecdsa_pubkey(OrigPub), Prv, Ky};
			{?EDDSA_SIGN_ALG, ed25519} ->
				{{_, Prv, Pb}, _} = new(KeyType),
				Ky =
					big_serialize:jsonify(
						{
							[
								{kty, <<"OKP">>},
								{alg, <<"EdDSA">>},
								{crv, <<"Ed25519">>},
								{x, big_util:encode(Pb)},
								{d, big_util:encode(Prv)}
							]
						}
					),
				{Pb, Prv, Ky}
		end,
	Filename = wallet_filepath(WalletName, Pub, KeyType),
	case filelib:ensure_dir(Filename) of
		ok ->
			case big_storage:write_file_atomic(Filename, Key) of
				ok ->
					{{KeyType, Priv, Pub}, {KeyType, Pub}};
				Error2 ->
					Error2
			end;
		Error ->
			Error
	end.

wallet_filepath(Wallet) ->
	{ok, Config} = application:get_env(bigfile, config),
	Filename = lists:flatten(["bigfile_keyfile_", binary_to_list(Wallet), ".json"]),
	filename:join([Config#config.data_dir, ?WALLET_DIR, Filename]).

wallet_filepath2(Wallet) ->
	{ok, Config} = application:get_env(bigfile, config),
	Filename = lists:flatten([binary_to_list(Wallet), ".json"]),
	filename:join([Config#config.data_dir, ?WALLET_DIR, Filename]).

%% @doc Read the keyfile for the key with the given address from disk.
%% Return not_found if bigfile_keyfile_[addr].json or [addr].json is not found
%% in [data_dir]/?WALLET_DIR.
load_key(Addr) ->
	Path = wallet_filepath(big_util:encode(Addr)),
	case filelib:is_file(Path) of
		false ->
			Path2 = wallet_filepath2(big_util:encode(Addr)),
			case filelib:is_file(Path2) of
				false ->
					not_found;
				true ->
					load_keyfile(Path2)
			end;
		true ->
			load_keyfile(Path)
	end.

%% @doc Extract the public and private key from a keyfile.
load_keyfile(File) ->
	{ok, Body} = file:read_file(File),
	{Key} = big_serialize:dejsonify(Body),
	{Pub, Priv, KeyType} =
		case lists:keyfind(<<"kty">>, 1, Key) of
			{<<"kty">>, <<"EC">>} ->
				{<<"x">>, XEncoded} = lists:keyfind(<<"x">>, 1, Key),
				{<<"y">>, YEncoded} = lists:keyfind(<<"y">>, 1, Key),
				{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
				OrigPub = iolist_to_binary([<<4:8>>, big_util:decode(XEncoded),
						big_util:decode(YEncoded)]),
				Pb = compress_ecdsa_pubkey(OrigPub),
				Prv = big_util:decode(PrivEncoded),
				KyType = {?ECDSA_SIGN_ALG, secp256k1},
				{Pb, Prv, KyType};
			{<<"kty">>, <<"OKP">>} ->
				{<<"x">>, PubEncoded} = lists:keyfind(<<"x">>, 1, Key),
				{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
				Pb = big_util:decode(PubEncoded),
				Prv = big_util:decode(PrivEncoded),
				KyType = {?EDDSA_SIGN_ALG, ed25519},
				{Pb, Prv, KyType};
			_ ->
				{<<"n">>, PubEncoded} = lists:keyfind(<<"n">>, 1, Key),
				{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
				Pb = big_util:decode(PubEncoded),
				Prv = big_util:decode(PrivEncoded),
				KyType = {?RSA_SIGN_ALG, 65537},
				{Pb, Prv, KyType}
		end,
	{{KeyType, Priv, Pub}, {KeyType, Pub}}.

%% @doc Sign some data with a private key.
sign({{KeyAlg, PublicExpnt}, Priv, Pub}, Data)
		when KeyAlg =:= ?RSA_SIGN_ALG andalso PublicExpnt =:= 65537 ->
	rsa_pss:sign(
		Data,
		sha256,
		#'RSAPrivateKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub),
			privateExponent = binary:decode_unsigned(Priv)
		}
	);
sign({{KeyAlg, KeyCrv}, Priv, _}, Data)
		when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
	secp256k1_nif:sign(Data, Priv);
sign({{KeyAlg, KeyCrv}, Priv, _}, Data)
		when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
	crypto:sign(
		KeyAlg,
		sha512,
		Data,
		[Priv, KeyCrv]
	).

%% @doc Verify that a signature is correct.
verify({{KeyAlg, PublicExpnt}, Pub}, Data, Sig)
		when KeyAlg =:= ?RSA_SIGN_ALG andalso PublicExpnt =:= 65537 ->
	rsa_pss:verify(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub)
		}
	);
% NOTE. We will not write pubkey for ECDSA signature. So don't use verify function for ECDSA, use ecrecover
% So this function will return always false if called with no Pub
verify({{KeyAlg, KeyCrv}, Pub}, Data, Sig)
		when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
	{Pass, PubExtracted} = secp256k1_nif:ecrecover(Data, Sig),
	Pass andalso PubExtracted =:= Pub;
verify({{KeyAlg, KeyCrv}, Pub}, Data, Sig)
		when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
	crypto:verify(
		KeyAlg,
		sha512,
		Data,
		Sig,
		[Pub, KeyCrv]
	).

%% @doc Verify that a signature is correct. The function was used to verify
%% transactions until the fork 2.4. It rejects a valid transaction when the
%% key modulus bit size is less than 4096. The new method (verify/3) successfully
%% verifies all the historical transactions so this function is not used anywhere
%% after the fork 2.4.
verify_pre_fork_2_4({{KeyAlg, PublicExpnt}, Pub}, Data, Sig)
		when KeyAlg =:= ?RSA_SIGN_ALG andalso PublicExpnt =:= 65537 ->
	rsa_pss:verify_legacy(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub)
		}
	).

%% @doc Generate an address from a public key.
to_address({{SigType, _Priv, Pub}, {SigType, Pub}}) ->
	to_address(Pub, SigType);
to_address({SigType, Pub}) ->
	to_address(Pub, SigType);
to_address({SigType, _Priv, Pub}) ->
	to_address(Pub, SigType).

%% @doc Generate an address from a public key.
to_address(PubKey, {?RSA_SIGN_ALG, 65537}) when bit_size(PubKey) == 256 ->
	%% Small keys are not secure, nobody is using them, the clause
	%% is for backwards-compatibility.
	PubKey;
to_address(PubKey, _SigType) ->
	hash_pub_key(PubKey).

hash_pub_key(PubKey) ->
	crypto:hash(?HASH_ALG, PubKey).

base64_address_with_optional_checksum_to_decoded_address(AddrBase64) ->
	Size = byte_size(AddrBase64),
	case Size > 7 of
		false ->
			big_util:decode(AddrBase64);
		true ->
			case AddrBase64 of
				<< MainBase64url:(Size - 7)/binary, ":", ChecksumBase64url:6/binary >> ->
					AddrDecoded = big_util:decode(MainBase64url),
					case byte_size(AddrDecoded) < 20 of
						true -> throw({error, invalid_address});
						false -> ok
					end,
					case byte_size(AddrDecoded) > 64 of
						true -> throw({error, invalid_address});
						false -> ok
					end,
					Checksum = big_util:decode(ChecksumBase64url),
					case decoded_address_to_checksum(AddrDecoded) =:= Checksum of
						true -> AddrDecoded;
						false -> throw({error, invalid_address_checksum})
					end;
				_ ->
					big_util:decode(AddrBase64)
			end
	end.

base64_address_with_optional_checksum_to_decoded_address_safe(AddrBase64)->
	try
		D = base64_address_with_optional_checksum_to_decoded_address(AddrBase64),
		{ok, D}
	catch
		_:_ ->
			{error, invalid}
	end.

%% @doc Read a wallet of one of the given types from disk. Files modified later are prefered.
%% If no file is found, create one of the type standing first in the list.
get_or_create_wallet(Types) ->
	{ok, Config} = application:get_env(bigfile, config),
	WalletDir = filename:join(Config#config.data_dir, ?WALLET_DIR),
	Entries =
		lists:reverse(lists:sort(filelib:fold_files(
			WalletDir,
			"(.*\\.json$)",
			false,
			fun(F, Acc) ->
				 [{filelib:last_modified(F), F} | Acc]
			end,
			[])
		)),
	get_or_create_wallet(Entries, Types).

get_or_create_wallet([], [Type | _]) ->
	big_wallet:new_keyfile(Type);
get_or_create_wallet([{_LastModified, F} | Entries], Types) ->
	{{Type, _, _}, _} = W = load_keyfile(F),
	case lists:member(Type, Types) of
		true ->
			W;
		false ->
			get_or_create_wallet(Entries, Types)
	end.

recover_key(_Data, <<>>, ?ECDSA_KEY_TYPE) ->
	<<>>;
recover_key(Data, Signature, ?ECDSA_KEY_TYPE) ->
	{_Pass, PubKey} = secp256k1_nif:ecrecover(Data, Signature),
	% Note. if Pass = false, then PubKey will be <<>>
	PubKey.

%%%===================================================================
%%% Private functions.
%%%===================================================================

wallet_filepath(WalletName, PubKey, KeyType) ->
	wallet_filepath(wallet_name(WalletName, PubKey, KeyType)).

wallet_name(wallet_address, PubKey, KeyType) ->
	big_util:encode(to_address(PubKey, KeyType));
wallet_name(WalletName, _, _) ->
	WalletName.

decoded_address_to_checksum(AddrDecoded) ->
	Crc = erlang:crc32(AddrDecoded),
	<< Crc:32 >>.

decoded_address_to_base64_address_with_checksum(AddrDecoded) ->
	Checksum = decoded_address_to_checksum(AddrDecoded),
	AddrBase64 = big_util:encode(AddrDecoded),
	ChecksumBase64 = big_util:encode(Checksum),
	<< AddrBase64/binary, ":", ChecksumBase64/binary >>.

compress_ecdsa_pubkey(<<4:8, PubPoint/binary>>) ->
	PubPointMid = byte_size(PubPoint) div 2,
	<<X:PubPointMid/binary, Y:PubPointMid/integer-unit:8>> = PubPoint,
	PubKeyHeader =
		case Y rem 2 of
			0 -> <<2:8>>;
			1 -> <<3:8>>
		end,
	iolist_to_binary([PubKeyHeader, X]).

%%%===================================================================
%%% Tests.
%%%===================================================================

wallet_sign_verify_test() ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(),
	Signature = sign(Priv, TestData),
	true = verify(Pub, TestData, Signature).

invalid_signature_test() ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(),
	<< _:32, Signature/binary >> = sign(Priv, TestData),
	false = verify(Pub, TestData, << 0:32, Signature/binary >>).

%% @doc Check generated keyfiles can be retrieved.
generate_keyfile_test() ->
	{Priv, Pub} = new_keyfile(),
	FileName = wallet_filepath(big_util:encode(to_address(Pub))),
	{Priv, Pub} = load_keyfile(FileName).

checksum_test() ->
	{_, Pub} = new(),
	Addr = to_address(Pub),
	AddrBase64 = big_util:encode(Addr),
	AddrBase64Wide = decoded_address_to_base64_address_with_checksum(Addr),
	Addr = base64_address_with_optional_checksum_to_decoded_address(AddrBase64Wide),
	Addr = base64_address_with_optional_checksum_to_decoded_address(AddrBase64),
	%% 64 bytes, for future.
	CorrectLongAddress = <<"0123456789012345678901234567890123456789012345678901234567890123">>,
	CorrectCheckSum = decoded_address_to_checksum(CorrectLongAddress),
	CorrectLongAddressBase64 = big_util:encode(CorrectLongAddress),
	CorrectCheckSumBase64 = big_util:encode(CorrectCheckSum),
	CorrectLongAddressWithChecksumBase64 = <<CorrectLongAddressBase64/binary, ":", CorrectCheckSumBase64/binary>>,
	case catch base64_address_with_optional_checksum_to_decoded_address(CorrectLongAddressWithChecksumBase64) of
		{error, _} -> throw({error, correct_long_address_should_bypass});
		_ -> ok
	end,
	%% 65 bytes.
	InvalidLongAddress = <<"01234567890123456789012345678901234567890123456789012345678901234">>,
	InvalidLongAddressBase64 = big_util:encode(InvalidLongAddress),
	case catch base64_address_with_optional_checksum_to_decoded_address(<<InvalidLongAddressBase64/binary, ":MDA">>) of
		{'EXIT', _} -> ok
	end,
	%% 100 bytes.
	InvalidLongAddress2 = <<"0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789">>,
	InvalidLongAddress2Base64 = big_util:encode(InvalidLongAddress2),
	case catch base64_address_with_optional_checksum_to_decoded_address(<<InvalidLongAddress2Base64/binary, ":MDA">>) of
		{'EXIT', _} -> ok
	end,
	%% 10 bytes
	InvalidShortAddress = <<"0123456789">>,
	InvalidShortAddressBase64 = big_util:encode(InvalidShortAddress),
	case catch base64_address_with_optional_checksum_to_decoded_address(<<InvalidShortAddressBase64/binary, ":MDA">>) of
		{'EXIT', _} -> ok
	end,
	InvalidChecksum = big_util:encode(<< 0:32 >>),
	case catch base64_address_with_optional_checksum_to_decoded_address(
			<< AddrBase64/binary, ":", InvalidChecksum/binary >>) of
		{error, invalid_address_checksum} -> ok
	end,
	case catch base64_address_with_optional_checksum_to_decoded_address(<<":MDA">>) of
		{'EXIT', _} -> ok
	end.
