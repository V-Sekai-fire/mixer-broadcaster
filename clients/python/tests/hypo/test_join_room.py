# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT
"""
Hypothesis tests of the handshake the client sends (Client.join_room in mixer/broadcaster/client.py). No network.
GOLDEN: the room, the engine, the engine's version and the protocol version are length-prefixed UTF-8 strings, then the
  ignore flag is a 32-bit bool, in that order, which is the layout spec/asyncapi.yaml gives joinRoom.
INVARIANT: for any room, engine, versions and flag, reading the sent data back in that order returns them, with no byte
  left over; an engine of any name is a join like any other.
CONTROL: a client that swaps the engine and its version, or still sends the earlier relay's second flag, is told apart.
"""

from hypothesis import given, strategies as st

from mixer.broadcaster import common
from mixer.broadcaster.client import Client

text = st.text(max_size=24)


class Sent(Client):
    """A client with no socket: it keeps what it would have sent."""

    def __init__(self):
        self.socket = None
        self.sent = []

    def send_command(self, command):
        self.sent.append(command)
        return True


def join_data(*args):
    c = Sent()
    c.join_room(*args)
    (command,) = c.sent
    assert command.type == common.MessageType.JOIN_ROOM
    return command.data


def read_back(data):
    room, i = common.decode_string(data, 0)
    engine, i = common.decode_string(data, i)
    version, i = common.decode_string(data, i)
    protocol, i = common.decode_string(data, i)
    ignore, i = common.decode_bool(data, i)
    return (room, engine, version, protocol, ignore), len(data) - i


def test_golden_the_layout_the_document_gives():
    fields = ("demo", "godot", "4.8", "1.0")
    strings = b"".join(len(s).to_bytes(4, "little") + s.encode() for s in fields)
    assert join_data(*fields, False) == strings + (0).to_bytes(4, "little")


@given(text, text, text, text, st.booleans())
def test_invariant_what_is_sent_reads_back_in_order(room, engine, version, protocol, ignore):
    sent = (room, engine, version, protocol, ignore)
    assert read_back(join_data(*sent)) == (sent, 0)


@given(text, text.filter(bool), text.filter(bool), text, st.booleans())
def test_control_swapped_fields_do_not_read_back(room, engine, version, protocol, ignore):
    if engine == version:
        return  # the same text in both places is no swap
    swapped = join_data(room, version, engine, protocol, ignore)
    assert read_back(swapped)[0] != (room, engine, version, protocol, ignore)


@given(text, text, text, text, st.booleans())
def test_control_a_second_flag_is_left_over(room, engine, version, protocol, ignore):
    earlier = join_data(room, engine, version, protocol, ignore) + common.encode_bool(False)
    assert read_back(earlier)[1] == 4, "the earlier relay's fifth field is four bytes with no place here"
