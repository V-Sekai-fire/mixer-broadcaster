# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Web do
  @moduledoc "Serves the three.js client and the hash of the demo certificate (a browser needs it for a self-signed WebTransport server)."
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:mixer_broadcaster, "priv/static/index.html"))
  end

  get "/geo" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:mixer_broadcaster, "priv/static/geo.html"))
  end

  # Demo only: the meshes the publisher extracted, by the SHA-256 of their desync index. Only that name shape is served.
  get "/usd/:file" do
    path = Path.join(Path.join(System.tmp_dir!(), "mixer_geo_usd"), file)

    if Regex.match?(~r/\A[0-9a-f]{64}\.usda\z/, file) and File.regular?(path) do
      conn |> put_resp_content_type("text/plain") |> send_file(200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end

  # Demo only, like every route here: the production relay serves WebTransport and nothing else, so it lists nothing.
  get "/rooms" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, IO.iodata_to_binary(JSON.encode_to_iodata!(MixerBroadcaster.Rooms.list())))
  end

  get "/connection" do
    info = Application.get_env(:mixer_broadcaster, :demo, %{})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, IO.iodata_to_binary(JSON.encode_to_iodata!(info)))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
