defmodule MixerBroadcaster.Mixer.Store do
  @moduledoc """
  Where bulk command data lives, named by the SHA-256 of its bytes. A command too big for its packet holds that digest;
  the data is here. In a deployment this is SeaweedFS, which every client can reach (desync and casync use the same
  store); `Memory` serves the tests. The digest is checked on the way out, so a store that returns other bytes is refused.

  `put(data)` returns the digest. `get(digest)` returns `{:ok, data}` or `{:error, reason}`. Neither raises.
  """
  @callback put(binary()) :: binary()
  @callback get(binary()) :: {:ok, binary()} | {:error, term()}

  def impl, do: Application.get_env(:mixer_broadcaster, :mixer_store, __MODULE__.Memory)
  def put(data), do: impl().put(data)

  def get(<<_::binary-size(32)>> = digest) do
    case impl().get(digest) do
      {:ok, data} = ok ->
        if :crypto.hash(:sha256, data) == digest, do: ok, else: {:error, :digest_mismatch}

      other ->
        other
    end
  end

  def get(_), do: {:error, :bad_digest}

  defmodule Memory do
    @moduledoc false
    @behaviour MixerBroadcaster.Mixer.Store
    @table :mixer_store_memory

    # created by `Mixer.Server` when it starts, which owns it
    def table_name, do: @table

    @impl true
    def put(data) do
      digest = :crypto.hash(:sha256, data)
      :ets.insert(@table, {digest, data})
      digest
    end

    @impl true
    def get(digest) do
      case :ets.lookup(@table, digest) do
        [{_, data}] -> {:ok, data}
        [] -> {:error, :not_found}
      end
    end
  end

  defmodule S3 do
    @moduledoc """
    SeaweedFS's S3 gateway, signed with AWS Signature V4: objects at `<bucket>/blob/<hex digest>`. Settings:
    `config :mixer_broadcaster, :s3, endpoint: "http://127.0.0.1:8333", bucket: "mixer"`; the keys come from
    `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` and are read when used. `sign/6` is public so tests can pin it.
    """
    @behaviour MixerBroadcaster.Mixer.Store

    @region "us-east-1"

    defp conf do
      c = Application.get_env(:mixer_broadcaster, :s3, [])
      {Keyword.get(c, :endpoint, "http://127.0.0.1:8333"), Keyword.get(c, :bucket, "mixer")}
    end

    @doc "The signing headers for `method path` with `payload`, as a list of `{name, value}`."
    def sign(method, host, path, payload, {access, secret}, now) do
      amz = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      day = Calendar.strftime(now, "%Y%m%d")
      ph = hex(:crypto.hash(:sha256, payload))
      signed = "host;x-amz-content-sha256;x-amz-date"
      canon_headers = "host:#{host}\nx-amz-content-sha256:#{ph}\nx-amz-date:#{amz}\n"
      canon = Enum.join([method, path, "", canon_headers, signed, ph], "\n")
      scope = "#{day}/#{@region}/s3/aws4_request"

      to_sign =
        Enum.join(["AWS4-HMAC-SHA256", amz, scope, hex(:crypto.hash(:sha256, canon))], "\n")

      key =
        ("AWS4" <> secret)
        |> mac(day)
        |> mac(@region)
        |> mac("s3")
        |> mac("aws4_request")

      sig = hex(mac(key, to_sign))

      [
        {"x-amz-date", amz},
        {"x-amz-content-sha256", ph},
        {"authorization",
         "AWS4-HMAC-SHA256 Credential=#{access}/#{scope}, SignedHeaders=#{signed}, Signature=#{sig}"}
      ]
    end

    defp mac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
    defp hex(bin), do: Base.encode16(bin, case: :lower)

    defp keys do
      with a when is_binary(a) <- System.get_env("AWS_ACCESS_KEY_ID"),
           s when is_binary(s) <- System.get_env("AWS_SECRET_ACCESS_KEY") do
        {:ok, {a, s}}
      else
        _ -> :error
      end
    end

    defp request(method, digest, payload) do
      {endpoint, bucket} = conf()
      %URI{host: host, port: port} = URI.parse(endpoint)
      path = "/#{bucket}/blob/" <> hex(digest)

      with {:ok, k} <- keys() do
        headers =
          for {n, v} <- sign(method, "#{host}:#{port}", path, payload, k, DateTime.utc_now()),
              do: {String.to_charlist(n), String.to_charlist(v)}

        url = String.to_charlist(endpoint <> path)

        req =
          if method == "PUT",
            do: {url, headers, ~c"application/octet-stream", payload},
            else: {url, headers}

        :httpc.request(String.to_atom(String.downcase(method)), req, [], body_format: :binary)
      else
        :error -> {:error, :no_s3_keys}
      end
    end

    @impl true
    def put(data) do
      digest = :crypto.hash(:sha256, data)
      _ = request("PUT", digest, data)
      digest
    end

    @impl true
    def get(digest) do
      case request("GET", digest, "") do
        {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
        {:ok, {{_, status, _}, _, _}} -> {:error, {:status, status}}
        {:error, e} -> {:error, e}
      end
    end
  end
end
