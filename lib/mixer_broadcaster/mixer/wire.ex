# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.Mixer.Wire do
  @moduledoc """
  The relay's command wire format, as `spec/asyncapi.yaml` describes it (`x-wire` on each message).

    * A command is a type and its data. It rides in one 100-byte packet (`MixerBroadcaster.Command`), bulk data by digest.
    * A string is `length u32 | utf-8 bytes`; a JSON value is a string; a bool is a u32 that is 1 or 0.

  Nothing here raises: a malformed input is `:error` or `{:error, reason}`.
  """

  @types %{
    join_room: 1,
    leave_room: 3,
    list_rooms: 4,
    content: 5,
    clear_content: 6,
    delete_room: 7,
    set_client_name: 11,
    send_error: 12,
    list_clients: 14,
    set_client_custom_attributes: 15,
    set_room_custom_attributes: 16,
    set_room_keep_open: 17,
    client_id: 18,
    client_update: 19,
    room_update: 20,
    room_deleted: 21,
    client_disconnected: 22,
    command: 100,
    query_animation_data: 139,
    optimized_commands: 200,
    frame: 205,
    entity_state: 210,
    entity_remove: 211,
    end_optimized_commands: 999,
    client_id_wrapper: 1000
  }

  @spec type(atom()) :: non_neg_integer()
  def type(name) when is_atom(name), do: Map.fetch!(@types, name)
  @spec type_name(non_neg_integer()) :: atom() | nil
  def type_name(number), do: Enum.find_value(@types, fn {k, v} -> if v == number, do: k end)

  @type command :: %{type: non_neg_integer(), id: non_neg_integer(), data: binary()}
  @typedoc "A command to send: `{type, data}`."
  @type encoded :: {non_neg_integer(), binary()}

  @doc "A command to send: its type and data. It travels as one packet (`MixerBroadcaster.Command`), so there is no framing."
  @spec encode(non_neg_integer() | atom(), binary(), non_neg_integer()) ::
          {non_neg_integer(), binary()}
  def encode(type, data \\ <<>>, _id \\ 0)
  def encode(type, data, _id) when is_atom(type), do: {type(type), data}
  def encode(type, data, _id) when is_integer(type) and is_binary(data), do: {type, data}

  # ---- fields ----

  @spec string(binary()) :: binary()
  def string(s) when is_binary(s), do: <<byte_size(s)::little-32, s::binary>>

  @spec read_string(binary()) :: {:ok, binary(), binary()} | :error
  def read_string(<<n::little-32, s::binary-size(n), rest::binary>>), do: {:ok, s, rest}
  def read_string(_), do: :error

  @spec bool(boolean()) :: <<_::32>>
  def bool(true), do: <<1::little-32>>
  def bool(false), do: <<0::little-32>>

  @spec read_bool(binary()) :: {:ok, boolean(), binary()} | :error
  def read_bool(<<v::little-32, rest::binary>>), do: {:ok, v == 1, rest}
  def read_bool(_), do: :error

  @spec json(term()) :: binary()
  def json(term), do: string(IO.iodata_to_binary(JSON.encode_to_iodata!(term)))

  @spec read_json(binary()) :: {:ok, term(), binary()} | :error
  def read_json(bin) do
    with {:ok, s, rest} <- read_string(bin),
         {:ok, term} <- JSON.decode(s) do
      {:ok, term, rest}
    else
      _ -> :error
    end
  end
end
