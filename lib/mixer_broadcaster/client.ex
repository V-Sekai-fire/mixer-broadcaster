defmodule MixerBroadcaster.Client do
  @moduledoc """
  WebTransport client with the same transfer modes as entities-godot `WebTransportPeer`:
  `send_unreliable/2` is a QUIC datagram, `send_reliable/3` opens a fresh bidirectional stream and sends with FIN.

  Replies arrive as messages to the process that connected; use `recv_reliable/4` and `recv_unreliable/2`.
  """

  @type session :: pid()

  @type stream :: non_neg_integer()

  @spec connect(String.t(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def connect(host, port, path \\ "/mixer", opts \\ []) do
    :webtransport.connect(String.to_charlist(host), port, path, %{
      transport: :h3,
      verify: Keyword.get(opts, :verify, :verify_peer),
      cacertfile: Keyword.get(opts, :cacertfile) |> cacertfile_opt(),
      compat_mode: Keyword.get(opts, :compat_mode, :latest)
    })
  end

  defp cacertfile_opt(nil), do: nil
  defp cacertfile_opt(path), do: String.to_charlist(path)

  @doc "Send one reliable packet. Returns `{:ok, stream_id}`; the reply comes back on the same stream."
  @spec send_reliable(session(), binary(), keyword()) :: {:ok, stream()} | {:error, term()}
  def send_reliable(session, packet, opts \\ []) when is_binary(packet) do
    with {:ok, stream} <- :webtransport.open_stream(session, :bidi),
         :ok <- send_fin(session, stream, packet, Keyword.get(opts, :fin, true)) do
      {:ok, stream}
    end
  end

  defp send_fin(session, stream, packet, true),
    do: :webtransport.send(session, stream, packet, :fin)

  defp send_fin(session, stream, packet, false), do: :webtransport.send(session, stream, packet)

  @spec send_unreliable(session(), binary()) :: :ok | {:error, term()}
  def send_unreliable(session, packet) when is_binary(packet),
    do: :webtransport.send_datagram(session, packet)

  @doc "Collect the reply on `stream` until `expected` bytes arrived or `timeout` ms passed."
  @spec recv_reliable(session(), stream(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, {:timeout, non_neg_integer()}}
  def recv_reliable(session, stream, expected, timeout \\ 5_000),
    do: collect(session, stream, expected, <<>>, timeout)

  defp collect(_session, _stream, expected, acc, _timeout) when byte_size(acc) >= expected,
    do: {:ok, acc}

  defp collect(session, stream, expected, acc, timeout) do
    receive do
      {:webtransport, ^session, {:stream, ^stream, :bidi, data}} ->
        collect(session, stream, expected, acc <> data, timeout)
    after
      timeout -> {:error, {:timeout, byte_size(acc)}}
    end
  end

  @spec recv_unreliable(session(), timeout()) :: {:ok, binary()} | {:error, :timeout}
  def recv_unreliable(session, timeout \\ 5_000) do
    receive do
      {:webtransport, ^session, {:datagram, data}} -> {:ok, data}
    after
      timeout -> {:error, :timeout}
    end
  end

  @spec close(session()) :: :ok
  def close(session), do: :webtransport.close_session(session)
end
