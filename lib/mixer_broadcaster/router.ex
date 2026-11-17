defmodule MixerBroadcaster.Router do
  @moduledoc """
  The listener has one handler, so this one picks by path: `/mixer` is the Mixer protocol (`Mixer.Session`), anything
  else is the room hub (`Hub`). It holds the chosen module and its state and passes every callback through.
  """
  @behaviour :webtransport_handler

  alias MixerBroadcaster.{Hub, Mixer}

  @impl true
  defdelegate origin_check(headers, opts), to: Hub

  @impl true
  def init(session, req, opts) do
    mod = if Map.get(req, :path, "/") == "/mixer", do: Mixer.Session, else: Hub
    wrap(mod, mod.init(session, req, opts))
  end

  @impl true
  def handle_stream(stream, kind, data, {mod, st}),
    do: wrap(mod, mod.handle_stream(stream, kind, data, st))

  @impl true
  def handle_datagram(data, {mod, st}), do: wrap(mod, mod.handle_datagram(data, st))
  @impl true
  def handle_info(msg, {mod, st}), do: wrap(mod, mod.handle_info(msg, st))
  @impl true
  def handle_stream_closed(stream, reason, {mod, st}),
    do: wrap(mod, mod.handle_stream_closed(stream, reason, st))

  @impl true
  def terminate(reason, {mod, st}), do: mod.terminate(reason, st)

  defp wrap(mod, {:ok, st}), do: {:ok, {mod, st}}
  defp wrap(mod, {:ok, st, actions}), do: {:ok, {mod, st}, actions}
  defp wrap(_mod, other), do: other
end
