defmodule MixerBroadcaster.Hub do
  @moduledoc """
  Room hub on top of the transport. A client connects to `/room/<name>`.

    * client to hub: JSON on a bidi stream (reliable) or a datagram,
      `{"t":"hello"}` asks for the current chart, `{"t":"set","id":0..23,"rgb":[r,g,b]}` changes a patch.
    * hub to clients: datagrams (the other sessions of the room get every accepted `set`; `hello` gets a snapshot).

  The hub never looks inside a room it is not in, so a client in another room sees nothing.

  Zero trust: unless `config :mixer_broadcaster, :auth` is `:off` (the local demo only), a session is not put in
  its room until it has been admitted. `hello` returns a fresh nonce; `auth` carries a token, the player's
  public key and a signature over the nonce (see `MixerBroadcaster.Auth`). Anything else gets
  `unauthenticated`. With no `:auth` configured at all, nobody is admitted.
  """
  @behaviour :webtransport_handler

  alias MixerBroadcaster.{Auth, Chart, Rooms}

  # Browsers always send an Origin; the library refuses those with 403 unless the handler opts in.
  # Only the origins of our own page are let in; non-browser clients send no Origin and always pass.
  @impl true
  def origin_check(headers, _opts) do
    allowed =
      Application.get_env(:mixer_broadcaster, :allowed_origins, [
        "http://localhost:4000",
        "http://127.0.0.1:4000"
      ])

    case List.keyfind(headers, "origin", 0) do
      {_, origin} -> if origin in allowed, do: :accept, else: {:reject, 403, "origin not allowed"}
      nil -> :accept
    end
  end

  @impl true
  def init(_session, req, _opts) do
    room = room_of(Map.get(req, :path, "/"))
    mode = Application.get_env(:mixer_broadcaster, :auth)
    state = %{room: room, mode: mode, admitted: mode == :off, nonce: nil, tries: 0}
    if state.admitted, do: join(room)
    {:ok, state}
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
  def handle_info({:relay, from, bin}, state) when from != self(),
    do: {:ok, state, [{:send_datagram, bin}]}

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_stream_closed(_stream, _reason, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # a snapshot goes back to the asker; "ok"/"error" answer a stream only
  defp datagram_for("{\"t\":\"snapshot\"" <> _ = snapshot), do: [{:send_datagram, snapshot}]
  defp datagram_for(_), do: []

  defp handle_message(data, %{admitted: false} = state), do: gate(data, state)

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

  # Before admission: only `hello` (answered with a nonce) and `auth` are understood. Every refusal looks the
  # same to the client; after `three` attempts the session stays locked.
  defp gate(_data, %{tries: n} = state) when n >= 3,
    do: {state, ~s({"t":"error","reason":"locked"})}

  defp gate(data, state) do
    case JSON.decode(data) do
      {:ok, %{"t" => "hello"}} ->
        nonce = Auth.nonce()
        {%{state | nonce: nonce}, JSON.encode!(%{t: "challenge", nonce: b64(nonce)})}

      {:ok, %{"t" => "auth", "token" => t, "key" => k, "sig" => sg}} ->
        attempt(state, t, k, sg)

      _ ->
        {state, ~s({"t":"error","reason":"unauthenticated"})}
    end
  end

  defp attempt(%{nonce: nil} = state, _, _, _),
    do: {state, ~s({"t":"error","reason":"unauthenticated"})}

  defp attempt(%{room: room, mode: mode, nonce: nonce} = state, t, k, sg) do
    state = %{state | nonce: nil, tries: state.tries + 1}

    with {:ok, token} <- unb64(t),
         {:ok, pub} <- unb64(k),
         {:ok, sig} <- unb64(sg),
         {:ok, _thumbprint} <-
           Auth.admit(mode, token, pub, sig, room, nonce, System.os_time(:second)) do
      join(room)
      {%{state | admitted: true}, ~s({"t":"ready"})}
    else
      _ -> {state, ~s({"t":"error","reason":"denied"})}
    end
  end

  defp join(room), do: {:ok, _} = Registry.register(MixerBroadcaster.Registry, room, nil)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(s) when is_binary(s), do: Base.url_decode64(s, padding: false)
  defp unb64(_), do: :error

  defp relay(room, bin) do
    me = self()

    Registry.dispatch(MixerBroadcaster.Registry, room, fn entries ->
      for {pid, _} <- entries, pid != me, do: send(pid, {:relay, me, bin})
    end)
  end

  defp room_of("/room/" <> name) when name != "", do: name
  defp room_of(_), do: "default"
end
