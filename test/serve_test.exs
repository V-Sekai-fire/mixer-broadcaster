# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.ServeTest do
  @moduledoc """
  CONTROL: the deployed relay cannot start open. A missing, short, long or non-hex root key is refused and nothing listens.
  GOLDEN: a good key starts a listener whose policy is the root key, never `:off`.
  INVARIANT: every string that is not exactly 64 hex characters is refused.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias MixerBroadcaster.Serve

  setup do
    saved = Application.get_env(:mixer_broadcaster, :auth)
    name = :"mb_relay_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> MixerBroadcaster.Server.stop(name) end)

    on_exit(fn ->
      restore(saved)
    end)

    %{name: name}
  end

  defp restore(nil), do: Application.delete_env(:mixer_broadcaster, :auth)
  defp restore(v), do: Application.put_env(:mixer_broadcaster, :auth, v)

  @good String.duplicate("ab", 32)

  test "control: no key, an empty key, a short key and a long key are all refused" do
    for bad <- [
          nil,
          "",
          "ab",
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.duplicate("a", 128)
        ] do
      assert Serve.root_key(bad) == {:error, :root_key}
    end
  end

  test "control: non-hex text of the right length is refused" do
    assert Serve.root_key(String.duplicate("zz", 32)) == {:error, :root_key}
    assert Serve.root_key(String.duplicate("g", 64)) == {:error, :root_key}
  end

  property "invariant: only exactly 64 hex characters are a root key" do
    check all(text <- StreamData.string(:printable, max_length: 100)) do
      case Serve.root_key(text) do
        {:ok, key} -> assert byte_size(key) == 32 and String.length(text) == 64
        {:error, :root_key} -> :ok
      end
    end

    check all(bytes <- StreamData.binary(length: 32)) do
      assert {:ok, ^bytes} = Serve.root_key(Base.encode16(bytes))
    end
  end

  test "control: start without a key listens on nothing and leaves no policy behind" do
    Application.delete_env(:mixer_broadcaster, :auth)
    assert {:error, :root_key} = Serve.start(%{"MB_WT_PORT" => "0"})
    assert Application.get_env(:mixer_broadcaster, :auth) == nil
  end

  test "control: a bad bind host is refused before anything starts", %{name: name} do
    assert {:error, {:bind, _, _}} =
             Serve.start(
               %{
                 "MB_ROOT_KEY" => @good,
                 "MB_BIND" => "no-such-host.invalid",
                 "MB_WT_PORT" => "0"
               },
               name: name
             )
  end

  test "golden: a good key starts the listener; the policy is the root key and never :off", %{
    name: name
  } do
    assert {:ok, %{port: port, cert_sha256: hash}} =
             Serve.start(%{"MB_ROOT_KEY" => @good, "MB_WT_PORT" => "0", "MB_BIND" => "127.0.0.1"},
               name: name
             )

    assert port > 0
    assert byte_size(hash) == 64
    assert %{root_key: root} = Application.get_env(:mixer_broadcaster, :auth)
    assert root == Base.decode16!(@good, case: :lower)
    refute Application.get_env(:mixer_broadcaster, :auth) == :off
    assert Application.get_env(:mixer_broadcaster, :allowed_origins) == []
  end

  test "golden: origins are taken from MB_ORIGINS, comma separated", %{name: name} do
    {:ok, _} =
      Serve.start(
        %{
          "MB_ROOT_KEY" => @good,
          "MB_WT_PORT" => "0",
          "MB_BIND" => "127.0.0.1",
          "MB_ORIGINS" => "https://a.example, https://b.example"
        },
        name: name
      )

    assert Application.get_env(:mixer_broadcaster, :allowed_origins) == [
             "https://a.example",
             "https://b.example"
           ]
  end
end
