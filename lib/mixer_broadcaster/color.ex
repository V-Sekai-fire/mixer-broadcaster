# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Color do
  @moduledoc """
  CIELAB colors and the sRGB bytes that go on the wire.

  Colors are defined in CIELAB under D50 (the illuminant of the ColorChecker reference data). sRGB is D65 and
  its primaries are fixed, so the D50-adapted (Bradford) sRGB matrices are used. Everything here is pure
  arithmetic: no `try`, no side effects.

    * `lab_to_srgb/1`  Lab D50 to 8-bit sRGB, flagged `:clipped` when the color is outside the sRGB gamut
    * `srgb_to_lab/1`  8-bit sRGB to Lab D50
    * `delta_e00/2`    CIEDE2000 difference between two Lab colors
  """

  @type lab :: {float(), float(), float()}
  @type rgb :: [byte()]

  @white {0.96422, 1.0, 0.82521}
  @eps 216 / 24389
  @kappa 24389 / 27

  # linear sRGB (D65 primaries) to XYZ, Bradford-adapted to D50 (Lindbloom)
  @to_xyz {{0.4360747, 0.3850649, 0.1430804}, {0.2225045, 0.7168786, 0.0606169},
           {0.0139322, 0.0971045, 0.7141733}}
  @to_rgb {{3.1338561, -1.6168667, -0.4906146}, {-0.9787684, 1.9161415, 0.0334540},
           {0.0719453, -0.2289914, 1.4052427}}

  # a linear channel this far outside 0..1 counts as out of gamut, below that it is rounding noise
  @gamut_tolerance 0.0005

  @spec lab_to_srgb(lab()) :: {rgb(), :in_gamut | :clipped}
  def lab_to_srgb({l, a, b}) do
    fy = (l + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    {wx, wy, wz} = @white
    xyz = {wx * finv(fx), wy * yinv(l, fy), wz * finv(fz)}
    lin = mul(@to_rgb, xyz) |> Tuple.to_list()

    status =
      if Enum.all?(lin, &(&1 >= -@gamut_tolerance and &1 <= 1 + @gamut_tolerance)),
        do: :in_gamut,
        else: :clipped

    {Enum.map(lin, &encode/1), status}
  end

  @spec srgb_to_lab(rgb()) :: lab()
  def srgb_to_lab([r, g, b]) do
    {x, y, z} = mul(@to_xyz, {decode(r), decode(g), decode(b)})
    {wx, wy, wz} = @white
    {fx, fy, fz} = {f(x / wx), f(y / wy), f(z / wz)}
    {116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)}
  end

  defp finv(t), do: if(t * t * t > @eps, do: t * t * t, else: (116 * t - 16) / @kappa)
  defp yinv(l, fy), do: if(l > @kappa * @eps, do: fy * fy * fy, else: l / @kappa)
  defp f(t), do: if(t > @eps, do: :math.pow(t, 1 / 3), else: (@kappa * t + 16) / 116)

  defp mul({{a, b, c}, {d, e, f}, {g, h, i}}, {x, y, z}),
    do: {a * x + b * y + c * z, d * x + e * y + f * z, g * x + h * y + i * z}

  defp decode(byte) do
    v = byte / 255
    if v <= 0.04045, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
  end

  defp encode(lin) do
    c = min(max(lin, 0.0), 1.0)
    v = if c <= 0.0031308, do: 12.92 * c, else: 1.055 * :math.pow(c, 1 / 2.4) - 0.055
    round(v * 255)
  end

  @doc "CIEDE2000 (Sharma, Wu, Dalal 2005) with kL = kC = kH = 1."
  @spec delta_e00(lab(), lab()) :: float()
  def delta_e00({l1, a1, b1}, {l2, a2, b2}) do
    c1 = :math.sqrt(a1 * a1 + b1 * b1)
    c2 = :math.sqrt(a2 * a2 + b2 * b2)
    cbar7 = :math.pow((c1 + c2) / 2, 7)
    g = 0.5 * (1 - :math.sqrt(cbar7 / (cbar7 + :math.pow(25.0, 7))))
    {a1p, a2p} = {(1 + g) * a1, (1 + g) * a2}
    {c1p, c2p} = {hypot(a1p, b1), hypot(a2p, b2)}
    {h1p, h2p} = {hue(b1, a1p), hue(b2, a2p)}

    dl = l2 - l1
    dc = c2p - c1p

    dh =
      cond do
        c1p * c2p == 0 -> 0.0
        abs(h2p - h1p) <= 180 -> h2p - h1p
        h2p - h1p > 180 -> h2p - h1p - 360
        true -> h2p - h1p + 360
      end

    dhp = 2 * :math.sqrt(c1p * c2p) * sin_deg(dh / 2)
    lbar = (l1 + l2) / 2
    cbarp = (c1p + c2p) / 2

    hbar =
      cond do
        c1p * c2p == 0 -> h1p + h2p
        abs(h1p - h2p) <= 180 -> (h1p + h2p) / 2
        h1p + h2p < 360 -> (h1p + h2p + 360) / 2
        true -> (h1p + h2p - 360) / 2
      end

    t =
      1 - 0.17 * cos_deg(hbar - 30) + 0.24 * cos_deg(2 * hbar) + 0.32 * cos_deg(3 * hbar + 6) -
        0.20 * cos_deg(4 * hbar - 63)

    dtheta = 30 * :math.exp(-:math.pow((hbar - 275) / 25, 2))
    rc = 2 * :math.sqrt(:math.pow(cbarp, 7) / (:math.pow(cbarp, 7) + :math.pow(25.0, 7)))
    sl = 1 + 0.015 * :math.pow(lbar - 50, 2) / :math.sqrt(20 + :math.pow(lbar - 50, 2))
    sc = 1 + 0.045 * cbarp
    sh = 1 + 0.015 * cbarp * t
    rt = -sin_deg(2 * dtheta) * rc

    :math.sqrt(
      :math.pow(dl / sl, 2) + :math.pow(dc / sc, 2) + :math.pow(dhp / sh, 2) +
        rt * (dc / sc) * (dhp / sh)
    )
  end

  defp hypot(x, y), do: :math.sqrt(x * x + y * y)

  defp hue(b, ap) do
    if b == 0 and ap == 0 do
      0.0
    else
      h = :math.atan2(b, ap) * 180 / :math.pi()
      if h < 0, do: h + 360, else: h
    end
  end

  defp sin_deg(d), do: :math.sin(d * :math.pi() / 180)
  defp cos_deg(d), do: :math.cos(d * :math.pi() / 180)
end
