# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mixer.S3Test do
  @moduledoc """
  GOLDEN: the signature equals the one the Python add-on makes for the same request (pinned values, both accepted by
  SeaweedFS). INVARIANT: the signature depends on every part of the request. CONTROL: no keys -> an error, never a raise.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Mixer.Store.S3

  @now ~U[2026-11-16 12:00:00Z]
  @keys {"AKID", "SECRET"}

  defp auth(hs), do: hs |> Enum.find(fn {n, _} -> n == "authorization" end) |> elem(1)

  test "golden: matches the Python signer for the same request" do
    hs = S3.sign("PUT", "127.0.0.1:8333", "/mixer/index/ab.caibx", "hello", @keys, @now)
    assert {"x-amz-date", "20261116T120000Z"} in hs

    assert {"x-amz-content-sha256",
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"} in hs

    assert auth(hs) ==
             "AWS4-HMAC-SHA256 Credential=AKID/20261116/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=0a331c1c483cc4d7c600145fe7dae057ebfdf4991c172a97cb2b265355c54cd9"
  end

  property "the signature changes with the method, host, path, body, key and time" do
    check all(
            body <- binary(),
            other <- binary(),
            body != other
          ) do
      base = auth(S3.sign("PUT", "h:1", "/b/k", body, @keys, @now))
      assert base == auth(S3.sign("PUT", "h:1", "/b/k", body, @keys, @now))
      refute base == auth(S3.sign("GET", "h:1", "/b/k", body, @keys, @now))
      refute base == auth(S3.sign("PUT", "h:2", "/b/k", body, @keys, @now))
      refute base == auth(S3.sign("PUT", "h:1", "/b/j", body, @keys, @now))
      refute base == auth(S3.sign("PUT", "h:1", "/b/k", other, @keys, @now))
      refute base == auth(S3.sign("PUT", "h:1", "/b/k", body, {"AKID", "OTHER"}, @now))
      refute base == auth(S3.sign("PUT", "h:1", "/b/k", body, @keys, DateTime.add(@now, 1)))
    end
  end

  test "control: without keys a get is an error, not a crash" do
    a = System.get_env("AWS_ACCESS_KEY_ID")
    s = System.get_env("AWS_SECRET_ACCESS_KEY")
    System.delete_env("AWS_ACCESS_KEY_ID")
    System.delete_env("AWS_SECRET_ACCESS_KEY")
    assert S3.get(:crypto.hash(:sha256, "x")) == {:error, :no_s3_keys}
    if a, do: System.put_env("AWS_ACCESS_KEY_ID", a)
    if s, do: System.put_env("AWS_SECRET_ACCESS_KEY", s)
  end
end
