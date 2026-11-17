# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.GodotMintRetryPythonxTest do
  @moduledoc """
  Step one of porting `clients/godot/tests/run_mint_retry.py`: run the Python file exactly as it is, inside Pythonx.
  The Elixir port comes after this passes. Needs `GODOT` to name the entities-zone double editor (stock Godot lacks
  WebTransportPeer and Sandbox); without it the test is skipped.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../clients/godot/tests/run_mint_retry.py", __DIR__)

  @tag timeout: 300_000
  @tag skip: if(System.get_env("GODOT") in [nil, ""], do: "set GODOT to the double editor", else: false)
  test "run_mint_retry.py passes unmodified under Pythonx" do
    # The script ends in sys.exit(code), which Python raises as SystemExit; the wrapper turns it into a number.
    {result, _globals} =
      Pythonx.eval(
        """
        g = {"__file__": path, "__name__": "__main__"}
        try:
            exec(compile(source, path, "exec"), g)
            code = 0
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
        code
        """,
        %{"path" => @script, "source" => File.read!(@script)}
      )

    assert Pythonx.decode(result) == 0
  end
end
