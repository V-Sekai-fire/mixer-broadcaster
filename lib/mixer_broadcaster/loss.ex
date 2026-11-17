defmodule MixerBroadcaster.Loss do
  @moduledoc """
  A wifi-like lossy channel for datagrams: the Gilbert-Elliott model, two states with their own loss rates and a chance of
  moving between them. Wifi loses packets in runs (interference, a roam, a busy air slot), not one at a time, so a model
  that drops each packet by an independent coin flip hides the failures that matter: a burst longer than any repeat.

  A channel is a plain value; `step/1` returns `{:drop | :pass, channel}` and keeps the random state inside, so a seed
  makes a run repeatable. Off by default. Set with `config :mixer_broadcaster, :loss, ...` or the `MB_LOSS` variable:
  `off`, `wifi`, `bad_wifi`, `lte` or a number 0..1 for plain independent loss. `MB_LOSS_SEED` fixes the seed.

  The presets (long-run loss, mean burst) are rough figures for a home access point, not measurements of ours:
    wifi      about 3.5% long-run; the bad state lasts about 4 packets and drops 80% of them, so runs of drops average about 2
    bad_wifi  about 12% long-run; the bad state lasts about 8 packets and drops 85%
  """

  defstruct state: :good, p_gb: 0.0, p_bg: 1.0, loss_good: 0.0, loss_bad: 1.0, rand: nil

  @type t :: %__MODULE__{}

  @presets %{
    "wifi" => %{p_gb: 0.01, p_bg: 0.25, loss_good: 0.005, loss_bad: 0.8},
    "bad_wifi" => %{p_gb: 0.02, p_bg: 0.12, loss_good: 0.01, loss_bad: 0.85},
    "lte" => %{p_gb: 0.003, p_bg: 0.4, loss_good: 0.002, loss_bad: 0.6}
  }

  @doc "A channel from a preset name, a probability, or a map of the four parameters."
  def new(spec, seed \\ nil)
  def new(nil, _), do: nil
  def new("off", _), do: nil
  def new(%__MODULE__{} = c, _), do: c

  def new(name, seed) when is_binary(name) do
    case Map.fetch(@presets, name) do
      {:ok, p} ->
        new(p, seed)

      :error ->
        case Float.parse(name) do
          {p, ""} -> new(p, seed)
          _ -> nil
        end
    end
  end

  def new(p, seed) when is_number(p) and p >= 0 and p <= 1,
    do: new(%{p_gb: 0.0, p_bg: 1.0, loss_good: p * 1.0, loss_bad: 1.0}, seed)

  def new(%{} = p, seed) do
    rand = :rand.seed_s(:exsss, seed || :erlang.unique_integer())
    struct!(__MODULE__, Map.put(p, :rand, rand))
  end

  @doc "The channel the application is configured for, or nil. One per session, so sessions do not share a burst."
  def from_env(env \\ System.get_env()) do
    spec = Application.get_env(:mixer_broadcaster, :loss) || env["MB_LOSS"]
    seed = if s = env["MB_LOSS_SEED"], do: String.to_integer(s), else: nil
    new(spec, seed)
  end

  @doc "Decide one datagram. `nil` is no channel: everything passes."
  def step(nil), do: {:pass, nil}

  def step(%__MODULE__{} = c) do
    {u1, r1} = :rand.uniform_s(c.rand)
    {u2, r2} = :rand.uniform_s(r1)
    loss = if c.state == :good, do: c.loss_good, else: c.loss_bad
    verdict = if u1 < loss, do: :drop, else: :pass
    flip = if c.state == :good, do: c.p_gb, else: c.p_bg
    state = if u2 < flip, do: other(c.state), else: c.state
    {verdict, %{c | state: state, rand: r2}}
  end

  defp other(:good), do: :bad
  defp other(:bad), do: :good

  @doc "The long-run loss rate the parameters give, from the stationary state probabilities."
  def expected_loss(%__MODULE__{p_gb: a, p_bg: b, loss_good: lg, loss_bad: lb}) when a + b > 0 do
    bad = a / (a + b)
    bad * lb + (1 - bad) * lg
  end

  def expected_loss(%__MODULE__{loss_good: lg}), do: lg
end
