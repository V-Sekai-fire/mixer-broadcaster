# MIT.
defmodule MixerBroadcaster.Auth do
  @moduledoc """
  The relay's door. A player has a token (see `MixerBroadcaster.Token`) and a P-256 key. The token names the
  key by its SHA-256 thumbprint; the player proves it holds the key by signing a fresh nonce from this relay.

    * thumbprint = SHA-256 of the 65-byte uncompressed public key (04 || X || Y)
    * signed message = "mixer-relay-v1" || room-length (u16) || room || nonce
    * signature = 64-byte r || s (what WebCrypto's ECDSA emits), P-256 with SHA-256

  A nonce is used once. A stolen token without the key is useless, and a recorded proof is useless for the
  next session because the nonce changes.
  """
  alias MixerBroadcaster.Token

  @nonce_bytes 32
  @max_tries 3

  @type config :: map() | :off | nil
  @type nonce :: <<_::256>>
  @type thumbprint :: <<_::256>>

  @spec max_tries() :: pos_integer()
  def max_tries, do: @max_tries
  @spec nonce() :: nonce()
  def nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)
  @spec thumbprint(<<_::520>>) :: thumbprint()
  def thumbprint(<<4, _::binary-size(64)>> = pub), do: :crypto.hash(:sha256, pub)

  @spec message(binary(), nonce()) :: binary()
  def message(room, nonce) when is_binary(room) and byte_size(nonce) == @nonce_bytes,
    do: <<"mixer-relay-v1", byte_size(room)::16, room::binary, nonce::binary>>

  @doc """
  The message a Mixer session signs: "mixer-session-v1" || nonce. A session has no room in its path (a client joins
  rooms after it connects), so the proof is not bound to one; each join is checked against the token on its own.
  """
  @spec session_message(nonce()) :: binary()
  def session_message(nonce) when byte_size(nonce) == @nonce_bytes,
    do: <<"mixer-session-v1", nonce::binary>>

  @doc """
  Admit a Mixer session: the key and proof are checked as for a room, and the token must be valid for this key and time
  with the room check deferred. Returns `{:ok, thumbprint, allow}`, where `allow.(room)` says whether the token covers
  that room (a token for several rooms, or narrowed by its holder, answers per room).
  """
  @spec admit_session(config(), binary(), binary(), binary(), binary(), integer()) ::
          {:ok, thumbprint(), (term() -> boolean())} | {:error, term()}
  def admit_session(%{root_key: root}, token, pub, sig, nonce, now)
      when is_binary(token) and is_binary(pub) and is_binary(sig) and is_binary(nonce) and
             byte_size(nonce) == @nonce_bytes do
    tp = if valid_pub?(pub), do: thumbprint(pub)

    with true <- tp != nil or {:error, :bad_key},
         true <- session_proof_ok?(pub, sig, nonce) or {:error, :bad_proof},
         {:ok, _} <- Token.verify(token, root, %{room: :none, thumbprint: tp, now: now}) do
      allow = fn room ->
        is_binary(room) and
          match?({:ok, _}, Token.verify(token, root, %{room: room, thumbprint: tp, now: now}))
      end

      {:ok, tp, allow}
    end
  end

  def admit_session(_config, _token, _pub, _sig, _nonce, _now), do: {:error, :not_configured}

  @doc """
  Does this token let its holder do `op` (such as `"read"`) in `room`? The key is the thumbprint the session was admitted
  with. A token minted without the operation, or narrowed so it no longer names it, answers `false`.
  """
  @spec allows?(config(), binary(), binary(), binary(), binary(), integer()) :: boolean()
  def allows?(%{root_key: root}, token, thumbprint, room, op, now)
      when is_binary(token) and is_binary(thumbprint) and is_binary(room) and is_binary(op) do
    match?(
      {:ok, _},
      Token.verify(token, root, %{room: room, thumbprint: thumbprint, now: now, op: op})
    )
  end

  def allows?(_, _, _, _, _, _), do: false

  defp session_proof_ok?(pub, <<_::binary-size(64)>> = raw, nonce) do
    :crypto.verify(:ecdsa, :sha256, session_message(nonce), raw_to_der(raw), [pub, :secp256r1])
  end

  defp session_proof_ok?(_, _, _), do: false

  @doc "The relay's decision. `config` is `%{root_key: <<_::256>>}`; anything else refuses."
  @spec admit(config(), binary(), binary(), binary(), binary(), binary(), integer()) ::
          {:ok, thumbprint()} | {:error, term()}
  def admit(%{root_key: root} = _config, token, pub, sig, room, nonce, now)
      when is_binary(token) and is_binary(pub) and is_binary(sig) and is_binary(nonce) do
    with true <- valid_pub?(pub) or {:error, :bad_key},
         true <- proof_ok?(pub, sig, room, nonce) or {:error, :bad_proof},
         {:ok, _} <-
           Token.verify(token, root, %{room: room, thumbprint: thumbprint(pub), now: now}) do
      {:ok, thumbprint(pub)}
    end
  end

  def admit(_config, _token, _pub, _sig, _room, _nonce, _now), do: {:error, :not_configured}

  # P-256: y^2 = x^3 - 3x + b (mod p), with 0 <= x, y < p. A point off the curve is not a key.
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  defp valid_pub?(<<4, x::unsigned-256, y::unsigned-256>>) when x < @p and y < @p do
    rem(y * y, @p) == rem(x * x * x - 3 * x + @b, @p)
  end

  defp valid_pub?(_), do: false

  defp proof_ok?(pub, <<_::binary-size(64)>> = raw, room, nonce) do
    :crypto.verify(:ecdsa, :sha256, message(room, nonce), raw_to_der(raw), [pub, :secp256r1])
  end

  defp proof_ok?(_, _, _, _), do: false

  # ---- test and client helpers (a guest client does the same with its own library) ----

  @spec generate_key() :: {binary(), binary()}
  def generate_key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    {pub, priv}
  end

  @spec sign(binary(), binary(), nonce()) :: binary()
  def sign(priv, room, nonce) do
    :crypto.sign(:ecdsa, :sha256, message(room, nonce), [priv, :secp256r1]) |> der_to_raw()
  end

  @doc "The proof a client makes for a Mixer session (the test and the guest ELF do the same)."
  @spec sign_session(binary(), nonce()) :: binary()
  def sign_session(priv, nonce),
    do: :crypto.sign(:ecdsa, :sha256, session_message(nonce), [priv, :secp256r1]) |> der_to_raw()

  # DER <-> raw r||s
  @spec raw_to_der(<<_::512>>) :: binary()
  def raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    {rb, sb} = {int(r), int(s)}
    body = <<2, byte_size(rb), rb::binary, 2, byte_size(sb), sb::binary>>
    <<0x30, byte_size(body), body::binary>>
  end

  @spec der_to_raw(binary()) :: binary()
  def der_to_raw(<<0x30, _len, 2, rl, r::binary-size(rl), 2, sl, s::binary-size(sl)>>),
    do: pad(r) <> pad(s)

  defp int(bin) do
    bin = String.trim_leading(bin, <<0>>)
    bin = if bin == "", do: <<0>>, else: bin
    if :binary.first(bin) >= 0x80, do: <<0, bin::binary>>, else: bin
  end

  defp pad(b) do
    b = String.trim_leading(b, <<0>>)
    <<0::size((32 - byte_size(b)) * 8), b::binary>>
  end
end
