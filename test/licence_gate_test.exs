# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.LicenceGateTest do
  @moduledoc """
  The relay works with MIT, Apache, BSD and MPL-2.0 licensed technologies only (MPL-2.0 is allowed).
  GOLDEN: every package in `mix.lock` states a licence, and every licence it states is on the permissive list.
  INVARIANT: for any licence text, `permissive?/1` is true exactly when it is on the list, so a copyleft or unknown
  licence is never let through by a near match.
  CONTROL: the usual copyleft licences, a package with no licence and an empty list are refused, so the gate can fail.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @permissive [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD 2-Clause",
    "BSD-3-Clause",
    "BSD 3-Clause",
    "ISC",
    "0BSD",
    "MPL-2.0"
  ]

  defp permissive?(licence), do: licence in @permissive

  # `licences` is the list a package states; an empty list is a package that states none
  defp all_permissive?([]), do: false
  defp all_permissive?(licences), do: Enum.all?(licences, &permissive?/1)

  defp licences_of(name) do
    path = Path.join([__DIR__, "..", "deps", to_string(name), "hex_metadata.config"])

    with {:ok, terms} <- :file.consult(String.to_charlist(path)),
         {_, licences} <- List.keyfind(terms, "licenses", 0) do
      {:ok, Enum.map(licences, &to_string/1)}
    else
      _ -> {:error, :no_licence}
    end
  end

  test "golden: every package in mix.lock is MIT, Apache, BSD or MPL-2.0 licensed" do
    {lock, _} = Code.eval_file(Path.join([__DIR__, "..", "mix.lock"]))
    assert map_size(lock) > 10

    for {name, _} <- lock do
      assert {:ok, licences} = licences_of(name), "#{name} states no licence"
      assert all_permissive?(licences), "#{name} is #{inspect(licences)}, which is not permissive"
    end
  end

  test "control: copyleft, unknown and missing licences are refused" do
    for bad <- [
          "GPL-3.0-or-later",
          "GPL-2.0-only",
          "LGPL-2.1-or-later",
          "AGPL-3.0-only",
          "MPL-1.1",
          "SSPL-1.0",
          ""
        ] do
      refute all_permissive?([bad]), bad
    end

    refute all_permissive?([])
    refute all_permissive?(["MIT", "GPL-3.0-or-later"])
    assert {:error, :no_licence} = licences_of(:a_package_that_is_not_there)
  end

  property "invariant: a licence passes exactly when it is on the list" do
    check all(text <- one_of([member_of(@permissive), string(:printable, max_length: 20)])) do
      assert permissive?(text) == text in @permissive
    end
  end
end
