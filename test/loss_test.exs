defmodule MixerBroadcaster.LossTest do
  @moduledoc """
  GOLDEN: no channel passes everything; the presets hit their long-run loss rate; a number is independent loss.
  INVARIANT: loss 0 never drops and loss 1 always drops, for any seed; the same seed gives the same run.
  CONTROL: wifi loss comes in runs, which independent loss at the same rate does not (the reason for the model);
  the hub drops datagrams in both directions and replays under a lossy channel; a clean hub still delivers.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.{Hub, Loss, Packet}

  defp run(channel, n) do
    {drops, _} =
      Enum.map_reduce(1..n, channel, fn _, c ->
        {v, c} = Loss.step(c)
        {v == :drop, c}
      end)

    drops
  end

  defp mean_run(drops) do
    runs = drops |> Enum.chunk_by(& &1) |> Enum.filter(&hd/1) |> Enum.map(&length/1)
    Enum.sum(runs) / max(length(runs), 1)
  end

  defp rate(drops), do: Enum.count(drops, & &1) / length(drops)

  test "golden: no channel is no loss, and unknown names are no channel" do
    assert Loss.step(nil) == {:pass, nil}
    assert Loss.new("off") == nil
    assert Loss.new("no-such-preset") == nil
    assert Loss.new(nil) == nil
  end

  test "golden: the presets lose about what their parameters say" do
    for name <- ["wifi", "bad_wifi", "lte"] do
      ch = Loss.new(name, 7)
      got = rate(run(ch, 400_000))
      want = Loss.expected_loss(ch)
      assert_in_delta got, want, want * 0.12, "#{name}: measured #{got}, expected #{want}"
    end

    assert_in_delta Loss.expected_loss(Loss.new("wifi", 1)), 0.035, 0.005
  end

  test "golden: a number is independent loss at that rate" do
    got = rate(run(Loss.new(0.2, 3), 200_000))
    assert_in_delta got, 0.2, 0.01
  end

  property "invariant: loss 0 never drops and loss 1 always drops, whatever the seed" do
    check all(seed <- integer(1..1_000_000), n <- integer(1..300)) do
      refute Enum.any?(run(Loss.new(0.0, seed), n))
      assert Enum.all?(run(Loss.new(1.0, seed), n))
    end
  end

  property "invariant: a seed makes a run repeatable, and a different seed makes a different one" do
    check all(seed <- integer(1..1_000_000)) do
      a = run(Loss.new("bad_wifi", seed), 2000)
      assert a == run(Loss.new("bad_wifi", seed), 2000)
      refute a == run(Loss.new("bad_wifi", seed + 1), 2000)
    end
  end

  test "control: wifi loss comes in runs; independent loss at the same rate does not" do
    wifi = Loss.new("wifi", 11)
    same_rate = Loss.new(Loss.expected_loss(wifi), 11)
    bursty = mean_run(run(wifi, 400_000))
    plain = mean_run(run(same_rate, 400_000))
    assert bursty > 1.8, "wifi mean run of drops #{bursty}"
    assert plain < 1.15, "independent mean run #{plain}"
  end

  defp with_loss(spec) do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    Application.put_env(:mixer_broadcaster, :loss, spec)

    on_exit(fn ->
      Application.delete_env(:mixer_broadcaster, :auth)
      Application.delete_env(:mixer_broadcaster, :loss)
    end)
  end

  defp pose do
    {:ok, bin} = File.read(Path.join(__DIR__, "fixtures/packet_golden_full.csv"))
    [hex | _] = bin |> String.split("\n") |> Enum.at(10) |> String.split(",")
    Base.decode16!(hex, case: :lower)
  end

  defp join(prefix) do
    room = "#{prefix}-#{System.unique_integer([:positive])}"
    {:ok, a} = Hub.init(nil, %{path: "/room/#{room}"}, [])
    assert_receive :replay
    {room, a}
  end

  test "golden: a hub with loss 1.0 drops what a client sends, what it would receive, and the late-join replay" do
    with_loss(1.0)
    {room, a} = join("lossy")
    assert Packet.valid?(pose())

    assert {:ok, _, []} = Hub.handle_datagram(pose(), a)

    assert MixerBroadcaster.Rooms.entities(room) == [],
           "a dropped pose must not be remembered either"

    assert {:ok, _} = Hub.handle_info({:relay, spawn(fn -> :ok end), pose()}, a)

    MixerBroadcaster.Rooms.put_entity(room, pose())
    assert {:ok, _, []} = Hub.handle_info({:replay, 1}, a)
  end

  test "control: the same hub with no loss stores, forwards and replays" do
    with_loss(nil)
    {room, a} = join("clean")

    assert {:ok, _, []} = Hub.handle_datagram(pose(), a)
    assert length(MixerBroadcaster.Rooms.entities(room)) == 1

    assert {:ok, _, [{:send_datagram, out}]} =
             Hub.handle_info({:relay, spawn(fn -> :ok end), pose()}, a)

    assert byte_size(out) == 100
    assert {:ok, _, [{:send_datagram, _}]} = Hub.handle_info({:replay, 1}, a)
  end

  test "golden: a lossy hub passes some and drops some, near the channel's rate" do
    with_loss("wifi")
    {_room, a} = join("some")

    {sent, _} =
      Enum.reduce(1..20_000, {0, a}, fn _, {n, st} ->
        case Hub.handle_info({:relay, spawn(fn -> :ok end), pose()}, st) do
          {:ok, st, [_]} -> {n + 1, st}
          {:ok, st} -> {n, st}
        end
      end)

    assert_in_delta 1 - sent / 20_000, 0.035, 0.012
  end
end
