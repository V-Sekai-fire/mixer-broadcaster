defmodule MixerBroadcaster.Serve do
  @moduledoc """
  The deployed relay's entry point (`MB_SERVE=1`). It is closed by construction:

    * `MB_ROOT_KEY` (64 hex characters, the macaroon root the relay verifies against) must be present and well
      formed, or the node refuses to boot. There is no default and no "off": `Demo` is the only place the door
      opens, and nothing here calls it.
    * Admission is `Auth.admit/7` in `Hub`: a token the root key vouches for, discharged by the minter for this
      room and this player's key, plus a signature over a fresh nonce by that key.
    * The relay holds only the root key. The minter's third-party key and every player's private key stay
      elsewhere.

  Other settings: `MB_WT_PORT` (UDP, default 4433), `MB_BIND` (a host name to bind to; Fly UDP needs
  `fly-global-services`), `MB_HOST` (a name for the certificate), `MB_ORIGINS` (browser origins, comma
  separated, empty by default so no browser page is let in), `MB_CERT_PEM` and `MB_KEY_PEM` (a fixed
  certificate; without them one is made at boot and its SHA-256 is logged).
  """
  alias MixerBroadcaster.Server

  @doc "Validate the root key text. 64 hex characters decode to 32 bytes; anything else is refused."
  @spec root_key(String.t() | nil) :: {:ok, <<_::256>>} | {:error, :root_key}
  def root_key(text) when is_binary(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _ -> {:error, :root_key}
    end
  end

  def root_key(_), do: {:error, :root_key}

  @doc "Set the policy: the relay verifies against `root`. Never `:off`."
  @spec put_policy(<<_::256>>) :: :ok
  def put_policy(root) when byte_size(root) == 32 do
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: root})
  end

  @doc "Start the listener, or answer why not. Nothing is listening unless this returns `{:ok, _}`."
  @spec start(%{optional(String.t()) => String.t()}, keyword()) ::
          {:ok, %{port: :inet.port_number(), cert_sha256: String.t()}} | {:error, term()}
  def start(env \\ System.get_env(), opts \\ []) do
    with {:ok, root} <- root_key(env["MB_ROOT_KEY"]),
         {:ok, ip} <- bind_ip(env["MB_BIND"]),
         {:ok, cert, key, hash} <- certificate(env),
         :ok <- put_policy(root),
         :ok <- put_origins(env["MB_ORIGINS"]),
         {:ok, %{port: port}} <-
           Server.start(
             name: Keyword.get(opts, :name, :mb_relay),
             port: String.to_integer(env["MB_WT_PORT"] || "4433"),
             ip: ip,
             certfile: cert,
             keyfile: key,
             handler: MixerBroadcaster.Router
           ) do
      {:ok, %{port: port, cert_sha256: Base.encode16(hash, case: :lower)}}
    end
  end

  defp put_origins(nil), do: Application.put_env(:mixer_broadcaster, :allowed_origins, [])

  defp put_origins(text) do
    origins = text |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    Application.put_env(:mixer_broadcaster, :allowed_origins, origins)
  end

  defp bind_ip(nil), do: {:ok, {0, 0, 0, 0}}
  defp bind_ip(""), do: {:ok, {0, 0, 0, 0}}

  defp bind_ip(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, {:bind, host, reason}}
    end
  end

  defp certificate(%{"MB_CERT_PEM" => pem, "MB_KEY_PEM" => key}) when pem != "" and key != "" do
    dir = Path.join(System.tmp_dir!(), "mb_relay_cert")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "cert.pem"), pem),
         :ok <- File.write(Path.join(dir, "key.pem"), key, [:write]),
         :ok <- File.chmod(Path.join(dir, "key.pem"), 0o600) do
      read_hash(dir)
    end
  end

  defp certificate(env) do
    dir = Path.join(System.tmp_dir!(), "mb_relay_cert")
    host = env["MB_HOST"] || "localhost"
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    with :ok <- File.mkdir_p(dir),
         {_, 0} <- cmd(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key]),
         :ok <- File.chmod(key, 0o600),
         {_, 0} <-
           cmd([
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
             "/CN=#{host}",
             "-addext",
             "subjectAltName=DNS:#{host},DNS:localhost"
           ]) do
      read_hash(dir)
    else
      {out, code} when is_integer(code) -> {:error, {:openssl, code, out}}
      other -> {:error, other}
    end
  end

  defp read_hash(dir) do
    cert = Path.join(dir, "cert.pem")

    with {:ok, pem} <- File.read(cert),
         [{:Certificate, der, _}] <- :public_key.pem_decode(pem) do
      {:ok, cert, Path.join(dir, "key.pem"), :crypto.hash(:sha256, der)}
    else
      other -> {:error, {:certificate, other}}
    end
  end

  defp cmd(args),
    do: System.cmd(System.find_executable("openssl") || "openssl", args, stderr_to_stdout: true)
end
