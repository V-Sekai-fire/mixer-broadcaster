# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.MeshTest do
  @moduledoc """
  GOLDEN: the desync index of a real mesh parses to its chunk id; the presigned query is pinned (the same algorithm,
  with real keys, was accepted by SeaweedFS and its tampered, expired and wrong-object variants refused); a player whose
  token carries "read" gets URLs for the index and every chunk of a mesh a pose in its room names.
  INVARIANT: an index built from any chunk ids parses back to them; garbage never raises; any change to a signed part
  changes the signature.
  CONTROL: no token, no read right, a right narrowed away, a digest nobody posted in this room, a digest posted in
  another room, a bad digest and a store that fails are all refused, and refusals read the same.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Auth, Hub, Rooms, Token}
  alias MixerBroadcaster.Mixer.Caibx
  alias MixerBroadcaster.Mixer.Store.S3

  @cube File.read!(Path.join(__DIR__, "fixtures/cube.caibx"))
  @cube_digest :crypto.hash(:sha256, @cube)
  @cube_chunk Base.decode16!("ED5CCA874632B32B5E127AB6F2BFAC4211ED7DDB050899C6CA014776A77B6B3F")

  # ---- a store that holds the cube and signs nothing real ----
  defmodule FakeBlobs do
    def object(key) do
      if key ==
           Caibx.index_key(
             :crypto.hash(:sha256, File.read!(Path.join(__DIR__, "fixtures/cube.caibx")))
           ),
         do: {:ok, File.read!(Path.join(__DIR__, "fixtures/cube.caibx"))},
         else: {:error, :not_found}
    end

    def presign_get(key, ttl), do: {:ok, "https://s3.test/#{key}?ttl=#{ttl}"}
  end

  # a store that answers the index key with another (valid) index
  defmodule SwappedBlobs do
    def object(_key) do
      {:ok, f} = File.read(Path.join(__DIR__, "fixtures/cube.caibx"))
      # change the chunk id: still a well formed index, but not the one the digest names
      {:ok,
       binary_part(f, 0, 72) <> :binary.copy(<<7>>, 32) <> binary_part(f, 104, byte_size(f) - 104)}
    end

    def presign_get(key, ttl), do: {:ok, "https://s3.test/#{key}?ttl=#{ttl}"}
  end

  defmodule BrokenBlobs do
    def object(_), do: {:error, :down}
    def presign_get(_, _), do: {:error, :no_s3_keys}
  end

  # ---- the index format ----

  defp index(ids) do
    items = for id <- ids, into: <<>>, do: <<1::little-64, id::binary>>

    <<48::little-64, 0x96824D9C7B129FF9::little-64, 0::little-64, 0::little-64, 0::little-64,
      0::little-64, 0xFFFFFFFFFFFFFFFF::little-64, 0xE75B9E112F17417D::little-64, items::binary,
      0::little-128, 0::little-64>>
  end

  test "golden: the real cube index lists its one chunk" do
    assert Caibx.chunk_ids(@cube) == {:ok, [@cube_chunk]}

    assert Caibx.chunk_key(@cube_chunk) ==
             "chunks/ed5c/ed5cca874632b32b5e127ab6f2bfac4211ed7ddb050899c6ca014776a77b6b3f.cacnk"

    assert Caibx.index_key(@cube_digest) ==
             "index/d4b2adf7954e043a95a7946b7e9a91b7fe49e96e2bc3d7a483f1cca0f735294e.caibx"
  end

  property "an index built from any chunk ids parses back to them" do
    check all(ids <- list_of(binary(length: 32), max_length: 40)) do
      assert Caibx.chunk_ids(index(ids)) == {:ok, ids}
    end
  end

  property "garbage and cut indexes never raise and never invent chunks" do
    check all(
            junk <- binary(max_length: 400),
            ids <- list_of(binary(length: 32), min_length: 1, max_length: 5)
          ) do
      assert match?({:ok, _}, Caibx.chunk_ids(junk)) or
               Caibx.chunk_ids(junk) == {:error, :bad_index}

      full = index(ids)
      cut = 64 + 40 * length(ids)
      # any cut inside the table (before its terminator) is refused
      for n <- 0..(cut - 1),
          do: assert(Caibx.chunk_ids(binary_part(full, 0, n)) == {:error, :bad_index})
    end
  end

  test "control: a wrong header type is refused" do
    <<a::binary-size(8), _::binary-size(8), rest::binary>> = index([@cube_chunk])
    assert Caibx.chunk_ids(a <> <<0::little-64>> <> rest) == {:error, :bad_index}
  end

  # ---- the presigned query ----

  @now ~U[2026-11-16 12:00:00Z]
  @keys {"AKID", "SECRET"}

  test "golden: the presigned query for fixed inputs" do
    assert S3.presign_query("GET", "127.0.0.1:8333", "/mixer/index/ab.caibx", 300, @keys, @now) ==
             "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKID%2F20261116%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261116T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=e023b9b496bf864c9ae319ab451264d7f6593b571649a924a9c6915ae53a1b35"
  end

  property "the signature depends on the method, host, path, lifetime, key and time" do
    check all(path <- string(:alphanumeric, min_length: 1), ttl <- integer(1..3600)) do
      p = "/mixer/" <> path
      sig = fn m, h, pa, t, k, n -> S3.presign_query(m, h, pa, t, k, n) end
      base = sig.("GET", "h:1", p, ttl, @keys, @now)
      assert base == sig.("GET", "h:1", p, ttl, @keys, @now)
      refute base == sig.("PUT", "h:1", p, ttl, @keys, @now)
      refute base == sig.("GET", "h:2", p, ttl, @keys, @now)
      refute base == sig.("GET", "h:1", p <> "x", ttl, @keys, @now)
      refute base == sig.("GET", "h:1", p, ttl + 1, @keys, @now)
      refute base == sig.("GET", "h:1", p, ttl, {"AKID", "OTHER"}, @now)
      refute base == sig.("GET", "h:1", p, ttl, @keys, DateTime.add(@now, 1))
    end
  end

  # ---- a player asking for a mesh ----

  setup do
    root = :crypto.strong_rand_bytes(32)
    tp = :crypto.strong_rand_bytes(32)
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: root})
    Application.put_env(:mixer_broadcaster, :blob_access, FakeBlobs)

    on_exit(fn ->
      Application.delete_env(:mixer_broadcaster, :auth)
      Application.delete_env(:mixer_broadcaster, :blob_access)
    end)

    %{root: root, tp: tp, room: "mesh-#{System.unique_integer([:positive])}"}
  end

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp reply(state, msg) do
    {:ok, st, [{:send, _, body, :fin} | _]} =
      Hub.handle_stream(0, :bidi, JSON.encode!(msg), state)

    {st, JSON.decode!(body)}
  end

  # an admitted session in `room` with a token for `rooms` carrying `ops`
  defp admitted(c, room, rooms, ops, narrow \\ nil) do
    {pub, priv} = Auth.generate_key()
    t = Token.issue(c.root, rooms, "minter", c.tp, ops)
    {:ok, full} = Token.discharge(t, c.tp, Auth.thumbprint(pub), 3600, System.os_time(:second))

    full =
      if narrow do
        {:ok, n} = Token.restrict_ops(full, narrow)
        n
      else
        full
      end

    state = elem(Hub.init(nil, %{path: "/room/#{room}"}, []), 1)
    {state, %{"nonce" => n}} = reply(state, %{t: "hello"})
    nonce = Base.url_decode64!(n, padding: false)

    {state, %{"t" => "ready"}} =
      reply(state, %{
        t: "auth",
        token: b64(full),
        key: b64(pub),
        sig: b64(Auth.sign(priv, room, nonce))
      })

    state
  end

  # a pose whose payload names `digest` (class `class`)
  defp pose(room, gid, digest, class \\ 4) do
    pkt =
      <<gid::little-32, 0::unit(8)-size(44), 0::little-24, class, 0::unit(8)-size(10),
        digest::binary, 0::48>>

    100 = byte_size(pkt)
    Rooms.put_entity(room, pkt)
  end

  defp ask(state, digest),
    do: elem(reply(state, %{t: "mesh", digest: Base.encode16(digest, case: :lower)}), 1)

  @denied %{"t" => "error", "reason" => "denied"}

  test "golden: a reader gets URLs for the index and every chunk of a posted mesh", c do
    pose(c.room, 1, @cube_digest)
    st = admitted(c, c.room, c.room, ["read"])

    assert %{"t" => "mesh", "expires" => 300, "index" => idx, "chunks" => [chunk]} =
             ask(st, @cube_digest)

    assert idx == "https://s3.test/#{Caibx.index_key(@cube_digest)}?ttl=300"
    assert chunk == "https://s3.test/#{Caibx.chunk_key(@cube_chunk)}?ttl=300"
  end

  test "control: a token without read is refused", c do
    pose(c.room, 1, @cube_digest)
    assert ask(admitted(c, c.room, c.room, []), @cube_digest) == @denied
  end

  test "control: a read right the holder narrowed away is refused", c do
    pose(c.room, 1, @cube_digest)
    assert ask(admitted(c, c.room, c.room, ["read"], []), @cube_digest) == @denied
  end

  test "control: a digest nobody posted in this room is refused", c do
    st = admitted(c, c.room, c.room, ["read"])
    assert ask(st, @cube_digest) == @denied
    assert ask(st, :crypto.strong_rand_bytes(32)) == @denied
  end

  test "control: a digest posted in another room is refused, even for a token that covers both",
       c do
    other = c.room <> "-other"
    pose(other, 1, @cube_digest)
    st = admitted(c, c.room, [c.room, other], ["read"])
    assert ask(st, @cube_digest) == @denied
  end

  test "control: a command packet's bytes are not a mesh digest", c do
    pose(c.room, 1, @cube_digest, 128)
    assert ask(admitted(c, c.room, c.room, ["read"]), @cube_digest) == @denied
  end

  test "control: a bad digest and an all-zero digest are refused", c do
    pose(c.room, 1, @cube_digest)
    st = admitted(c, c.room, c.room, ["read"])
    assert elem(reply(st, %{t: "mesh", digest: "zz"}), 1) == @denied
    assert elem(reply(st, %{t: "mesh", digest: "abcd"}), 1) == @denied
    assert ask(st, <<0::256>>) == @denied
  end

  test "control: the open demo hub (no tokens) is refused", c do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    pose(c.room, 1, @cube_digest)
    st = elem(Hub.init(nil, %{path: "/room/#{c.room}"}, []), 1)
    assert ask(st, @cube_digest) == @denied
  end

  test "control: an index that does not hash to the digest is not served", c do
    pose(c.room, 1, @cube_digest)
    st = admitted(c, c.room, c.room, ["read"])
    Application.put_env(:mixer_broadcaster, :blob_access, SwappedBlobs)
    assert ask(st, @cube_digest) == %{"t" => "error", "reason" => "unavailable"}
  end

  test "control: a failing store is `unavailable`, not a crash", c do
    pose(c.room, 1, @cube_digest)
    st = admitted(c, c.room, c.room, ["read"])
    Application.put_env(:mixer_broadcaster, :blob_access, BrokenBlobs)
    assert ask(st, @cube_digest) == %{"t" => "error", "reason" => "unavailable"}
  end
end
