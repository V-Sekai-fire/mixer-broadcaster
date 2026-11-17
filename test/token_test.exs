# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.TokenTest do
  @moduledoc """
  GOLDEN: the happy path, two players, one relay.
  INVARIANT: for any room, key and lifetime a discharged token verifies for exactly that room and key.
  CONTROL: every way to be refused is refused (each one is a separate test that must fail closed).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Token

  @now 1_800_000_000

  defp keys, do: {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)}
  defp thumb, do: :crypto.strong_rand_bytes(32)
  defp ctx(room, t, now \\ @now), do: %{room: room, thumbprint: t, now: now}

  defp minted(root, tp, room, t, ttl \\ 3600) do
    token = Token.issue(root, room, "minter.internal", tp)
    {:ok, full} = Token.discharge(token, tp, t, ttl, @now)
    {token, full}
  end

  test "golden: two players in one room, each bound to their own key" do
    {root, tp} = keys()
    {a, b} = {thumb(), thumb()}
    {_, ta} = minted(root, tp, "hypo", a)
    {_, tb} = minted(root, tp, "hypo", b)
    assert {:ok, %{room: "hypo"}} = Token.verify(ta, root, ctx("hypo", a))
    assert {:ok, %{room: "hypo"}} = Token.verify(tb, root, ctx("hypo", b))
    assert {:error, :wrong_key} = Token.verify(ta, root, ctx("hypo", b))
  end

  property "invariant: a discharged token verifies for its room and key, and only inside its window" do
    check all(
            room <- string(:alphanumeric, min_length: 1, max_length: 24),
            ttl <- integer(1..86_400),
            offset <- integer(0..86_400)
          ) do
      {root, tp} = keys()
      t = thumb()
      {_, full} = minted(root, tp, room, t, ttl)
      result = Token.verify(full, root, ctx(room, t, @now + offset))
      if offset <= ttl, do: assert({:ok, _} = result), else: assert({:error, :expired} = result)
    end
  end

  describe "control: refused" do
    setup do
      {root, tp} = keys()
      t = thumb()
      {bare, full} = minted(root, tp, "hypo", t)
      %{root: root, tp: tp, t: t, bare: bare, full: full}
    end

    test "no discharge", %{root: r, t: t, bare: bare} do
      assert {:error, :no_discharge} = Token.verify(bare, r, ctx("hypo", t))
    end

    test "wrong room", %{root: r, t: t, full: f} do
      assert {:error, :wrong_room} = Token.verify(f, r, ctx("other", t))
    end

    test "wrong key", %{root: r, full: f} do
      assert {:error, :wrong_key} = Token.verify(f, r, ctx("hypo", thumb()))
    end

    test "expired and not yet valid", %{root: r, t: t, full: f} do
      assert {:error, :expired} = Token.verify(f, r, ctx("hypo", t, @now + 3601))
      assert {:error, :expired} = Token.verify(f, r, ctx("hypo", t, @now - 1))
    end

    test "another relay's root key", %{t: t, full: f} do
      assert {:error, :bad_signature} =
               Token.verify(f, :crypto.strong_rand_bytes(32), ctx("hypo", t))
    end

    test "a discharge made with another minter key is not accepted", %{root: r, t: t} do
      token = Token.issue(r, "hypo", "minter.internal", :crypto.strong_rand_bytes(32))
      other_minter = :crypto.strong_rand_bytes(32)
      assert {:error, _} = Token.discharge(token, other_minter, t, 3600, @now)
    end

    test "a discharge made for another token is not accepted", %{
      root: r,
      tp: tp,
      t: t,
      full: full
    } do
      {:ok, [1, _main, [d]]} = decode(full)
      other = Token.issue(r, "hypo", "minter.internal", tp)
      {:ok, [1, main2, []]} = decode(other)
      grafted = CBOR.encode([1, main2, [d]])
      assert {:error, :no_discharge} = Token.verify(grafted, r, ctx("hypo", t))
    end

    test "dropping the room caveat is refused (the chain breaks)", %{root: r, t: t, full: full} do
      {:ok, [1, [root_link, _room | rest], ds]} = decode(full)
      cut = CBOR.encode([1, [root_link | rest], ds])
      assert {:error, _} = Token.verify(cut, r, ctx("hypo", t))
    end

    test "unknown version, trailing bytes, empty, garbage", %{root: r, t: t, full: full} do
      {:ok, [1, main, ds]} = decode(full)

      assert {:error, :unknown_version} =
               Token.verify(CBOR.encode([2, main, ds]), r, ctx("hypo", t))

      assert {:error, :trailing_bytes} = Token.verify(full <> <<0>>, r, ctx("hypo", t))
      assert {:error, _} = Token.verify(<<>>, r, ctx("hypo", t))
      assert {:error, _} = Token.verify("not cbor at all", r, ctx("hypo", t))
      assert {:error, :bad_token} = Token.verify(String.duplicate("a", 9000), r, ctx("hypo", t))
    end
  end

  property "control: flipping any single byte of a valid token is refused" do
    {root, tp} = keys()
    t = thumb()
    {_, full} = minted(root, tp, "hypo", t)

    check all(i <- integer(0..(byte_size(full) - 1)), bit <- integer(0..7)) do
      <<pre::binary-size(^i), b, post::binary>> = full
      mutated = <<pre::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit)), post::binary>>
      assert {:error, _} = Token.verify(mutated, root, ctx("hypo", t))
    end
  end

  property "control: truncating or extending a valid token is refused" do
    {root, tp} = keys()
    t = thumb()
    {_, full} = minted(root, tp, "hypo", t)

    check all(n <- integer(1..(byte_size(full) - 1))) do
      assert {:error, _} = Token.verify(binary_part(full, 0, n), root, ctx("hypo", t))
    end

    check all(extra <- binary(min_length: 1, max_length: 40)) do
      assert {:error, _} = Token.verify(full <> extra, root, ctx("hypo", t))
    end
  end

  property "control: arbitrary bytes never verify and never crash" do
    {root, _} = keys()

    check all(junk <- binary(max_length: 400), max_runs: 3000) do
      assert {:error, _} = Token.verify(junk, root, ctx("hypo", thumb()))
    end
  end

  defp decode(bin), do: case(CBOR.decode(bin), do: ({:ok, t, ""} -> {:ok, t}))
end
