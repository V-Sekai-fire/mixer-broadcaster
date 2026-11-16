defmodule MixerBroadcaster.Hub do
  @moduledoc """
  Room hub on top of the transport. A client connects to `/room/<name>`.

    * client to hub: JSON on a bidi stream (reliable) or a datagram,
      `{"t":"hello"}` asks for the current chart, `{"t":"set","id":0..23,"rgb":[r,g,b]}` changes a patch.
    * hub to clients: datagrams (the other sessions of the room get every accepted `set`; `hello` gets a snapshot).

  The hub never looks inside a room it is not in, so a client in another room sees nothing.
  """
  @behaviour :webtransport_handler

  alias MixerBroadcaster.{Chart, Rooms}

  # Browsers always send an Origin; the library refuses those with 403 unless the handler opts in.
  # Only the origins of our own page are let in; non-browser clients send no Origin and always pass.
  @impl true
  def origin_check(headers, _opts) do
    allowed = Application.get_env(:mixer_broadcaster, :allowed_origins, ["http://localhost:4000", "http://127.0.0.1:4000"])

    case List.keyfind(headers, "origin", 0) do
      {_, origin} -> if origin in allowed, do: :accept, else: {:reject, 403, "origin not allowed"}
      nil -> :accept
    end
  end

  @impl true
  def init(_session, req, _opts) do
    room = room_of(Map.get(req, :path, "/"))
    {:ok, _} = Registry.register(MixerBroadcaster.Registry, room, nil)
    {:ok, %{room: room}}
  end

  @impl true
  def handle_stream(stream, :bidi, data, state) do
    {state, reply} = handle_message(data, state)
    {:ok, state, [{:send, stream, reply, :fin}] ++ datagram_for(reply)}
  end

  def handle_stream(_stream, :uni, _data, state), do: {:ok, state}

  @impl true
  def handle_datagram(data, state) do
    {state, reply} = handle_message(data, state)
    {:ok, state, datagram_for(reply)}
  end

  @impl true
  def handle_info({:relay, from, bin}, state) when from != self(), do: {:ok, state, [{:send_datagram, bin}]}
  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_stream_closed(_stream, _reason, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # a snapshot goes back to the asker; "ok"/"error" answer a stream only
  defp datagram_for("{\"t\":\"snapshot\"" <> _ = snapshot), do: [{:send_datagram, snapshot}]
  defp datagram_for(_), do: []

  defp handle_message(data, %{room: room} = state) do
    case JSON.decode(data) do
      {:ok, %{"t" => "hello"}} ->
        {state, Chart.snapshot(Rooms.chart(room))}

      {:ok, %{"t" => "set", "id" => id, "rgb" => rgb}} ->
        case Rooms.set(room, id, rgb) do
          :ok ->
            relay(room, Chart.set_message(id, rgb))
            {state, ~s({"t":"ok"})}

          {:error, _} ->
            {state, ~s({"t":"error","reason":"bad_patch"})}
        end

      _ ->
        {state, ~s({"t":"error","reason":"bad_message"})}
    end
  end

  defp relay(room, bin) do
    me = self()
    Registry.dispatch(MixerBroadcaster.Registry, room, fn entries ->
      for {pid, _} <- entries, pid != me, do: send(pid, {:relay, me, bin})
    end)
  end

  defp room_of("/room/" <> name) when name != "", do: name
  defp room_of(_), do: "default"
end
