# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Token do
  @moduledoc """
  Zero-trust player tokens: a macaroon chain whose links are COSE_Mac0 messages (RFC 9052 section 6.3) in
  deterministic CBOR (RFC 8949 section 4.2).

      token     = [1, main_chain, [discharge_chain, ...]]          ; 1 is the format version
      chain     = [mac0_root, mac0_caveat, ...]
      mac0      = [h'A10105', {}, payload, tag]                    ; alg 5 = HMAC 256/256, nothing else is accepted
      tag       = HMAC-SHA256(key, ["MAC0", h'A10105', h'', payload])
      root key  = the chain's own key; each caveat link is keyed with the tag of the link before it
      caveat    = [4, not_before, not_after] | [1001, room] | [1003, [room, ...]] | [1005, [op, ...]] | [1002, key_thumbprint]
                | [11, location, vk, ticket]

  Caveats all have to hold. `1001` is one room; `1003` is any of a list of rooms. Anyone holding a token can append
  a caveat (`restrict_rooms/2`) and so narrow it, to one of its rooms for a single session, say; nobody can widen it.

  Who holds what:

    * the relay (Fly) holds only the ROOT key. `issue/4` makes a token for one room with a third-party caveat.
    * the minter (beside Bao) holds the THIRD-PARTY key. After it authenticates a player it calls `discharge/5`,
      which adds the validity window and the player's key thumbprint. The relay cannot make that part.
    * `verify/3` denies by default: no discharge, a discharge for another token, expired, wrong room, wrong key,
      an unknown caveat, an unknown version or algorithm, trailing bytes, or any encoding that is not the
      deterministic one, are all refused.

  Bytes are always wrapped as CBOR byte strings, because a bare Elixir binary encodes as text.
  """

  @version 1
  @max_bytes 8192
  @max_depth 4
  @protected <<0xA1, 0x01, 0x05>>

  @max_rooms 64
  @ops ["read"]

  # `room: :none` defers the room check: a session is admitted first and each room it asks for is checked on its own.
  @type ctx :: %{
          required(:room) => String.t() | :none,
          required(:thumbprint) => binary(),
          required(:now) => integer(),
          optional(:op) => String.t()
        }

  # ---- relay side ----

  @doc """
  A token for `room`, or for any of a list of rooms. It is useless until the minter at `location` (holding
  `tp_key`) discharges it.
  """
  @spec issue(binary(), String.t() | [String.t()], String.t(), binary(), [String.t()]) ::
          binary() | {:error, :bad_ops | :bad_rooms}
  def issue(root_key, room, location, tp_key, ops \\ [])

  def issue(root_key, room, location, tp_key, ops)
      when byte_size(root_key) == 32 and byte_size(tp_key) == 32 and is_binary(room) and
             is_binary(location) and is_list(ops) do
    with :ok <- check_ops(ops), do: do_issue(root_key, [1001, room], ops, location, tp_key)
  end

  def issue(root_key, [_ | _] = rooms, location, tp_key, ops)
      when byte_size(root_key) == 32 and byte_size(tp_key) == 32 and is_binary(location) and
             length(rooms) <= @max_rooms and is_list(ops) do
    with :ok <- check_ops(ops),
         true <- Enum.all?(rooms, &is_binary/1) or {:error, :bad_rooms},
         do: do_issue(root_key, [1003, Enum.uniq(rooms)], ops, location, tp_key)
  end

  defp check_ops(ops),
    do: if(Enum.all?(ops, &(&1 in @ops)), do: :ok, else: {:error, :bad_ops})

  defp do_issue(root_key, room_caveat, ops, location, tp_key) do
    root = mac0(root_key, enc([bytes(rand(16))]))
    {room_link, tail} = link(tag_of(root), room_caveat)

    {op_links, tail} =
      if ops == [] do
        {[], tail}
      else
        {l, t} = link(tail, [1005, Enum.uniq(ops)])
        {[l], t}
      end

    rn = rand(32)
    vk = seal(rn, tail, "mixer/3p/vk/1")
    ticket = seal(enc([bytes(rn)]), tp_key, "mixer/3p/ticket/1")
    {tp_link, _} = link(tail, [11, location, bytes(vk), bytes(ticket)])

    enc([@version, [root, room_link] ++ op_links ++ [tp_link], []])
  end

  @doc "Check a token. Returns `{:ok, %{room:, thumbprint:}}` or `{:error, reason}`."
  @spec verify(binary(), binary(), ctx()) :: {:ok, map()} | {:error, term()}
  def verify(token, root_key, %{room: _, thumbprint: _, now: _} = ctx)
      when is_binary(token) and byte_size(token) <= @max_bytes and byte_size(root_key) == 32 do
    with {:ok, [@version, main, discharges]} <- strict_decode(token),
         true <- (is_list(main) and is_list(discharges)) or {:error, :bad_token},
         {:ok, caveats} <- check_chain(main, root_key, discharges, 0),
         :ok <- require_all(caveats),
         :ok <- require_op(caveats, Map.get(ctx, :op)),
         :ok <- evaluate(caveats, ctx) do
      {:ok, %{room: ctx.room, thumbprint: ctx.thumbprint}}
    else
      {:ok, [_other_version | _]} -> {:error, :unknown_version}
      {:error, _} = e -> e
      _ -> {:error, :bad_token}
    end
  end

  def verify(_, _, _), do: {:error, :bad_token}

  @doc """
  Narrow a token to some of its rooms by appending a `1003` caveat. This needs no key: the chain's last tag is the
  key for the next link. The result still has to satisfy every caveat before it, so a room outside the original set
  stays refused.
  """
  @spec restrict_rooms(binary(), [String.t(), ...]) :: {:ok, binary()} | {:error, term()}
  def restrict_rooms(token, [_ | _] = rooms)
      when is_binary(token) and length(rooms) <= @max_rooms do
    with true <- Enum.all?(rooms, &is_binary/1) or {:error, :bad_rooms},
         {:ok, [@version, main, ds]} <- strict_decode(token),
         true <- (is_list(main) and main != []) or {:error, :bad_token} do
      {link_, _} = link(tag_of(List.last(main)), [1003, Enum.uniq(rooms)])
      {:ok, enc([@version, main ++ [link_], ds])}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_token}
    end
  end

  @doc """
  Narrow a token's operations by appending a `1005` caveat. Like `restrict_rooms/2` it needs no key and can only remove
  rights: every `1005` caveat has to name an operation for it to be allowed.
  """
  @spec restrict_ops(binary(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def restrict_ops(token, ops) when is_binary(token) and is_list(ops) do
    with :ok <- check_ops(ops),
         {:ok, [@version, main, ds]} <- strict_decode(token),
         true <- (is_list(main) and main != []) or {:error, :bad_token} do
      {link_, _} = link(tag_of(List.last(main)), [1005, Enum.uniq(ops)])
      {:ok, enc([@version, main ++ [link_], ds])}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_token}
    end
  end

  # ---- minter side ----

  @doc "After authenticating the player: bind the token to their key for `ttl` seconds."
  @spec discharge(binary(), binary(), binary(), pos_integer(), integer()) ::
          {:ok, binary()} | {:error, term()}
  def discharge(token, tp_key, thumbprint, ttl, now \\ System.os_time(:second))
      when byte_size(tp_key) == 32 and byte_size(thumbprint) == 32 and is_integer(ttl) and ttl > 0 do
    with {:ok, [@version, main, ds]} <- strict_decode(token),
         {:ok, ticket} <- find_ticket(main),
         {:ok, [%CBOR.Tag{tag: :bytes, value: rn}]} <-
           unseal(ticket, tp_key, "mixer/3p/ticket/1") |> decode_inner() do
      root = mac0(rn, enc([bytes(ticket)]))
      {window, tail} = link(tag_of(root), [4, now, now + ttl])
      {key, _} = link(tail, [1002, bytes(thumbprint)])
      {:ok, enc([@version, main, ds ++ [[root, window, key]]])}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_token}
    end
  end

  # ---- chain ----

  defp check_chain(_chain, _key, _ds, depth) when depth > @max_depth, do: {:error, :too_deep}

  defp check_chain([root | links], key, discharges, depth) do
    with {:ok, payload, tail} <- check_mac0(root, key),
         {:ok, [%CBOR.Tag{tag: :bytes, value: _kid}]} <- strict_decode(payload) do
      walk(links, tail, discharges, depth, [])
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_token}
    end
  end

  defp check_chain(_, _, _, _), do: {:error, :bad_token}

  defp walk([], _tail, _ds, _depth, acc), do: {:ok, acc}

  defp walk([l | rest], tail, ds, depth, acc) do
    with {:ok, payload, next} <- check_mac0(l, tail),
         {:ok, cav} <- caveat(payload) do
      case cav do
        {:third, _loc, vk, ticket} ->
          with {:ok, dkey} <- unseal(vk, tail, "mixer/3p/vk/1"),
               {:ok, d} <- find_discharge(ds, ticket),
               {:ok, inner} <- check_chain(d, dkey, List.delete(ds, d), depth + 1) do
            walk(rest, next, ds, depth, acc ++ [{:sep}] ++ inner)
          else
            {:error, :no_discharge} -> {:error, :no_discharge}
            _ -> {:error, :bad_discharge}
          end

        other ->
          walk(rest, next, ds, depth, acc ++ [other])
      end
    end
  end

  defp find_discharge(ds, ticket) do
    Enum.find(ds, fn
      [[_, _, payload, _] | _] ->
        match?({:ok, [%CBOR.Tag{tag: :bytes, value: ^ticket}]}, strict_decode_bytes(payload))

      _ ->
        false
    end)
    |> case do
      nil -> {:error, :no_discharge}
      d -> {:ok, d}
    end
  end

  defp find_ticket(main) do
    Enum.find_value(main, {:error, :no_third_party_caveat}, fn
      [_, _, %CBOR.Tag{tag: :bytes, value: p}, _] ->
        case caveat(p) do
          {:ok, {:third, _, _, t}} -> {:ok, t}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # ---- COSE_Mac0 ----

  defp mac0(key, payload) do
    [bytes(@protected), %{}, bytes(payload), bytes(hmac(key, mac_structure(payload)))]
  end

  defp link(key, caveat) do
    m = mac0(key, enc(caveat))
    {m, tag_of(m)}
  end

  defp tag_of([_, _, _, %CBOR.Tag{tag: :bytes, value: t}]), do: t

  defp check_mac0(
         [
           %CBOR.Tag{tag: :bytes, value: @protected},
           m,
           %CBOR.Tag{tag: :bytes, value: payload},
           %CBOR.Tag{tag: :bytes, value: tag}
         ],
         key
       )
       when m == %{} and byte_size(tag) == 32 do
    if equal?(hmac(key, mac_structure(payload)), tag),
      do: {:ok, payload, tag},
      else: {:error, :bad_signature}
  end

  defp check_mac0(_, _), do: {:error, :bad_token}

  defp mac_structure(payload), do: enc(["MAC0", bytes(@protected), bytes(<<>>), bytes(payload)])

  # ---- caveats ----

  defp caveat(payload) do
    case strict_decode(payload) do
      {:ok, [4, nb, na]} when is_integer(nb) and is_integer(na) ->
        {:ok, {:window, nb, na}}

      {:ok, [1001, room]} when is_binary(room) ->
        {:ok, {:room, room}}

      {:ok, [1003, rooms]} when is_list(rooms) and rooms != [] and length(rooms) <= @max_rooms ->
        if Enum.all?(rooms, &is_binary/1), do: {:ok, {:rooms, rooms}}, else: {:error, :bad_caveat}

      {:ok, [1005, ops]} when is_list(ops) and length(ops) <= 8 ->
        if Enum.all?(ops, &is_binary/1), do: {:ok, {:ops, ops}}, else: {:error, :bad_caveat}

      {:ok, [1002, %CBOR.Tag{tag: :bytes, value: t}]} when byte_size(t) == 32 ->
        {:ok, {:key, t}}

      {:ok, [11, loc, %CBOR.Tag{tag: :bytes, value: vk}, %CBOR.Tag{tag: :bytes, value: ticket}]}
      when is_binary(loc) ->
        {:ok, {:third, loc, vk, ticket}}

      {:ok, [type | _]} when is_integer(type) ->
        {:error, {:unknown_caveat, type}}

      _ ->
        {:error, :bad_caveat}
    end
  end

  # An operation is allowed only if the minter said so: a `1005` caveat before the third-party link names it. A holder
  # appends caveats after that link, and those can only narrow, so one added to a token that had none grants nothing.
  defp require_op(_, nil), do: :ok

  defp require_op(cs, op) do
    minted = Enum.take_while(cs, &(elem(&1, 0) != :sep))

    granted =
      Enum.any?(minted, fn
        {kind, v} -> kind == :ops and op in v
        _ -> false
      end)

    if granted, do: :ok, else: {:error, :op_not_allowed}
  end

  defp require_all(cs) do
    has = fn k -> Enum.any?(cs, &(elem(&1, 0) == k)) end

    cond do
      not has.(:window) -> {:error, :no_validity_window}
      not (has.(:room) or has.(:rooms)) -> {:error, :no_room}
      not has.(:key) -> {:error, :no_key}
      true -> :ok
    end
  end

  defp evaluate(cs, %{room: room, thumbprint: thumb, now: now} = ctx) do
    op = Map.get(ctx, :op)

    Enum.reduce_while(cs, :ok, fn
      {:sep}, _ -> {:cont, :ok}
      {:ops, _}, _ when op == nil -> {:cont, :ok}
      {:ops, ops}, _ -> if op in ops, do: {:cont, :ok}, else: {:halt, {:error, :op_not_allowed}}
      {:window, nb, na}, _ when now >= nb and now <= na -> {:cont, :ok}
      {:window, _, _}, _ -> {:halt, {:error, :expired}}
      {:room, _}, _ when room == :none -> {:cont, :ok}
      {:rooms, _}, _ when room == :none -> {:cont, :ok}
      {:room, r}, _ -> if r == room, do: {:cont, :ok}, else: {:halt, {:error, :wrong_room}}
      {:rooms, rs}, _ -> if room in rs, do: {:cont, :ok}, else: {:halt, {:error, :wrong_room}}
      {:key, t}, _ -> if equal?(t, thumb), do: {:cont, :ok}, else: {:halt, {:error, :wrong_key}}
    end)
  end

  # ---- encoding ----

  defp enc(term), do: CBOR.encode(term)
  defp bytes(b) when is_binary(b), do: %CBOR.Tag{tag: :bytes, value: b}
  defp rand(n), do: :crypto.strong_rand_bytes(n)
  defp hmac(key, msg), do: :crypto.mac(:hmac, :sha256, key, msg)

  defp equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp equal?(_, _), do: false

  # Decode, then require that re-encoding gives the same bytes. That refuses trailing data, non-minimal
  # integers, indefinite lengths and any other encoding that is not the deterministic one.
  defp strict_decode(bin) when is_binary(bin) do
    case CBOR.decode(bin) do
      {:ok, term, ""} -> if enc(term) == bin, do: {:ok, term}, else: {:error, :not_deterministic}
      {:ok, _, _} -> {:error, :trailing_bytes}
      _ -> {:error, :bad_token}
    end
  end

  defp strict_decode(_), do: {:error, :bad_token}

  defp strict_decode_bytes(%CBOR.Tag{tag: :bytes, value: v}), do: strict_decode(v)
  defp strict_decode_bytes(_), do: {:error, :bad_token}

  defp decode_inner({:ok, bin}), do: strict_decode(bin)
  defp decode_inner(other), do: other

  # ---- sealed boxes (ChaCha20-Poly1305; the key is 32 bytes) ----

  defp seal(pt, key, aad) do
    nonce = rand(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, pt, aad, true)
    nonce <> ct <> tag
  end

  defp unseal(<<nonce::binary-size(12), rest::binary>>, key, aad) when byte_size(rest) >= 16 do
    n = byte_size(rest) - 16
    <<ct::binary-size(^n), tag::binary-size(16)>> = rest

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, ct, aad, tag, false) do
      pt when is_binary(pt) -> {:ok, pt}
      _ -> {:error, :bad_box}
    end
  end

  defp unseal(_, _, _), do: {:error, :bad_box}
end
