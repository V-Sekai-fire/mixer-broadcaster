defmodule MixerBroadcaster.Mixer.SessionTest do
  @moduledoc """
  GOLDEN: two clients speak the Mixer protocol as 100-byte command packets: one creates a room, the other joins and is
  replayed what was stored, a pose goes out as a datagram, bulk data goes by digest.
  CONTROL (closed relay): a session that has not logged in gets nothing; a token for one room cannot join another; a
  malformed packet gets SEND_ERROR and the session carries on; a torn packet waits for its rest.
  """
  use ExUnit.Case, async: false

  alias MixerBroadcaster.{Auth, Command, Token}
  alias MixerBroadcaster.Mixer.{Server, Session, Store, Wire}

  setup do
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    Application.put_env(:mixer_broadcaster, :auth, :off)
    :ok
  end

  # a session in its own process, so the server can address it
  defp start_session do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, st} = Session.init(nil, %{path: "/mixer"}, [])
        send(parent, {:ready, self()})
        loop(st, [])
      end)

    receive do
      {:ready, ^pid} -> pid
    end
  end

  defp loop(st, acc) do
    receive do
      {:call, from, fun} ->
        {st2, actions} = fun.(st)
        send(from, {:done, self(), actions})
        loop(st2, acc)

      {:drain, from} ->
        send(from, {:drained, self(), Enum.reverse(acc)})
        loop(st, [])

      {:mixer_out, _, _} = msg ->
        {:ok, st2, actions} = wrap(Session.handle_info(msg, st))
        loop(st2, Enum.reverse(actions) ++ acc)
    end
  end

  defp wrap({:ok, st}), do: {:ok, st, []}
  defp wrap(other), do: other

  defp call(pid, fun) do
    send(pid, {:call, self(), fun})

    receive do
      {:done, ^pid, actions} -> actions
    end
  end

  defp stream(pid, data, id \\ 0) do
    call(pid, fn st ->
      {:ok, st2, actions} = wrap(Session.handle_stream(id, :bidi, data, st))
      {st2, actions}
    end)
  end

  defp datagram(pid, data) do
    call(pid, fn st ->
      {:ok, st2, actions} = wrap(Session.handle_datagram(data, st))
      {st2, actions}
    end)
  end

  # what the server has sent the session since the last drain (after it has had time to)
  defp drain(pid) do
    Process.sleep(60)
    send(pid, {:drain, self()})

    receive do
      {:drained, ^pid, actions} -> actions
    end
  end

  defp packet(type, data) do
    {:ok, p} = Command.pack(type, data, 1, 0, &Store.put/1)
    p
  end

  defp join_packet(room),
    do:
      packet(
        Wire.type(:join_room),
        Wire.string(room) <>
          Wire.string("5") <> Wire.string("1") <> Wire.bool(false) <> Wire.bool(false)
      )

  # the commands in the stream sends of an action list
  defp commands(actions) do
    for {:send, _, <<_::binary-size(100)>> = p} <- actions do
      {:ok, c} = Command.unpack(p, &Store.get/1)
      {c.type, c.data}
    end
  end

  defp names(actions),
    do: actions |> commands() |> Enum.map(fn {t, _} -> Wire.type_name(t) || t end)

  test "golden: create, join with replay, a pose by datagram, bulk by digest" do
    a = start_session()
    b = start_session()

    stream(a, join_packet("room"))
    assert names(drain(a)) |> Enum.take(2) == [:join_room, :content]
    stream(a, packet(Wire.type(:content), <<>>))
    big = :binary.copy("mesh", 100)
    stream(a, packet(120, Wire.string("/Cube") <> big))
    pose = <<7::little-32, 0::unit(8)-size(96)>>
    datagram(a, pose)
    drain(a)

    stream(b, join_packet("room"))
    got = drain(b)
    assert [:clear_content, :join_room] -- names(got) == [], "cleared and joined"

    assert {120, data} = List.keyfind(commands(got), 120, 0)
    assert data == Wire.string("/Cube") <> big, "bulk data came back whole through the store"
    assert [<<7::little-32, _::binary>>] = for({:send_datagram, d} <- got, do: d)

    datagram(a, <<9::little-32, 0::unit(8)-size(96)>>)
    live = for {:send_datagram, d} <- drain(b), do: d
    assert [<<9::little-32, _::binary>>] = live, "a live pose reaches the room"
    assert drain(a) |> Enum.filter(&match?({:send_datagram, _}, &1)) == [], "and not its sender"
  end

  test "control: a session that ends leaves the server, and its room goes with its last member" do
    a = start_session()
    stream(a, join_packet("gone"))
    drain(a)
    assert Map.has_key?(Server.state().rooms, "gone")
    call(a, fn st -> {st, Session.terminate(:normal, st) && []} end)
    Process.sleep(60)
    refute Map.has_key?(Server.state().rooms, "gone")
    assert Server.state().clients |> Map.values() |> Enum.all?(&(&1.room != "gone"))
  end

  test "control: bad input gets SEND_ERROR and the session carries on; a torn packet waits" do
    a = start_session()
    stream(a, join_packet("r"))
    drain(a)

    bad = :binary.copy(<<255>>, 100)
    actions = stream(a, bad)
    assert [:send_error] == names(actions)

    {first, second} = String.split_at(packet(Wire.type(:content), <<>>), 40)
    assert stream(a, first) == []
    assert stream(a, second) == [], "a torn packet is joined, then handled"
    assert :room_update in names(drain(a))

    two = packet(Wire.type(:list_clients), <<>>) <> packet(Wire.type(:list_rooms), <<>>)
    stream(a, two)

    assert Enum.count(names(drain(a)), &(&1 in [:list_clients, :list_rooms])) == 2,
           "two packets in one chunk"
  end

  describe "closed relay" do
    setup do
      root = :crypto.strong_rand_bytes(32)
      Application.put_env(:mixer_broadcaster, :auth, %{root_key: root})
      %{root: root}
    end

    defp b64(b), do: Base.url_encode64(b, padding: false)

    defp login(pid, root, rooms) do
      {pub, priv} = Auth.generate_key()
      tp_key = :crypto.strong_rand_bytes(32)

      {:ok, token} =
        Token.discharge(
          Token.issue(root, rooms, "m", tp_key),
          tp_key,
          Auth.thumbprint(pub),
          3600,
          System.os_time(:second)
        )

      [{:send, _, hello_reply, :fin}] = stream(pid, ~s({"t":"hello"}))
      %{"nonce" => n} = JSON.decode!(hello_reply)
      nonce = Base.url_decode64!(n, padding: false)

      msg =
        JSON.encode!(%{
          t: "auth",
          token: b64(token),
          key: b64(pub),
          sig: b64(Auth.sign_session(priv, nonce))
        })

      [{:send, _, reply, :fin}] = stream(pid, msg)
      JSON.decode!(reply)
    end

    test "golden: a token for one room joins it and not another", %{root: root} do
      a = start_session()
      assert %{"t" => "ready"} = login(a, root, ["lobby"])
      stream(a, join_packet("vault"))
      assert :send_error in names(drain(a))
      stream(a, join_packet("lobby"))

      assert [:join_room, :content] ==
               names(drain(a)) |> Enum.filter(&(&1 in [:join_room, :content]))
    end

    test "control: before login nothing is heard, and nothing reaches a room", %{root: root} do
      open = start_session()
      assert %{"t" => "ready"} = login(open, root, ["lobby"])
      stream(open, join_packet("lobby"))
      stream(open, packet(Wire.type(:content), <<>>))
      drain(open)

      stranger = start_session()
      [{:send, _, reply, :fin}] = stream(stranger, join_packet("lobby"))
      assert JSON.decode!(reply) == %{"t" => "error", "reason" => "unauthenticated"}
      assert datagram(stranger, <<1::little-32, 0::unit(8)-size(96)>>) == []
      assert drain(stranger) == []
      assert drain(open) == [], "the stranger's packets never reached the room"
    end

    test "control: a wrong proof is denied and three tries lock the session", %{root: root} do
      a = start_session()

      for _ <- 1..3 do
        [{:send, _, h, :fin}] = stream(a, ~s({"t":"hello"}))
        assert %{"nonce" => _} = JSON.decode!(h)
        [{:send, _, r, :fin}] = stream(a, ~s({"t":"auth","token":"AA","key":"AA","sig":"AA"}))
        assert %{"reason" => "denied"} = JSON.decode!(r)
      end

      [{:send, _, r, :fin}] = stream(a, ~s({"t":"hello"}))
      assert %{"reason" => "locked"} = JSON.decode!(r)
      assert root
    end
  end
end
