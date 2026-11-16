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

  def max_tries, do: @max_tries
  def nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)
  def thumbprint(<<4, _::binary-size(64)>> = pub), do: :crypto.hash(:sha256, pub)

  def message(room, nonce) when is_binary(room) and byte_size(nonce) == @nonce_bytes,
    do: <<"mixer-relay-v1", byte_size(room)::16, room::binary, nonce::binary>>

  @doc "The relay's decision. `config` is `%{root_key: <<_::256>>}`; anything else refuses."
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

  def generate_key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    {pub, priv}
  end

  def sign(priv, room, nonce) do
    :crypto.sign(:ecdsa, :sha256, message(room, nonce), [priv, :secp256r1]) |> der_to_raw()
  end

  # DER <-> raw r||s
  def raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    {rb, sb} = {int(r), int(s)}
    body = <<2, byte_size(rb), rb::binary, 2, byte_size(sb), sb::binary>>
    <<0x30, byte_size(body), body::binary>>
  end

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
