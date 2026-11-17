# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

ExUnit.start()

Mox.defmock(MixerBroadcaster.BlobMock, for: MixerBroadcaster.Mixer.Store.BlobAccess)
