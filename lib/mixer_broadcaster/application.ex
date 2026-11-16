defmodule MixerBroadcaster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The WebTransport listener is started on demand by MixerBroadcaster.Server.start/1
    children = [
      {Registry, keys: :duplicate, name: MixerBroadcaster.Registry},
      MixerBroadcaster.Rooms
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MixerBroadcaster.Supervisor)
  end
end
