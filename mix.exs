defmodule MixerBroadcaster.MixProject do
  use Mix.Project

  def project do
    [
      app: :mixer_broadcaster,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Broadcaster for Mixer: HTTP/3 WebTransport is the only network protocol.",
      licenses: ["MIT"]
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :public_key], mod: {MixerBroadcaster.Application, []}]
  end

  defp deps do
    [
      # Pure Erlang WebTransport over HTTP/3 (Apache-2.0); no Rust or C toolchain
      {:webtransport, "~> 0.5"},
      # Property-based testing (Elixir's counterpart of Hypothesis)
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
