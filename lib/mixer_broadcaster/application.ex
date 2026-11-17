# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Bulk command data: in memory unless MB_STORE=s3, then SeaweedFS's S3 gateway at MB_S3 (default
    # http://127.0.0.1:8333), bucket MB_S3_BUCKET (default mixer); the keys are AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
    if System.get_env("MB_STORE") == "s3" do
      Application.put_env(:mixer_broadcaster, :mixer_store, MixerBroadcaster.Mixer.Store.S3)

      Application.put_env(:mixer_broadcaster, :s3,
        endpoint: System.get_env("MB_S3", "http://127.0.0.1:8333"),
        bucket: System.get_env("MB_S3_BUCKET", "mixer")
      )
    end

    # The WebTransport listener is started on demand by MixerBroadcaster.Server.start/1
    children = [
      {Registry, keys: :duplicate, name: MixerBroadcaster.Registry},
      MixerBroadcaster.Rooms,
      MixerBroadcaster.Mixer.Server,
      MixerBroadcaster.Clock
    ]

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: MixerBroadcaster.Supervisor)

    # A deployed relay (MB_SERVE=1) either starts closed, with its root key, or does not start at all.
    if System.get_env("MB_SERVE") == "1" do
      case MixerBroadcaster.Serve.start() do
        {:ok, info} ->
          IO.puts("relay up: udp #{info.port}, certificate sha256 #{info.cert_sha256}")
          {:ok, sup}

        {:error, reason} ->
          Supervisor.stop(sup)
          {:error, {:relay_refused, reason}}
      end
    else
      {:ok, sup}
    end
  end
end
