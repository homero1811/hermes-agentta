FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM node:22-bookworm-slim AS node_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache.
# tini reaps orphaned zombie processes (MCP stdio subprocesses, git, bun, etc.)
# that would otherwise accumulate when hermes runs as PID 1. See #15012.
# Playwright OS dependencies are installed here so the later browser install does
# not run a second apt-get during the npm layer.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential curl wget python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli tini \
    at-spi2-common fonts-freefont-ttf fonts-ipafont-gothic fonts-liberation fonts-noto-color-emoji fonts-tlwg-loma-otf fonts-unifont fonts-wqy-zenhei \
    libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libavahi-client3 libavahi-common-data libavahi-common3 libcups2t64 libfontenc1 \
    libice6 libnspr4 libnss3 libsm6 libunwind8 libxaw7 libxcomposite1 libxdamage1 libxfont2 libxkbfile1 libxmu6 libxpm4 libxt6t64 \
    x11-xkb-utils xfonts-encodings xfonts-scalable xfonts-utils xserver-common xvfb && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
COPY --from=node_source /usr/local/bin/node /usr/local/bin/
COPY --from=node_source /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    npm --version && \
    npx --version

WORKDIR /opt/hermes
RUN chown hermes:hermes /opt/hermes
USER hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
#
# ui-tui/packages/hermes-ink/ is copied IN FULL (not just its manifests)
# because it is referenced as a `file:` workspace dependency from
# ui-tui/package.json.  Copying the tree up front lets npm resolve the
# workspace to real content instead of stopping at a bare package.json.
COPY --chown=hermes:hermes package.json package-lock.json ./
COPY --chown=hermes:hermes web/package.json web/package-lock.json web/
COPY --chown=hermes:hermes ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY --chown=hermes:hermes ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

# `npm_config_install_links=false` forces npm to install `file:` deps as
# symlinks (the npm 10+ default).  Installing as copies produces a hidden
# node_modules/.package-lock.json that permanently disagrees with the root
# lock on the @hermes/ink entry. That disagreement trips the TUI launcher's
# `_tui_need_npm_install()` check on every startup and triggers a runtime
# `npm install` that then fails with EACCES (node_modules/ is root-owned from
# build time).
ENV npm_config_install_links=false
ENV npm_config_cache=/tmp/npm-cache

RUN npm install --prefer-offline --no-audit && \
    rm -rf /tmp/npm-cache
RUN npx playwright install chromium --only-shell && \
    rm -rf /tmp/npm-cache
RUN cd web && npm install --prefer-offline --no-audit && \
    rm -rf /tmp/npm-cache
RUN cd ui-tui && npm install --prefer-offline --no-audit && \
    npm cache clean --force && \
    rm -rf /tmp/npm-cache

# ---------- Layer-cached Python dependency install ----------
# Copy only pyproject.toml + uv.lock so the Python dep resolve + wheel
# download + native-extension compile layer is cached unless those inputs
# change.  Before this split the Python install sat after `COPY . .`, so
# every source-only commit re-did ~4-5 min of dep work on cold builds.
#
# README.md is referenced by pyproject.toml's `readme =` field, but it's
# excluded from the build context by .dockerignore's `*.md`.  uv's build
# frontend stats the readme path during dep resolution, so we `touch` an
# empty placeholder — the real README is restored by `COPY . .` below.
#
# `uv sync --frozen --no-install-project --extra all` installs only the
# deps reachable through the composite `[all]` extra (handpicked set
# intended for the production image).  We do NOT use `--all-extras`:
# that would pull in `[rl]` (atroposlib + tinker + torch + wandb from
# git), `[yc-bench]` (another git dep), and `[termux-all]` (Android
# redundancy), none of which belong in the published container.
#
# The editable link is created after the source copy below.
COPY --chown=hermes:hermes pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes . .

# Build browser dashboard and terminal UI assets.
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

# ---------- Runtime ownership ----------
# Dependency installs and build outputs are created as hermes, avoiding a cold
# build recursive chmod/chown over node_modules that can stall Coolify workers.
# Start as root so the entrypoint can usermod/groupmod + gosu.
# If HERMES_UID is unset, the entrypoint drops to the default hermes user (10000).

# ---------- Link hermes-agent itself (editable) ----------
# Deps are already installed in the cached layer above; `--no-deps` makes
# this a fast (~1s) egg-link creation with no resolution or downloads.
RUN uv pip install --no-cache-dir --no-deps -e "."

USER root

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"
VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]