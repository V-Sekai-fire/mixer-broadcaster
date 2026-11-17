# SPDX-FileCopyrightText: 2026-present K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

"""On Windows the Mitsuba 3 wheel makes the interpreter exit with status 1 once it is imported, even when every test
passed (`python -c "import mitsuba"` does the same). Pytest knows the real result, so after it has reported, leave with
that status instead of letting the library's teardown overwrite it."""

import os
import sys


def pytest_unconfigure(config):
    if sys.platform == "win32" and "mitsuba" in sys.modules:
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(int(getattr(config, "_mixer_exitstatus", 0)))


def pytest_sessionfinish(session, exitstatus):
    session.config._mixer_exitstatus = int(exitstatus)
