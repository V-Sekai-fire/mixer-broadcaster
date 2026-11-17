# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.ColorTest do
  @moduledoc """
  CIELAB color math and the BabelColor chart defined in it.

    * GOLDEN:    CIEDE2000 matches the published Sharma test pairs; the 24 BabelColor patches in Lab derive sRGB
                 that agrees with BabelColor's own published sRGB column; cyan is the one clipped patch.
    * INVARIANT: sRGB bytes survive sRGB to Lab to sRGB; ΔE00 of a color with itself is 0 and ΔE00 is symmetric.
    * CONTROL:   reading sRGB bytes as linear light (a color-space swap) is far above the pass threshold, so the
                 check can fail.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.{Chart, Color}

  # BabelColor Avg., Table 2: sRGB column (8 bit), patches 1..24
  @babelcolor_srgb [
    [115, 81, 67],
    [196, 149, 129],
    [93, 123, 157],
    [90, 108, 65],
    [130, 129, 176],
    [99, 191, 171],
    [220, 123, 45],
    [72, 92, 168],
    [195, 84, 98],
    [91, 59, 105],
    [160, 189, 62],
    [229, 161, 41],
    [43, 62, 147],
    [71, 149, 72],
    [176, 48, 56],
    [238, 200, 22],
    [188, 84, 150],
    [0, 136, 166],
    [245, 245, 240],
    [200, 201, 201],
    [160, 161, 161],
    [120, 121, 121],
    [83, 84, 85],
    [50, 50, 50]
  ]

  # Sharma, Wu, Dalal 2005, pairs 1 to 3
  @sharma [
    {{50.0, 2.6772, -79.7751}, {50.0, 0.0, -82.7485}, 2.0425},
    {{50.0, 3.1571, -77.2803}, {50.0, 0.0, -82.7485}, 2.8615},
    {{50.0, 2.8361, -74.0200}, {50.0, 0.0, -82.7485}, 3.4412}
  ]

  test "golden: CIEDE2000 reproduces the Sharma reference pairs" do
    for {a, b, want} <- @sharma, do: assert_in_delta(Color.delta_e00(a, b), want, 0.0001)
  end

  test "golden: the chart has 24 Lab-defined patches, dark skin first, black last" do
    patches = Chart.patches()
    assert length(patches) == 24
    assert hd(patches).name == "dark skin" and hd(patches).lab == {38.36, 13.80, 14.65}
    assert List.last(patches).name == "black 2"
  end

  test "golden: derived sRGB agrees with BabelColor's published sRGB" do
    for {p, pub} <- Enum.zip(Chart.patches(), @babelcolor_srgb) do
      assert Enum.max(Enum.zip_with(p.rgb, pub, &abs(&1 - &2))) <= 6, p.name
      assert Color.delta_e00(Color.srgb_to_lab(p.rgb), Color.srgb_to_lab(pub)) < 1.5, p.name
    end
  end

  test "golden: every patch except cyan is inside the sRGB gamut and round-trips below ΔE00 1" do
    for p <- Chart.patches() do
      d = Color.delta_e00(p.lab, Color.srgb_to_lab(p.rgb))

      if p.name == "cyan" do
        assert p.gamut == :clipped
        assert d > 1.0
      else
        assert p.gamut == :in_gamut, p.name
        assert d < 1.0, p.name
      end
    end
  end

  test "golden: white is L* 100 and black is L* 0 for the D50 reference white" do
    {l, a, b} = Color.srgb_to_lab([255, 255, 255])
    assert_in_delta l, 100.0, 0.01
    assert_in_delta a, 0.0, 0.01
    assert_in_delta b, 0.0, 0.01
    assert Color.srgb_to_lab([0, 0, 0]) == {0.0, 0.0, 0.0}
  end

  property "invariant: any sRGB color survives sRGB to Lab to sRGB" do
    check all(rgb <- list_of(integer(0..255), length: 3)) do
      assert {^rgb, :in_gamut} = rgb |> Color.srgb_to_lab() |> Color.lab_to_srgb()
    end
  end

  property "invariant: ΔE00 is zero on itself and symmetric" do
    lab =
      tuple(
        {float(min: 0.0, max: 100.0), float(min: -100.0, max: 100.0),
         float(min: -100.0, max: 100.0)}
      )

    check all(x <- lab, y <- lab) do
      assert_in_delta Color.delta_e00(x, x), 0.0, 1.0e-9
      assert_in_delta Color.delta_e00(x, y), Color.delta_e00(y, x), 1.0e-9
    end
  end

  property "control: reading sRGB bytes as linear light is far above the pass threshold" do
    check all(v <- integer(40..180)) do
      right = Color.srgb_to_lab([v, v, v])
      # a decoder that skips the sRGB curve takes the byte as light: Y = v/255
      wrong = {116 * :math.pow(v / 255, 1 / 3) - 16, 0.0, 0.0}
      assert Color.delta_e00(right, wrong) > 5.0
    end
  end
end
