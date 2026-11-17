# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.ChartPropertyTest do
  @moduledoc """
  StreamData properties for the shared 24-patch color chart.

    * GOLDEN:    the default chart is the classic 24-patch color chart: 24 patches, dark skin first, black last.
    * INVARIANT: any in-range set is read back unchanged and touches no other patch.
    * CONTROL:   an out-of-range patch or channel is refused and leaves the chart as it was.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Chart

  test "golden: the default chart is the classic 24-patch color chart" do
    chart = Chart.default()
    assert map_size(chart) == 24
    assert chart[0] == [115, 82, 68]
    assert chart[18] == [243, 243, 242]
    assert chart[23] == [52, 52, 52]
  end

  property "invariant: an accepted set is read back and touches nothing else" do
    check all(id <- integer(0..23), rgb <- list_of(integer(0..255), length: 3)) do
      {:ok, changed} = Chart.set(Chart.default(), id, rgb)
      assert changed[id] == rgb
      assert Map.delete(changed, id) == Map.delete(Chart.default(), id)
    end
  end

  property "control: anything out of range is refused" do
    check all(
            id <- one_of([integer(-50..-1), integer(24..500)]),
            rgb <- list_of(integer(0..255), length: 3)
          ) do
      assert Chart.set(Chart.default(), id, rgb) == {:error, :bad_patch}
    end

    check all(channel <- one_of([integer(-50..-1), integer(256..900)])) do
      assert Chart.set(Chart.default(), 0, [channel, 0, 0]) == {:error, :bad_patch}
    end
  end

  test "the snapshot a late joiner gets carries all 24 patches in order" do
    assert {:ok, %{"t" => "snapshot", "patches" => patches}} =
             JSON.decode(Chart.snapshot(Chart.default()))

    assert length(patches) == 24
    assert hd(patches) == [115, 82, 68]
  end
end
