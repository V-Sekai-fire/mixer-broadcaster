defmodule MixerBroadcaster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The WebTransport listener is started on demand by MixerBroadcaster.Server.start/1
    Supervisor.start_link([], strategy: :one_for_one, name: MixerBroadcaster.Supervisor)
  end
end
