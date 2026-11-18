# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Command do
  @moduledoc """
  A command as one 100-byte packet of class `command` (128), as contract-entity-packet (`EntityPacket/Classes.lean`) defines it.

  A command has no pose, so its data uses the bytes a pose would: bytes 4..39 then 56..97, read as one run of 78.
  `gid` is the command's key, `class_owner` is `(128 << 24) | owner`, `sub_index` is `(used << 16) | type`.
  The run's byte 0 is the mode: 0 inline (the next `used - 1` bytes are the data, up to 77), 1 by digest (32 bytes of
  digest then a u24 length; the data is in the chunk store). Unused bytes are zero; the wire is zstd and run-length
  coded, so they cost almost nothing.

  Nothing here raises: a malformed packet is `{:error, reason}`.
  """

  @size 100
  @class 128
  @pose 210
  @run 78
  @inline_max 77
  @max_bulk 0xFFFFFF

  @index_mark "mixer-index:"

  @doc """
  Data over `@max_bulk` bytes does not go in the chunk store whole: the sender chunks it with desync and the packet
  names the index (mode 2: the SHA-256 of the desync index, as a mesh is named). The relay never reads that data, so
  inside it a mode 2 command is carried as `index(digest, key)`: this marker, the 32 byte digest and the command's key
  (this is not a credential. The key came from the data, which the relay never sees, and must survive so a newer command still replaces an older one). `pack/5` turns the
  marker back into mode 2, and `unpack/2` makes it from mode 2.
  """
  @spec index(<<_::256>>, non_neg_integer()) :: binary()
  def index(<<_::binary-size(32)>> = digest, key) when key in 0..0xFFFFFFFF,
    do: <<@index_mark, digest::binary, key::little-32>>

  @spec index?(binary()) :: boolean()
  def index?(<<@index_mark, _::binary-size(32), _::little-32>>), do: true
  def index?(_), do: false

  @spec size() :: pos_integer()
  def size, do: @size
  @spec inline_max() :: pos_integer()
  def inline_max, do: @inline_max

  @doc "The key two commands share when the newer should replace the older: type and the data's leading string."
  @spec key(non_neg_integer(), binary()) :: non_neg_integer()
  def key(type, data) do
    lead =
      case data do
        <<n::little-32, s::binary-size(n), _::binary>> when n > 0 -> s
        _ -> <<>>
      end

    <<k::little-32, _::binary>> = :crypto.hash(:sha256, <<type::little-16, lead::binary>>)
    k
  end

  @doc """
  A command as 100 bytes. `store` is called with the data only when it does not fit inside the packet, and must
  return its 32-byte digest.
  """
  @spec pack(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer(), (binary() ->
                                                                                   binary())) ::
          {:ok, binary()} | {:error, atom()}
  def pack(type, data, owner, hlc, store)
      when is_integer(type) and is_binary(data) and is_integer(owner) and is_integer(hlc) and
             is_function(store, 1) do
    cond do
      type < 1 or type > 0xFFFF or type == @pose ->
        {:error, :bad_type}

      owner < 0 or owner >= 0x1000000 ->
        {:error, :bad_owner}

      hlc < 0 or hlc >= Bitwise.bsl(1, 64) ->
        {:error, :bad_hlc}

      index?(data) ->
        <<@index_mark, digest::binary-size(32), key::little-32>> = data
        {:ok, build(type, owner, hlc, key, <<2, digest::binary>>, 33)}

      byte_size(data) <= @inline_max ->
        {:ok, build(type, owner, hlc, key(type, data), <<0, data::binary>>, 1 + byte_size(data))}

      byte_size(data) > @max_bulk ->
        {:error, :too_large}

      true ->
        bulk(type, owner, hlc, data, store.(data))
    end
  end

  defp bulk(type, owner, hlc, data, <<digest::binary-size(32)>>),
    do:
      {:ok,
       build(
         type,
         owner,
         hlc,
         key(type, data),
         <<1, digest::binary, byte_size(data)::little-24>>,
         36
       )}

  defp bulk(_, _, _, _, _), do: {:error, :bad_digest}

  defp build(type, owner, hlc, key, run, used) do
    <<a::binary-size(36), b::binary-size(42)>> = pad(run, @run)

    <<key::little-32, a::binary, hlc::little-64,
      Bitwise.bor(Bitwise.bsl(@class, 24), owner)::little-32,
      Bitwise.bor(Bitwise.bsl(used, 16), type)::little-32, b::binary, 0, 0>>
  end

  defp pad(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))

  @doc """
  `{:ok, %{type, owner, hlc, key, data}}`. `fetch` reads bulk data by digest: `{:ok, data}` or an error. The
  length the packet states must match what comes back.
  """
  @spec unpack(binary(), (binary() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, map()} | {:error, atom()}
  def unpack(
        <<key::little-32, a::binary-size(36), hlc::little-64, owner::little-24, class::8,
          type::little-16, used::little-16, b::binary-size(42), 0, 0>>,
        fetch
      )
      when is_function(fetch, 1) do
    run = a <> b

    cond do
      class != @class ->
        {:error, :not_a_command}

      type < 1 or type == @pose or used < 1 or used > @run ->
        {:error, :bad_header}

      :binary.part(run, used, @run - used) != :binary.copy(<<0>>, @run - used) ->
        {:error, :dirty_tail}

      true ->
        body(run, used, %{type: type, owner: owner, hlc: hlc, key: key}, fetch)
    end
  end

  def unpack(_, _), do: {:error, :bad_size}

  defp body(<<0, _::binary>> = run, used, meta, _fetch),
    do: {:ok, Map.put(meta, :data, binary_part(run, 1, used - 1))}

  defp body(<<1, digest::binary-size(32), len::little-24, _::binary>>, 36, meta, fetch)
       when len > @inline_max do
    case fetch.(digest) do
      {:ok, data} when byte_size(data) == len -> {:ok, Map.put(meta, :data, data)}
      {:ok, _} -> {:error, :wrong_length}
      _ -> {:error, :missing_bulk}
    end
  end

  defp body(<<2, digest::binary-size(32), _::binary>>, 33, meta, _fetch),
    do: {:ok, Map.put(meta, :data, index(digest, meta.key))}

  defp body(_, _, _, _), do: {:error, :bad_body}
end
