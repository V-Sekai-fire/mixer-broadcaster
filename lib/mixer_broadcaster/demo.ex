defmodule MixerBroadcaster.Demo do
  @moduledoc """
  One command to see the clients meet: `mix demo`.

  Makes a P-256 certificate valid 13 days (browsers accept a self-signed WebTransport server by hash only when it
  is ECDSA and lives at most 14 days), starts the hub on QUIC `:wt_port` and the web page on TCP `:web_port`.
  """
  alias MixerBroadcaster.{Hub, Server, Web}

  def start(opts \\ []) do
    wt_port =
      Keyword.get(opts, :wt_port, String.to_integer(System.get_env("MB_WT_PORT") || "4433"))

    web_port = Keyword.get(opts, :web_port, 4000)
    dir = Path.join(System.tmp_dir!(), "mixer_broadcaster_demo")
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    with :ok <- File.mkdir_p(dir),
         {_, 0} <-
           System.cmd(
             openssl(),
             ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd(
             openssl(),
             [
               "req",
               "-x509",
               "-new",
               "-key",
               key,
               "-out",
               cert,
               "-days",
               "13",
               "-subj",
               "/CN=localhost",
               "-addext",
               "subjectAltName=DNS:localhost,IP:127.0.0.1"
             ], stderr_to_stdout: true),
         {:ok, pem} <- File.read(cert),
         [{:Certificate, der, _}] <- :public_key.pem_decode(pem),
         {:ok, %{port: port}} <-
           Server.start(
             name: :mb_demo,
             port: wt_port,
             certfile: cert,
             keyfile: key,
             handler: Hub,
             compat_mode: compat()
           ),
         {:ok, _} <- Bandit.start_link(plug: Web, port: web_port) do
      hash = :crypto.hash(:sha256, der) |> :binary.bin_to_list()

      # the local demo is the only place the door is open; a deployed relay sets :auth to its root key
      Application.put_env(:mixer_broadcaster, :auth, :off)
      Application.put_env(:mixer_broadcaster, :demo, %{wt_port: port, cert_sha256: hash})
      {:ok, %{wt_port: port, web_port: web_port, cert: cert}}
    else
      {out, code} when is_integer(code) -> {:error, {:openssl, code, out}}
      other -> {:error, other}
    end
  end

  # MB_COMPAT=latest|legacy_browser_compat|auto picks which WebTransport drafts the hub accepts
  defp compat do
    case System.get_env("MB_COMPAT") do
      "latest" -> :latest
      "legacy_browser_compat" -> :legacy_browser_compat
      _ -> :auto
    end
  end

  defp openssl do
    case System.find_executable("openssl") do
      nil -> "C:/Program Files/Git/usr/bin/openssl.exe"
      path -> path
    end
  end
end
