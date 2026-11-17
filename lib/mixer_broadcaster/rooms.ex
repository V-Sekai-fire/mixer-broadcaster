defmodule MixerBroadcaster.Rooms do
  @moduledoc "Room chart state held on the server, so a client that joins late gets the current chart."
  use Agent

  alias MixerBroadcaster.Chart

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  # Latest stamped packet of each entity (by its first four bytes, the id), so a client that joins late sees the room.
  def put_entity(room, <<gid::binary-size(4), _::binary>> = pkt) do
    Agent.update(__MODULE__, fn rooms ->
      Map.update(rooms, {:entities, room}, %{gid => pkt}, &Map.put(&1, gid, pkt))
    end)
  end

  @doc """
  The rooms that have a player in them or a remembered entity: `[%{name, players, entities}]`, by name. A room a
  client has only asked for, and never joined, is not listed; a room whose players have left stays while it still
  holds entities, so a late joiner can find it.
  """
  def list do
    players =
      MixerBroadcaster.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.frequencies()

    held =
      Agent.get(__MODULE__, fn rooms ->
        for {{:entities, room}, ents} <- rooms, into: %{}, do: {room, map_size(ents)}
      end)

    (Map.keys(players) ++ Map.keys(held))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{name: &1, players: Map.get(players, &1, 0), entities: Map.get(held, &1, 0)})
  end

  @doc """
  The mesh digests that poses in `room` name: the 32 bytes at the start of an entity's payload (byte 62), for every
  class but `command`, whose bytes mean something else. All-zero (no mesh) is left out.
  """
  def mesh_digests(room) do
    for <<_::binary-size(51), class, _::binary-size(10), digest::binary-size(32), _::binary>> <-
          entities(room),
        class != 128,
        digest != <<0::256>>,
        uniq: true,
        do: digest
  end

  def entities(room),
    do: Agent.get(__MODULE__, &(&1 |> Map.get({:entities, room}, %{}) |> Map.values()))

  def chart(room), do: Agent.get(__MODULE__, &Map.get(&1, room, Chart.default()))

  def set(room, id, rgb) do
    Agent.get_and_update(__MODULE__, fn rooms ->
      case Chart.set(Map.get(rooms, room, Chart.default()), id, rgb) do
        {:ok, chart} -> {:ok, Map.put(rooms, room, chart)}
        {:error, reason} -> {{:error, reason}, rooms}
      end
    end)
  end
end
