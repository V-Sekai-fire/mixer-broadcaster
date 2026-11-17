# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.MixProject do
  use Mix.Project

  def project do
    [
      app: :mixer_broadcaster,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [demo: &demo/1, frontier: ["test test/frontier_test.exs"]],
      dialyzer: [flags: [:error_handling, :extra_return, :missing_return]],
      description: "Broadcaster for Mixer: HTTP/3 WebTransport is the only network protocol.",
      licenses: ["MIT"]
    ]
  end

  def cli, do: [preferred_envs: [frontier: :test]]

  def application do
    [extra_applications: [:logger, :ssl, :public_key, :inets], mod: {MixerBroadcaster.Application, []}]
  end

  defp deps do
    [
      # Pure Erlang WebTransport over HTTP/3 (Apache-2.0); no Rust or C toolchain
      {:webtransport, "~> 0.5"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      # Property-based testing (Elixir's counterpart of Hypothesis)
      {:cbor, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      # The AsyncAPI document in spec/ is held to the real Hub by test/asyncapi_test.exs
      {:yaml_elixir, "~> 2.11", only: :test},
      {:ex_json_schema, "~> 0.10", only: :test},
      {:mox, "~> 1.2", only: :test},
      # Runs the Python reference scripts as they are, before they are ported to Elixir (one uv config per app: config/config.exs)
      {:pythonx, "~> 0.4", only: :test},
      # Static analysis: `mix dialyzer`
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp demo(_args) do
    Mix.Task.run("app.start")
    Logger.configure(level: String.to_atom(System.get_env("MB_LOG") || "info"))
    {:ok, info} = MixerBroadcaster.Demo.start()
    IO.puts("hub on https://localhost:#{info.wt_port}/room/<name>   page on http://localhost:#{info.web_port}/")
    Process.sleep(:infinity)
  end
end
