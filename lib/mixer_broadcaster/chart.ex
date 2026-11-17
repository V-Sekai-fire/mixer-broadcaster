# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Chart do
  @moduledoc """
  The shared object the three clients agree on: a classic 24-patch color chart, row by row from dark skin to black.

  The patches are defined in CIELAB (D50), not in RGB. The values are the BabelColor average of 20 measured
  ColorChecker charts (Pascale, "RGB coordinates of the Macbeth ColorChecker", BabelColor, 2006, Table 2). The wire
  still carries 8-bit sRGB, derived from the Lab definition by `MixerBroadcaster.Color.lab_to_srgb/1`.
  The cyan patch is outside the sRGB gamut and is clipped; `patches/0` says so.

  A chart is a map of patch index (0..23) to [r, g, b].
  """
  alias MixerBroadcaster.Color

  @patches [
    {"dark skin", {38.36, 13.80, 14.65}},
    {"light skin", {66.06, 17.74, 17.85}},
    {"blue sky", {50.09, -4.41, -22.51}},
    {"foliage", {43.20, -13.46, 21.73}},
    {"blue flower", {55.36, 8.89, -24.82}},
    {"bluish green", {70.70, -32.89, -0.24}},
    {"orange", {62.56, 35.13, 58.05}},
    {"purplish blue", {40.18, 9.55, -44.29}},
    {"moderate red", {51.71, 47.69, 16.86}},
    {"purple", {30.38, 21.13, -20.31}},
    {"yellow green", {72.49, -23.46, 57.08}},
    {"orange yellow", {71.96, 19.49, 68.00}},
    {"blue", {28.65, 15.60, -50.52}},
    {"green", {55.05, -38.09, 31.62}},
    {"red", {42.18, 54.89, 28.79}},
    {"yellow", {82.23, 4.05, 79.84}},
    {"magenta", {51.82, 49.79, -13.90}},
    {"cyan", {50.55, -27.97, -28.14}},
    {"white 9.5", {96.39, -0.40, 2.24}},
    {"neutral 8", {81.01, -0.57, 0.18}},
    {"neutral 6.5", {66.30, -0.43, -0.08}},
    {"neutral 5", {50.83, -0.69, -0.27}},
    {"neutral 3.5", {35.72, -0.52, -0.47}},
    {"black 2", {20.71, 0.03, -0.45}}
  ]

  @type rgb :: [byte()]
  @type t :: %{optional(non_neg_integer()) => rgb()}
  @type patch :: %{
          name: String.t(),
          lab: Color.lab(),
          rgb: rgb(),
          gamut: :in_gamut | :clipped
        }

  @doc "The 24 patches with their Lab definition, derived sRGB and gamut status."
  @spec patches() :: [patch()]
  def patches do
    for {name, lab} <- @patches do
      {rgb, gamut} = Color.lab_to_srgb(lab)
      %{name: name, lab: lab, rgb: rgb, gamut: gamut}
    end
  end

  @spec default() :: t()
  def default, do: patches() |> Enum.with_index() |> Map.new(fn {p, i} -> {i, p.rgb} end)

  @doc "Apply one patch change; `{:error, :bad_patch}` for anything outside 0..23 or a byte range."
  @spec set(t(), term(), term()) :: {:ok, t()} | {:error, :bad_patch}
  def set(chart, id, [r, g, b] = rgb)
      when is_integer(id) and id in 0..23 and r in 0..255 and g in 0..255 and b in 0..255,
      do: {:ok, Map.put(chart, id, rgb)}

  def set(_chart, _id, _rgb), do: {:error, :bad_patch}

  @spec snapshot(t()) :: binary()
  def snapshot(chart) do
    patches = for i <- 0..23, do: Map.fetch!(chart, i)
    IO.iodata_to_binary(JSON.encode_to_iodata!(%{t: "snapshot", patches: patches}))
  end

  @spec set_message(non_neg_integer(), rgb()) :: binary()
  def set_message(id, rgb),
    do: IO.iodata_to_binary(JSON.encode_to_iodata!(%{t: "set", id: id, rgb: rgb}))
end
