defmodule MixerBroadcaster.Rooms do
  @moduledoc "Room chart state held on the server, so a client that joins late gets the current chart."
  use Agent

  alias MixerBroadcaster.Chart

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

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
