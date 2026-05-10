# Coolify Deployment (Dashboard UI)

This deploys Hermes web UI on Coolify and serves it at:

- `https://hs.tsunamiautomation.com`

## 1. Prerequisites

- DNS `A` record for `hs.tsunamiautomation.com` points to your Coolify server IP.
- Git repo connected in Coolify (this fork/repo).

## 2. Create the Coolify resource

- Type: `Docker Compose`
- Compose file: `docker-compose.coolify.yml`
- Service to expose: `hermes-dashboard`
- Internal port: `9119`
- Domain: `hs.tsunamiautomation.com`
- Enable HTTPS/Let's Encrypt in Coolify.

## 3. Required environment variables in Coolify

Set these in the resource:

- `OPENAI_API_KEY` (or your preferred provider key such as `ANTHROPIC_API_KEY`)

Optional:

- `HERMES_DASHBOARD_TUI=1` (already effectively enabled by `--tui`)

## 4. Persistent storage

`hermes_data` volume stores config, sessions, logs, and credentials at `/opt/data`.

## 5. Deploy

- Click `Deploy` in Coolify.
- After successful deploy, open `https://hs.tsunamiautomation.com`.

## Notes

- This exposes the dashboard over the internet; protect Coolify access tightly.
- Hermes dashboard itself does not provide full external auth. Keep access limited at the proxy/network layer where possible.
