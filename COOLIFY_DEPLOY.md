# Coolify Deployment (Dashboard UI, Internet-Safe)

This deploys Hermes web UI on Coolify and serves it at:

- `https://hs.tsunamiautomation.com`

## 1. Prerequisites

- DNS `A` record for `hs.tsunamiautomation.com` points to your Coolify server IP.
- Git repo connected in Coolify (this fork/repo).

## 2. Create the Coolify resource

- Type: `Docker Compose`
- Compose file: `docker-compose.coolify.yml`
- Service to expose: `hermes-dashboard` (Traefik-routed, no host port publish)
- Internal port: `9119`
- Domain: `hs.tsunamiautomation.com`
- Enable HTTPS/Let's Encrypt in Coolify.

## 3. Required environment variables in Coolify

Set these in the resource:

- `OPENAI_API_KEY` (or your preferred provider key such as `ANTHROPIC_API_KEY`)
- `BASICAUTH_USERS` (Traefik BasicAuth users string, e.g. `admin:$$apr1$$...`)

Optional:
- Provider-specific keys for tools you want to use.

## 4. Persistent storage

`hermes_data` volume stores config, sessions, logs, and credentials at `/opt/data`.

## 5. Deploy

- Click `Deploy` in Coolify.
- After successful deploy, open `https://hs.tsunamiautomation.com`.

## Security behavior

- No `ports:` host bind is used; service is internal-only and routed via Coolify/Traefik.
- Dashboard runs without `--insecure`.
- Access is protected by Traefik BasicAuth middleware (`BASICAUTH_USERS`).
