# SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
#
# SPDX-License-Identifier: MIT

# The relay: HTTP/3 WebTransport (QUIC, UDP) and nothing else. Closed by construction: it refuses to boot
# without MB_ROOT_KEY, set with `fly secrets set` and never baked into the image.
FROM elixir:1.20.5-otp-28-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates git build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod

COPY lib lib
COPY priv priv
RUN mix deps.compile && mix compile

ENV MB_SERVE=1 MB_WT_PORT=4433
CMD ["mix", "run", "--no-halt"]
