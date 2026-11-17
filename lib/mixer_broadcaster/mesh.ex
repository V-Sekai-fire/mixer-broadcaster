# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mesh do
  @moduledoc """
  A client asks `{"t":"mesh","digest":"<hex>"}` and, if it may, gets short-lived presigned S3 URLs for the mesh's desync
  index and every chunk the index lists: `{"t":"mesh","expires":300,"index":url,"chunks":[url, ...]}`. The bucket stays
  closed; the URLs are the only way a client without keys reads it.

  It answers only when ALL of these hold, and every refusal reads the same (`denied`) so a client learns nothing about
  which one failed:
    * the session was admitted with a token (the open demo hub has none);
    * that token carries the `"read"` operation for this session's room (macaroon caveat 1005);
    * a pose in this room names that digest.

  `config :mixer_broadcaster, :blob_access, Module` swaps the store for tests; the module has `object/1` and
  `presign_get/2`, as `MixerBroadcaster.Mixer.Store.S3` does.
  """
  alias MixerBroadcaster.{Auth, Rooms}
  alias MixerBroadcaster.Mixer.Caibx

  @ttl 300
  @max_chunks 2000

  @denied ~s({"t":"error","reason":"denied"})

  @spec ttl() :: pos_integer()
  def ttl, do: @ttl

  @budget 900

  @doc """
  A mesh reply cut into pieces that each fit one datagram (about `@budget` bytes of JSON). The first piece is the reply
  itself with as many chunk URLs as fit, plus `"n"`, how many there are in all; each later piece is
  `{"t":"mesh_more","digest":hex,"from":k,"chunks":[...]}`. Anything that is not a mesh reply, or already fits, comes
  back as it is. A single URL longer than the budget still goes out alone.
  """
  def split(reply, budget \\ @budget) when is_binary(reply) do
    with true <- byte_size(reply) > budget,
         {:ok, %{"t" => "mesh", "chunks" => urls} = head} <- JSON.decode(reply) do
      {first, rest} = take(urls, Map.put(head, "n", length(urls)), budget)

      [
        JSON.encode!(Map.put(Map.put(head, "n", length(urls)), "chunks", first))
        | more(rest, head["digest"], length(first), budget)
      ]
    else
      _ -> [reply]
    end
  end

  # The first piece carries the index URL, which is long: it takes chunk URLs only while the whole piece still fits the
  # budget, and none at all when the index URL alone leaves no room (the later pieces carry them).
  defp take(urls, head, budget) do
    size = byte_size(JSON.encode!(Map.put(head, "chunks", [])))
    {part, rest} = fit(urls, [], size, budget)

    case part do
      [first | _] when size + byte_size(first) + 3 > budget -> {[], urls}
      _ -> {part, rest}
    end
  end

  defp more([], _digest, _from, _budget), do: []

  defp more(urls, digest, from, budget) do
    base = %{"t" => "mesh_more", "digest" => digest, "from" => from}
    {part, rest} = fit(urls, [], byte_size(JSON.encode!(Map.put(base, "chunks", []))) + 8, budget)

    [
      JSON.encode!(Map.put(base, "chunks", part))
      | more(rest, digest, from + length(part), budget)
    ]
  end

  # take URLs while the piece stays within the budget; always at least one, so the split ends
  defp fit([], acc, _size, _budget), do: {Enum.reverse(acc), []}

  defp fit([url | rest] = all, acc, size, budget) do
    cost = byte_size(url) + 3

    if acc != [] and size + cost > budget,
      do: {Enum.reverse(acc), all},
      else: fit(rest, [url | acc], size + cost, budget)
  end

  @doc "The reply for a mesh request from `state` (a hub session). Never raises."
  @spec grant(term(), term()) :: String.t()
  def grant(%{token: token, thumb: thumb, room: room, mode: mode}, hex)
      when is_binary(token) and is_binary(thumb) and is_binary(hex) do
    with {:ok, digest} <- Base.decode16(hex, case: :mixed),
         32 <- byte_size(digest),
         true <- Auth.allows?(mode, token, thumb, room, "read", System.os_time(:second)),
         true <- digest in Rooms.mesh_digests(room),
         {:ok, reply} <- urls(digest) do
      JSON.encode!(reply)
    else
      {:error, :unavailable} -> ~s({"t":"error","reason":"unavailable"})
      _ -> @denied
    end
  end

  def grant(_state, _hex), do: @denied

  defp store,
    do: Application.get_env(:mixer_broadcaster, :blob_access, MixerBroadcaster.Mixer.Store.S3)

  defp urls(digest) do
    with {:ok, index} <- store().object(Caibx.index_key(digest)),
         true <- :crypto.hash(:sha256, index) == digest or {:error, :unavailable},
         {:ok, ids} <- Caibx.chunk_ids(index),
         true <- length(ids) <= @max_chunks or {:error, :unavailable},
         {:ok, index_url} <- store().presign_get(Caibx.index_key(digest), @ttl),
         {:ok, chunk_urls} <- all(ids) do
      {:ok,
       %{
         t: "mesh",
         digest: Base.encode16(digest, case: :lower),
         expires: @ttl,
         index: index_url,
         chunks: chunk_urls
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp all(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case store().presign_get(Caibx.chunk_key(id), @ttl) do
        {:ok, url} -> {:cont, {:ok, [url | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> {:error, :unavailable}
    end
  end
end
