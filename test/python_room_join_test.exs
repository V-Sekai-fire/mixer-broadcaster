# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.PythonRoomJoinTest do
  @moduledoc """
  The Python reference consumer (issue #32) joins a real closed room over HTTP/3 WebTransport and reads its state.

  GOLDEN: Elixir pens publish 7 strokes; the Python client passes the door (token, P-256 key, signed nonce) and reports
  7 entities and a digest. The digest is checked against one computed here from what the relay itself holds
  (`Rooms.entities/1`), not from anything Python sent, so the two languages agree on the room.
  INVARIANT: the same holds for random strokes in every round.
  CONTROL: a token for another room is refused at the door (exit 2); an empty room reads as 0 entities; a digest that
  leaves the relay's clock field in is shown to differ from Python's, so the comparison can fail.

  Needs a Python with `aioquic` and `cryptography`: set `MB_PYTHON` to its path (the pixi environment of
  `clients/python` has both). Without it the test is skipped and says so.
  """
  use ExUnit.Case, async: false

  alias MixerBroadcaster.{Auth, Client, Rooms, Serve, Token}

  @moduletag timeout: 300_000
  @python System.get_env("MB_PYTHON")
  @tool Path.expand("../clients/python/tools/room_join.py", __DIR__)
  @rounds 3

  @tag skip:
         if(@python in [nil, ""],
           do: "set MB_PYTHON to a Python with aioquic and cryptography",
           else: false
         )
  test "the Python client reads the same room the relay holds" do
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:mixer_broadcaster)
    relay = start_relay()
    on_exit(fn -> MixerBroadcaster.Server.stop(relay.name) end)

    # CONTROL for the comparison: a digest that keeps the relay's clock must differ from the one that drops it
    <<head::binary-size(40), _::binary-size(8), rest::binary>> = stroke_packet(1)
    pkt = <<head::binary, 123_456::little-64, rest::binary>>
    refute digest([pkt], true) == digest([pkt], false)

    for i <- 1..@rounds do
      room = "pyjoin-#{i}-#{System.unique_integer([:positive])}"
      publish(relay, room, 7)
      held = Rooms.entities(room)
      assert length(held) == 7

      {out, 0} = run_python(relay, room, mint(relay, [room]))
      state = JSON.decode!(out)
      assert state["count"] == 7, "round #{i}: python read #{state["count"]} entities"

      assert state["digest"] == digest(held, false),
             "round #{i}: python and the relay disagree on the digest"

      refute state["digest"] == digest(held, true)

      # CONTROL: a token for another room does not open this one
      {err, code} = run_python(relay, room, mint(relay, ["somewhere-else-#{i}"]))
      assert code == 2 and err =~ "refused", "round #{i}: expected a refusal, got #{code} #{err}"

      # CONTROL: an empty room reads as empty
      empty = "pyjoin-empty-#{i}-#{System.unique_integer([:positive])}"
      {out, 0} = run_python(relay, empty, mint(relay, [empty]))
      assert JSON.decode!(out)["count"] == 0
    end
  end

  # ---------------------------------------------------------------- the relay and its players

  defp start_relay do
    root = :crypto.strong_rand_bytes(32)
    name = :"pyjoin_#{System.unique_integer([:positive])}"

    {:ok, %{port: port}} =
      Serve.start(
        %{"MB_ROOT_KEY" => Base.encode16(root), "MB_WT_PORT" => "0", "MB_BIND" => "127.0.0.1"},
        name: name
      )

    %{
      root: root,
      port: port,
      name: name,
      cert: Path.join([System.tmp_dir!(), "mb_relay_cert", "cert.pem"])
    }
  end

  # a key, and a token for `rooms` bound to that key's thumbprint
  defp mint(relay, rooms) do
    {pub, priv} = Auth.generate_key()
    tp = :crypto.strong_rand_bytes(32)
    token = Token.issue(relay.root, rooms, "minter", tp, ["read"])
    {:ok, full} = Token.discharge(token, tp, Auth.thumbprint(pub), 3600, System.os_time(:second))

    %{
      token: Base.url_encode64(full, padding: false),
      key: Base.encode16(priv, case: :lower),
      pub: pub,
      priv: priv
    }
  end

  defp run_python(relay, room, player) do
    System.cmd(@python, [@tool, "localhost", Integer.to_string(relay.port), relay.cert, room],
      env: [{"MB_TOKEN", player.token}, {"MB_KEY", player.key}],
      stderr_to_stdout: true
    )
  end

  # an Elixir pen: joins the room and publishes `n` strokes, then leaves; the relay keeps the entities
  defp publish(relay, room, n) do
    player = mint(relay, [room])
    {:ok, s} = Client.connect("localhost", relay.port, "/room/#{room}", cacertfile: relay.cert)
    %{"nonce" => nonce} = ask(s, %{t: "hello"})
    sig = Auth.sign(player.priv, room, Base.url_decode64!(nonce, padding: false))
    token = player.token

    %{"t" => "ready"} =
      ask(s, %{t: "auth", token: token, key: b64(player.pub), sig: b64(sig)})

    # a pose sent on a stream is answered "ok" once the relay has stored and forwarded it
    for k <- 1..n do
      {:ok, stream} = Client.send_reliable(s, stroke_packet(k))
      {:ok, ~s({"t":"ok"})} = recv_fin(s, stream)
    end

    Client.close(s)
  end

  # id (4), pose (4..39), relay clock (40..47), class (51) = mesh, mesh digest (62..93)
  defp stroke_packet(gid) do
    pose = :crypto.strong_rand_bytes(36)
    digest = :crypto.hash(:sha256, pose)
    <<gid::little-32, pose::binary, 0::64, 0::24, 4, 0::unit(8)-size(10), digest::binary, 0::48>>
  end

  # SHA-256 over the room's packets ordered by id; the relay's clock field (bytes 40..47) is zeroed unless `keep_clock`
  defp digest(packets, keep_clock) do
    packets
    |> Enum.sort_by(fn <<gid::little-32, _::binary>> -> gid end)
    |> Enum.map(fn <<head::binary-size(40), clock::binary-size(8), rest::binary>> ->
      if keep_clock, do: [head, clock, rest], else: [head, <<0::64>>, rest]
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp ask(session, msg) do
    {:ok, stream} = Client.send_reliable(session, JSON.encode!(msg))
    {:ok, body} = recv_fin(session, stream)
    JSON.decode!(body)
  end

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
end
