# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mixer.Caibx do
  @moduledoc """
  Reads the chunk ids out of a desync index (`.caibx`), so the relay can presign each chunk of a mesh for a client.

  Layout (all little endian): a 48 byte index header (`size = 48`, type `0x96824d9c7b129ff9`, flags, three chunk size
  limits), a table header (`size = 0xffffffffffffffff`, type `0xe75b9e112f17417d`), then 40 byte items (end offset,
  32 byte chunk id) until an item whose offset is 0, then a tail. Nothing here raises: bad input is `{:error, :bad_index}`.
  """

  @max_chunks 100_000
  @index_type 0x96824D9C7B129FF9
  @table_type 0xE75B9E112F17417D

  @spec chunk_ids(binary()) :: {:ok, [binary()]} | {:error, :bad_index}
  def chunk_ids(
        <<48::little-64, @index_type::little-64, _flags::little-64, _min::little-64,
          _avg::little-64, _max::little-64, 0xFFFFFFFFFFFFFFFF::little-64, @table_type::little-64,
          items::binary>>
      ),
      do: items(items, [], 0)

  def chunk_ids(_), do: {:error, :bad_index}

  defp items(_, _, n) when n > @max_chunks, do: {:error, :bad_index}
  # a zero offset ends the table; there must be one
  defp items(<<0::little-64, _::binary>>, acc, _), do: {:ok, Enum.reverse(acc)}

  defp items(<<_off::little-64, id::binary-size(32), rest::binary>>, acc, n),
    do: items(rest, [id | acc], n + 1)

  defp items(_, _, _), do: {:error, :bad_index}

  @doc "The object key of a chunk in the store: `chunks/<first four hex>/<hex>.cacnk`."
  @spec chunk_key(<<_::256>>) :: String.t()
  def chunk_key(<<_::binary-size(32)>> = id) do
    hex = Base.encode16(id, case: :lower)
    "chunks/" <> binary_part(hex, 0, 4) <> "/" <> hex <> ".cacnk"
  end

  @doc "The object key of an index: `index/<hex of its SHA-256>.caibx`."
  @spec index_key(<<_::256>>) :: String.t()
  def index_key(<<_::binary-size(32)>> = digest),
    do: "index/" <> Base.encode16(digest, case: :lower) <> ".caibx"
end
