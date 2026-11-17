defmodule MixerBroadcaster.EntityRemoveTest do
  @moduledoc """
  GOLDEN: a player creates an entity (a pose), changes it (a newer pose) and removes it (an ENTITY_REMOVE command with
  the entity's id); after the remove the room no longer stores the entity, so a player who joins late never sees it, and
  the other players in the room hear the remove live.
  INVARIANT: removing any set of entities, in any order, leaves exactly the ones not removed.
  CONTROL: a remove for an id nobody posted, for an entity in another room, and a remove with a short or odd payload
  change nothing and never crash; a remove is not stored as an entity itself (it would replay to a late joiner).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Clock, Command, Hub, Packet, Rooms}

  @remove 211

  setup do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    %{room: "rm-#{System.unique_integer([:positive])}"}
  end

  defp session(room), do: elem(Hub.init(nil, %{path: "/room/#{room}"}, []), 1)

  # a stamped 100-byte pose of class 4 for entity `gid`, at x = `x` metres (millionths on the wire)
  defp pose(gid, x) do
    {:ok, word} = Clock.stamp(0)

    Packet.put_hlc(
      <<gid::little-32, round(x * 1_000_000)::little-signed-64, 0::unit(8)-size(28), 0::64,
        0::little-24, 4, 0::unit(8)-size(48)>>,
      word
    )
  end

  defp remove_pkt(payload) do
    {:ok, pkt} = Command.pack(@remove, payload, 1, 0, fn _ -> flunk("inline") end)
    pkt
  end

  defp send_packet(state, pkt) do
    {:ok, st, _} = Hub.handle_datagram(pkt, state)
    st
  end

  defp stored_gids(room),
    do: for(<<gid::little-32, _::binary>> <- Rooms.entities(room), do: gid) |> Enum.sort()

  test "golden: create, change, then remove: the room forgets the entity", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    assert stored_gids(room) == [7]
    a = send_packet(a, pose(7, 2.5))
    assert stored_gids(room) == [7]
    _ = send_packet(a, remove_pkt(<<7::little-32>>))
    assert stored_gids(room) == []
  end

  test "golden: a player who joins after the remove is replayed nothing", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    _ = send_packet(a, remove_pkt(<<7::little-32>>))
    late = session(room)
    assert {:ok, _, []} = Hub.handle_info(:replay, late)
  end

  test "golden: the others in the room hear the remove live", %{room: room} do
    me = self()

    listener =
      spawn_link(fn ->
        {:ok, _} = Registry.register(MixerBroadcaster.Registry, room, nil)
        send(me, :listening)

        receive do
          {:relay, _, bin} -> send(me, {:heard, bin})
        end
      end)

    assert_receive :listening
    a = session(room)
    pkt = remove_pkt(<<7::little-32>>)
    _ = send_packet(a, pkt)
    assert_receive {:heard, bin}, 1000
    assert Packet.valid?(bin)

    assert {:ok, %{type: @remove, data: <<7::little-32>>}} =
             Command.unpack(bin, fn _ -> {:error, :none} end)

    Process.exit(listener, :normal)
  end

  test "control: two removes, one after the other, both take effect", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    a = send_packet(a, pose(8, 1.0))
    a = send_packet(a, pose(9, 2.0))
    a = send_packet(a, remove_pkt(<<7::little-32>>))
    assert stored_gids(room) == [8, 9]
    _ = send_packet(a, remove_pkt(<<9::little-32>>))
    assert stored_gids(room) == [8]
  end

  test "control: a remove is not stored as an entity itself", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    pkt = remove_pkt(<<7::little-32>>)
    <<key::little-32, _::binary>> = pkt
    _ = send_packet(a, pkt)
    refute key in stored_gids(room)
    assert Rooms.entities(room) == []
  end

  test "control: a remove for an id nobody posted changes nothing", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    _ = send_packet(a, remove_pkt(<<99::little-32>>))
    assert stored_gids(room) == [7]
  end

  test "control: a remove in another room does not touch this one", %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))
    other = session(room <> "-other")
    _ = send_packet(other, remove_pkt(<<7::little-32>>))
    assert stored_gids(room) == [7]
    _ = a
  end

  test "control: a short remove payload names no entity; a longer one names the first four bytes",
       %{room: room} do
    a = session(room)
    a = send_packet(a, pose(7, 0.0))

    for payload <- [<<>>, <<7>>, <<7, 0, 0>>] do
      _ = send_packet(a, remove_pkt(payload))
    end

    assert stored_gids(room) == [7]

    for payload <- [<<8::little-32, 1, 2, 3>>, :binary.copy(<<255>>, 40)] do
      _ = send_packet(a, remove_pkt(payload))
    end

    assert stored_gids(room) == [7]
    _ = send_packet(a, remove_pkt(<<7::little-32, 1, 2, 3>>))
    assert stored_gids(room) == []
  end

  property "removing any subset leaves exactly the rest", %{room: room} do
    check all(
            gids <- uniq_list_of(integer(1..100_000), min_length: 1, max_length: 12),
            gone <- list_of(member_of(gids), max_length: 12),
            max_runs: 25
          ) do
      r = room <> "-#{System.unique_integer([:positive])}"
      a = session(r)
      a = Enum.reduce(gids, a, &send_packet(&2, pose(&1, 0.5)))
      Enum.reduce(gone, a, &send_packet(&2, remove_pkt(<<&1::little-32>>)))
      assert stored_gids(r) == Enum.sort(gids -- gone)
    end
  end
end
