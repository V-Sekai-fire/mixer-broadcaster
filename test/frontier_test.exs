# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.FrontierTest do
  @moduledoc """
  Frontier learning over the relay's interface: does the code do what `spec/asyncapi.yaml` says, over real
  WebTransport, on the closed relay (`MB_SERVE=1`), with a minted token and a signed nonce for every client.

  Run it alone with `mix frontier` (no arguments). A level is a class of problem, ordered low to high (the door, the
  refusals, the chart, poses, meshes, commands, the demo's HTTP routes, configuration); a problem is one run of that
  class with random names and values, `FRONTIER_N` of them per level (default 8). Every problem runs inside
  `attempt/3`, which records pass or fail and never raises, so one run measures every level. The report lists the
  levels by regret, `1[s >= 1] - s/n`, highest first, and writes the ledger to `_build/frontier_ledger.json`.

  GOLDEN: every reply, datagram and command the relay sends fits its schema in the document, and every request the
  document describes is answered the way it says.
  INVARIANT: the same holds for random room names, chart patches, colours, poses and flows.
  CONTROL: refusals (no proof, another room's token, another key, a bad token, three failures, a browser origin) are
  part of the levels, and a planted wrong reply (`control_fails/0`) must fail the checker, so a level cannot pass
  vacuously. The run fails while any level is below n/n.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias MixerBroadcaster.{Auth, Client, Command, Serve, Token, Web}
  alias MixerBroadcaster.Mixer.{Store, Wire}

  @moduletag timeout: 600_000
  @spec_path Path.join([__DIR__, "..", "spec", "asyncapi.yaml"])
  @cube File.read!(Path.join(__DIR__, "fixtures/cube.caibx"))
  @cube_digest :crypto.hash(:sha256, @cube)
  @hex_digest Base.encode16(@cube_digest, case: :lower)
  @n String.to_integer(System.get_env("FRONTIER_N") || "8")

  setup :set_mox_global

  # ---------------------------------------------------------------- the ledger

  defp ledger_put(level, ok, reason),
    do:
      Agent.update(
        :frontier_ledger,
        &Map.update(&1, level, [{ok, reason}], fn l -> l ++ [{ok, reason}] end)
      )

  # one problem; never raises
  defp attempt(level, fun) do
    result =
      try do
        fun.()
        {true, nil}
      rescue
        e -> {false, e |> Exception.message() |> String.slice(0, 300)}
      catch
        kind, value -> {false, "#{kind}: #{inspect(value) |> String.slice(0, 300)}"}
      end

    ledger_put(level, elem(result, 0), elem(result, 1))
  end

  defp run_level(level, n, fun) do
    for i <- 0..(n - 1), do: attempt(level, fn -> fun.(i) end)
    :ok
  end

  # ---------------------------------------------------------------- the document

  defp resolve(doc, pointer),
    do: ExJsonSchema.Schema.resolve(%{"$ref" => pointer, "components" => doc["components"]})

  defp fits?(doc, schema, value),
    do: ExJsonSchema.Validator.valid?(resolve(doc, "#/components/schemas/#{schema}"), value)

  defp fits_payload?(doc, name, value),
    do:
      ExJsonSchema.Validator.valid?(resolve(doc, "#/components/messages/#{name}/payload"), value)

  defp must_fit(doc, schema, value) do
    if not fits?(doc, schema, value), do: flunk("#{inspect(value)} does not fit #{schema}")
    value
  end

  defp wire_messages(doc, from),
    do:
      for({n, m} <- doc["components"]["messages"], w = m["x-wire"], w["from"] == from, do: {n, w})

  defp message(doc, name), do: doc["components"]["messages"][name]

  defp enc("string", v), do: Wire.string(v)
  defp enc("bool", v), do: Wire.bool(v)
  defp enc("json", v), do: Wire.json(v)
  defp enc("raw", v), do: v
  defp enc("bytes", v), do: Base.decode16!(v, case: :lower)

  defp dec("string", bin), do: with({:ok, s, r} <- Wire.read_string(bin), do: {s, r})
  defp dec("bool", bin), do: with({:ok, b, r} <- Wire.read_bool(bin), do: {b, r})
  defp dec("json", bin), do: with({:ok, t, r} <- Wire.read_json(bin), do: {t, r})
  defp dec("raw", bin), do: {bin, <<>>}
  defp dec("bytes", bin), do: {Base.encode16(bin, case: :lower), <<>>}

  # a command packet from the document's own words
  defp pack(doc, name, payload) do
    w = message(doc, name)["x-wire"]
    data = for [f, kind] <- w["fields"], into: <<>>, do: enc(kind, payload[f])
    {:ok, pkt} = Command.pack(w["type"] || payload["type"], data, 1, 0, &Store.put/1)
    pkt
  end

  # a relay packet, read by the document: its message name and payload, checked against the payload schema
  defp read_packet(doc, pkt) do
    {:ok, %{type: type, data: data}} = Command.unpack(pkt, &Store.get/1)
    all = wire_messages(doc, "server")

    {name, w} =
      Enum.find(all, fn {_, w} -> w["type"] == type end) ||
        (type > 100 && Enum.find(all, fn {_, w} -> w["typeFrom"] end)) ||
        flunk("the document has no relay message of type #{type}")

    {payload, rest} =
      Enum.reduce(w["fields"], {%{}, data}, fn [f, kind], {acc, bin} ->
        {v, bin} = dec(kind, bin)
        {Map.put(acc, f, v), bin}
      end)

    if rest != <<>>, do: flunk("#{name}: bytes left over")
    payload = if w["typeFrom"], do: Map.put(payload, "type", type), else: payload

    if not fits_payload?(doc, name, payload),
      do: flunk("#{name} #{inspect(payload)} does not fit its schema")

    {name, payload}
  end

  # ---------------------------------------------------------------- the relay and its players

  defp start_relay do
    root = :crypto.strong_rand_bytes(32)
    name = :"frontier_#{System.unique_integer([:positive])}"

    {:ok, %{port: port}} =
      Serve.start(
        %{"MB_ROOT_KEY" => Base.encode16(root), "MB_WT_PORT" => "0", "MB_BIND" => "127.0.0.1"},
        name: name
      )

    cert = Path.join([System.tmp_dir!(), "mb_relay_cert", "cert.pem"])
    %{root: root, port: port, cert: cert, name: name}
  end

  defp connect(relay, path, opts \\ []) do
    case Client.connect("localhost", relay.port, path, [cacertfile: relay.cert] ++ opts) do
      {:ok, s} -> s
      other -> flunk("could not connect to #{path}: #{inspect(other)}")
    end
  end

  # a player's keys and a token for `rooms`
  defp player(relay, rooms, ops \\ []) do
    {pub, priv} = Auth.generate_key()
    tp = :crypto.strong_rand_bytes(32)
    token = Token.issue(relay.root, rooms, "minter", tp, ops)
    {:ok, full} = Token.discharge(token, tp, Auth.thumbprint(pub), 3600, System.os_time(:second))
    %{pub: pub, priv: priv, token: full}
  end

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp recv_fin(session, stream, acc \\ <<>>, timeout \\ 4_000) do
    receive do
      {:webtransport, ^session, {:stream, ^stream, :bidi, d}} ->
        recv_fin(session, stream, acc <> d, timeout)

      {:webtransport, ^session, {:stream_fin, ^stream, :bidi, d}} ->
        {:ok, acc <> d}
    after
      timeout -> {:error, {:timeout, acc}}
    end
  end

  # one request on its own stream; the JSON reply on the same stream
  defp ask(session, msg) do
    bin = if is_binary(msg), do: msg, else: JSON.encode!(msg)
    {:ok, stream} = Client.send_reliable(session, bin)

    case recv_fin(session, stream) do
      {:ok, body} -> JSON.decode!(body)
      other -> flunk("no reply on the stream: #{inspect(other)}")
    end
  end

  defp datagrams(session, quiet \\ 350, acc \\ []) do
    case Client.recv_unreliable(session, quiet) do
      {:ok, d} -> datagrams(session, quiet, acc ++ [d])
      {:error, :timeout} -> acc
    end
  end

  defp flush(session), do: datagrams(session, 60)

  # the door, as the document gives it. `kind` is {:room, room} or :session.
  defp door(doc, session, p, kind) do
    %{"nonce" => n} = ch = must_fit(doc, "challenge", ask(session, %{t: "hello"}))
    nonce = Base.url_decode64!(n, padding: false)

    sig =
      if kind == :session,
        do: Auth.sign_session(p.priv, nonce),
        else: Auth.sign(p.priv, elem(kind, 1), nonce)

    ready =
      must_fit(
        doc,
        "ready",
        ask(session, %{t: "auth", token: b64(p.token), key: b64(p.pub), sig: b64(sig)})
      )

    {ch, ready}
  end

  defp admitted_in_room(doc, relay, room, ops \\ [], rooms \\ nil) do
    p = player(relay, rooms || [room], ops)
    s = connect(relay, "/room/#{room}")
    door(doc, s, p, {:room, room})
    flush(s)
    {s, p}
  end

  defp room_name(i), do: "f#{i}-#{System.unique_integer([:positive])}"

  # ---------------------------------------------------------------- the levels

  defp level_room_door(doc, relay, i) do
    room = room_name(i)
    p = player(relay, [room])
    s = connect(relay, "/room/#{room}")
    door(doc, s, p, {:room, room})
    snap = must_fit(doc, "snapshot", ask(s, %{t: "hello"}))
    assert length(snap["patches"]) == 24
    Client.close(s)
  end

  defp level_refusals(doc, relay, i) do
    room = room_name(i)

    case rem(i, 4) do
      0 ->
        s = connect(relay, "/room/#{room}")
        e = must_fit(doc, "error", ask(s, %{t: "set", id: 0, rgb: [1, 2, 3]}))
        assert e["reason"] == "unauthenticated"

      1 ->
        p = player(relay, ["some-other-room"])
        s = connect(relay, "/room/#{room}")
        {:ok, _} = {:ok, ask(s, %{t: "hello"})}
        assert denied?(doc, s, p, room)

      2 ->
        mine = player(relay, [room])
        theirs = player(relay, [room])
        s = connect(relay, "/room/#{room}")
        %{"nonce" => n} = ask(s, %{t: "hello"})
        sig = Auth.sign(theirs.priv, room, Base.url_decode64!(n, padding: false))

        e =
          must_fit(
            doc,
            "error",
            ask(s, %{t: "auth", token: b64(mine.token), key: b64(mine.pub), sig: b64(sig)})
          )

        assert e["reason"] == "denied"

      3 ->
        s = connect(relay, "/room/#{room}")

        for _ <- 1..3 do
          ask(s, %{t: "hello"})
          e = must_fit(doc, "error", ask(s, %{t: "auth", token: "AA", key: "AA", sig: "AA"}))
          assert e["reason"] == "denied"
        end

        e = must_fit(doc, "error", ask(s, %{t: "hello"}))
        assert e["reason"] == "locked"
    end
  end

  defp denied?(doc, s, p, room) do
    %{"nonce" => n} = ask(s, %{t: "hello"})
    sig = Auth.sign(p.priv, room, Base.url_decode64!(n, padding: false))

    e =
      must_fit(
        doc,
        "error",
        ask(s, %{t: "auth", token: b64(p.token), key: b64(p.pub), sig: b64(sig)})
      )

    e["reason"] == "denied"
  end

  defp level_chart(doc, relay, i) do
    room = room_name(i)
    {a, _} = admitted_in_room(doc, relay, room)
    {b, _} = admitted_in_room(doc, relay, room)
    {c, _} = admitted_in_room(doc, relay, room_name(i + 1000))

    [id] = Enum.take(StreamData.integer(0..23), 1)
    rgb = Enum.take(StreamData.integer(0..255), 3)

    ok = must_fit(doc, "ok", ask(a, %{t: "set", id: id, rgb: rgb}))
    assert ok == %{"t" => "ok"}

    [dg] = datagrams(b)
    set = must_fit(doc, "set", JSON.decode!(dg))
    assert set["id"] == id and set["rgb"] == rgb

    assert datagrams(c, 250) == []
    snap = must_fit(doc, "snapshot", ask(b, %{t: "hello"}))
    assert Enum.at(snap["patches"], id) == rgb

    bad = must_fit(doc, "error", ask(a, %{t: "set", id: 24, rgb: rgb}))
    assert bad["reason"] == "bad_patch"
    for s <- [a, b, c], do: Client.close(s)
  end

  defp pose_bytes(gid, digest \\ <<0::256>>, class \\ 0),
    do:
      <<gid::little-32, 0::unit(8)-size(44), 0::little-24, class, 0::unit(8)-size(10),
        digest::binary, 0::48>>

  defp level_pose(doc, relay, i) do
    room = room_name(i)
    {a, _} = admitted_in_room(doc, relay, room)
    {b, _} = admitted_in_room(doc, relay, room)
    {c, _} = admitted_in_room(doc, relay, room_name(i + 1000))
    gid = :rand.uniform(1_000_000)
    pose = pose_bytes(gid)
    assert byte_size(pose) == 100

    :ok = Client.send_unreliable(a, pose)
    [got] = datagrams(b)
    assert byte_size(got) == 100 and binary_part(got, 0, 4) == binary_part(pose, 0, 4)
    assert binary_part(got, 48, 52) == binary_part(pose, 48, 52)
    assert datagrams(c, 250) == []

    assert must_fit(doc, "ok", ask(a, pose)) == %{"t" => "ok"}
    bad = <<pose::binary-size(98), 1, 1>>
    e = must_fit(doc, "error", ask(a, bad))
    assert e["reason"] == "bad_packet"
    for s <- [a, b, c], do: Client.close(s)
  end

  defp level_mesh(doc, relay, i) do
    stub(MixerBroadcaster.BlobMock, :object, fn _ -> {:ok, @cube} end)

    stub(MixerBroadcaster.BlobMock, :presign_get, fn key, ttl ->
      {:ok, "https://s3.test/#{key}?ttl=#{ttl}"}
    end)

    room = room_name(i)
    {poster, _} = admitted_in_room(doc, relay, room, ["read"])
    :ok = Client.send_unreliable(poster, pose_bytes(7, @cube_digest, 4))
    Process.sleep(80)
    ask_mesh = %{t: "mesh", digest: @hex_digest}

    case rem(i, 4) do
      0 ->
        g = must_fit(doc, "meshGrant", ask(poster, ask_mesh))
        assert g["digest"] == @hex_digest and g["expires"] == 300

      1 ->
        {reader, _} = admitted_in_room(doc, relay, room, ["read"])
        flush(reader)
        :ok = Client.send_unreliable(reader, JSON.encode!(ask_mesh))
        [first | _] = datagrams(reader)
        g = must_fit(doc, "meshGrant", JSON.decode!(first))
        assert g["digest"] == @hex_digest

      2 ->
        {noread, _} = admitted_in_room(doc, relay, room, [])
        e = must_fit(doc, "error", ask(noread, ask_mesh))
        assert e["reason"] == "denied"

      3 ->
        e = must_fit(doc, "error", ask(poster, %{t: "mesh", digest: String.duplicate("0", 64)}))
        assert e["reason"] == "denied"
    end

    Client.close(poster)
  end

  # --- commands over a real stream

  defp commander(doc, relay, rooms) do
    p = player(relay, rooms)
    s = connect(relay, "/mixer")
    door(doc, s, p, :session)
    %{session: s, p: p, stream: nil}
  end

  defp send_cmd(doc, c, name, payload \\ nil) do
    payload = payload || hd(message(doc, name)["examples"])["payload"]
    send_pkt(c, pack(doc, name, payload))
  end

  defp send_pkt(%{stream: nil} = c, pkt) do
    {:ok, stream} = Client.send_reliable(c.session, pkt, fin: false)
    %{c | stream: stream}
  end

  defp send_pkt(c, pkt) do
    :ok = :webtransport.send(c.session, c.stream, pkt)
    c
  end

  # what the relay sends back on the command stream, until it is quiet; each packet read by the document
  defp drain(doc, c, quiet \\ 300, acc \\ <<>>) do
    receive do
      {:webtransport, s, {:stream, st, :bidi, d}} when s == c.session and st == c.stream ->
        drain(doc, c, quiet, acc <> d)
    after
      quiet -> for <<pkt::binary-size(100) <- acc>>, do: read_packet(doc, pkt)
    end
  end

  defp names(outs), do: for({n, _} <- outs, do: n)
  defp errors(outs), do: for({"sendErrorOut", %{"message" => m}} <- outs, do: m)

  defp example(doc, name, over),
    do: hd(message(doc, name)["examples"])["payload"] |> Map.merge(over)

  defp level_commands(doc, relay, i) do
    room = room_name(i)

    case rem(i, 4) do
      0 ->
        a = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        outs = drain(doc, a)
        assert "joinRoomOk" in names(outs) and "contentOffer" in names(outs)
        a = send_cmd(doc, a, "content")
        assert "roomUpdate" in names(drain(doc, a))
        a = send_cmd(doc, a, "listRooms")
        assert [%{"rooms" => rooms}] = for({"roomList", p} <- drain(doc, a), do: p)
        assert rooms[room]["joinable"] == true
        a = send_cmd(doc, a, "clientIdRequest")
        assert [%{"id" => id}] = for({"clientIdReply", p} <- drain(doc, a), do: p)
        assert id != ""
        Client.close(a.session)

      1 ->
        a = commander(doc, relay, [room])
        b = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, a)
        a = send_cmd(doc, a, "content")
        drain(doc, a)
        a = send_cmd(doc, a, "roomCommand", %{"type" => 150, "data" => "0a0b"})
        drain(doc, a)
        b = send_cmd(doc, b, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        outs = drain(doc, b)
        assert Enum.take(names(outs), 1) == ["clearContent"] and "joinRoomOk" in names(outs)
        assert {"roomCommandOut", %{"type" => 150, "data" => "0a0b"}} in outs
        b = send_cmd(doc, b, "roomCommand", %{"type" => 151, "data" => "ff"})
        drain(doc, b)
        assert {"roomCommandOut", %{"type" => 151, "data" => "ff"}} in drain(doc, a)
        Client.close(a.session)
        Client.close(b.session)

      2 ->
        a = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => "outside-#{room}"}))
        assert errors(drain(doc, a)) == ["Not allowed in room outside-#{room}"]
        a = send_cmd(doc, a, "unknownCommand")
        assert errors(drain(doc, a)) == ["Command 2 received but no handler for it on server"]
        a = send_pkt(a, :binary.copy(<<0>>, 100))
        assert [m] = errors(drain(doc, a))
        assert m =~ "bad command packet"
        Client.close(a.session)

      3 ->
        a = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, a)
        a = send_cmd(doc, a, "setClientName")
        drain(doc, a)
        a = send_cmd(doc, a, "setClientCustomAttributes")
        assert "clientUpdate" in names(drain(doc, a))

        a =
          send_cmd(
            doc,
            a,
            "setRoomCustomAttributes",
            example(doc, "setRoomCustomAttributes", %{"room" => room})
          )

        assert "roomUpdate" in names(drain(doc, a))

        a =
          send_cmd(doc, a, "setRoomKeepOpen", example(doc, "setRoomKeepOpen", %{"room" => room}))

        drain(doc, a)
        a = send_cmd(doc, a, "listClients")
        assert [%{"clients" => cl}] = for({"clientList", p} <- drain(doc, a), do: p)
        assert Enum.any?(cl, fn {_, v} -> v["room"] == room end)
        a = send_cmd(doc, a, "leaveRoom")
        assert "leaveRoomOk" in names(drain(doc, a))
        a = send_cmd(doc, a, "deleteRoom", %{"room" => room})
        assert {"roomDeleted", %{"room" => room}} in drain(doc, a)
        Client.close(a.session)
    end
  end

  # --- late joiners, removal and bulk data

  # a player admitted to a room, keeping every datagram the relay sends after `ready` (a late joiner's replay)
  defp admitted_keeping(doc, relay, room) do
    p = player(relay, [room])
    s = connect(relay, "/room/#{room}")
    door(doc, s, p, {:room, room})
    s
  end

  defp level_late(doc, relay, i) do
    room = room_name(i)
    {a, _} = admitted_in_room(doc, relay, room)
    gid = :rand.uniform(1_000_000)

    case rem(i, 4) do
      0 ->
        # a late joiner is replayed the last packet of every entity, three times
        :ok = Client.send_unreliable(a, pose_bytes(gid))
        Process.sleep(100)
        b = admitted_keeping(doc, relay, room)
        got = datagrams(b, 450)
        assert length(got) == 3, "expected the replay three times, got #{length(got)}"
        assert got |> Enum.map(&binary_part(&1, 0, 4)) |> Enum.uniq() == [<<gid::little-32>>]

      1 ->
        # an ENTITY_REMOVE takes the entity out of what a late joiner is replayed
        :ok = Client.send_unreliable(a, pose_bytes(gid))
        {:ok, rm} = Command.pack(211, <<gid::little-32>>, 1, 0, &Store.put/1)
        :ok = Client.send_unreliable(a, rm)
        Process.sleep(150)
        b = admitted_keeping(doc, relay, room)
        assert datagrams(b, 450) == []

      2 ->
        # data too big for one packet goes by digest and arrives whole
        c1 = commander(doc, relay, [room])
        c2 = commander(doc, relay, [room])
        data = :crypto.strong_rand_bytes(200)
        c1 = send_cmd(doc, c1, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, c1)
        c1 = send_cmd(doc, c1, "content")
        drain(doc, c1)
        c2 = send_cmd(doc, c2, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, c2)

        c1 =
          send_cmd(doc, c1, "roomCommand", %{
            "type" => 160,
            "data" => Base.encode16(data, case: :lower)
          })

        drain(doc, c1)

        assert {"roomCommandOut", %{"type" => 160, "data" => Base.encode16(data, case: :lower)}} in drain(
                 doc,
                 c2
               )

      3 ->
        # a mode 2 command (by desync index) is carried as the marker, the digest and the key
        c1 = commander(doc, relay, [room])
        c2 = commander(doc, relay, [room])
        marker = Command.index(:crypto.strong_rand_bytes(32), 7)
        c1 = send_cmd(doc, c1, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, c1)
        c1 = send_cmd(doc, c1, "content")
        drain(doc, c1)
        c2 = send_cmd(doc, c2, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, c2)

        c1 =
          send_cmd(doc, c1, "roomCommand", %{
            "type" => 161,
            "data" => Base.encode16(marker, case: :lower)
          })

        drain(doc, c1)

        assert {"roomCommandOut", %{"type" => 161, "data" => Base.encode16(marker, case: :lower)}} in drain(
                 doc,
                 c2
               )
    end
  end

  # --- departures, the door of the command path, short datagrams

  defp level_departures(doc, relay, i) do
    room = room_name(i)

    case rem(i, 4) do
      0 ->
        a = commander(doc, relay, [room])
        b = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, a)
        a = send_cmd(doc, a, "content")
        drain(doc, a)
        b = send_cmd(doc, b, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, b)
        drain(doc, a)
        Client.close(b.session)
        outs = drain(doc, a, 800)

        assert "clientDisconnected" in names(outs),
               "no clientDisconnected, saw #{inspect(names(outs))}"

      1 ->
        a = commander(doc, relay, [room])
        watcher = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, a)
        watcher = send_cmd(doc, watcher, "listRooms")
        drain(doc, watcher)
        a = send_cmd(doc, a, "leaveRoom")
        drain(doc, a)
        outs = drain(doc, watcher, 600)
        assert {"roomDeleted", %{"room" => room}} in outs

      2 ->
        s = connect(relay, "/mixer")

        for _ <- 1..3 do
          ask(s, %{t: "hello"})
          e = must_fit(doc, "error", ask(s, %{t: "auth", token: "AA", key: "AA", sig: "AA"}))
          assert e["reason"] == "denied"
        end

        assert must_fit(doc, "error", ask(s, %{t: "hello"}))["reason"] == "locked"

      3 ->
        a = commander(doc, relay, [room])
        a = send_cmd(doc, a, "joinRoom", example(doc, "joinRoom", %{"room" => room}))
        drain(doc, a)
        :ok = Client.send_unreliable(a.session, :binary.copy(<<0>>, 99))
        a = send_cmd(doc, a, "clientIdRequest")
        assert "clientIdReply" in names(drain(doc, a))
    end
  end

  # --- the client library, as the document describes a reply (on the same stream, with FIN)

  defp level_client(doc, relay, i) do
    s = connect(relay, "/room/#{room_name(i)}")

    case rem(i, 2) do
      0 ->
        reply = ~s({"t":"error","reason":"unauthenticated"})
        {:ok, stream} = Client.send_reliable(s, JSON.encode!(%{t: "set", id: 0, rgb: [1, 2, 3]}))
        assert {:ok, ^reply} = Client.recv_reliable(s, stream, byte_size(reply), 1_500)

      1 ->
        {:ok, stream} = Client.send_reliable(s, JSON.encode!(%{t: "hello"}))
        assert {:ok, body} = Client.recv_reliable(s, stream, 1, 1_500)
        must_fit(doc, "challenge", JSON.decode!(body))
    end

    Client.close(s)
  end

  # --- the demo's HTTP routes, over a real HTTP server

  defp http(port, path) do
    :inets.start()
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

    case :httpc.request(:get, {url, []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, headers, body}} ->
        {status, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}

      other ->
        flunk("no HTTP answer: #{inspect(other)}")
    end
  end

  defp level_http(doc, port, i) do
    case rem(i, 6) do
      0 ->
        {200, h, body} = http(port, "/rooms")
        assert h["content-type"] =~ "application/json"
        must_fit(doc, "roomList", JSON.decode!(body))

      1 ->
        {200, h, body} = http(port, "/connection")
        assert h["content-type"] =~ "application/json" and is_map(JSON.decode!(body))

      2 ->
        {200, h, _} = http(port, "/")
        assert h["content-type"] =~ "text/html"

      3 ->
        {200, h, _} = http(port, "/geo")
        assert h["content-type"] =~ "text/html"

      4 ->
        assert {404, _, "not found"} = http(port, "/usd/#{String.duplicate("cd", 32)}.usda")

      5 ->
        assert {404, _, "not found"} = http(port, "/nothing-#{i}")
    end
  end

  # --- configuration and origins

  defp level_config(doc, relay, i) do
    case i do
      0 ->
        assert Serve.start(%{"MB_WT_PORT" => "0"}) == {:error, :root_key}

      1 ->
        listed = doc["servers"]["relay"]["x-environment"] |> Map.keys()
        for v <- ~w(MB_SERVE MB_ROOT_KEY MB_WT_PORT MB_BIND MB_ORIGINS), do: assert(v in listed)

      2 ->
        assert Application.get_env(:mixer_broadcaster, :allowed_origins) == []

      3 ->
        r =
          :webtransport.connect(
            ~c"localhost",
            relay.port,
            "/room/x",
            origin_opts(relay, "https://evil.example")
          )

        refute match?({:ok, _}, r),
               "a browser origin the closed relay does not list was let in: #{inspect(r)}"

      4 ->
        s = connect(relay, "/room/x")
        assert is_pid(s)
        Client.close(s)
    end
  end

  defp origin_opts(relay, origin),
    do: %{
      transport: :h3,
      verify: :verify_peer,
      cacertfile: String.to_charlist(relay.cert),
      compat_mode: :latest,
      headers: [{"origin", origin}]
    }

  # a planted wrong reply must fail the checker
  defp control_fails(doc) do
    for {schema, bad} <- [
          {"ok", %{"t" => "ok", "extra" => 1}},
          {"error", %{"t" => "error", "reason" => "made_up"}},
          {"meshGrant",
           %{"t" => "mesh", "expires" => 300, "index" => "https://x", "chunks" => []}}
        ] do
      assert_raise ExUnit.AssertionError, fn -> must_fit(doc, schema, bad) end
    end

    assert_raise ExUnit.AssertionError, fn -> flunk("planted") end
    :ok
  end

  # ---------------------------------------------------------------- the run

  test "frontier: every level of the interface is n/n" do
    {:ok, _} = Application.ensure_all_started(:mixer_broadcaster)
    Logger.configure(level: :error)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: :frontier_ledger)
    Application.put_env(:mixer_broadcaster, :blob_access, MixerBroadcaster.BlobMock)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :blob_access) end)

    {:ok, doc} = YamlElixir.read_from_file(@spec_path)
    attempt("0 control: a planted wrong reply fails the checker", fn -> control_fails(doc) end)

    relay = start_relay()
    on_exit(fn -> MixerBroadcaster.Server.stop(relay.name) end)

    {:ok, web} = Bandit.start_link(plug: Web, port: 0, startup_log: false)
    {:ok, {_, web_port}} = ThousandIsland.listener_info(web)

    run_level("1 room door", @n, &level_room_door(doc, relay, &1))
    run_level("2 refusals", @n, &level_refusals(doc, relay, &1))
    run_level("3 chart", @n, &level_chart(doc, relay, &1))
    run_level("4 poses", @n, &level_pose(doc, relay, &1))
    run_level("5 meshes", @n, &level_mesh(doc, relay, &1))
    run_level("6 commands", @n, &level_commands(doc, relay, &1))
    run_level("7 demo http", @n, &level_http(doc, web_port, &1))
    run_level("8 configuration", 5, &level_config(doc, relay, &1))
    run_level("9 late joiners, removal, bulk", @n, &level_late(doc, relay, &1))
    run_level("10 departures and the command door", @n, &level_departures(doc, relay, &1))
    run_level("11 the client library", 4, &level_client(doc, relay, &1))

    report(Agent.get(:frontier_ledger, & &1))
  end

  defp report(ledger) do
    rows =
      for {level, runs} <- ledger do
        n = length(runs)
        s = Enum.count(runs, &elem(&1, 0))
        regret = if(s >= 1, do: 1, else: 0) - s / n
        {level, s, n, regret, for({false, why} <- runs, do: why) |> Enum.uniq() |> Enum.take(3)}
      end

    IO.puts("\nfrontier (passes over problems; regret = 1[s>=1] - s/n):")

    for {level, s, n, regret, why} <-
          Enum.sort_by(rows, fn {l, s, n, r, _} -> {-r, s == n, l} end) do
      IO.puts(
        "  #{String.pad_trailing(level, 52)} #{s}/#{n}  regret #{Float.round(regret * 1.0, 3)}"
      )

      for w <- why, do: IO.puts("      #{String.replace(w, "\n", " ")}")
    end

    File.mkdir_p!("_build")

    File.write!(
      "_build/frontier_ledger.json",
      JSON.encode!(
        for(
          {l, s, n, r, w} <- rows,
          do: %{level: l, passes: s, problems: n, regret: r, failures: w}
        )
      )
    )

    failing = for {l, s, n, _, _} <- rows, s < n, do: l
    assert failing == [], "levels below n/n: #{inspect(failing)}"
  end
end
