<!--
SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee

SPDX-License-Identifier: MIT
-->

# Changelog

The record of the frontier-learning iterations over the relay's interface. `mix frontier` (no arguments) runs every
level against the real closed relay over WebTransport and prints passes over problems per level; `FRONTIER_N` sets the
problems per level (default 8). 1.000 covers only the problems written so far.

## Frontier iteration 1: the document against the code

Levels, low to high: 1 room door, 2 refusals, 3 chart, 4 poses, 5 meshes, 6 commands, 7 demo HTTP, 8 configuration,
9 late joiners, removal and bulk data, 10 departures and the command door, 11 the client library. Every client is
admitted with a minted token and a signed nonce; the control level plants a wrong reply and must fail the checker.

Baseline: levels 1 to 10 passed n/n on the first run; level 11 (the client library) was 0/4.

Level 11, kept: `Client.recv_reliable/4` waited only for `stream` events, but a reply the relay sends with FIN arrives
as a `stream_fin` event, so every JSON reply timed out with 0 bytes. It now reads `stream_fin` too. Level 11 is 4/4 and
no lower level dropped.

Not measured: a level with no problems is unmeasured, for example the closed relay under datagram loss (`MB_LOSS`),
a browser origin that `MB_ORIGINS` allows, and meshes larger than one datagram over a real connection.

## Frontier iteration 2: the document against the AsyncAPI 3.1.0 specification

Read the specification itself (Channel Object: every message sent to a channel must be valid against one and only one
of its messages; Message Object: `headers` define application headers; Data Type Formats: `binary` is a `format`).

Kept: the command path was one channel whose empty-payload commands (`leaveRoom`, `listRooms`, `content` and the relay's
`leaveRoomOk`, `contentOffer`, `clearContent`) were all the same schema, so a packet fit several messages. The path is
now two channels, `commandsIn` and `commandsOut`, and each command message carries its type number in `headers`, so a
packet fits exactly one. A test checks every type number from 1 to 1200 on both channels. The packet schema now says
`format: binary` instead of `contentEncoding: binary`. All frontier levels stay n/n and the AsyncAPI CLI validates.
