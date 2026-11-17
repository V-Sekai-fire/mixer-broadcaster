defmodule MixerBroadcaster.Mixer.CoreTest do
  @moduledoc """
  GOLDEN: a creator, a late joiner and a client outside the room go through a Mixer session the way the Python server
  runs it: create, content, join with replay, forward, leave, delete.
  INVARIANT: for any run of commands, the late joiner receives exactly the room's stored commands in order; an entity's
  newest pose replaces its older ones and a remove drops it; nothing is ever sent to a client that is not connected; a
  client never hears about a room its token does not cover.
  CONTROL: a second join, a join to an unfinished room, a version mismatch, a command from a client in no room, and an
  unknown client are refused or ignored.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MixerBroadcaster.Mixer.{Core, Wire}

  @join_room Wire.type(:join_room)
  @leave_room Wire.type(:leave_room)
  @list_rooms Wire.type(:list_rooms)
  @content Wire.type(:content)
  @clear_content Wire.type(:clear_content)
  @delete_room Wire.type(:delete_room)
  @list_clients Wire.type(:list_clients)
  @entity_state Wire.type(:entity_state)
  @entity_remove Wire.type(:entity_remove)
  @client_update Wire.type(:client_update)
  @room_update Wire.type(:room_update)
  @room_deleted Wire.type(:room_deleted)
  @send_error Wire.type(:send_error)
  @client_disconnected Wire.type(:client_disconnected)

  defp cmd(type, data \\ <<>>), do: %{type: Wire.type(type), id: 0, data: data}

  defp join(name, bv \\ "5.3", mv \\ "1.0"),
    do:
      cmd(
        :join_room,
        Wire.string(name) <>
          Wire.string(bv) <> Wire.string(mv) <> Wire.bool(false) <> Wire.bool(false)
      )

  defp pose(gid, x),
    do:
      cmd(
        :entity_state,
        <<gid::little-32, x::little-size(768)>>
        |> binary_part(0, 4)
        |> Kernel.<>(:binary.copy(<<x>>, 96))
      )

  defp world(clients, allow \\ fn _ -> true end),
    do: Enum.reduce(clients, Core.new(), &Core.connect(&2, &1, "127.0.0.1", 1, allow))

  defp send_as(s, id, c), do: Core.handle(s, id, c)
  defp to(outs, id), do: for({^id, {t, d}} <- outs, do: {t, d})
  defp types(outs, id), do: outs |> to(id) |> Enum.map(&elem(&1, 0))

  defp create(s, id, room) do
    {s, _} = send_as(s, id, join(room))
    {s, outs} = send_as(s, id, cmd(:content))
    {s, outs}
  end

  test "golden: create, join with replay, forward, leave and delete" do
    s = world(~w(a b c))
    {s, outs} = send_as(s, "a", join("room"))

    assert Enum.take(types(outs, "a"), 2) == [@join_room, @content],
           "the creator is told to send the content"

    {s, _} = send_as(s, "a", cmd(:content))
    {s, _} = send_as(s, "a", pose(7, 1))
    {s, _} = send_as(s, "a", pose(8, 2))

    {s, outs} = send_as(s, "b", join("room"))
    got = types(outs, "b")

    assert [@clear_content, @entity_state, @entity_state, @join_room] = Enum.take(got, 4),
           "replay, then the join"

    assert to(outs, "c") |> Enum.all?(fn {t, _} -> t in [@client_update, @room_update] end)

    {s, outs} = send_as(s, "b", pose(7, 3))
    assert [{@entity_state, d}] = Enum.filter(to(outs, "a"), &(elem(&1, 0) == @entity_state))
    assert binary_part(d, 0, 4) == <<7::little-32>>

    assert Enum.filter(to(outs, "b"), &(elem(&1, 0) == @entity_state)) == [],
           "not echoed to the sender"

    assert Enum.filter(to(outs, "c"), &(elem(&1, 0) == @entity_state)) == [],
           "not sent outside the room"

    {s, _} = send_as(s, "a", cmd(:leave_room))
    {s, outs} = send_as(s, "b", cmd(:leave_room))
    assert @room_deleted in types(outs, "c"), "the last one out deletes the room"
    assert s.rooms == %{}
  end

  test "golden: a pose replaces the older pose of its entity and a remove drops it, so a late joiner sees one each" do
    s = world(~w(a b))
    {s, _} = create(s, "a", "r")
    {s, _} = send_as(s, "a", pose(1, 1))
    {s, _} = send_as(s, "a", pose(1, 2))
    {s, _} = send_as(s, "a", pose(2, 3))
    {s, _} = send_as(s, "a", cmd(:entity_remove, <<2::little-32>>))
    {_, outs} = send_as(s, "b", join("r"))
    poses = for {@entity_state, d} <- to(outs, "b"), do: d
    assert [<<1::little-32, rest::binary>>] = poses
    assert rest == :binary.copy(<<2>>, 96), "the newest pose of entity 1"
  end

  test "control: refusals and ignored commands" do
    s = world(~w(a b))
    {s1, outs} = send_as(s, "a", join("r"))
    {_, outs2} = send_as(s1, "b", join("r"))
    assert @send_error in types(outs2, "b"), "joining a room that is not joinable yet"
    assert outs != []

    {s2, _} = create(s, "a", "r")
    {_, outs} = send_as(s2, "a", join("other"))
    assert @send_error in types(outs, "a"), "a second join"
    {_, outs} = send_as(s2, "b", join("r", "9.9"))
    assert @send_error in types(outs, "b"), "a Blender version mismatch"
    {_, outs} = send_as(s2, "b", join("r", "5.3", "9.9"))
    assert @send_error in types(outs, "b"), "a Mixer version mismatch"
    {_, outs} = send_as(s2, "b", pose(1, 1))
    assert outs == [], "a command from a client in no room goes nowhere"
    {s3, outs} = send_as(s2, "ghost", join("r"))
    assert {s3, outs} == {s2, []}, "an unknown client"
    {_, outs} = send_as(s2, "b", cmd(:leave_room))
    assert @send_error in types(outs, "b"), "leaving with no room"
    {_, outs} = send_as(s2, "a", %{type: 50, id: 0, data: <<>>})
    assert @send_error in types(outs, "a"), "a server command with no handler"
    {_, outs} = send_as(s2, "a", cmd(:entity_state, <<1, 2, 3>>))
    assert @send_error in types(outs, "a"), "a malformed pose"
  end

  test "control: a client whose token does not cover a room never hears about it" do
    allow = fn room -> room == "open" end
    s = world(~w(a b))
    s = put_in(s.clients["b"].allow, allow)
    {s, outs} = send_as(s, "a", join("secret"))
    assert to(outs, "b") == []
    {s, outs} = send_as(s, "a", cmd(:content))
    assert to(outs, "b") == []
    {s, outs} = send_as(s, "b", cmd(:list_rooms))
    assert [{_, json}] = to(outs, "b")
    assert {:ok, rooms, _} = Wire.read_json(json)
    assert rooms == %{}, "its list leaves the secret room out"
    {s, outs} = send_as(s, "b", cmd(:list_clients))
    assert [{_, json}] = to(outs, "b")
    assert {:ok, clients, _} = Wire.read_json(json)
    assert Map.keys(clients) == ["b"], "and the player in it"
    {_, outs} = send_as(s, "a", cmd(:leave_room))
    assert to(outs, "b") == [], "and its deletion"
  end

  property "invariant: other commands are replayed to a late joiner in the order they were sent" do
    check all(
            types <-
              StreamData.uniq_list_of(
                StreamData.filter(StreamData.integer(101..199), &(&1 != 139)),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 60
          ) do
      s = world(~w(a b))
      {s, _} = create(s, "a", "r")

      s =
        Enum.reduce(types, s, fn t, s ->
          {s, _} = send_as(s, "a", %{type: t, id: 0, data: <<t::little-32>>})
          s
        end)

      {_, outs} = send_as(s, "b", join("r"))
      replayed = for {t, <<_::little-32>>} <- to(outs, "b"), t in 101..199, do: t
      assert replayed == types
    end
  end

  property "invariant: a late joiner gets the room's stored commands in order and nobody unknown is addressed" do
    entity = StreamData.integer(1..4)

    op =
      StreamData.one_of([
        StreamData.map(StreamData.tuple({entity, StreamData.integer(0..255)}), fn {g, x} ->
          {:pose, g, x}
        end),
        StreamData.map(entity, &{:remove, &1}),
        StreamData.constant(:content_cmd)
      ])

    check all(ops <- StreamData.list_of(op, max_length: 40), max_runs: 80) do
      s = world(~w(a b))
      {s, _} = create(s, "a", "r")

      {s, model, addressed} =
        Enum.reduce(ops, {s, %{}, []}, fn
          {:pose, g, x}, {s, m, ad} ->
            {s, outs} = send_as(s, "a", pose(g, x))
            {s, Map.put(m, g, x), outs ++ ad}

          {:remove, g}, {s, m, ad} ->
            {s, outs} = send_as(s, "a", cmd(:entity_remove, <<g::little-32>>))
            {s, Map.delete(m, g), outs ++ ad}

          :content_cmd, {s, m, ad} ->
            {s, outs} = send_as(s, "a", cmd(:content))
            {s, m, outs ++ ad}
        end)

      {_, outs} = send_as(s, "b", join("r"))

      got =
        for {@entity_state, <<g::little-32, rest::binary>>} <- to(outs, "b"),
            into: %{},
            do: {g, :binary.first(rest)}

      assert got == model, "late joiner sees the newest pose of every entity still there"

      assert length(for {@entity_state, _} <- to(outs, "b"), do: 1) == map_size(model),
             "one command each"

      assert Enum.all?(addressed ++ outs, fn {id, _} -> id in ["a", "b"] end)
    end
  end
end
