# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

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

  alias MixerBroadcaster.{Auth, Chart, Clock, Loss, Mesh, Packet, Rooms}

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

    state = %{
      room: room,
      mode: mode,
      admitted: mode == :off,
      nonce: nil,
      tries: 0,
      token: nil,
      thumb: nil,
      loss: Loss.from_env(),
      live: MapSet.new()
    }

    if state.admitted, do: join(room)
    if state.admitted, do: send(self(), :replay)
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
    case lose(state) do
      {:drop, state} ->
        {:ok, state, []}

      {:pass, state} ->
        {state, reply} = handle_message(data, state)
        {:ok, state, datagram_replies(reply)}
    end
  end

  @impl true
  def handle_info({:relay, from, bin}, state) when from != self() do
    case lose(state) do
      {:drop, state} -> {:ok, state}
      {:pass, state} -> {:ok, %{state | live: remember(state.live, bin)}, [{:send_datagram, bin}]}
    end
  end

  # a client that joins late gets the last packet of every entity in the room
  # Datagrams can be lost and the first may leave before the client is listening, so the replay goes out three times.
  def handle_info(:replay, state), do: handle_info({:replay, 3}, state)

  def handle_info({:replay, n}, %{room: room} = state) do
    if n > 1, do: Process.send_after(self(), {:replay, n - 1}, 250)

    {sends, state} =
      Enum.flat_map_reduce(Rooms.entities(room), state, fn pkt, st ->
        # an entity this session already heard live is newer than the stored copy: replaying it would go backwards
        case if(live?(st.live, pkt), do: {:drop, st}, else: lose(st)) do
          {:drop, st} -> {[], st}
          {:pass, st} -> {[{:send_datagram, pkt}], st}
        end
      end)

    {:ok, state, sends}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_stream_closed(_stream, _reason, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # a snapshot goes back to the asker; "ok"/"error" answer a stream only
  defp datagram_for("{\"t\":\"snapshot\"" <> _ = snapshot), do: [{:send_datagram, snapshot}]
  defp datagram_for(_), do: []

  # A request that came as a datagram is answered as datagrams: a client such as Godot's `WebTransportPeer` reads no
  # reply from a bidi stream. A pose's "ok" is dropped (it would answer every packet), and a mesh reply too big for one
  # datagram is cut into several (`Mesh.split/1`).
  defp datagram_replies(~s({"t":"ok"})), do: []
  defp datagram_replies(~s({"t":"error","reason":"bad_packet"})), do: []

  defp datagram_replies("{\"t\":\"mesh\"" <> _ = reply),
    do: Enum.map(Mesh.split(reply), &{:send_datagram, &1})

  defp datagram_replies("{" <> _ = reply), do: [{:send_datagram, reply}]
  defp datagram_replies(_), do: []

  defp handle_message(data, %{admitted: false} = state), do: gate(data, state)

  # A pose: exactly one 100-byte entity packet. The relay stamps its clock and forwards it to the room.
  # (A JSON message of exactly 100 bytes would land here; every real one is shorter.)
  defp handle_message(<<_::binary-size(100)>> = pkt, %{room: room} = state) do
    with true <- Packet.valid?(pkt),
         {:ok, word} <- Clock.stamp(Packet.hlc(pkt)) do
      stamped = Packet.put_hlc(pkt, word)
      keep(room, stamped)
      relay(room, stamped)
      {state, ~s({"t":"ok"})}
    else
      _ -> {state, ~s({"t":"error","reason":"bad_packet"})}
    end
  end

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

      {:ok, %{"t" => "mesh", "digest" => hex}} ->
        {state, Mesh.grant(state, hex)}

      _ ->
        {state, ~s({"t":"error","reason":"bad_message"})}
    end
  end

  # An ENTITY_REMOVE command (type 211, inline, the entity's id as its first four bytes) takes the entity out of the
  # room's stored content and is not stored itself: every remove shares one command key, so keeping them would let
  # each replace the last, and a player who joins late would be replayed a remove for an entity it never heard of.
  # Everything else is stored by its id, the newest replacing the older.
  defp keep(
         room,
         <<_::binary-size(4), 0, gid::little-32, _::binary-size(42), 128, 211::little-16,
           _::binary>> = pkt
       ) do
    used = Bitwise.bsr(:binary.decode_unsigned(binary_part(pkt, 52, 4), :little), 16)
    if used >= 5, do: Rooms.delete_entity(room, gid)
  end

  defp keep(room, pkt), do: Rooms.put_entity(room, pkt)

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
         {:ok, thumbprint} <-
           Auth.admit(mode, token, pub, sig, room, nonce, System.os_time(:second)) do
      join(room)
      send(self(), :replay)
      {%{state | admitted: true, token: token, thumb: thumbprint}, ~s({"t":"ready"})}
    else
      _ -> {state, ~s({"t":"error","reason":"denied"})}
    end
  end

  # one verdict per datagram, in either direction, from this session's own channel
  defp lose(state) do
    {verdict, loss} = Loss.step(state.loss)
    {verdict, %{state | loss: loss}}
  end

  defp remember(live, <<gid::binary-size(4), _::binary>>), do: MapSet.put(live, gid)
  defp remember(live, _), do: live
  defp live?(live, <<gid::binary-size(4), _::binary>>), do: MapSet.member?(live, gid)

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
