# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

defmodule MixerBroadcaster.AsyncApiTest do
  @moduledoc """
  The AsyncAPI document in `spec/asyncapi.yaml` and the real relay agree, in both directions.
  GOLDEN: every message the room hub can send (challenge, ready, snapshot, ok, mesh grant, every error), every answer of
  the demo's HTTP routes, the echo handler, and every command a client may send and the relay may answer, validate
  against their schemas. The commands are encoded and decoded from the document's `x-wire` alone, and one session of
  three clients drives the real command rules through all of them.
  INVARIANT: every example validates; any chart patch is echoed in a message that fits; any 100 bytes sent to a command
  session are taken or answered with an error that fits; every command type the code knows is in the document; every
  environment variable the code reads is in the document and the other way round.
  CONTROL: planted wrong values fail their schemas; a spec with a message left out of the session would fail the
  coverage check; the blob store is a Mox mock, so the mesh grant is checked without S3.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox
  import Plug.Test

  alias MixerBroadcaster.{Auth, Command, Handler, Hub, Mesh, Rooms, Token, Web}
  alias MixerBroadcaster.Mixer.{Caibx, Core, Session, Store, Wire}

  setup :verify_on_exit!

  @spec_path Path.join([__DIR__, "..", "spec", "asyncapi.yaml"])
  @cube File.read!(Path.join(__DIR__, "fixtures/cube.caibx"))
  @cube_digest :crypto.hash(:sha256, @cube)
  @hex_digest Base.encode16(@cube_digest, case: :lower)

  setup do
    root = :crypto.strong_rand_bytes(32)
    tp = :crypto.strong_rand_bytes(32)
    Application.put_env(:mixer_broadcaster, :auth, %{root_key: root})
    Application.put_env(:mixer_broadcaster, :blob_access, MixerBroadcaster.BlobMock)

    on_exit(fn ->
      Application.delete_env(:mixer_broadcaster, :auth)
      Application.delete_env(:mixer_broadcaster, :blob_access)
      Application.delete_env(:mixer_broadcaster, :demo)
    end)

    {:ok, doc} = YamlElixir.read_from_file(@spec_path)
    %{root: root, tp: tp, doc: doc, room: "spec-#{System.unique_integer([:positive])}"}
  end

  # ---- the document ----

  defp resolve(doc, pointer),
    do: ExJsonSchema.Schema.resolve(%{"$ref" => pointer, "components" => doc["components"]})

  defp valid?(doc, schema, value),
    do: ExJsonSchema.Validator.valid?(resolve(doc, "#/components/schemas/#{schema}"), value)

  defp message(doc, name), do: doc["components"]["messages"][name]

  defp valid_payload?(doc, name, value),
    do:
      ExJsonSchema.Validator.valid?(resolve(doc, "#/components/messages/#{name}/payload"), value)

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp wire_messages(doc, from),
    do:
      for({n, m} <- doc["components"]["messages"], w = m["x-wire"], w["from"] == from, do: {n, w})

  # ---- commands, from x-wire alone ----

  defp encode(doc, name, payload) do
    w = message(doc, name)["x-wire"]
    data = for [f, kind] <- w["fields"], into: <<>>, do: enc(kind, payload[f])
    %{type: w["type"] || payload["type"], id: 0, data: data}
  end

  defp enc("string", v), do: Wire.string(v)
  defp enc("bool", v), do: Wire.bool(v)
  defp enc("json", v), do: Wire.json(v)
  defp enc("raw", v), do: v
  defp enc("bytes", v), do: Base.decode16!(v, case: :lower)

  defp dec("string", bin), do: with({:ok, s, r} <- Wire.read_string(bin), do: {s, r})
  defp dec("bool", bin), do: with({:ok, b, r} <- Wire.read_bool(bin), do: {b, r})
  defp dec("json", bin), do: with({:ok, t, r} <- Wire.read_json(bin), do: {t, r})
  defp dec("raw", bin), do: {bin, <<>>}
  defp dec("bytes", bin), do: {Base.encode16(bin, case: :lower), <<>>}

  # the message a server-to-client command of this type is, and its fields
  defp decode(doc, {type, data}) do
    all = wire_messages(doc, "server")

    {name, w} =
      Enum.find(all, fn {_, w} -> w["type"] == type end) ||
        (type > 100 && Enum.find(all, fn {_, w} -> w["typeFrom"] end)) ||
        flunk("no server message of type #{type} in the document")

    {payload, rest} =
      Enum.reduce(w["fields"], {%{}, data}, fn [f, kind], {acc, bin} ->
        {v, bin} = dec(kind, bin)
        {Map.put(acc, f, v), bin}
      end)

    assert rest == <<>>, "#{name}: bytes left over"
    {name, if(w["typeFrom"], do: Map.put(payload, "type", type), else: payload)}
  end

  # every command the relay sends must be one the document names, with data that fits
  defp check_outs(doc, outs) do
    for {cid, enc} <- outs do
      {name, payload} = decode(doc, enc)

      assert valid_payload?(doc, name, payload),
             "#{name} #{inspect(payload)} does not fit its schema"

      {cid, name, payload}
    end
  end

  # ---- a player, as the relay sees one ----

  defp reply(state, msg) do
    {:ok, st, [{:send, _, body, :fin} | _]} =
      Hub.handle_stream(0, :bidi, JSON.encode!(msg), state)

    {st, JSON.decode!(body)}
  end

  defp admitted(c, room, ops) do
    {pub, priv} = Auth.generate_key()
    t = Token.issue(c.root, room, "minter", c.tp, ops)
    {:ok, full} = Token.discharge(t, c.tp, Auth.thumbprint(pub), 3600, System.os_time(:second))

    state = elem(Hub.init(nil, %{path: "/room/#{room}"}, []), 1)
    {state, challenge} = reply(state, %{t: "hello"})
    nonce = Base.url_decode64!(challenge["nonce"], padding: false)

    {state, ready} =
      reply(state, %{
        t: "auth",
        token: b64(full),
        key: b64(pub),
        sig: b64(Auth.sign(priv, room, nonce))
      })

    {state, challenge, ready}
  end

  defp pose(room, digest) do
    Rooms.put_entity(
      room,
      <<1::little-32, 0::unit(8)-size(44), 0::little-24, 4, 0::unit(8)-size(10), digest::binary,
        0::48>>
    )
  end

  # ================= the document itself =================

  test "golden: it is a 3.1 document, every example fits its headers and payload, every message is on a channel",
       %{doc: doc} do
    assert doc["asyncapi"] == "3.1.0"
    assert doc["servers"]["relay"]["protocol"] == "webtransport"

    for {name, msg} <- doc["components"]["messages"], ex <- msg["examples"] || [] do
      assert valid_payload?(doc, name, ex["payload"]),
             "example of #{name} does not fit its payload"

      if msg["headers"] do
        assert resolve_headers_ok?(doc, name, ex["headers"]),
               "example of #{name} does not fit its headers"
      end
    end

    on_channels =
      for {_, ch} <- Map.merge(doc["channels"], doc["components"]["channels"] || %{}),
          {_, %{"$ref" => ref}} <- ch["messages"],
          into: MapSet.new(),
          do: ref |> String.split("/") |> List.last()

    assert Map.keys(doc["components"]["messages"]) -- MapSet.to_list(on_channels) == []
  end

  defp resolve_headers_ok?(doc, name, value),
    do:
      ExJsonSchema.Validator.valid?(resolve(doc, "#/components/messages/#{name}/headers"), value)

  # ---- what the AsyncAPI 3.1.0 specification itself requires of a document

  defp pointer(doc, "#/" <> path), do: get_in(doc, String.split(path, "/"))

  defp refs(%{"$ref" => ref}), do: [ref]
  defp refs(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&refs/1)
  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_), do: []

  defp all_operations(doc),
    do: Map.merge(doc["operations"], doc["components"]["operations"] || %{})

  test "conformance: every $ref resolves, and component keys are in the form the specification allows",
       %{doc: doc} do
    for ref <- refs(doc), do: assert(pointer(doc, ref) != nil, "#{ref} does not resolve")

    for {_, section} <- doc["components"], is_map(section), key <- Map.keys(section) do
      assert key =~ ~r/^[a-zA-Z0-9\.\-_]+$/, "component key #{key}"
    end

    for key <- Map.keys(doc["servers"]), do: assert(key =~ ~r/^[A-Za-z0-9_\-]+$/)
  end

  # the fixed fields of each object of the AsyncAPI 3.1.0 text; anything else must be an `x-` extension
  @fields %{
    root: ~w(asyncapi id info servers defaultContentType channels operations components),
    info: ~w(title version description termsOfService contact license tags externalDocs),
    license: ~w(name url),
    server:
      ~w(host protocol protocolVersion pathname description title summary variables security tags externalDocs bindings),
    channel:
      ~w(address messages title summary description servers parameters tags externalDocs bindings),
    parameter: ~w(enum default description examples location),
    operation:
      ~w(action channel title summary description security tags externalDocs bindings traits messages reply),
    reply: ~w(address channel messages),
    message:
      ~w(headers payload correlationId contentType name title summary description tags externalDocs bindings examples traits),
    example: ~w(headers payload name summary),
    components:
      ~w(schemas servers channels operations messages securitySchemes serverVariables parameters correlationIds replies replyAddresses externalDocs tags operationTraits messageTraits serverBindings channelBindings operationBindings messageBindings),
    bindings:
      ~w(http ws kafka anypointmq amqp amqp1 mqtt mqtt5 nats jms sns solace sqs stomp redis mercure ibmmq googlepubsub pulsar ros2),
    http_operation: ~w(method query bindingVersion),
    http_message: ~w(headers statusCode bindingVersion)
  }

  defp only_defined(where, map, kind) do
    extra =
      for k <- Map.keys(map),
          k not in @fields[kind],
          not Regex.match?(~r/^x-[\w\d\.\x2d_]+$/, k),
          do: k

    assert extra == [], "#{where}: fields the specification does not define: #{inspect(extra)}"
  end

  test "conformance: every object has only the fields the specification defines (or x- extensions), and its required ones",
       %{doc: doc} do
    only_defined("root", doc, :root)
    for k <- ~w(asyncapi info), do: assert(Map.has_key?(doc, k))
    only_defined("info", doc["info"], :info)
    for k <- ~w(title version), do: assert(is_binary(doc["info"][k]), "info.#{k}")
    only_defined("license", doc["info"]["license"], :license)
    assert is_binary(doc["info"]["license"]["name"])
    only_defined("components", doc["components"], :components)
    assert doc["defaultContentType"] =~ ~r{^[\w.+-]+/[\w.+-]+$}

    for {id, s} <- Map.merge(doc["servers"], doc["components"]["servers"] || %{}) do
      only_defined("server #{id}", s, :server)
      assert is_binary(s["host"]) and is_binary(s["protocol"]), "server #{id} host and protocol"
      refute s["host"] =~ "://", "server #{id}: host is a host name, not a URL"
      only_defined("server #{id} bindings", s["bindings"] || %{}, :bindings)
      # the HTTP server binding is reserved and holds nothing
      assert (s["bindings"] || %{})["http"] in [nil, %{}]
    end

    for {id, ch} <- Map.merge(doc["channels"], doc["components"]["channels"] || %{}) do
      only_defined("channel #{id}", ch, :channel)
      only_defined("channel #{id} bindings", ch["bindings"] || %{}, :bindings)

      for {pid, param} <- ch["parameters"] || %{},
          do: only_defined("parameter #{id}.#{pid}", param, :parameter)

      refute (ch["address"] || "") =~ ~r/[?#]/,
             "channel #{id}: no query or fragment in an address"

      assert (ch["bindings"] || %{})["http"] in [nil, %{}]
    end

    for {id, op} <- all_operations(doc) do
      only_defined("operation #{id}", op, :operation)
      assert op["action"] in ["send", "receive"], "operation #{id} action"

      assert is_map(op["channel"]) and Map.keys(op["channel"]) == ["$ref"],
             "operation #{id} channel is a reference"

      only_defined("operation #{id} bindings", op["bindings"] || %{}, :bindings)

      if http = (op["bindings"] || %{})["http"],
        do: only_defined("operation #{id} http", http, :http_operation)

      if reply = op["reply"], do: only_defined("operation #{id} reply", reply, :reply)
    end

    for {id, m} <- doc["components"]["messages"] do
      only_defined("message #{id}", m, :message)
      only_defined("message #{id} bindings", m["bindings"] || %{}, :bindings)

      if http = (m["bindings"] || %{})["http"],
        do: only_defined("message #{id} http", http, :http_message)

      if ct = m["contentType"],
        do:
          assert(
            ct =~ ~r{^[\w.+-]+/[\w.+-]+$},
            "message #{id}: contentType is a specific media type"
          )

      for ex <- m["examples"] || [] do
        only_defined("message #{id} example", ex, :example)
        assert Map.has_key?(ex, "headers") or Map.has_key?(ex, "payload")
      end
    end
  end

  test "conformance: a reference object holds only its $ref; roots point at roots", %{doc: doc} do
    walk = fn walk, node ->
      case node do
        %{"$ref" => _} = m ->
          assert Map.keys(m) == ["$ref"], "a reference with extra fields: #{inspect(m)}"

        m when is_map(m) ->
          Enum.each(Map.values(m), &walk.(walk, &1))

        l when is_list(l) ->
          Enum.each(l, &walk.(walk, &1))

        _ ->
          :ok
      end
    end

    walk.(walk, doc)

    for {id, op} <- doc["operations"] do
      assert String.starts_with?(op["channel"]["$ref"], "#/channels/"),
             "root operation #{id} points outside the root channels"

      if reply = op["reply"],
        do:
          assert(
            String.starts_with?(reply["channel"]["$ref"], "#/channels/"),
            "root operation #{id} reply"
          )
    end

    for {id, ch} <- doc["channels"],
        %{"$ref" => ref} <- ch["servers"] || [],
        do:
          assert(
            String.starts_with?(ref, "#/servers/"),
            "root channel #{id} points outside the root servers"
          )
  end

  test "conformance: an operation's messages are among its channel's, and so are its reply's", %{
    doc: doc
  } do
    for {id, op} <- all_operations(doc) do
      channel = op["channel"]["$ref"]

      for %{"$ref" => ref} <- op["messages"] || [],
          do:
            assert(
              String.starts_with?(ref, channel <> "/messages/"),
              "#{id}: #{ref} is not on #{channel}"
            )

      if reply = op["reply"] do
        for %{"$ref" => ref} <- reply["messages"] || [],
            do:
              assert(
                String.starts_with?(ref, reply["channel"]["$ref"] <> "/messages/"),
                "#{id}: reply #{ref} is not on its channel"
              )
      end
    end
  end

  test "conformance: everything outside components is used, and a channel address names exactly its parameters",
       %{doc: doc} do
    used_servers =
      for {_, ch} <- doc["channels"],
          %{"$ref" => r} <- ch["servers"] || [],
          into: MapSet.new(),
          do: r

    for key <- Map.keys(doc["servers"]),
        do: assert("#/servers/#{key}" in used_servers, "server #{key} is not used")

    used_channels =
      for {_, op} <- doc["operations"], into: MapSet.new(), do: op["channel"]["$ref"]

    for key <- Map.keys(doc["channels"]),
        do: assert("#/channels/#{key}" in used_channels, "channel #{key} has no operation")

    for {key, ch} <- Map.merge(doc["channels"], doc["components"]["channels"] || %{}) do
      in_address =
        ~r/\{(\w+)\}/
        |> Regex.scan(ch["address"] || "", capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert in_address == (ch["parameters"] || %{}) |> Map.keys() |> Enum.sort(),
             "channel #{key} parameters"
    end
  end

  test "conformance: an HTTP reply carries its status code, and a request that has no body lists no message",
       %{doc: doc} do
    for {id, op} <- all_operations(doc), op["bindings"]["http"] do
      assert op["messages"] == [], "#{id}: a GET has no message"

      assert op["bindings"]["http"]["method"] in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE)

      for %{"$ref" => ref} <- op["reply"]["messages"] do
        code =
          pointer(doc, ref)["$ref"]
          |> then(&pointer(doc, &1))
          |> get_in(["bindings", "http", "statusCode"])

        assert is_integer(code) and code in 100..599, "#{id}: #{ref} has no status code"
      end
    end
  end

  test "conformance: every message sent to a channel is valid against one and only one message of it",
       %{doc: doc} do
    for {channel, ch} <- doc["channels"] do
      names =
        for {_, %{"$ref" => ref}} <- ch["messages"], do: ref |> String.split("/") |> List.last()

      for name <- names, ex <- message(doc, name)["examples"] || [] do
        hits =
          for other <- names,
              valid_payload?(doc, other, ex["payload"]),
              is_nil(message(doc, other)["headers"]) or
                resolve_headers_ok?(doc, other, ex["headers"]),
              do: other

        assert hits == [name], "#{channel}: an example of #{name} fits #{inspect(hits)}"
      end
    end
  end

  test "invariant: every command type the code knows is in the document, and every listed type is the code's",
       %{doc: doc} do
    listed =
      for {_, m} <- doc["components"]["messages"],
          w = m["x-wire"],
          t = w["type"],
          uniq: true,
          do: t

    assert Enum.all?(listed, &(Wire.type_name(&1) != nil))

    known = for n <- 1..1000, Wire.type_name(n), n < 100, do: n
    assert known -- listed == []

    assert Enum.any?(doc["components"]["messages"], fn {_, m} ->
             m["x-wire"]["typeFrom"] && m["x-wire"]["from"] == "client"
           end)
  end

  test "invariant: a command is told apart by its type in its headers, exactly one message per channel and number",
       %{doc: doc} do
    for {channel, from} <- [{"commandsIn", "client"}, {"commandsOut", "server"}] do
      names =
        for {_, %{"$ref" => ref}} <- doc["channels"][channel]["messages"],
            name = ref |> String.split("/") |> List.last(),
            message(doc, name)["headers"],
            do: name

      # each header schema is resolved once; resolving it per number is what made this test slow
      schemas = Map.new(names, &{&1, resolve(doc, "#/components/messages/#{&1}/headers")})
      fits? = fn name, ty -> ExJsonSchema.Validator.valid?(schemas[name], %{"type" => ty}) end

      # the channel holds only the messages of its direction, and each one's header agrees with its x-wire
      for name <- names do
        w = message(doc, name)["x-wire"]
        assert w["from"] == from, "#{name} is on #{channel} but is sent by the #{w["from"]}"

        if w["type"] do
          assert fits?.(name, w["type"])
          refute fits?.(name, w["type"] + 1)
        end
      end

      listed = for {_, w} <- wire_messages(doc, from), ty = w["type"], do: ty

      for n <- 1..1200 do
        hits = for m <- names, fits?.(m, n), do: m
        expected = if from == "client" or n in listed or n > 100, do: 1, else: 0
        assert length(hits) == expected, "#{channel}: type #{n} fits #{inspect(hits)}"
      end
    end
  end

  test "invariant: every environment variable lib/ reads is in the document and the other way round",
       %{doc: doc} do
    listed = doc["servers"]["relay"]["x-environment"] |> Map.keys() |> Enum.sort()

    used =
      Path.wildcard(Path.join([__DIR__, "..", "lib", "**", "*.ex"]))
      |> Enum.flat_map(
        &(~r/\b(?:MB|AWS)_[A-Z0-9_]+/
          |> Regex.scan(File.read!(&1))
          |> List.flatten())
      )
      |> Enum.uniq()
      |> Enum.sort()

    assert used == listed
  end

  # ================= the room hub =================

  test "golden: the door and the room's replies fit the document", c do
    {state, challenge, ready} = admitted(c, c.room, [])
    assert valid?(c.doc, "challenge", challenge)
    assert valid?(c.doc, "ready", ready)

    {state, snap} = reply(state, %{t: "hello"})
    assert valid?(c.doc, "snapshot", snap)

    {state, ok} = reply(state, %{t: "set", id: 3, rgb: [1, 2, 3]})
    assert valid?(c.doc, "ok", ok)
    assert valid?(c.doc, "set", %{"t" => "set", "id" => 3, "rgb" => [1, 2, 3]})

    {state, bad_patch} = reply(state, %{t: "set", id: 99, rgb: [1, 2, 3]})
    assert bad_patch["reason"] == "bad_patch" and valid?(c.doc, "error", bad_patch)

    {_state, bad_message} = reply(state, %{t: "nonsense"})
    assert bad_message["reason"] == "bad_message" and valid?(c.doc, "error", bad_message)
  end

  test "golden: a hello on a stream is answered on the stream and as a datagram; as a datagram only as a datagram",
       c do
    {state, _, _} = admitted(c, c.room, [])
    hello = JSON.encode!(%{t: "hello"})

    {:ok, state, [{:send, 0, body, :fin}, {:send_datagram, dg}]} =
      Hub.handle_stream(0, :bidi, hello, state)

    assert body == dg and valid?(c.doc, "snapshot", JSON.decode!(body))

    {:ok, state, [{:send_datagram, dg2}]} = Hub.handle_datagram(hello, state)
    assert valid?(c.doc, "snapshot", JSON.decode!(dg2))

    set = JSON.encode!(%{t: "set", id: 1, rgb: [9, 9, 9]})
    assert {:ok, ^state, []} = Hub.handle_datagram(set, state)
  end

  test "golden: a pose on a stream is answered ok, a bad one bad_packet, and on a datagram not at all",
       c do
    {state, _, _} = admitted(c, c.room, [])
    good = <<0::unit(8)-size(100)>>
    bad = <<0::unit(8)-size(98), 1, 1>>

    {:ok, _, [{:send, 0, ok, :fin}]} = Hub.handle_stream(0, :bidi, good, state)
    assert valid?(c.doc, "ok", JSON.decode!(ok))

    {:ok, _, [{:send, 0, err, :fin}]} = Hub.handle_stream(0, :bidi, bad, state)

    assert JSON.decode!(err)["reason"] == "bad_packet" and
             valid?(c.doc, "error", JSON.decode!(err))

    assert {:ok, ^state, []} = Hub.handle_datagram(good, state)
  end

  test "golden: a mesh grant from a mocked store fits the document", c do
    pose(c.room, @cube_digest)
    {state, _, _} = admitted(c, c.room, ["read"])
    index_key = Caibx.index_key(@cube_digest)

    expect(MixerBroadcaster.BlobMock, :object, fn ^index_key -> {:ok, @cube} end)

    expect(MixerBroadcaster.BlobMock, :presign_get, 2, fn key, ttl ->
      {:ok, "https://s3.test/#{key}?ttl=#{ttl}"}
    end)

    {_state, grant} = reply(state, %{t: "mesh", digest: @hex_digest})
    assert valid?(c.doc, "meshGrant", grant)
    assert grant["digest"] == @hex_digest
    assert length(grant["chunks"]) == 1
  end

  test "golden: a reply too big for one datagram is cut into pieces that fit the document", c do
    urls =
      for i <- 1..60,
          do:
            "https://s3.test/chunks/#{String.pad_leading("#{i}", 4, "0")}/#{String.duplicate("ab", 32)}.cacnk?ttl=300"

    whole =
      JSON.encode!(%{
        t: "mesh",
        digest: @hex_digest,
        expires: 300,
        index: "https://s3.test/i.caibx?ttl=300",
        chunks: urls
      })

    [first | rest] = Mesh.split(whole)
    assert rest != []

    head = JSON.decode!(first)
    assert valid?(c.doc, "meshGrant", head) and head["n"] == 60

    pieces = Enum.map(rest, &JSON.decode!/1)
    for p <- pieces, do: assert(valid?(c.doc, "meshMore", p))

    assert head["chunks"] ++ Enum.flat_map(pieces, & &1["chunks"]) == urls
    assert Enum.map(pieces, & &1["from"]) |> hd() == length(head["chunks"])

    # a reply that fits goes whole, with no `n`
    assert [one] =
             Mesh.split(
               JSON.encode!(%{
                 t: "mesh",
                 digest: @hex_digest,
                 expires: 300,
                 index: "https://s3.test/i",
                 chunks: []
               })
             )

    refute Map.has_key?(JSON.decode!(one), "n")
  end

  test "golden: a request that came as a datagram is refused as a datagram", c do
    {state, _, _} = admitted(c, c.room, [])

    assert {:ok, _, [{:send_datagram, dg}]} =
             Hub.handle_datagram(JSON.encode!(%{t: "nonsense"}), state)

    err = JSON.decode!(dg)
    assert err["reason"] == "bad_message" and valid?(c.doc, "error", err)
  end

  test "control: a store that is down is `unavailable`; refusals read the same and fit the error schema",
       c do
    pose(c.room, @cube_digest)
    {state, _, _} = admitted(c, c.room, ["read"])
    expect(MixerBroadcaster.BlobMock, :object, fn _ -> {:error, :down} end)
    {_state, down} = reply(state, %{t: "mesh", digest: @hex_digest})
    assert down == %{"t" => "error", "reason" => "unavailable"} and valid?(c.doc, "error", down)

    open = elem(Hub.init(nil, %{path: "/room/#{c.room}"}, []), 1)
    {_, err} = reply(open, %{t: "set", id: 0, rgb: [0, 0, 0]})
    assert err["reason"] == "unauthenticated" and valid?(c.doc, "error", err)

    {state, _, _} = admitted(c, c.room, [])
    {_state, denied} = reply(state, %{t: "mesh", digest: @hex_digest})
    assert denied == %{"t" => "error", "reason" => "denied"} and valid?(c.doc, "error", denied)
  end

  test "control: three failed proofs lock the session", c do
    state = elem(Hub.init(nil, %{path: "/room/#{c.room}"}, []), 1)

    state =
      Enum.reduce(1..3, state, fn _, st ->
        {st, %{"nonce" => _}} = reply(st, %{t: "hello"})
        {st, denied} = reply(st, %{t: "auth", token: "AA", key: "AA", sig: "AA"})
        assert denied["reason"] == "denied" and valid?(c.doc, "error", denied)
        st
      end)

    {_, locked} = reply(state, %{t: "hello"})
    assert locked["reason"] == "locked" and valid?(c.doc, "error", locked)
  end

  test "golden: the origin check is the document's", %{doc: doc} do
    # the document lists the defaults; `MB_ORIGINS` (put_origins) replaces them, so start from none set
    Application.delete_env(:mixer_broadcaster, :allowed_origins)
    b = doc["servers"]["relay"]["bindings"]["x-webtransport"]

    for o <- b["allowedOrigins"], do: assert(Hub.origin_check([{"origin", o}], []) == :accept)
    assert Hub.origin_check([], []) == :accept

    assert Hub.origin_check([{"origin", "https://evil.example"}], []) ==
             {:reject, b["rejectStatus"], "origin not allowed"}
  end

  # ================= the command session =================

  test "golden: one session of three clients goes through every command in the document", %{
    doc: doc
  } do
    core =
      Core.new()
      |> Core.connect("a", "10.0.0.1", 1111)
      |> Core.connect("b", "10.0.0.2", 2222)
      |> Core.connect("c", "10.0.0.3", 3333, &(&1 != "demo"))

    Process.put(:t, %{core: core, used: MapSet.new(), seen: MapSet.new()})

    run = fn id, cmd, name ->
      %{core: core, used: used, seen: seen} = Process.get(:t)
      {core, outs} = Core.handle(core, id, cmd)
      outs = check_outs(doc, outs)

      Process.put(:t, %{
        core: core,
        used: MapSet.put(used, name),
        seen: Enum.reduce(outs, seen, fn {_, n, _}, s -> MapSet.put(s, n) end)
      })

      outs
    end

    ask = fn id, name, over ->
      ex = hd(message(doc, name)["examples"])["payload"] |> Map.merge(over)
      run.(id, encode(doc, name, ex), name)
    end

    errors = fn outs -> for {_, "sendErrorOut", %{"message" => m}} <- outs, do: m end

    entity = fn gid, rest ->
      Base.encode16(<<gid::little-32>> <> :binary.copy(<<0>>, 96 - rest), case: :lower)
    end

    # a creates the room; the content is offered to the creator, and nobody else is told yet
    outs = ask.("a", "joinRoom", %{})
    assert Enum.any?(outs, &match?({"a", "contentOffer", _}, &1))

    assert [%{"demo" => %{"joinable" => false}}] =
             for({"b", "roomList", %{"rooms" => r}} <- ask.("b", "listRooms", %{}), do: r)

    assert errors.(ask.("b", "joinRoom", %{})) == ["Room demo is not joinable yet."]

    assert Enum.any?(
             ask.("a", "content", %{}),
             &match?({_, "roomUpdate", %{"update" => %{"demo" => %{"joinable" => true}}}}, &1)
           )

    assert errors.(ask.("a", "content", %{})) == [
             "Room demo is already joinable."
           ]

    assert errors.(ask.("b", "content", %{})) == ["You must join a room before you can make it joinable."]

    assert [m] = errors.(ask.("b", "joinRoom", %{"mixer_version" => "9"}))
    assert m =~ "The Mixer version does not match"
    assert [m] = errors.(ask.("b", "joinRoom", %{"engine_version" => "4.0"}))
    assert m =~ "The engine version does not match"

    # a late joiner gets the stored commands, in order, between clear_content and join_room
    ask.("a", "roomCommand", %{"type" => 150, "data" => "0a0b"})
    outs = ask.("b", "joinRoom", %{})
    names = for {"b", n, _} <- outs, do: n
    assert Enum.take(names, 1) == ["clearContent"] and "joinRoomOk" in names

    assert Enum.any?(
             outs,
             &match?({"b", "roomCommandOut", %{"type" => 150, "data" => "0a0b"}}, &1)
           )

    assert errors.(ask.("b", "joinRoom", %{})) |> hd() =~ "You are already in room"
    assert errors.(ask.("c", "joinRoom", %{})) == ["You are not allowed in room demo."]

    assert errors.(run.("c", %{type: 1, id: 0, data: <<1>>}, "joinRoom")) == [
             "The JOIN_ROOM command is malformed."
           ]

    # an entity is kept once; a removal drops it; a malformed one is refused
    ent = entity.(7, 0) |> binary_part(0, 8)
    full = ent <> String.duplicate("00", 96)

    assert Enum.any?(
             ask.("a", "roomCommand", %{"type" => 210, "data" => full}),
             &match?({"b", "roomCommandOut", %{"type" => 210}}, &1)
           )

    ask.("a", "roomCommand", %{"type" => 210, "data" => full})

    assert Enum.any?(
             ask.("a", "roomCommand", %{"type" => 211, "data" => "07000000"}),
             &match?({"b", "roomCommandOut", %{"type" => 211}}, &1)
           )

    assert errors.(ask.("a", "roomCommand", %{"type" => 210, "data" => "0102"})) == [
             "The entity_state command is malformed."
           ]

    assert errors.(ask.("a", "unknownCommand", %{})) == [
             "The server has no handler for command 2."
           ]

    # attributes, names, keep-open, the lists, the id
    ask.("a", "setClientName", %{})

    assert Enum.any?(
             ask.("a", "setClientCustomAttributes", %{}),
             &match?({"b", "clientUpdate", _}, &1)
           )

    assert Enum.any?(
             ask.("a", "setRoomCustomAttributes", %{}),
             &match?({_, "roomUpdate", %{"update" => %{"demo" => %{"scene" => "cube"}}}}, &1)
           )

    ask.("a", "setRoomKeepOpen", %{})

    assert errors.(run.("a", %{type: 17, id: 0, data: <<1>>}, "setRoomKeepOpen")) == [
             "The SET_ROOM_KEEP_OPEN command is malformed."
           ]

    assert errors.(
             run.("a", %{type: 15, id: 0, data: Wire.string("[1]")}, "setClientCustomAttributes")
           ) == ["The SET_CLIENT_CUSTOM_ATTRIBUTES command is malformed."]

    assert errors.(run.("a", %{type: 16, id: 0, data: <<>>}, "setRoomCustomAttributes")) == [
             "The SET_ROOM_CUSTOM_ATTRIBUTES command is malformed."
           ]

    assert [%{"id" => "a"}] =
             for({"a", "clientIdReply", p} <- ask.("a", "clientIdRequest", %{}), do: p)

    assert [clients] =
             for({"a", "clientList", %{"clients" => cl}} <- ask.("a", "listClients", %{}), do: cl)

    assert Map.keys(clients) |> Enum.sort() == ["a", "b"]

    assert Enum.any?(
             ask.("a", "sendError", %{}),
             &match?({"b", "sendErrorOut", %{"message" => "something broke"}}, &1)
           )

    # leaving, an error for a client with no room, disconnecting, deleting
    assert errors.(ask.("c", "leaveRoom", %{})) == ["You cannot leave a room. You are not in a room."]
    assert Enum.any?(ask.("b", "leaveRoom", %{}), &match?({"b", "leaveRoomOk", _}, &1))
    ask.("b", "joinRoom", %{})
    %{core: core} = Process.get(:t)
    {core, outs} = Core.disconnect(core, "b")

    assert Enum.any?(
             check_outs(doc, outs),
             &match?({"a", "clientDisconnected", %{"id" => "b"}}, &1)
           )

    t = Process.get(:t)
    Process.put(:t, %{t | core: core, seen: MapSet.put(t.seen, "clientDisconnected")})

    ask.("a", "leaveRoom", %{})

    assert Enum.any?(
             ask.("a", "deleteRoom", %{}),
             &match?({"a", "roomDeleted", %{"room" => "demo"}}, &1)
           )

    # coverage: every client command and every relay command in the document was exercised
    %{used: used, seen: seen} = Process.get(:t)
    assert MapSet.new(for {n, _} <- wire_messages(doc, "client"), do: n) == used
    assert MapSet.new(for {n, _} <- wire_messages(doc, "server"), do: n) == seen
  end

  test "golden: the examples of the client commands encode to what the relay's own wire reads back",
       %{doc: doc} do
    {:ok, "demo", r} =
      Wire.read_string(
        encode(doc, "joinRoom", hd(message(doc, "joinRoom")["examples"])["payload"]).data
      )

    assert {:ok, "godot", r} = Wire.read_string(r)
    assert {:ok, "4.8", r} = Wire.read_string(r)
    assert {:ok, "1.0", r} = Wire.read_string(r)
    assert {:ok, false, <<>>} = Wire.read_bool(r)
  end

  test "golden: any 100 bytes sent to a command session are taken or answered with an error that fits",
       %{doc: doc} do
    Application.put_env(:mixer_broadcaster, :auth, :off)
    {:ok, st} = Session.init(nil, %{path: "/mixer"}, [])

    {:ok, st, [{:send, 0, pkt}]} = Session.handle_stream(0, :bidi, :binary.copy(<<0>>, 100), st)
    {:ok, %{type: 12, data: data}} = Command.unpack(pkt, &Store.get/1)
    {name, payload} = decode(doc, {12, data})
    assert name == "sendErrorOut" and valid_payload?(doc, name, payload)
    assert payload["message"] =~ "bad command packet"

    # a torn packet waits for its rest
    {:ok, st, []} = Session.handle_stream(0, :bidi, :binary.copy(<<0>>, 99), st)
    {:ok, _st, [{:send, 0, pkt2}]} = Session.handle_stream(0, :bidi, <<0>>, st)
    assert {:ok, %{type: 12}} = Command.unpack(pkt2, &Store.get/1)

    check all(bytes <- binary(length: 100), max_runs: 200) do
      case Session.handle_stream(0, :bidi, bytes, st) do
        {:ok, _, []} ->
          :ok

        {:ok, _, [{:send, 0, p}]} ->
          {:ok, %{type: 12, data: d}} = Command.unpack(p, &Store.get/1)
          {n, pl} = decode(doc, {12, d})
          assert valid_payload?(doc, n, pl)
      end
    end
  end

  test "golden: the command door has the room door's replies", c do
    state = elem(Session.init(nil, %{path: "/mixer"}, []), 1)

    send_json = fn st, msg ->
      {:ok, st, [{:send, 0, body, :fin}]} = Session.handle_stream(0, :bidi, JSON.encode!(msg), st)
      {st, JSON.decode!(body)}
    end

    {state, challenge} = send_json.(state, %{t: "hello"})
    assert valid?(c.doc, "challenge", challenge)

    {pub, priv} = Auth.generate_key()
    t = Token.issue(c.root, c.room, "minter", c.tp, ["read"])
    {:ok, full} = Token.discharge(t, c.tp, Auth.thumbprint(pub), 3600, System.os_time(:second))
    nonce = Base.url_decode64!(challenge["nonce"], padding: false)

    {state, ready} =
      send_json.(state, %{
        t: "auth",
        token: b64(full),
        key: b64(pub),
        sig: b64(Auth.sign_session(priv, nonce))
      })

    assert ready == %{"t" => "ready"} and valid?(c.doc, "ready", ready)
    assert state.admitted

    # three failed proofs, then locked
    fresh = elem(Session.init(nil, %{path: "/mixer"}, []), 1)

    fresh =
      Enum.reduce(1..3, fresh, fn _, st ->
        {st, _} = send_json.(st, %{t: "hello"})
        {st, denied} = send_json.(st, %{t: "auth", token: "AA", key: "AA", sig: "AA"})
        assert denied["reason"] == "denied" and valid?(c.doc, "error", denied)
        st
      end)

    {_, locked} = send_json.(fresh, %{t: "hello"})
    assert locked["reason"] == "locked" and valid?(c.doc, "error", locked)
  end

  # ================= the demo's HTTP routes and the echo handler =================

  defp get(path), do: Web.call(conn(:get, path), Web.init([]))

  test "golden: the demo routes answer as the document says", c do
    rooms = get("/rooms")
    assert rooms.status == 200
    assert valid?(c.doc, "roomList", JSON.decode!(rooms.resp_body))

    Application.put_env(:mixer_broadcaster, :demo, %{"wt_port" => 4433})
    info = get("/connection")
    assert info.status == 200 and JSON.decode!(info.resp_body) == %{"wt_port" => 4433}
    Application.delete_env(:mixer_broadcaster, :demo)
    assert get("/connection").resp_body == "{}"

    for page <- ["/", "/geo"] do
      r = get(page)
      assert r.status == 200 and hd(Plug.Conn.get_resp_header(r, "content-type")) =~ "text/html"
    end

    dir = Path.join(System.tmp_dir!(), "mixer_geo_usd")
    File.mkdir_p!(dir)
    file = "#{String.duplicate("ab", 32)}.usda"
    File.write!(Path.join(dir, file), "#usda 1.0")
    on_exit(fn -> File.rm(Path.join(dir, file)) end)

    r = get("/usd/#{file}")
    assert r.status == 200 and hd(Plug.Conn.get_resp_header(r, "content-type")) =~ "text/plain"

    for path <- [
          "/usd/#{String.duplicate("cd", 32)}.usda",
          "/usd/..%2Fsecret",
          "/usd/a.usda",
          "/nothing"
        ] do
      r = get(path)
      assert r.status == 404 and r.resp_body == "not found", path
    end

    assert message(c.doc, "notFound")["payload"]["const"] == "not found"
  end

  test "golden: the echo handler returns streams as streams and datagrams as datagrams" do
    {:ok, st} = Handler.init(nil, %{}, [])
    assert {:ok, ^st, [{:send, 4, "abc"}]} = Handler.handle_stream(4, :bidi, "abc", st)
    assert {:ok, ^st} = Handler.handle_stream(6, :uni, "abc", st)
    assert {:ok, ^st, [{:send_datagram, "xyz"}]} = Handler.handle_datagram("xyz", st)
  end

  # ================= controls and properties =================

  test "control: planted wrong values fail their schemas, so the checks above can fail", c do
    refute valid?(c.doc, "ok", %{"t" => "ok", "extra" => 1})
    refute valid?(c.doc, "set", %{"t" => "set", "id" => 24, "rgb" => [0, 0, 0]})
    refute valid?(c.doc, "set", %{"t" => "set", "id" => 0, "rgb" => [0, 0, 256]})
    refute valid?(c.doc, "error", %{"t" => "error", "reason" => "made_up"})
    refute valid?(c.doc, "challenge", %{"t" => "challenge", "nonce" => "short"})

    refute valid_payload?(c.doc, "sendErrorOut", %{"message" => "gibberish"})
    refute valid_payload?(c.doc, "roomCommandOut", %{"type" => 5, "data" => ""})

    refute valid?(c.doc, "meshMore", %{
             "t" => "mesh_more",
             "digest" => @hex_digest,
             "from" => 0,
             "chunks" => []
           })

    refute valid?(c.doc, "meshGrant", %{
             "t" => "mesh",
             "expires" => 300,
             "index" => "https://x",
             "chunks" => []
           })

    refute valid_payload?(c.doc, "joinRoomOk", %{"room" => "demo", "extra" => 1})
    refute valid_payload?(c.doc, "clientUpdate", %{"update" => %{}})
    refute valid_payload?(c.doc, "roomList", %{"rooms" => %{"x" => %{"joinable" => "yes"}}})
  end

  test "control: a command type the document does not list is refused by the decoder", %{doc: doc} do
    assert_raise ExUnit.AssertionError, fn -> decode(doc, {2, <<>>}) end
  end

  property "invariant: any chart patch the hub accepts echoes a message that fits the schemas",
           c do
    {state, _, _} = admitted(c, c.room, [])

    check all(id <- integer(0..23), rgb <- list_of(integer(0..255), length: 3)) do
      {_state, ok} = reply(state, %{t: "set", id: id, rgb: rgb})
      assert valid?(c.doc, "ok", ok)
      assert valid?(c.doc, "set", %{"t" => "set", "id" => id, "rgb" => rgb})
    end
  end
end
