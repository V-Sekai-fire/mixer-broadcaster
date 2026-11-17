# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.TokenOpsTest do
  @moduledoc """
  GOLDEN: a token minted with the "read" operation allows a read in its rooms; a holder may drop the right.
  INVARIANT: asking for an operation succeeds exactly when the minter granted it and no narrowing removed it.
  CONTROL: a token minted without operations allows none; an ordinary join still works without asking for one; an
  unknown operation, a widening attempt, and a tampered token are refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Token

  @now 1_800_000_000

  defp minted(rooms, ops) do
    {root, tp, t} =
      {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32),
       :crypto.strong_rand_bytes(32)}

    {:ok, token} = {:ok, Token.issue(root, rooms, "minter.internal", tp, ops)}
    {:ok, full} = Token.discharge(token, tp, t, 3600, @now)
    {root, t, full}
  end

  defp ctx(room, t, op \\ nil),
    do:
      %{room: room, thumbprint: t, now: @now} |> then(&if op, do: Map.put(&1, :op, op), else: &1)

  test "golden: a token with read allows read in its rooms" do
    {root, t, full} = minted(["a", "b"], ["read"])
    assert {:ok, _} = Token.verify(full, root, ctx("a", t, "read"))
    assert {:ok, _} = Token.verify(full, root, ctx("a", t))
    assert {:error, :wrong_room} = Token.verify(full, root, ctx("c", t, "read"))
  end

  test "golden: a single-room token can carry read too" do
    {root, t, full} = minted("solo", ["read"])
    assert {:ok, _} = Token.verify(full, root, ctx("solo", t, "read"))
  end

  test "golden: a holder drops the right with no key" do
    {root, t, full} = minted(["a"], ["read"])
    {:ok, none} = Token.restrict_ops(full, [])
    # an empty list names no operation, so nothing is allowed
    assert {:error, :op_not_allowed} = Token.verify(none, root, ctx("a", t, "read"))
    assert {:ok, _} = Token.verify(none, root, ctx("a", t)), "it can still join"
    assert {:ok, _} = Token.verify(full, root, ctx("a", t, "read")), "the original is unchanged"
  end

  test "control: a token minted without operations allows none" do
    {root, t, full} = minted(["a"], [])
    assert {:error, :op_not_allowed} = Token.verify(full, root, ctx("a", t, "read"))
    assert {:ok, _} = Token.verify(full, root, ctx("a", t))
  end

  test "control: an unknown operation cannot be minted or added" do
    root = :crypto.strong_rand_bytes(32)

    assert {:error, :bad_ops} =
             Token.issue(root, ["a"], "m", :crypto.strong_rand_bytes(32), ["write"])

    {_, _, full} = minted(["a"], ["read"])
    assert {:error, :bad_ops} = Token.restrict_ops(full, ["delete"])
  end

  test "control: appending read to a token that had none does not give it" do
    {root, t, full} = minted(["a"], [])
    {:ok, wider} = Token.restrict_ops(full, ["read"])
    assert {:error, :op_not_allowed} = Token.verify(wider, root, ctx("a", t, "read"))
  end

  property "read is allowed exactly when granted and not narrowed away" do
    check all(
            granted <- boolean(),
            narrowings <- list_of(boolean(), max_length: 3)
          ) do
      {root, t, full} = minted(["a"], if(granted, do: ["read"], else: []))

      token =
        Enum.reduce(narrowings, full, fn keep, tok ->
          {:ok, n} = Token.restrict_ops(tok, if(keep, do: ["read"], else: []))
          n
        end)

      allowed = granted and Enum.all?(narrowings)

      assert match?({:ok, _}, Token.verify(token, root, ctx("a", t, "read"))) == allowed
      assert match?({:ok, _}, Token.verify(token, root, ctx("a", t)))
    end
  end

  property "a flipped byte in a token with read never allows more" do
    check all(i <- integer(0..400)) do
      {root, t, full} = minted(["a"], ["read"])
      i = rem(i, byte_size(full))
      <<pre::binary-size(i), b, post::binary>> = full
      bad = <<pre::binary, Bitwise.bxor(b, 1), post::binary>>

      case Token.verify(bad, root, ctx("a", t, "read")) do
        {:ok, _} -> assert bad == full
        {:error, _} -> :ok
      end
    end
  end
end
