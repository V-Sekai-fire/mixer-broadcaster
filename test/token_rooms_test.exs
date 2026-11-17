# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.TokenRoomsTest do
  @moduledoc """
  GOLDEN: a token for a set of rooms admits each room in the set; a holder narrows it to some of them.
  INVARIANT: for any rooms, any narrowing and any room asked for, the token verifies exactly when the room is in the
  original set AND in every narrowing; narrowing never admits a room the token did not already admit.
  CONTROL: a room outside the set, a narrowing to a room outside the set, and a tampered narrowed token are refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Token

  @now 1_800_000_000

  defp setup_keys,
    do:
      {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32),
       :crypto.strong_rand_bytes(32)}

  defp ctx(room, t), do: %{room: room, thumbprint: t, now: @now}

  defp minted(rooms) do
    {root, tp, t} = setup_keys()
    token = Token.issue(root, rooms, "minter.internal", tp)
    {:ok, full} = Token.discharge(token, tp, t, 3600, @now)
    {root, t, full}
  end

  test "golden: every room in the set is admitted, and one outside is not" do
    {root, t, full} = minted(["lobby", "arena", "club"])

    for r <- ["lobby", "arena", "club"],
        do: assert({:ok, _} = Token.verify(full, root, ctx(r, t)))

    assert {:error, :wrong_room} = Token.verify(full, root, ctx("vault", t))
  end

  test "golden: a single room still works as before" do
    {root, t, full} = minted("lobby")
    assert {:ok, _} = Token.verify(full, root, ctx("lobby", t))
    assert {:error, :wrong_room} = Token.verify(full, root, ctx("arena", t))
  end

  test "golden: a holder narrows a token to some of its rooms, with no key" do
    {root, t, full} = minted(["lobby", "arena", "club"])
    {:ok, narrow} = Token.restrict_rooms(full, ["arena"])
    assert {:ok, _} = Token.verify(narrow, root, ctx("arena", t))
    assert {:error, :wrong_room} = Token.verify(narrow, root, ctx("lobby", t))
    assert {:ok, _} = Token.verify(full, root, ctx("lobby", t)), "the original is unchanged"
  end

  test "golden: a deferred room check admits the session and leaves each room to be checked on its own" do
    {root, t, full} = minted(["lobby", "arena"])
    assert {:ok, _} = Token.verify(full, root, ctx(:none, t))
    {:ok, narrow} = Token.restrict_rooms(full, ["lobby"])
    assert {:ok, _} = Token.verify(narrow, root, ctx(:none, t))
    assert {:error, :wrong_room} = Token.verify(narrow, root, ctx("arena", t))
  end

  test "control: narrowing to a room outside the set does not admit it" do
    {root, t, full} = minted(["lobby", "arena"])
    {:ok, wide} = Token.restrict_rooms(full, ["vault", "lobby"])
    assert {:error, :wrong_room} = Token.verify(wide, root, ctx("vault", t))
    assert {:ok, _} = Token.verify(wide, root, ctx("lobby", t))
    assert {:error, :wrong_room} = Token.verify(wide, root, ctx("arena", t))
  end

  test "control: a narrowing that shares no room with the set admits nothing" do
    {root, t, full} = minted(["lobby"])
    {:ok, none} = Token.restrict_rooms(full, ["vault"])

    for r <- ["lobby", "vault"],
        do: assert({:error, :wrong_room} = Token.verify(none, root, ctx(r, t)))
  end

  test "control: another key's thumbprint, another root and an empty or bad room list are refused" do
    {root, t, full} = minted(["lobby"])

    assert {:error, :wrong_key} =
             Token.verify(full, root, ctx("lobby", :crypto.strong_rand_bytes(32)))

    assert {:error, _} = Token.verify(full, :crypto.strong_rand_bytes(32), ctx("lobby", t))
    assert {:error, :bad_rooms} = Token.issue(root, ["a", 5], "m", :crypto.strong_rand_bytes(32))
    assert {:error, :bad_rooms} = Token.restrict_rooms(full, ["a", 5])

    assert_raise FunctionClauseError, fn ->
      Token.issue(root, [], "m", :crypto.strong_rand_bytes(32))
    end
  end

  property "invariant: admitted exactly when the room is in the set and in every narrowing" do
    room = StreamData.member_of(~w(a b c d e f))
    rooms = StreamData.map(StreamData.list_of(room, min_length: 1, max_length: 8), &Enum.uniq/1)

    check all(
            set <- rooms,
            narrowings <- StreamData.list_of(rooms, max_length: 3),
            ask <- room,
            max_runs: 40
          ) do
      {root, t, full} = minted(set)

      token =
        Enum.reduce(narrowings, full, fn n, acc ->
          {:ok, tok} = Token.restrict_rooms(acc, n)
          tok
        end)

      want = Enum.all?([set | narrowings], &(ask in &1))
      got = match?({:ok, _}, Token.verify(token, root, ctx(ask, t)))

      assert got == want,
             "set #{inspect(set)} narrowed #{inspect(narrowings)} asked #{ask}: got #{got}"
    end
  end

  property "control: flipping any single byte of a narrowed token is refused" do
    {root, t, full} = minted(["lobby", "arena"])
    {:ok, narrow} = Token.restrict_rooms(full, ["arena"])

    check all(
            i <- StreamData.integer(0..(byte_size(narrow) - 1)),
            bit <- StreamData.integer(0..7),
            max_runs: 200
          ) do
      <<head::binary-size(i), b, tail::binary>> = narrow
      flipped = <<head::binary, Bitwise.bxor(b, Bitwise.<<<(1, bit)), tail::binary>>
      assert {:error, _} = Token.verify(flipped, root, ctx("arena", t))
    end
  end
end
