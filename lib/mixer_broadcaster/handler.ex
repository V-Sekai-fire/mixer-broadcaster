defmodule MixerBroadcaster.Handler do
  @moduledoc """
  Session handler. First increment (Gall's law): echo every reliable packet and datagram back to its sender.
  Rooms and fan-out are built on top of this once the transport is proven.
  """
  @behaviour :webtransport_handler

  @impl true
  def init(_session, _request, _opts), do: {:ok, %{}}

  @impl true
  def handle_stream(stream, :bidi, data, state), do: {:ok, state, [{:send, stream, data}]}
  def handle_stream(_stream, :uni, _data, state), do: {:ok, state}

  @impl true
  def handle_datagram(data, state), do: {:ok, state, [{:send_datagram, data}]}

  @impl true
  def handle_stream_closed(_stream, _reason, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
