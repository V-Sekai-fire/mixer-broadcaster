defmodule MixerBroadcaster.Chart do
  @moduledoc """
  The shared object the three clients agree on: a classic 24-patch color chart, 24 sRGB 8-bit patches (D65),
  row by row from dark skin to black. Same table as entities-model-explorer `ColorChart.gd`.
  A chart is a map of patch index (0..23) to [r, g, b].
  """
  @checker [
    [115, 82, 68],
    [194, 150, 130],
    [98, 122, 157],
    [87, 108, 67],
    [133, 128, 177],
    [103, 189, 170],
    [214, 126, 44],
    [80, 91, 166],
    [193, 90, 99],
    [94, 60, 108],
    [157, 188, 64],
    [224, 163, 46],
    [56, 61, 150],
    [70, 148, 73],
    [175, 54, 60],
    [231, 199, 31],
    [187, 86, 149],
    [8, 133, 161],
    [243, 243, 242],
    [200, 200, 200],
    [160, 160, 160],
    [122, 122, 121],
    [85, 85, 85],
    [52, 52, 52]
  ]

  @type rgb :: [byte()]
  @type t :: %{optional(non_neg_integer()) => rgb()}

  @spec default() :: t()
  def default, do: @checker |> Enum.with_index() |> Map.new(fn {rgb, i} -> {i, rgb} end)

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
