# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.BlocklistTest do
  @moduledoc """
  House rule: no try, rescue, catch or throw in lib/. Expected failures are {:ok, v} / {:error, r}.
  A planted control proves the scanner can fail.
  """
  use ExUnit.Case, async: true

  @pattern ~r/^\s*(try|rescue|catch|throw)\b/m

  test "lib/ has no try/rescue/catch/throw" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"), File.read!(path) =~ @pattern, do: path

    assert offenders == []
  end

  test "CONTROL: the scanner flags a planted rescue" do
    assert "def f do\n  x()\nrescue\n  _ -> :error\nend\n" =~ @pattern
  end
end
