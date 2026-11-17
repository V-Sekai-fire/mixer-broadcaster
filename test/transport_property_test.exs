# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.TransportPropertyTest do
  @moduledoc """
  Property tests (StreamData) against a real listener on loopback and a real QUIC client.

    * GOLDEN:    fixed packets with a written-down expected reply.
    * INVARIANT: any list of reliable packets comes back byte for byte, each on its own stream, in any order.
    * CONTROL:   a client that sends nothing receives nothing; proves the receive helpers can time out.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Client, Server}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mixer_broadcaster)
    dir = Path.join(System.tmp_dir!(), "mb_#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p(dir)
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    {_out, 0} =
      System.cmd(openssl(), [
        "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert, "-days", "2", "-nodes",
        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"
      ], stderr_to_stdout: true)

    {:ok, %{port: port}} = Server.start(name: :mb_test, certfile: cert, keyfile: key)
    on_exit(fn -> Server.stop(:mb_test) end)
    {:ok, port: port, cert: cert}
  end

  # Git for Windows ships openssl outside PATH on GitHub runners
  defp openssl do
    System.find_executable("openssl") || "C:/Program Files/Git/usr/bin/openssl.exe"
  end

  defp connect!(ctx) do
    {:ok, session} = Client.connect("localhost", ctx.port, "/mixer", cacertfile: ctx.cert)
    session
  end

  test "GOLDEN: one reliable packet is echoed unchanged", ctx do
    session = connect!(ctx)
    {:ok, stream} = Client.send_reliable(session, "hello mixer")
    assert {:ok, "hello mixer"} = Client.recv_reliable(session, stream, 11)
    Client.close(session)
  end

  test "GOLDEN: one datagram is echoed unchanged", ctx do
    session = connect!(ctx)
    :ok = Client.send_unreliable(session, "ping")
    assert {:ok, "ping"} = Client.recv_unreliable(session)
    Client.close(session)
  end

  property "INVARIANT: every reliable packet returns byte for byte on its own stream", ctx do
    session = connect!(ctx)

    check all packets <- list_of(binary(min_length: 1, max_length: 4000), min_length: 1, max_length: 6),
              max_runs: 15 do
      sent =
        for p <- packets do
          {:ok, stream} = Client.send_reliable(session, p)
          {stream, p}
        end

      for {stream, p} <- sent do
        assert {:ok, ^p} = Client.recv_reliable(session, stream, byte_size(p))
      end
    end

    Client.close(session)
  end

  property "INVARIANT: a datagram of any size up to 1000 bytes is echoed", ctx do
    session = connect!(ctx)

    check all packet <- binary(min_length: 1, max_length: 1000), max_runs: 15 do
      :ok = Client.send_unreliable(session, packet)
      assert {:ok, ^packet} = Client.recv_unreliable(session)
    end

    Client.close(session)
  end

  test "CONTROL: a client that sends nothing receives nothing", ctx do
    session = connect!(ctx)
    assert {:error, :timeout} = Client.recv_unreliable(session, 500)
    assert {:error, {:timeout, 0}} = Client.recv_reliable(session, 4, 1, 500)
    Client.close(session)
  end

  test "CONTROL: a client pinned to the wrong certificate cannot connect", ctx do
    other = Path.join(Path.dirname(ctx.cert), "other.pem")
    key = Path.join(Path.dirname(ctx.cert), "other_key.pem")

    {_out, 0} =
      System.cmd(openssl(), [
        "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", other, "-days", "2", "-nodes",
        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"
      ], stderr_to_stdout: true)

    assert {:error, _} = Client.connect("localhost", ctx.port, "/mixer", cacertfile: other)
  end
end
