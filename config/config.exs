# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

import Config

# Pythonx takes ONE uv configuration per app, so every Python script run under it shares this environment.
# Add a dependency here, never a second uv_init.
if config_env() == :test do
  config :pythonx, :uv_init,
    pyproject_toml: """
    [project]
    name = "mixer-broadcaster-pythonx"
    version = "0.0.0"
    requires-python = "==3.12.*"
    dependencies = []
    """
end
