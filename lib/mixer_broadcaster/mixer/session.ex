# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mixer.Session do
  @moduledoc """
  One client of the relay speaking the Mixer protocol, at `/mixer`.

    * Before admission, the first bidi stream carries the hub's JSON `hello` / `challenge` / `auth` (a token is far too
      big for a packet, and there is no store before login). The proof signs "mixer-session-v1" + nonce. With
      `auth: :off` (the demo) the session is admitted at once.
    * After admission, a bidi stream carries commands as 100-byte packets (`MixerBroadcaster.Command`), and datagrams
      carry poses (any other class). The relay answers on the stream the client sent its first command on.
    * A command that is not a whole number of packets, a malformed packet or a command the core refuses gets
      `SEND_ERROR`, never a crash.
  """
  @behaviour :webtransport_handler

  alias MixerBroadcaster.{Auth, Clock, Command, Loss, Packet}
  alias MixerBroadcaster.Mixer.{Server, Store, Wire}

  @pose Wire.type(:entity_state)

  @impl true
  def init(_session, _req, _opts) do
    mode = Application.get_env(:mixer_broadcaster, :auth)

    state = %{
      mode: mode,
      admitted: mode == :off,
      id: nil,
      allow: fn _ -> true end,
      nonce: nil,
      tries: 0,
      buf: <<>>,
      stream: nil,
      loss: Loss.from_env()
    }

    {:ok, if(state.admitted, do: connect(state), else: state)}
  end

  @impl true
  def handle_stream(stream, :bidi, data, %{admitted: false} = state) do
    {state, reply} = gate(data, state)
    {:ok, state, [{:send, stream, reply, :fin}]}
  end

  def handle_stream(stream, :bidi, data, state) do
    {state, errors} =
      take_packets(%{state | stream: state.stream || stream, buf: state.buf <> data})

    {:ok, state, Enum.map(errors, &{:send, state.stream, &1})}
  end

  def handle_stream(_stream, :uni, _data, state), do: {:ok, state}

  @impl true
  def handle_datagram(pkt, %{admitted: true, id: id} = state) when byte_size(pkt) == 100 do
    case lose(state) do
      {:drop, state} ->
        {:ok, state, []}

      {:pass, state} ->
        with true <- Packet.valid?(pkt), {:ok, word} <- Clock.stamp(Packet.hlc(pkt)) do
          Server.command(id, %{type: @pose, id: 0, data: Packet.put_hlc(pkt, word)})
        end

        {:ok, state, []}
    end
  end

  def handle_datagram(_data, state), do: {:ok, state, []}

  @impl true
  def handle_info({:mixer_out, @pose, pkt}, state) do
    case lose(state) do
      {:drop, state} -> {:ok, state}
      {:pass, state} -> {:ok, state, [{:send_datagram, pkt}]}
    end
  end

  def handle_info({:mixer_out, type, data}, %{stream: nil} = state)
      when is_integer(type) and is_binary(data),
      do: {:ok, state}

  def handle_info({:mixer_out, type, data}, %{stream: stream} = state) do
    {:ok, word} = Clock.stamp(0)

    case Command.pack(type, data, 0, word, &Store.put/1) do
      {:ok, pkt} -> {:ok, state, [{:send, stream, pkt}]}
      {:error, _} -> {:ok, state}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_stream_closed(_stream, _reason, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{id: id}) when is_binary(id), do: Server.disconnect(id)
  def terminate(_reason, _state), do: :ok

  # ---- packets in ----

  defp take_packets(%{buf: buf} = state) when byte_size(buf) < 100, do: {state, []}

  defp take_packets(%{buf: <<pkt::binary-size(100), rest::binary>>} = state) do
    state = %{state | buf: rest}

    case Command.unpack(pkt, &Store.get/1) do
      {:ok, %{type: type, data: data}} ->
        Server.command(state.id, %{type: type, id: 0, data: data})
        take_packets(state)

      {:error, reason} ->
        {state, errors} = take_packets(state)
        {state, [error_packet(reason) | errors]}
    end
  end

  defp error_packet(reason) do
    {:ok, pkt} =
      Command.pack(Wire.type(:send_error), "bad command packet: #{reason}", 0, 0, &Store.put/1)

    pkt
  end

  # ---- the door ----

  defp gate(_data, %{tries: n} = state) when n >= 3,
    do: {state, ~s({"t":"error","reason":"locked"})}

  defp gate(data, state) do
    case JSON.decode(data) do
      {:ok, %{"t" => "hello"}} ->
        nonce = Auth.nonce()

        {%{state | nonce: nonce},
         JSON.encode!(%{t: "challenge", nonce: Base.url_encode64(nonce, padding: false)})}

      {:ok, %{"t" => "auth", "token" => t, "key" => k, "sig" => sg}} ->
        attempt(state, t, k, sg)

      _ ->
        {state, ~s({"t":"error","reason":"unauthenticated"})}
    end
  end

  defp attempt(%{nonce: nil} = state, _, _, _),
    do: {state, ~s({"t":"error","reason":"unauthenticated"})}

  defp attempt(%{mode: mode, nonce: nonce} = state, t, k, sg) do
    state = %{state | nonce: nil, tries: state.tries + 1}

    with {:ok, token} <- unb64(t),
         {:ok, pub} <- unb64(k),
         {:ok, sig} <- unb64(sg),
         {:ok, _tp, allow} <-
           Auth.admit_session(mode, token, pub, sig, nonce, System.os_time(:second)) do
      {connect(%{state | allow: allow, admitted: true}), ~s({"t":"ready"})}
    else
      _ -> {state, ~s({"t":"error","reason":"denied"})}
    end
  end

  defp unb64(s) when is_binary(s), do: Base.url_decode64(s, padding: false)
  defp unb64(_), do: :error

  defp connect(state), do: %{state | id: Server.connect("127.0.0.1", 0, state.allow)}

  defp lose(state) do
    {verdict, loss} = Loss.step(state.loss)
    {verdict, %{state | loss: loss}}
  end
end
