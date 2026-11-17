# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.AuthSessionTest do
  @moduledoc """
  GOLDEN: a player with a token for two rooms is admitted to a Mixer session and may enter those rooms and no other.
  INVARIANT: for any set of rooms, narrowing and room asked for, `allow` agrees with the token alone.
  CONTROL: a proof for a room is no proof for a session, another player's key, a stale nonce, another relay's token, a
  bad point, a short proof and a tampered token are all refused; a Mixer join to a room outside the token is refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.{Auth, Token}
  alias MixerBroadcaster.Mixer.{Core, Wire}

  @now 1_800_000_000

  defp relay, do: %{root_key: :crypto.strong_rand_bytes(32)}

  defp player(cfg, rooms) do
    {pub, priv} = Auth.generate_key()
    tp_key = :crypto.strong_rand_bytes(32)
    token = Token.issue(cfg.root_key, rooms, "minter", tp_key)
    {:ok, full} = Token.discharge(token, tp_key, Auth.thumbprint(pub), 3600, @now)
    %{pub: pub, priv: priv, token: full}
  end

  defp login(cfg, p, nonce \\ Auth.nonce()),
    do: Auth.admit_session(cfg, p.token, p.pub, Auth.sign_session(p.priv, nonce), nonce, @now)

  test "golden: admitted, and may enter exactly the rooms of its token" do
    cfg = relay()
    p = player(cfg, ["lobby", "arena"])
    assert {:ok, tp, allow} = login(cfg, p)
    assert tp == Auth.thumbprint(p.pub)
    assert allow.("lobby") and allow.("arena")
    refute allow.("vault")
    refute allow.(nil)
  end

  test "golden: a Mixer join to a room outside the token is refused, one inside is accepted" do
    cfg = relay()
    p = player(cfg, ["lobby"])
    {:ok, _, allow} = login(cfg, p)
    s = Core.connect(Core.new(), "a", "127.0.0.1", 1, allow)

    join = fn room ->
      %{
        type: Wire.type(:join_room),
        id: 0,
        data:
          Wire.string(room) <>
            Wire.string("5") <> Wire.string("1") <> Wire.bool(false) <> Wire.bool(false)
      }
    end

    {s2, outs} = Core.handle(s, "a", join.("vault"))
    assert [{"a", {t, _}}] = outs
    assert t == Wire.type(:send_error)
    assert s2.rooms == %{}
    {s3, _} = Core.handle(s, "a", join.("lobby"))
    assert Map.has_key?(s3.rooms, "lobby")
  end

  property "invariant: allow agrees with the token for any rooms, narrowing and room" do
    room = StreamData.member_of(~w(a b c d e))
    rooms = StreamData.map(StreamData.list_of(room, min_length: 1, max_length: 5), &Enum.uniq/1)

    check all(
            set <- rooms,
            narrow <- StreamData.one_of([StreamData.constant(nil), rooms]),
            ask <- room,
            max_runs: 40
          ) do
      cfg = relay()
      p = player(cfg, set)

      p =
        if narrow do
          {:ok, t} = Token.restrict_rooms(p.token, narrow)
          %{p | token: t}
        else
          p
        end

      {:ok, _, allow} = login(cfg, p)
      assert allow.(ask) == (ask in set and (narrow == nil or ask in narrow))
    end
  end

  test "control: refusals" do
    cfg = relay()
    p = player(cfg, ["lobby"])
    nonce = Auth.nonce()

    # a proof made for a room is not a proof for a session
    room_proof = Auth.sign(p.priv, "lobby", nonce)
    assert {:error, :bad_proof} = Auth.admit_session(cfg, p.token, p.pub, room_proof, nonce, @now)
    # not even for a room with an empty name: the two messages never coincide
    assert {:error, :bad_proof} =
             Auth.admit_session(cfg, p.token, p.pub, Auth.sign(p.priv, "", nonce), nonce, @now)

    # and the other way: a session proof does not admit to a room
    assert {:error, :bad_proof} =
             Auth.admit(
               cfg,
               p.token,
               p.pub,
               Auth.sign_session(p.priv, nonce),
               "lobby",
               nonce,
               @now
             )

    # another player's key, a stale nonce, another relay's token
    other = player(cfg, ["lobby"])

    assert {:error, _} =
             Auth.admit_session(
               cfg,
               p.token,
               other.pub,
               Auth.sign_session(other.priv, nonce),
               nonce,
               @now
             )

    assert {:error, :bad_proof} =
             Auth.admit_session(
               cfg,
               p.token,
               p.pub,
               Auth.sign_session(p.priv, nonce),
               Auth.nonce(),
               @now
             )

    assert {:error, _} = login(relay(), p)

    # not a point on the curve, a short proof, an expired token, a tampered token, no configuration
    bad = <<4, 1::256, 1::256>>

    assert {:error, :bad_key} =
             Auth.admit_session(cfg, p.token, bad, Auth.sign_session(p.priv, nonce), nonce, @now)

    assert {:error, :bad_proof} =
             Auth.admit_session(cfg, p.token, p.pub, <<1, 2, 3>>, nonce, @now)

    assert {:error, _} =
             Auth.admit_session(
               cfg,
               p.token,
               p.pub,
               Auth.sign_session(p.priv, nonce),
               nonce,
               @now + 7200
             )

    <<h, rest::binary>> = p.token

    assert {:error, _} =
             Auth.admit_session(
               cfg,
               <<Bitwise.bxor(h, 1), rest::binary>>,
               p.pub,
               Auth.sign_session(p.priv, nonce),
               nonce,
               @now
             )

    assert {:error, :not_configured} =
             Auth.admit_session(
               %{},
               p.token,
               p.pub,
               Auth.sign_session(p.priv, nonce),
               nonce,
               @now
             )

    assert {:error, :not_configured} = Auth.admit_session(nil, p.token, p.pub, <<>>, nonce, @now)
  end
end
