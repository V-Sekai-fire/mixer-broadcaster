defmodule MixerBroadcaster.Mixer.Core do
  @moduledoc """
  The Mixer server's rules, as a pure state machine: `handle(state, client_id, command)` returns the new state and the
  commands to send, as `{client_id, command_bytes}`. No process, no socket, no clock. It follows
  `mixer/broadcaster/apps/server.py` (the Python server this relay replaces):

    * a client creates a room by joining a name nobody has; the creator sends the room's content, then `CONTENT`
      makes the room joinable
    * a client that joins gets `CLEAR_CONTENT`, every stored command in order, then `JOIN_ROOM`
    * every other command (type above `COMMAND`) is stored for late joiners and forwarded to the room's other members
    * client and room changes are announced to every client (`CLIENT_UPDATE`, `ROOM_UPDATE`, `ROOM_DELETED`)

  What differs: `ENTITY_STATE` is stored by entity (the newest per id replaces the older) and `ENTITY_REMOVE` drops
  it, so a room's content stays one pose per entity however long it runs.
  """
  alias MixerBroadcaster.Mixer.Wire

  defstruct rooms: %{}, clients: %{}

  @no_store [:client_id_wrapper, :frame, :query_animation_data]

  @type t :: %__MODULE__{rooms: map(), clients: map()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Register a client. Nothing is announced; the client asks for the lists itself. `allow` says which rooms the client
  may see (`fn room -> boolean end`): a closed relay passes the check its token admits, so a client hears about a
  room, and about who is in it, only if its token covers that room.
  """
  @spec connect(t(), String.t(), String.t(), non_neg_integer(), (String.t() -> boolean())) :: t()
  def connect(%__MODULE__{} = s, id, ip, port, allow \\ fn _ -> true end)
      when is_binary(id) and is_binary(ip) and is_integer(port) and is_function(allow, 1) do
    %{
      s
      | clients:
          Map.put(s.clients, id, %{room: nil, attrs: %{}, ip: ip, port: port, allow: allow})
    }
  end

  @doc "A client is gone: it leaves its room, and everyone else is told."
  @spec disconnect(t(), String.t()) :: {t(), [{String.t(), Wire.encoded()}]}
  def disconnect(%__MODULE__{} = s, id) do
    case Map.fetch(s.clients, id) do
      :error ->
        {s, []}

      {:ok, %{room: room}} ->
        {s, outs} = if room, do: leave(s, id), else: {s, []}
        s = %{s | clients: Map.delete(s.clients, id)}
        {s, outs ++ broadcast(s, Wire.encode(:client_disconnected, Wire.string(id)), room)}
    end
  end

  @spec handle(t(), String.t(), Wire.command()) :: {t(), [{String.t(), Wire.encoded()}]}
  def handle(%__MODULE__{} = s, id, %{type: type, data: data} = cmd) do
    if Map.has_key?(s.clients, id),
      do: dispatch(s, id, Wire.type_name(type), type, data, cmd),
      else: {s, []}
  end

  # ---- the server's own commands ----

  defp dispatch(s, id, :join_room, _t, data, _cmd) do
    with {:ok, name, r} <- Wire.read_string(data),
         {:ok, bv, r} <- Wire.read_string(r),
         {:ok, mv, r} <- Wire.read_string(r),
         {:ok, ignore, r} <- Wire.read_bool(r),
         {:ok, generic, _} <- Wire.read_bool(r) do
      cond do
        s.clients[id].room ->
          error(s, id, "Received join_room but room #{s.clients[id].room} is already joined")

        not s.clients[id].allow.(name) ->
          error(s, id, "Not allowed in room #{name}")

        true ->
          join(s, id, name, bv, mv, ignore, generic)
      end
    else
      _ -> error(s, id, "malformed JOIN_ROOM")
    end
  end

  defp dispatch(s, id, :leave_room, _t, _data, _cmd) do
    if s.clients[id].room do
      {s, outs} = leave(s, id)
      {s, outs ++ [{id, Wire.encode(:leave_room)}]}
    else
      error(s, id, "Received leave_room but no room is joined")
    end
  end

  defp dispatch(s, id, :list_rooms, _t, _d, _c) do
    rooms =
      for {name, room} <- s.rooms,
          s.clients[id].allow.(name),
          into: %{},
          do: {name, attributes(room)}

    {s, [{id, Wire.encode(:list_rooms, Wire.json(rooms))}]}
  end

  defp dispatch(s, id, :list_clients, _t, _d, _c) do
    clients =
      for {cid, c} <- s.clients,
          cid == id or (c.room && s.clients[id].allow.(c.room)),
          into: %{} do
        {cid, client_attributes(cid, c)}
      end

    {s, [{id, Wire.encode(:list_clients, Wire.json(clients))}]}
  end

  defp dispatch(s, _id, :delete_room, _t, data, _c) do
    case s.rooms do
      %{^data => %{members: []}} -> delete_room(s, data)
      _ -> {s, []}
    end
  end

  defp dispatch(s, id, :send_error, _t, _d, cmd),
    do: {s, broadcast(s, Wire.encode(cmd.type, cmd.data, cmd.id), s.clients[id].room, id)}

  defp dispatch(s, id, :set_client_name, _t, data, _c),
    do: set_client_attrs(s, id, %{"user_name" => data})

  defp dispatch(s, id, :set_client_custom_attributes, _t, data, _c) do
    case Wire.read_json(data) do
      {:ok, %{} = attrs, _} -> set_client_attrs(s, id, attrs)
      _ -> error(s, id, "malformed SET_CLIENT_CUSTOM_ATTRIBUTES")
    end
  end

  defp dispatch(s, id, :set_room_custom_attributes, _t, data, _c) do
    with {:ok, name, r} <- Wire.read_string(data),
         {:ok, %{} = attrs, _} <- Wire.read_json(r) do
      case s.rooms do
        %{^name => room} ->
          {merged, diff} = merge(room.attrs, attrs)
          s = put_room(s, %{room | attrs: merged})
          {s, room_update(s, name, diff)}

        _ ->
          {s, []}
      end
    else
      _ -> error(s, id, "malformed SET_ROOM_CUSTOM_ATTRIBUTES")
    end
  end

  defp dispatch(s, id, :set_room_keep_open, _t, data, _c) do
    with {:ok, name, r} <- Wire.read_string(data),
         {:ok, value, _} <- Wire.read_bool(r) do
      case s.rooms do
        %{^name => %{keep_open: ^value}} ->
          {s, []}

        %{^name => room} ->
          s = put_room(s, %{room | keep_open: value})
          {s, room_update(s, name, %{"keep_open" => value})}

        _ ->
          {s, []}
      end
    else
      _ -> error(s, id, "malformed SET_ROOM_KEEP_OPEN")
    end
  end

  defp dispatch(s, id, :client_id, _t, _d, _c), do: {s, [{id, Wire.encode(:client_id, id)}]}

  defp dispatch(s, id, :content, _t, _d, _c) do
    case s.clients[id].room && s.rooms[s.clients[id].room] do
      nil ->
        error(s, id, "Unjoined client trying to set room joinable")

      %{joinable: true, name: name} ->
        error(s, id, "Trying to set joinable room #{name} which is already joinable")

      room ->
        s = put_room(s, %{room | joinable: true})
        {s, room_update(s, room.name, %{"joinable" => true})}
    end
  end

  # ---- every other command: a room command ----

  defp dispatch(s, id, name, type, _data, cmd) do
    cond do
      type <= Wire.type(:command) ->
        error(s, id, "Command #{type} received but no handler for it on server")

      is_nil(s.clients[id].room) ->
        {s, []}

      true ->
        room = s.rooms[s.clients[id].room]
        store(s, id, room, name, cmd)
    end
  end

  # ---- rooms ----

  defp join(s, id, name, bv, mv, ignore, generic) do
    case s.rooms do
      %{^name => room} ->
        cond do
          not room.joinable ->
            error(s, id, "Room #{name} not joinable yet.")

          not room.ignore_version_check and room.blender_version != bv ->
            error(
              s,
              id,
              "Blender version mismatch with room #{name}: client version is #{bv}, room version is #{room.blender_version}"
            )

          not room.ignore_version_check and room.mixer_version != mv ->
            error(
              s,
              id,
              "Mixer version mismatch with room #{name}: client version is #{mv}, room version is #{room.mixer_version}"
            )

          true ->
            stored =
              for c <- Enum.reverse(room.commands), do: {id, Wire.encode(c.type, c.data, c.id)}

            s = put_room(s, %{room | members: room.members ++ [id]})
            s = put_in(s.clients[id].room, name)

            outs =
              [{id, Wire.encode(:clear_content)}] ++
                stored ++ [{id, Wire.encode(:join_room, Wire.string(name))}]

            {s, outs ++ client_update(s, id, %{"room" => name})}
        end

      _ ->
        room = %{
          name: name,
          blender_version: bv,
          mixer_version: mv,
          ignore_version_check: ignore,
          generic_protocol: generic,
          keep_open: false,
          byte_size: 0,
          joinable: false,
          attrs: %{},
          commands: [],
          members: [id]
        }

        s = put_room(s, room)
        s = put_in(s.clients[id].room, name)

        outs =
          [{id, Wire.encode(:join_room, Wire.string(name))}, {id, Wire.encode(:content)}] ++
            broadcast(
              s,
              Wire.encode(:room_update, Wire.json(%{name => attributes(room)})),
              name,
              id
            ) ++
            client_update(s, id, %{"room" => name})

        {s, outs}
    end
  end

  defp leave(s, id) do
    name = s.clients[id].room
    room = s.rooms[name]
    s = put_room(s, %{room | members: List.delete(room.members, id)})
    s = put_in(s.clients[id].room, nil)
    outs = client_update(s, id, %{"room" => nil})

    if s.rooms[name].members == [] and not s.rooms[name].keep_open do
      {s, more} = delete_room(s, name)
      {s, outs ++ more}
    else
      {s, outs}
    end
  end

  defp delete_room(s, name) do
    {%{s | rooms: Map.delete(s.rooms, name)},
     broadcast(s, Wire.encode(:room_deleted, Wire.string(name)), name)}
  end

  # An entity is stored once, by its id: the newest ENTITY_STATE replaces the older one, ENTITY_REMOVE drops it.
  defp store(s, id, room, kind, cmd) when kind in [:entity_state, :entity_remove] do
    gid = binary_part(cmd.data, 0, min(4, byte_size(cmd.data)))

    valid =
      (kind == :entity_state and byte_size(cmd.data) == 100) or
        (kind == :entity_remove and byte_size(cmd.data) == 4)

    if valid do
      kept =
        Enum.reject(
          room.commands,
          &(&1.type == Wire.type(:entity_state) and binary_part(&1.data, 0, 4) == gid)
        )

      commands = if kind == :entity_state, do: [cmd | kept], else: kept
      forward(s, id, room, commands, cmd)
    else
      error(s, id, "malformed #{kind}")
    end
  end

  defp store(s, id, room, kind, cmd) do
    commands = if kind in @no_store, do: room.commands, else: merged(room.commands, cmd)
    forward(s, id, room, commands, cmd)
  end

  # consecutive optimised commands for the same path replace each other
  defp merged([%{type: t} = last | rest] = commands, %{type: t} = cmd) when t > 200 and t < 999 do
    if same_path?(last.data, cmd.data), do: [cmd | rest], else: [cmd | commands]
  end

  defp merged(commands, cmd), do: [cmd | commands]

  defp same_path?(a, b) do
    match?({:ok, p, _} when is_binary(p), Wire.read_string(a)) and
      Wire.read_string(a) |> elem(1) == Wire.read_string(b) |> elem(1)
  end

  defp forward(s, id, room, commands, cmd) do
    bytes = fn cs -> cs |> Enum.map(&(14 + byte_size(&1.data))) |> Enum.sum() end
    updated = %{room | commands: commands, byte_size: bytes.(commands)}
    s = put_room(s, updated)

    diff =
      %{}
      |> then(
        &if updated.byte_size != room.byte_size,
          do: Map.put(&1, "byte_size", updated.byte_size),
          else: &1
      )
      |> then(
        &if length(commands) != length(room.commands),
          do: Map.put(&1, "command_count", length(commands)),
          else: &1
      )

    to_members = for m <- room.members, m != id, do: {m, Wire.encode(cmd.type, cmd.data, cmd.id)}
    {s, room_update(s, room.name, diff) ++ to_members}
  end

  # ---- attributes and announcements ----

  defp set_client_attrs(s, id, attrs) do
    {merged, diff} = merge(s.clients[id].attrs, attrs)
    s = put_in(s.clients[id].attrs, merged)
    {s, client_update(s, id, diff)}
  end

  defp merge(current, updates) do
    Enum.reduce(updates, {current, %{}}, fn {k, v}, {cur, diff} ->
      if Map.get(cur, k, :missing) == v,
        do: {cur, diff},
        else: {Map.put(cur, k, v), Map.put(diff, k, v)}
    end)
  end

  defp client_attributes(id, c),
    do: Map.merge(c.attrs, %{"id" => id, "ip" => c.ip, "port" => c.port, "room" => c.room})

  defp attributes(room) do
    Map.merge(room.attrs, %{
      "keep_open" => room.keep_open,
      "blender_version" => room.blender_version,
      "mixer_version" => room.mixer_version,
      "ignore_version_check" => room.ignore_version_check,
      "generic_protocol" => room.generic_protocol,
      "command_count" => length(room.commands),
      "byte_size" => room.byte_size,
      "joinable" => room.joinable
    })
  end

  # a client's change goes to the clients that may see its room, and to the client itself
  defp client_update(s, id, diff, room \\ nil)
  defp client_update(_s, _id, diff, _room) when diff == %{}, do: []

  defp client_update(s, id, diff, room),
    do:
      broadcast(
        s,
        Wire.encode(:client_update, Wire.json(%{id => diff})),
        room || s.clients[id].room,
        id
      )

  defp room_update(_s, _name, diff) when diff == %{}, do: []

  defp room_update(s, name, diff),
    do: broadcast(s, Wire.encode(:room_update, Wire.json(%{name => diff})), name)

  # to every client whose token covers `room`, and to `also`
  defp broadcast(s, command, room, also \\ nil) do
    for {cid, c} <- s.clients, cid == also or (room != nil and c.allow.(room)), do: {cid, command}
  end

  defp put_room(s, room), do: %{s | rooms: Map.put(s.rooms, room.name, room)}

  defp error(s, id, message), do: {s, [{id, Wire.encode(:send_error, Wire.string(message))}]}
end
