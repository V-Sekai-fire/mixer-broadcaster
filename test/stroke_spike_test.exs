# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.StrokeSpikeTest do
  @moduledoc """
  Relay spike (issue #34): what one player builds, every player sees, in one room with several pens.

  Three pens join one room over HTTP/3 WebTransport and each publish 20 strokes at the same time. A stroke is a small
  mesh named by its digest and posed as an entity (a 100-byte packet, class mesh). Headless Elixir pens stand in for
  the Wings3D, Godot and Babylon.js clients, which are not built yet (#26, #27); the relay cannot tell them apart.

  GOLDEN: after the strokes every pen holds 60 entities, and each one's pose bytes equal the publisher's (the relay's
  own clock field, bytes 40..47, is the one thing it rewrites).
  INVARIANT: the same holds for every round, with random poses and random timing.
  CONTROL: a client in another room sees no entity; a late joiner sees all 60; and the comparison itself is shown to
  fail when one pose byte is flipped, so the check cannot pass vacuously.

  The numbers it prints (median and worst time from a stroke leaving a pen to the last pen holding it, bytes per
  stroke) are the ones the issue asks for.
  """
  use ExUnit.Case, async: false

  alias MixerBroadcaster.{Auth, Client, Serve, Token}

  @moduletag timeout: 300_000
  @pens 3
  @strokes 20
  @rounds String.to_integer(System.get_env("SPIKE_ROUNDS") || "5")
  @class_mesh 4

  # ---------------------------------------------------------------- the relay and its players

  defp start_relay do
    root = :crypto.strong_rand_bytes(32)
    name = :"spike_#{System.unique_integer([:positive])}"

    {:ok, %{port: port}} =
      Serve.start(
        %{"MB_ROOT_KEY" => Base.encode16(root), "MB_WT_PORT" => "0", "MB_BIND" => "127.0.0.1"},
        name: name
      )

    cert = Path.join([System.tmp_dir!(), "mb_relay_cert", "cert.pem"])
    %{root: root, port: port, cert: cert, name: name}
  end

  defp player(relay, room) do
    {pub, priv} = Auth.generate_key()
    tp = :crypto.strong_rand_bytes(32)
    token = Token.issue(relay.root, [room], "minter", tp, [])
    {:ok, full} = Token.discharge(token, tp, Auth.thumbprint(pub), 3600, System.os_time(:second))
    %{pub: pub, priv: priv, token: full}
  end

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp recv_fin(session, stream, acc \\ <<>>) do
    receive do
      {:webtransport, ^session, {:stream, ^stream, :bidi, d}} ->
        recv_fin(session, stream, acc <> d)

      {:webtransport, ^session, {:stream_fin, ^stream, :bidi, d}} ->
        {:ok, acc <> d}
    after
      4_000 -> {:error, :timeout}
    end
  end

  defp ask(session, msg) do
    {:ok, stream} = Client.send_reliable(session, JSON.encode!(msg))
    {:ok, body} = recv_fin(session, stream)
    JSON.decode!(body)
  end

  # connect to the room and pass the door; the calling process owns the session and gets its datagrams
  defp join(relay, room) do
    p = player(relay, room)
    {:ok, s} = Client.connect("localhost", relay.port, "/room/#{room}", cacertfile: relay.cert)
    %{"nonce" => n} = ask(s, %{t: "hello"})
    sig = Auth.sign(p.priv, room, Base.url_decode64!(n, padding: false))
    %{"t" => "ready"} = ask(s, %{t: "auth", token: b64(p.token), key: b64(p.pub), sig: b64(sig)})
    s
  end

  # ---------------------------------------------------------------- a stroke

  # A stroke is a ribbon: 16 points along a random curve, two vertices each, as float32 positions and uint32 indices.
  defp stroke_mesh do
    pts = for i <- 0..15, do: {i * 0.05, :rand.uniform() * 0.2, :rand.uniform() * 0.2}

    verts =
      for {x, y, z} <- pts,
          dy <- [0.0, 0.01],
          into: <<>>,
          do: <<x::float-32, y + dy::float-32, z::float-32>>

    idx = for i <- 0..14, t <- [[0, 1, 2], [2, 1, 3]], j <- t, into: <<>>, do: <<2 * i + j::32>>
    verts <> idx
  end

  # 100 bytes: id (4), pose (4..39), relay clock (40..47), 48..50 zero, class (51), mesh digest (62..93).
  defp stroke_packet(gid, mesh) do
    pose = :crypto.strong_rand_bytes(36)
    digest = :crypto.hash(:sha256, mesh)

    <<gid::little-32, pose::binary, 0::64, 0::24, @class_mesh, 0::unit(8)-size(10),
      digest::binary, 0::48>>
  end

  # the relay rewrites only its clock, bytes 40..47
  defp same_pose?(
         <<a::binary-size(40), _::binary-size(8), a2::binary>>,
         <<b::binary-size(40), _::binary-size(8), b2::binary>>
       ),
       do: a == b and a2 == b2

  defp same_pose?(_, _), do: false

  # ---------------------------------------------------------------- a pen

  # The pen's own process owns the session, so it is the one that hears the room. It reports ready, waits for `:go`,
  # sends its strokes from a second process while it keeps listening, and returns every entity it heard with the time.
  defp pen(relay, room, idx, parent, sent) do
    spawn_link(fn ->
      s = join(relay, room)
      send(parent, {:ready, self()})
      receive do: (:go -> :ok)

      sender =
        Task.async(fn ->
          for k <- 1..@strokes do
            mesh = stroke_mesh()
            pkt = stroke_packet(idx * 1000 + k, mesh)
            t0 = System.monotonic_time(:nanosecond)
            :ok = Client.send_unreliable(s, pkt)
            :ets.insert(sent, {idx * 1000 + k, t0, pkt, byte_size(mesh)})
            Process.sleep(:rand.uniform(10))
          end

          :done
        end)

      heard = listen(s, %{}, sender)
      send(parent, {:heard, idx, heard})
      Client.close(s)
    end)
  end

  # drain datagrams with their arrival time until the sender is done and the room has been quiet for 600 ms
  defp listen(s, heard, sender, done? \\ false) do
    case Client.recv_unreliable(s, if(done?, do: 600, else: 20)) do
      {:ok, <<gid::little-32, _::binary>> = pkt} when byte_size(pkt) == 100 ->
        t = System.monotonic_time(:nanosecond)
        listen(s, Map.put_new(heard, gid, {pkt, t}), sender, done?)

      {:ok, _other} ->
        listen(s, heard, sender, done?)

      {:error, :timeout} ->
        cond do
          done? -> heard
          match?({:ok, _}, Task.yield(sender, 0)) -> listen(s, heard, sender, true)
          true -> listen(s, heard, sender, false)
        end
    end
  end

  defp drain(s, acc \\ %{}) do
    case Client.recv_unreliable(s, 1_500) do
      {:ok, <<gid::little-32, _::binary>> = pkt} when byte_size(pkt) == 100 ->
        drain(s, Map.put(acc, gid, pkt))

      {:ok, _} ->
        drain(s, acc)

      {:error, :timeout} ->
        acc
    end
  end

  # ---------------------------------------------------------------- a round

  defp run_round(relay, i) do
    room = "spike-#{i}-#{System.unique_integer([:positive])}"
    sent = :ets.new(:sent, [:public, :set])
    outsider = join(relay, "elsewhere-#{i}-#{System.unique_integer([:positive])}")

    pens = for idx <- 1..@pens, do: pen(relay, room, idx, self(), sent)
    for _ <- pens, do: receive(do: ({:ready, _} -> :ok))
    for p <- pens, do: send(p, :go)

    heard = for _ <- pens, into: %{}, do: receive(do: ({:heard, idx, h} -> {idx, h}))

    published =
      Map.new(:ets.tab2list(sent), fn {gid, t0, pkt, size} -> {gid, {t0, pkt, size}} end)

    late = join(relay, room)
    late_heard = drain(late)
    outsider_heard = drain(outsider)
    Client.close(late)
    Client.close(outsider)

    %{published: published, heard: heard, late: late_heard, outsider: outsider_heard, room: room}
  end

  test "spike #34: three pens, one room, every player sees every stroke" do
    {:ok, _} = Application.ensure_all_started(:mixer_broadcaster)
    Logger.configure(level: :error)
    relay = start_relay()
    on_exit(fn -> MixerBroadcaster.Server.stop(relay.name) end)

    # CONTROL for the comparison: one flipped pose byte must be reported as different, a changed clock must not
    p = stroke_packet(1, "x")
    <<pre::binary-size(10), b, post::binary>> = p
    assert same_pose?(p, p)
    refute same_pose?(p, pre <> <<Bitwise.bxor(b, 1)>> <> post)
    <<head::binary-size(40), _::binary-size(8), tail::binary>> = p
    assert same_pose?(p, head <> <<9::64>> <> tail)

    rounds = for i <- 1..@rounds, do: run_round(relay, i)

    for {r, n} <- Enum.with_index(rounds, 1) do
      total = @pens * @strokes
      assert map_size(r.published) == total

      # GOLDEN / INVARIANT: every pen ends with all 60 entities at the publisher's poses
      for {idx, h} <- r.heard do
        mine = for {gid, _} <- r.published, div(gid, 1000) == idx, do: gid
        others = Map.keys(r.published) -- mine
        missing = for gid <- others, not Map.has_key?(h, gid), do: gid
        assert missing == [], "round #{n}: pen #{idx} never received #{inspect(missing)}"

        for gid <- others do
          {pkt, _} = h[gid]
          {_, orig, _} = r.published[gid]
          assert same_pose?(pkt, orig), "round #{n}: pen #{idx} has a different pose for #{gid}"
        end
      end

      # a late joiner sees all 60 at the same poses
      assert map_size(r.late) == total,
             "round #{n}: late joiner saw #{map_size(r.late)} of #{total}"

      for {gid, pkt} <- r.late, do: assert(same_pose?(pkt, elem(r.published[gid], 1)))

      # CONTROL: a client outside the room sees none
      assert r.outsider == %{}
      assert length(MixerBroadcaster.Rooms.entities(r.room)) == total
    end

    # numbers
    lat =
      for r <- rounds, {gid, {t0, _, _}} <- r.published do
        arrivals = for {idx, h} <- r.heard, div(gid, 1000) != idx, do: elem(h[gid], 1)
        (Enum.max(arrivals) - t0) / 1_000_000
      end
      |> Enum.sort()

    median = Enum.at(lat, div(length(lat), 2))
    worst = List.last(lat)
    mesh_sizes = for r <- rounds, {_, {_, _, size}} <- r.published, do: size
    mesh_avg = Enum.sum(mesh_sizes) / length(mesh_sizes)

    IO.puts("""

    spike #34: #{@rounds} rounds x #{@pens} pens x #{@strokes} strokes = #{length(lat)} strokes
      every pen ended with #{@pens * @strokes} entities at the publisher's poses; late joiner saw #{@pens * @strokes}; outsider saw 0
      stroke end to last pen holding it: median #{Float.round(median, 2)} ms, worst #{Float.round(worst, 2)} ms
      bytes per stroke through the relay: 100 up, #{100 * (@pens - 1)} down to the other pens (+100 to each late joiner)
      bytes per stroke mesh (by digest, outside the relay): #{round_int(mesh_avg)}
    """)
  end

  defp round_int(f), do: f |> Float.round() |> trunc()
end
