# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mixer.BridgeTest do
  @moduledoc """
  GOLDEN: a pose from a Mixer client in room R reaches the hub's room R (stored for late joiners, relayed to its sessions).
  CONTROL: a client in no room, a client in another room and a packet that is not 100 bytes reach nothing.
  """
  use ExUnit.Case, async: false

  alias MixerBroadcaster.{Rooms, Command}
  alias MixerBroadcaster.Mixer.{Server, Store, Wire}

  @pose Wire.type(:entity_state)

  defp pkt(gid, x), do: <<gid::little-32, x, 0::unit(8)-size(94), 0, 0>> |> binary_part(0, 100)

  defp join_data(room),
    do:
      Wire.string(room) <>
        Wire.string("godot") <> Wire.string("4.8") <> Wire.string("1") <> Wire.bool(false)

  # a stand-in for a hub session: registered in the room, it hears {:relay, from, packet}
  defp hub_listener(room) do
    parent = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(MixerBroadcaster.Registry, room, nil)
      send(parent, :registered)

      receive do
        :report -> send(parent, {:heard, collect([])})
      end
    end)
  end

  defp collect(acc) do
    receive do
      {:relay, _, p} -> collect([p | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp heard(pid) do
    Process.sleep(80)
    send(pid, :report)
    assert_receive {:heard, got}, 1000
    got
  end

  defp client, do: Server.connect("127.0.0.1", 0, fn _ -> true end)

  defp in_room(room) do
    id = client()
    Server.command(id, %{type: Wire.type(:join_room), id: 0, data: join_data(room)})
    id
  end

  test "golden: a pose in room R reaches the hub's room R and is kept for a late joiner" do
    room = "bridge-#{System.unique_integer([:positive])}"
    l = hub_listener(room)
    assert_receive :registered
    id = in_room(room)
    Server.command(id, %{type: @pose, id: 0, data: pkt(7, 9)})
    assert heard(l) == [pkt(7, 9)]
    assert Rooms.entities(room) == [pkt(7, 9)]
  end

  test "control: no room, another room and short packets reach nothing" do
    room = "bridge-#{System.unique_integer([:positive])}"
    l = hub_listener(room)
    assert_receive :registered
    server = Process.whereis(Server)

    Server.command(client(), %{type: @pose, id: 0, data: pkt(1, 1)})
    other = in_room("elsewhere-#{System.unique_integer([:positive])}")
    Server.command(other, %{type: @pose, id: 0, data: pkt(2, 2)})
    id = in_room(room)
    Server.command(id, %{type: @pose, id: 0, data: <<1, 2, 3>>})
    assert heard(l) == []
    assert Rooms.entities(room) == []
    assert Process.whereis(Server) == server, "a bad packet must not take the server down"
    assert Store.impl() && Command.size() == 100
  end
end
