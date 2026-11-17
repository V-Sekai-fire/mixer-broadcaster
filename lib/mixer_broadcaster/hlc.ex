defmodule MixerBroadcaster.Hlc do
  @moduledoc """
  The traditional Hybrid Logical Clock (Kulkarni, Demirbas et al., "Logical Physical Clocks", 2014).

  A stamp is `{l, c}`: `l` is the largest physical time seen, in milliseconds, and `c` orders events while
  `l` stands still. On the wire it is one little-endian u64 at byte 40 of the entity packet: `l` in the high
  48 bits and `c` in the low 16, as in contract-entity-packet (EntityPacket/Hlc.lean), which this module
  matches rule for rule. A counter that would pass 16 bits is refused, never wrapped: a wrapped counter puts
  a later event before an earlier one.
  """
  import Bitwise

  @c_max 0xFFFF
  @l_max Bitwise.bsl(1, 48) - 1

  @type t :: {non_neg_integer, non_neg_integer}

  @spec pack(t) :: non_neg_integer
  def pack({l, c}), do: Bitwise.bor(Bitwise.bsl(l, 16), c)

  @spec unpack(non_neg_integer) :: t
  def unpack(w), do: {Bitwise.bsr(w, 16), Bitwise.band(w, @c_max)}

  @doc "Local or send event at physical time `pt`."
  @spec send_event(t, non_neg_integer) :: {:ok, t} | :error
  def send_event({l0, c0}, pt) do
    l = max(l0, pt)
    check(l, if(l == l0, do: c0 + 1, else: 0))
  end

  @doc "Receipt of a message stamped `{lm, cm}` at physical time `pt`."
  @spec recv(t, t, non_neg_integer) :: {:ok, t} | :error
  def recv({l0, c0}, {lm, cm}, pt) do
    l = max(max(l0, lm), pt)

    c =
      cond do
        l == l0 and l == lm -> max(c0, cm) + 1
        l == l0 -> c0 + 1
        l == lm -> cm + 1
        true -> 0
      end

    check(l, c)
  end

  @doc "The order the paper defines: `l` first, then `c`."
  def before?({l1, c1}, {l2, c2}), do: l1 < l2 or (l1 == l2 and c1 < c2)

  defp check(l, c) when l > @l_max or c > @c_max, do: :error
  defp check(l, c), do: {:ok, {l, c}}
end

defmodule MixerBroadcaster.Clock do
  @moduledoc "The relay's own HLC: one per node. Every packet it forwards is stamped through `recv/3`."
  use Agent

  alias MixerBroadcaster.Hlc

  def start_link(_), do: Agent.start_link(fn -> {0, 0} end, name: __MODULE__)

  @doc "Stamp a packet that arrived with HLC word `word`; returns the word to forward, or `:error`."
  def stamp(word, pt_ms \\ System.os_time(:millisecond)) do
    Agent.get_and_update(__MODULE__, fn mine ->
      case Hlc.recv(mine, Hlc.unpack(word), pt_ms) do
        {:ok, next} -> {{:ok, Hlc.pack(next)}, next}
        :error -> {:error, mine}
      end
    end)
  end
end

defmodule MixerBroadcaster.Packet do
  @moduledoc """
  The 100-byte fabric entity packet, as far as the relay needs it. The layout is owned by
  contract-entity-packet (EntityPacket/Codec.lean); the relay reads only the clock and the reserved tail.
  The golden rows in test/fixtures are that repository's, so a drift in the layout fails here.
  """
  @size 100
  @off_hlc 40
  @off_reserved 98

  def size, do: @size

  @doc "A packet is exactly 100 bytes and its two reserved bytes are zero."
  def valid?(<<_::binary-size(@off_reserved), 0, 0>>), do: true
  def valid?(_), do: false

  def hlc(<<_::binary-size(@off_hlc), w::little-unsigned-64, _::binary>>), do: w

  def put_hlc(<<head::binary-size(@off_hlc), _::binary-size(8), rest::binary>>, w),
    do: <<head::binary, w::little-unsigned-64, rest::binary>>
end
