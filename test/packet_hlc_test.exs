defmodule MixerBroadcaster.PacketHlcTest do
  @moduledoc """
  GOLDEN: the 64 packets of contract-entity-packet parse, carry the clock the CSV lists, and survive a restamp.
  INVARIANT: a stamped packet is after both the relay's clock and the packet's; only the clock bytes change.
  CONTROL: a short packet, a nonzero reserved tail, and a full counter are refused; a planted receive defect is caught.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Clock, Hlc, Hub, Packet, Rooms}

  @rows File.stream!(Path.join(__DIR__, "fixtures/packet_golden_full.csv"))
        |> Stream.drop(1)
        |> Enum.map(fn line ->
          [hex | rest] = line |> String.trim() |> String.split(",")
          {Base.decode16!(hex, case: :lower), String.to_integer(Enum.at(rest, 10))}
        end)

  test "golden: 64 rows, each 100 bytes, valid, with the CSV's clock" do
    assert length(@rows) == 64

    for {bin, hlc} <- @rows do
      assert byte_size(bin) == Packet.size()
      assert Packet.valid?(bin)
      assert Packet.hlc(bin) == hlc
      assert Packet.put_hlc(bin, hlc) == bin
    end
  end

  test "golden: the clock rules, worked by hand" do
    assert Hlc.send_event({100, 3}, 100) == {:ok, {100, 4}}
    assert Hlc.send_event({100, 3}, 101) == {:ok, {101, 0}}
    assert Hlc.send_event({100, 3}, 90) == {:ok, {100, 4}}
    assert Hlc.recv({100, 3}, {100, 9}, 100) == {:ok, {100, 10}}
    assert Hlc.recv({100, 3}, {105, 2}, 100) == {:ok, {105, 3}}
    assert Hlc.recv({100, 3}, {99, 50}, 100) == {:ok, {100, 4}}
    assert Hlc.recv({100, 3}, {99, 50}, 200) == {:ok, {200, 0}}
    assert Hlc.pack({Bitwise.<<<(1, 48) - 1, 0xFFFF}) == 0xFFFF_FFFF_FFFF_FFFF
  end

  property "invariant: pack and unpack are inverses, and packed order is pair order" do
    check all(
            l1 <- integer(0..(Bitwise.<<<(1, 48) - 1)),
            c1 <- integer(0..0xFFFF),
            l2 <- integer(0..(Bitwise.<<<(1, 48) - 1)),
            c2 <- integer(0..0xFFFF)
          ) do
      assert Hlc.unpack(Hlc.pack({l1, c1})) == {l1, c1}
      assert Hlc.before?({l1, c1}, {l2, c2}) == Hlc.pack({l1, c1}) < Hlc.pack({l2, c2})
    end
  end

  defp recv_broken({l0, c0}, {lm, cm}, pt) do
    l = max(max(l0, lm), pt)

    c =
      cond do
        l == l0 and l == lm -> c0 + 1
        l == l0 -> c0 + 1
        l == lm -> cm + 1
        true -> 0
      end

    {l, c}
  end

  property "invariant: recv is after the node's stamp and the message's, with l the largest time" do
    check all(
            base <- integer(1_780_000_000_000..1_780_000_000_050),
            {dl, dm, dp} <- {integer(0..2), integer(0..2), integer(0..2)},
            {c0, cm} <- {integer(0..40), integer(0..40)}
          ) do
      {mine, msg, pt} = {{base + dl, c0}, {base + dm, cm}, base + dp}
      {:ok, r} = Hlc.recv(mine, msg, pt)
      assert Hlc.before?(mine, r) and Hlc.before?(msg, r)
      assert elem(r, 0) == Enum.max([elem(mine, 0), elem(msg, 0), pt])
    end
  end

  test "control: the planted receive defect is caught by the same property" do
    caught =
      for dl <- 0..2, dm <- 0..2, dp <- 0..2, c0 <- 0..9, cm <- 0..9, reduce: false do
        acc ->
          {mine, msg, pt} = {{100 + dl, c0}, {100 + dm, cm}, 100 + dp}
          r = recv_broken(mine, msg, pt)
          acc or not (Hlc.before?(mine, r) and Hlc.before?(msg, r))
      end

    assert caught
  end

  test "control: a full counter is refused, not wrapped" do
    assert Hlc.send_event({100, 0xFFFF}, 100) == :error
    assert Hlc.send_event({100, 0xFFFF}, 101) == {:ok, {101, 0}}
  end

  test "control: short, long and dirty-tail packets are not valid" do
    {bin, _} = hd(@rows)
    refute Packet.valid?(binary_part(bin, 0, 99))
    refute Packet.valid?(bin <> <<0>>)
    refute Packet.valid?(binary_part(bin, 0, 98) <> <<0, 1>>)
  end

  test "golden: the hub stamps a pose and forwards it to the room; an outsider gets nothing; only the clock changes" do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    room = "pose-#{System.unique_integer([:positive])}"
    me = self()

    listener = fn r ->
      spawn_link(fn ->
        {:ok, st} = Hub.init(nil, %{path: "/room/#{r}"}, [])
        send(me, {:up, r})

        receive do
          {:relay, _, _} = m -> send(me, {:got, r, Hub.handle_info(m, st)})
        after
          1500 -> send(me, {:got, r, :nothing})
        end
      end)
    end

    listener.(room)
    listener.("elsewhere-#{room}")
    for _ <- 1..2, do: assert_receive({:up, _})
    {:ok, a} = Hub.init(nil, %{path: "/room/#{room}"}, [])
    {bin, _} = Enum.at(@rows, 9)
    t0 = System.os_time(:millisecond)
    assert {:ok, _, []} = Hub.handle_datagram(bin, a)
    assert_receive {:got, ^room, {:ok, _, [{:send_datagram, out}]}}
    assert byte_size(out) == 100
    assert binary_part(out, 0, 40) == binary_part(bin, 0, 40)
    assert binary_part(out, 48, 52) == binary_part(bin, 48, 52)
    {l, _c} = Hlc.unpack(Packet.hlc(out))
    assert l >= t0 and l <= System.os_time(:millisecond) + 1
    assert_receive {:got, other, :nothing} when other != room, 3000
  end

  test "golden: a client that joins late gets the latest packet of every entity, and only its own room's" do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    room = "late-#{System.unique_integer([:positive])}"
    {:ok, a} = Hub.init(nil, %{path: "/room/#{room}"}, [])
    assert_receive :replay
    assert {:ok, _, []} = Hub.handle_info(:replay, a)
    {base, _} = Enum.at(@rows, 9)
    pose = fn gid, x -> <<gid::little-32, x::little-signed-64>> <> binary_part(base, 12, 88) end

    for pkt <- [pose.(1, 100), pose.(2, 200), pose.(1, 300)],
        do: assert({:ok, _, []} = Hub.handle_datagram(pkt, a))

    {:ok, late} = Hub.init(nil, %{path: "/room/#{room}"}, [])
    assert_receive :replay
    assert {:ok, _, sends} = Hub.handle_info(:replay, late)

    got =
      for {:send_datagram, <<gid::little-32, x::little-signed-64, _::binary>>} <- sends,
          do: {gid, x}

    assert Enum.sort(got) == [{1, 300}, {2, 200}]

    assert Enum.all?(sends, fn {:send_datagram, p} -> byte_size(p) == 100 and Packet.valid?(p) end)

    {:ok, other} = Hub.init(nil, %{path: "/room/elsewhere-#{room}"}, [])
    assert_receive :replay
    assert {:ok, _, []} = Hub.handle_info(:replay, other)
  end

  test "invariant: a replay never goes back past a pose the client already heard live" do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    room = "order-#{System.unique_integer([:positive])}"
    {:ok, a} = Hub.init(nil, %{path: "/room/#{room}"}, [])
    {base, _} = Enum.at(@rows, 9)
    pose = fn gid, x -> <<gid::little-32, x::little-signed-64>> <> binary_part(base, 12, 88) end
    Rooms.put_entity(room, pose.(1, 100))
    Rooms.put_entity(room, pose.(2, 200))
    {:ok, late} = Hub.init(nil, %{path: "/room/#{room}"}, [])

    assert {:ok, late, [{:send_datagram, _}]} =
             Hub.handle_info({:relay, spawn(fn -> :ok end), pose.(1, 150)}, late)

    assert {:ok, _, sends} = Hub.handle_info({:replay, 1}, late)
    assert for({:send_datagram, <<gid::little-32, _::binary>>} <- sends, do: gid) == [2]
  end

  test "control: an unadmitted client gets no replay until it is admitted" do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    {:ok, a} = Hub.init(nil, %{path: "/room/guarded"}, [])
    assert_receive :replay
    {base, _} = Enum.at(@rows, 9)
    assert {:ok, _, []} = Hub.handle_datagram(base, a)
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: :crypto.strong_rand_bytes(32)})
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    {:ok, stranger} = Hub.init(nil, %{path: "/room/guarded"}, [])
    refute_receive :replay, 200
    assert stranger.admitted == false
  end

  test "control: a bad packet from an admitted player never reaches the room" do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    {:ok, a} = Hub.init(nil, %{path: "/room/bad-#{System.unique_integer([:positive])}"}, [])
    dirty = :binary.copy(<<1>>, 100)
    assert {:ok, _, []} = Hub.handle_datagram(dirty, a)
    assert {:ok, _, [{:send, 0, reply, :fin}]} = Hub.handle_stream(0, :bidi, dirty, a)
    assert JSON.decode!(reply)["reason"] == "bad_packet"
  end

  test "the clock agent never goes backwards over many stamps" do
    words = for _ <- 1..500, do: elem(Clock.stamp(0), 1)
    assert words == Enum.sort(words)
    assert length(Enum.uniq(words)) == 500
  end
end
