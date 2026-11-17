# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Server do
  @moduledoc """
  The broadcaster's one listener: HTTP/3 WebTransport (QUIC), nothing else.

  Transport semantics follow entities-godot `WebTransportPeer` so both ends agree:

    * unreliable packets are QUIC datagrams,
    * each reliable packet is its own bidirectional stream, sent with FIN.

  Every function answers `{:ok, value}` or `{:error, reason}`; nothing here raises.
  """

  @doc """
  Start a listener. Options: `:port` (0 picks a free one), `:certfile`, `:keyfile`, `:name`, `:handler`.
  Returns `{:ok, %{name: name, port: port}}`.
  """
  @spec start(keyword()) :: {:ok, %{name: atom(), port: :inet.port_number()}} | {:error, term()}
  def start(opts) do
    name = Keyword.get(opts, :name, :mixer_broadcaster)

    listener_opts = %{
      transport: :h3,
      port: Keyword.get(opts, :port, 0),
      certfile: String.to_charlist(Keyword.fetch!(opts, :certfile)),
      keyfile: String.to_charlist(Keyword.fetch!(opts, :keyfile)),
      handler: Keyword.get(opts, :handler, MixerBroadcaster.Handler),
      compat_mode: Keyword.get(opts, :compat_mode, :auto)
    }

    with {:ok, _pid} <- :webtransport.start_listener(name, listener_opts),
         {:ok, {_ip, port}} <- :webtransport.listener_sockname(name) do
      {:ok, %{name: name, port: port}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(atom()) :: :ok | {:error, term()}
  def stop(name), do: :webtransport.stop_listener(name)
end
