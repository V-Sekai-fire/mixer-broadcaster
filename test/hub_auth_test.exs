# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.HubAuthTest do
  @moduledoc """
  GOLDEN: two admitted players in one room see each other; an outsider in another room sees nothing.
  CONTROL: every way of getting in without being admitted fails, and a failed session never reaches the room.
  """
  use ExUnit.Case, async: false

  alias MixerBroadcaster.{Auth, Hub, Token}

  @now 1_800_000_000

  setup do
    root = :crypto.strong_rand_bytes(32)
    tp = :crypto.strong_rand_bytes(32)
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: root})
    on_exit(fn -> Application.delete_env(:mixer_broadcaster, :auth) end)
    %{root: root, tp: tp}
  end

  # ---- a player, as the relay sees one ----
  defp session(room), do: elem(Hub.init(nil, %{path: "/room/#{room}"}, []), 1)

  defp talk(state, msg) do
    {:ok, st, actions} = Hub.handle_datagram(JSON.encode!(msg), state)
    {st, actions}
  end

  defp reply(state, msg) do
    {:ok, st, [{:send, _, body, :fin} | _]} =
      Hub.handle_stream(0, :bidi, JSON.encode!(msg), state)

    {st, JSON.decode!(body)}
  end

  defp token_for(tp, root, room, pub, ttl \\ 3600) do
    t = Token.issue(root, room, "minter", tp)
    {:ok, full} = Token.discharge(t, tp, Auth.thumbprint(pub), ttl, System.os_time(:second))
    full
  end

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp login(state, token, {pub, priv}, room) do
    {state, %{"t" => "challenge", "nonce" => n}} = reply(state, %{t: "hello"})
    nonce = Base.url_decode64!(n, padding: false)

    reply(state, %{
      t: "auth",
      token: b64(token),
      key: b64(pub),
      sig: b64(Auth.sign(priv, room, nonce))
    })
  end

  test "golden: two players meet in a room; an outsider in another room sees nothing", %{
    root: r,
    tp: tp
  } do
    {k1, k2, k3} = {Auth.generate_key(), Auth.generate_key(), Auth.generate_key()}
    test_pid = self()

    # player B and the outsider C run in their own processes, like real sessions
    b =
      Task.async(fn ->
        st = session("hypo")
        {st, %{"t" => "ready"}} = login(st, token_for(tp, r, "hypo", elem(k2, 0)), k2, "hypo")
        send(test_pid, :b_ready)
        receive do: (:go -> :ok)
        {_st, %{"t" => "ok"}} = reply(st, %{t: "set", id: 18, rgb: [255, 0, 0]})
        :done
      end)

    c =
      Task.async(fn ->
        st = session("other")
        {_st, %{"t" => "ready"}} = login(st, token_for(tp, r, "other", elem(k3, 0)), k3, "other")
        send(test_pid, :c_ready)

        receive do
          {:relay, _, _} -> :heard_something
        after
          600 -> :silence
        end
      end)

    a = session("hypo")
    {_a, %{"t" => "ready"}} = login(a, token_for(tp, r, "hypo", elem(k1, 0)), k1, "hypo")
    assert_receive :b_ready, 2000
    assert_receive :c_ready, 2000
    send(b.pid, :go)
    assert_receive {:relay, _, bin}, 2000
    assert %{"t" => "set", "id" => 18, "rgb" => [255, 0, 0]} = JSON.decode!(bin)
    assert Task.await(b) == :done
    assert Task.await(c) == :silence
  end

  describe "control: not admitted" do
    setup %{root: r, tp: tp} do
      %{k: Auth.generate_key(), r: r, tp: tp}
    end

    defp in_room?(room),
      do:
        Registry.lookup(MixerBroadcaster.Registry, room)
        |> Enum.any?(fn {pid, _} -> pid == self() end)

    test "a message before login" do
      st = session("hypo")
      assert {_, %{"reason" => "unauthenticated"}} = reply(st, %{t: "set", id: 1, rgb: [1, 2, 3]})
      refute in_room?("hypo")
    end

    test "auth before hello (no nonce was issued)", %{k: {pub, priv} = k, r: r, tp: tp} do
      st = session("hypo")
      sig = Auth.sign(priv, "hypo", :crypto.strong_rand_bytes(32))
      msg = %{t: "auth", token: b64(token_for(tp, r, "hypo", pub)), key: b64(pub), sig: b64(sig)}
      assert {_, %{"reason" => "unauthenticated"}} = reply(st, msg)
      refute in_room?("hypo")
      _ = k
    end

    test "a token for another room", %{k: {pub, _} = k, r: r, tp: tp} do
      st = session("hypo")

      assert {st, %{"reason" => "denied"}} =
               login(st, token_for(tp, r, "elsewhere", pub), k, "hypo")

      refute in_room?("hypo")
      assert {_, %{"reason" => "unauthenticated"}} = reply(st, %{t: "set", id: 1, rgb: [1, 2, 3]})
    end

    test "a token bound to someone else's key", %{k: k, r: r, tp: tp} do
      {other_pub, _} = Auth.generate_key()
      st = session("hypo")

      assert {_, %{"reason" => "denied"}} =
               login(st, token_for(tp, r, "hypo", other_pub), k, "hypo")

      refute in_room?("hypo")
    end

    test "a token with no discharge", %{k: k, r: r, tp: tp} do
      st = session("hypo")

      assert {_, %{"reason" => "denied"}} =
               login(st, Token.issue(r, "hypo", "minter", tp), k, "hypo")

      refute in_room?("hypo")
    end

    test "an expired token", %{k: {pub, _} = k, r: r, tp: tp} do
      t = Token.issue(r, "hypo", "minter", tp)
      {:ok, old} = Token.discharge(t, tp, Auth.thumbprint(pub), 10, System.os_time(:second) - 100)
      st = session("hypo")
      assert {_, %{"reason" => "denied"}} = login(st, old, k, "hypo")
      refute in_room?("hypo")
    end

    test "a recorded proof does not work in a new session", %{k: {pub, priv}, r: r, tp: tp} do
      tok = token_for(tp, r, "hypo", pub)
      first = session("hypo")
      {first, %{"nonce" => n1}} = reply(first, %{t: "hello"})
      old_sig = Auth.sign(priv, "hypo", Base.url_decode64!(n1, padding: false))

      assert {_, %{"t" => "ready"}} =
               reply(first, %{t: "auth", token: b64(tok), key: b64(pub), sig: b64(old_sig)})

      Registry.unregister(MixerBroadcaster.Registry, "hypo")

      second = session("hypo")
      {second, %{"nonce" => _fresh}} = reply(second, %{t: "hello"})

      assert {_, %{"reason" => "denied"}} =
               reply(second, %{t: "auth", token: b64(tok), key: b64(pub), sig: b64(old_sig)})

      refute in_room?("hypo")
    end

    test "a proof made for another room", %{k: {pub, priv}, r: r, tp: tp} do
      tok = token_for(tp, r, "hypo", pub)
      st = session("hypo")
      {st, %{"nonce" => n}} = reply(st, %{t: "hello"})
      sig = Auth.sign(priv, "other", Base.url_decode64!(n, padding: false))

      assert {_, %{"reason" => "denied"}} =
               reply(st, %{t: "auth", token: b64(tok), key: b64(pub), sig: b64(sig)})
    end

    test "a public key that is not on the curve", %{r: r, tp: tp} do
      bad = <<4>> <> :crypto.strong_rand_bytes(64)
      st = session("hypo")
      {st, %{"nonce" => _}} = reply(st, %{t: "hello"})
      tok = Token.issue(r, "hypo", "minter", tp)
      msg = %{t: "auth", token: b64(tok), key: b64(bad), sig: b64(:crypto.strong_rand_bytes(64))}
      assert {_, %{"reason" => "denied"}} = reply(st, msg)
    end

    test "three failures lock the session, even for a valid login afterwards", %{
      k: {pub, priv} = k,
      r: r,
      tp: tp
    } do
      st = session("hypo")
      st = Enum.reduce(1..3, st, fn _, s -> elem(login(s, "junk", k, "hypo"), 0) end)
      assert {st, %{"reason" => "locked"}} = reply(st, %{t: "hello"})

      tok = token_for(tp, r, "hypo", pub)
      sig = Auth.sign(priv, "hypo", Auth.nonce())

      assert {_, %{"reason" => "locked"}} =
               reply(st, %{t: "auth", token: b64(tok), key: b64(pub), sig: b64(sig)})

      refute in_room?("hypo")
    end

    test "no :auth configured means nobody gets in" do
      Application.delete_env(:mixer_broadcaster, :auth)
      k = Auth.generate_key()
      st = session("hypo")
      assert {_, %{"reason" => "denied"}} = login(st, "anything", k, "hypo")
      refute in_room?("hypo")
    end
  end

  test "property: the proof round-trips through the raw/DER conversion for many keys" do
    for _ <- 1..200 do
      {pub, priv} = Auth.generate_key()
      nonce = Auth.nonce()
      sig = Auth.sign(priv, "r", nonce)
      assert byte_size(sig) == 64

      assert :crypto.verify(:ecdsa, :sha256, Auth.message("r", nonce), Auth.raw_to_der(sig), [
               pub,
               :secp256r1
             ])
    end
  end
end
