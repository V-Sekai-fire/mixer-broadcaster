# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.CommandTest do
  @moduledoc """
  GOLDEN: the 96 command packets the add-on's codec writes decode here to the fields it started from and encode
  back to the same bytes, small and bulk.
  INVARIANT: for any type, owner, clock and data, pack then unpack gives them back; bulk data goes to the store only when
  it does not fit; the packet is always 100 bytes.
  CONTROL: a pose type, a bad owner, a short or long packet, a nonzero tail, another class, a wrong stored length and a
  missing blob are refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Command

  @fixture Path.join([__DIR__, "fixtures", "command_golden.csv"])

  defp store_in(table),
    do: fn d ->
      digest = :crypto.hash(:sha256, d)
      :ets.insert(table, {digest, d})
      digest
    end

  defp fetch_from(table) do
    fn digest ->
      case :ets.lookup(table, digest) do
        [{_, d}] -> {:ok, d}
        [] -> {:error, :missing}
      end
    end
  end

  defp rows do
    @fixture
    |> File.read!()
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(fn line ->
      [t, o, h, d, p, b] = line |> String.trim() |> String.split(",")

      %{
        type: String.to_integer(t),
        owner: String.to_integer(o),
        hlc: String.to_integer(h),
        data: Base.decode16!(d, case: :lower),
        packet: Base.decode16!(p, case: :lower),
        bulk: b == "1"
      }
    end)
  end

  test "golden: the add-on's packets decode here and encode back to the same bytes" do
    table = :ets.new(:blobs, [:set, :public])
    rs = rows()
    assert length(rs) == 96
    assert Enum.any?(rs, & &1.bulk) and Enum.any?(rs, &(not &1.bulk))

    for r <- rs do
      if r.bulk, do: :ets.insert(table, {:crypto.hash(:sha256, r.data), r.data})
      assert {:ok, got} = Command.unpack(r.packet, fetch_from(table))
      assert {got.type, got.owner, got.hlc, got.data} == {r.type, r.owner, r.hlc, r.data}
      assert {:ok, r.packet} == Command.pack(r.type, r.data, r.owner, r.hlc, store_in(table))
    end
  end

  property "invariant: pack then unpack gives the command back, in one 100 byte packet" do
    check all(
            type <- StreamData.filter(StreamData.integer(1..0xFFFF), &(&1 != 210)),
            data <-
              StreamData.one_of([
                StreamData.binary(max_length: 77),
                StreamData.binary(min_length: 78, max_length: 2000)
              ]),
            owner <- StreamData.integer(0..0xFFFFFF),
            hlc <- StreamData.integer(0..(Bitwise.bsl(1, 64) - 1)),
            max_runs: 200
          ) do
      table = :ets.new(:blobs, [:set, :public])
      assert {:ok, pkt} = Command.pack(type, data, owner, hlc, store_in(table))
      assert byte_size(pkt) == 100
      assert :ets.info(table, :size) == 0 == byte_size(data) <= 77

      assert {:ok, %{type: ^type, owner: ^owner, hlc: ^hlc, data: ^data}} =
               Command.unpack(pkt, fetch_from(table))
    end
  end

  describe "mode 2: data named by its desync index (over 16 MiB, never read by the relay)" do
    test "golden: the packet holds the digest and the sender's key; the store and fetch are never called" do
      digest = :crypto.hash(:sha256, "an index")
      data = Command.index(digest, 0xDEADBEEF)
      no = fn _ -> flunk("the relay must not touch the store or fetch") end
      assert {:ok, pkt} = Command.pack(77, data, 9, 1234, no)
      <<key::little-32, run::binary-size(36), _hlc::little-64, _::binary>> = pkt
      assert key == 0xDEADBEEF
      assert <<2, ^digest::binary-size(32), 0, 0, 0>> = run

      assert {:ok, %{type: 77, owner: 9, hlc: 1234, key: 0xDEADBEEF, data: ^data}} =
               Command.unpack(pkt, no)

      assert Command.index?(data)
    end

    test "golden: the same packet as the add-on writes it (mode 2, used 33, key from the sender)" do
      # built by mixer/broadcaster/entity.py pack_command for type 77, owner 9, hlc 1234, digest = 32 bytes of 0x11
      key = 0x01020304

      py =
        <<key::little-32, 2, :binary.copy(<<0x11>>, 32)::binary, 0, 0, 0, 1234::little-64,
          9::little-24, 128, 77::little-16, 33::little-16, 0::unit(8)-size(42), 0, 0>>

      assert byte_size(py) == 100
      assert {:ok, %{data: d, key: ^key}} = Command.unpack(py, fn _ -> {:error, :none} end)
      assert d == Command.index(:binary.copy(<<0x11>>, 32), key)
      assert {:ok, ^py} = Command.pack(77, d, 9, 1234, fn _ -> flunk("no store") end)
    end

    property "any digest, key, owner and clock survive the relay (unpack, then pack)" do
      check all(
              digest <- StreamData.binary(length: 32),
              key <- StreamData.integer(0..0xFFFFFFFF),
              type <- StreamData.integer(1..0xFFFF),
              owner <- StreamData.integer(0..0xFFFFFF),
              hlc <- StreamData.integer(0..(Bitwise.bsl(1, 64) - 1)),
              type != 210
            ) do
        no = fn _ -> flunk("no store") end
        {:ok, pkt} = Command.pack(type, Command.index(digest, key), owner, hlc, no)
        assert {:ok, %{data: data, key: ^key}} = Command.unpack(pkt, no)
        assert data == Command.index(digest, key)
        assert {:ok, ^pkt} = Command.pack(type, data, owner, hlc, no)
      end
    end

    test "control: a mode 2 packet with the wrong used length, a dirty tail or a short body is refused" do
      digest = :binary.copy(<<7>>, 32)
      no = fn _ -> {:error, :none} end
      {:ok, pkt} = Command.pack(77, Command.index(digest, 5), 1, 0, no)
      <<head::binary-size(52), type::little-16, used::little-16, rest::binary>> = pkt
      assert {:ok, _} = Command.unpack(pkt, no)

      assert {:error, _} =
               Command.unpack(<<head::binary, type::little-16, 36::little-16, rest::binary>>, no)

      assert {:error, _} =
               Command.unpack(<<head::binary, type::little-16, 32::little-16, rest::binary>>, no)

      assert used == 33
      <<pre::binary-size(60), _, post::binary>> = pkt
      assert {:error, :dirty_tail} = Command.unpack(<<pre::binary, 1, post::binary>>, no)
    end

    test "control: ordinary data that merely starts like the marker but is another length is inline data, not an index" do
      d = "mixer-index:" <> String.duplicate("x", 10)
      refute Command.index?(d)
      assert {:ok, pkt} = Command.pack(77, d, 1, 0, fn _ -> flunk("inline") end)
      assert {:ok, %{data: ^d}} = Command.unpack(pkt, fn _ -> {:error, :none} end)
    end
  end

  property "control: any single flipped bit either changes the command or is refused, never returns the same one" do
    {:ok, pkt} = Command.pack(101, "hello", 5, 9, fn _ -> flunk("inline") end)
    {:ok, base} = Command.unpack(pkt, fn _ -> {:error, :none} end)

    check all(i <- StreamData.integer(0..99), bit <- StreamData.integer(0..7), max_runs: 300) do
      <<head::binary-size(^i), b, tail::binary>> = pkt
      flipped = <<head::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit))::8, tail::binary>>

      case Command.unpack(flipped, fn _ -> {:error, :none} end) do
        {:ok, got} -> refute got == base
        {:error, _} -> :ok
      end
    end
  end

  test "control: the refusals" do
    no = fn _ -> flunk("not bulk") end

    for t <- [0, 210, 0x10000, -1],
        do: assert({:error, :bad_type} = Command.pack(t, "x", 1, 0, no))

    assert {:error, :bad_owner} = Command.pack(101, "x", 0x1000000, 0, no)
    assert {:error, :bad_hlc} = Command.pack(101, "x", 1, Bitwise.bsl(1, 64), no)

    assert {:error, :bad_digest} =
             Command.pack(101, :binary.copy("a", 100), 1, 0, fn _ -> "short" end)

    {:ok, ok} = Command.pack(101, "abc", 1, 0, no)
    gone = fn _ -> {:error, :none} end

    patch = fn bin, at, val ->
      n = byte_size(val)
      <<h::binary-size(^at), _::binary-size(^n), t::binary>> = bin
      h <> val <> t
    end

    for bad <- [
          patch.(ok, 60, <<1>>),
          patch.(ok, 20, <<1>>),
          patch.(ok, 99, <<1>>),
          patch.(ok, 51, <<4>>),
          patch.(ok, 52, <<210, 0>>),
          patch.(ok, 52, <<0, 0>>),
          patch.(ok, 54, <<0, 0>>),
          patch.(ok, 54, <<79, 0>>),
          patch.(ok, 4, <<2>>)
        ] do
      assert {:error, _} = Command.unpack(bad, gone)
    end

    assert {:error, :bad_size} = Command.unpack(binary_part(ok, 0, 99), gone)
    assert {:error, :bad_size} = Command.unpack(ok <> <<0>>, gone)

    table = :ets.new(:blobs, [:set, :public])
    {:ok, big} = Command.pack(101, :binary.copy("z", 200), 1, 0, store_in(table))
    assert {:error, :missing_bulk} = Command.unpack(big, gone)
    assert {:error, :wrong_length} = Command.unpack(big, fn _ -> {:ok, "short"} end)
  end
end
