defmodule MixerBroadcaster.Mixer.Server do
  @moduledoc """
  The one process that owns the Mixer rooms (`Mixer.Core`). A session registers, sends its commands here and receives
  what the core says to send it as `{:mixer_out, type, data}`. The core stays pure; this is only its mailbox.
  """
  use GenServer

  alias MixerBroadcaster.Mixer.Core

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Register the calling process as a client. `allow.(room)` says which rooms its token covers. Returns its id."
  def connect(server \\ __MODULE__, ip, port, allow),
    do: GenServer.call(server, {:connect, self(), ip, port, allow})

  def command(server \\ __MODULE__, id, cmd), do: GenServer.cast(server, {:command, id, cmd})
  def disconnect(server \\ __MODULE__, id), do: GenServer.cast(server, {:disconnect, id})
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @impl true
  def init(:ok) do
    _ = :ets.new(MixerBroadcaster.Mixer.Store.Memory.table_name(), [:set, :public, :named_table])
    {:ok, %{core: Core.new(), pids: %{}}}
  end

  @impl true
  def handle_call({:connect, pid, ip, port, allow}, _from, st) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Process.monitor(pid)

    {:reply, id,
     %{st | core: Core.connect(st.core, id, ip, port, allow), pids: Map.put(st.pids, id, pid)}}
  end

  def handle_call(:state, _from, st), do: {:reply, st.core, st}

  @impl true
  def handle_cast({:command, id, cmd}, st) do
    {core, outs} = Core.handle(st.core, id, cmd)
    deliver(outs, st.pids)
    bridge_pose(core, id, cmd)
    {:noreply, %{st | core: core}}
  end

  def handle_cast({:disconnect, id}, st), do: {:noreply, drop(st, id)}

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, st) do
    case Enum.find(st.pids, fn {_, p} -> p == pid end) do
      {id, _} -> {:noreply, drop(st, id)}
      nil -> {:noreply, st}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  # A pose from a Mixer client also goes to the hub's room of the same name, so viewers that watch `/room/<name>`
  # (three.js, Godot, the model explorer) see what the add-on moves. Only a client that is in a room, and only a
  # pose the core accepted (a whole 100-byte packet).
  defp bridge_pose(core, id, %{type: 210, data: <<_::binary-size(100)>> = pkt}) do
    with %{room: room} when is_binary(room) <- core.clients[id] do
      MixerBroadcaster.Rooms.put_entity(room, pkt)
      me = self()

      Registry.dispatch(MixerBroadcaster.Registry, room, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:relay, me, pkt})
      end)
    end

    :ok
  end

  defp bridge_pose(_, _, _), do: :ok

  defp drop(st, id) do
    {core, outs} = Core.disconnect(st.core, id)
    pids = Map.delete(st.pids, id)
    deliver(outs, pids)
    %{st | core: core, pids: pids}
  end

  defp deliver(outs, pids) do
    for {cid, {type, data}} <- outs, pid = pids[cid], do: send(pid, {:mixer_out, type, data})
    :ok
  end
end
