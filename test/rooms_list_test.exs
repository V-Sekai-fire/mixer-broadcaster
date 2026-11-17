# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.RoomsListTest do
  @moduledoc """
  GOLDEN: the list names every room with a player or a remembered entity, with both counts.
  INVARIANT: for any set of sessions, each room's player count is the number of sessions in it.
  CONTROL: a room nobody joined is absent; an unadmitted session is not counted; a room whose players left keeps its entities.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Hub, Rooms}

  setup do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    :ok
  end

  # a session is a process that joined the room and stays until told to stop
  defp session(room, mode \\ :off) do
    parent = self()

    pid =
      spawn(fn ->
        Application.put_env(:mixer_broadcaster, :auth, mode)
        {:ok, _} = Hub.init(nil, %{path: "/room/#{room}"}, [])
        send(parent, {:in, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:in, ^pid}
    pid
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, _, _, _}
    # the registry drops the entry when the process is gone
    Process.sleep(20)
  end

  defp mine(prefix), do: Rooms.list() |> Enum.filter(&String.starts_with?(&1.name, prefix))

  test "golden: players and entities are counted per room, sorted by name" do
    p = "g#{System.unique_integer([:positive])}-"
    a1 = session(p <> "b")
    a2 = session(p <> "b")
    c1 = session(p <> "a")
    Rooms.put_entity(p <> "b", <<1::little-32, 0::size(768)>>)
    Rooms.put_entity(p <> "b", <<2::little-32, 0::size(768)>>)

    assert mine(p) == [
             %{name: p <> "a", players: 1, entities: 0},
             %{name: p <> "b", players: 2, entities: 2}
           ]

    Enum.each([a1, a2, c1], &stop/1)
  end

  test "control: a room that was never joined is absent, and an unadmitted session is not a player" do
    p = "c#{System.unique_integer([:positive])}-"
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: :crypto.strong_rand_bytes(32)})
    stranger = session(p <> "locked", %{root_key: :crypto.strong_rand_bytes(32)})
    assert mine(p) == []
    stop(stranger)
  end

  test "control: when its players leave, a room that holds entities stays and an empty one goes" do
    p = "l#{System.unique_integer([:positive])}-"
    a = session(p <> "kept")
    b = session(p <> "empty")
    Rooms.put_entity(p <> "kept", <<7::little-32, 0::size(768)>>)
    stop(a)
    stop(b)
    assert mine(p) == [%{name: p <> "kept", players: 0, entities: 1}]
  end

  property "invariant: each room's player count is the number of sessions in it" do
    check all(
            counts <- list_of(integer(0..4), min_length: 1, max_length: 4),
            max_runs: 15
          ) do
      p = "p#{System.unique_integer([:positive])}-"

      pids =
        for {n, i} <- Enum.with_index(counts), _ <- 1..n//1, do: {i, session(p <> "r#{i}")}

      want =
        for {n, i} <- Enum.with_index(counts),
            n > 0,
            do: %{name: p <> "r#{i}", players: n, entities: 0}

      assert mine(p) == Enum.sort_by(want, & &1.name)
      Enum.each(pids, fn {_, pid} -> stop(pid) end)
    end
  end
end
