defmodule MixerBroadcaster.Web do
  @moduledoc "Serves the three.js client and the hash of the demo certificate (a browser needs it for a self-signed WebTransport server)."
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:mixer_broadcaster, "priv/static/index.html"))
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
