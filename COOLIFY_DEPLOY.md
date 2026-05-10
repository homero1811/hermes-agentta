# Coolify Production Runbook (Hermes Dashboard)

Target hostname: `https://hs.tsunamiautomation.com`

## Objective

Deploy Hermes dashboard on Coolify with HTTPS, proxy-layer authentication, persistent data, health checks, and a defined rollback path.

Automation helper:

- `scripts/coolify_prod_readiness.sh`
- Runs preflight, compose security assertions, DNS resolution, and public URL reachability checks.
- Optional strict DNS match: `EXPECTED_IP=<coolify-public-ipv4> scripts/coolify_prod_readiness.sh`
- `scripts/coolify_deploy_recovery.sh`
- Runs queue normalization, single deploy trigger, status polling, edge checks, and evidence capture via Coolify API.

## Blocking security requirements

- Never deploy with `--insecure`.
- Never publish host ports for dashboard (`ports:` must not be used).
- Route external traffic only via Coolify/Traefik HTTPS.
- Require reverse-proxy auth (`BASICAUTH_USERS`) before go-live.
- Keep all secrets in Coolify environment variables only.

## Pre-deploy checklist

- Cloudflare DNS `A` record:
  - Name: `hs`
  - Value: `<coolify-public-ipv4>`
  - Proxy status: Proxied (recommended)
- Validate DNS propagation:
  - `dig +short hs.tsunamiautomation.com`
- Coolify project/repository connected.
- Resource type is `Docker Compose`.
- Compose file path is `docker-compose.coolify.yml`.
- Domain set exactly to `hs.tsunamiautomation.com`.
- HTTPS/Let's Encrypt enabled in Coolify.
- Auth middleware configured via `BASICAUTH_USERS`.

## Required runtime configuration

Set in Coolify resource environment:

- `OPENAI_API_KEY` (or provider equivalent such as `ANTHROPIC_API_KEY`)
- `BASICAUTH_USERS` (Traefik BasicAuth users string, e.g. `admin:$$apr1$$...`)

Persistent data:

- Named Docker volume `hermes_data` mounted at `/opt/data`
- Stores Hermes config, logs, sessions, and runtime state across restarts

## Deployment steps

1. Create/update the Coolify Compose resource using `docker-compose.coolify.yml`.
2. Confirm exposed service is `hermes-dashboard` on internal port `9119`.
3. Confirm there is no host port binding.
4. Confirm `OPENAI_API_KEY` and `BASICAUTH_USERS` are set in Coolify env vars.
5. Run preflight checks:
   - `scripts/coolify_prod_readiness.sh`
6. Trigger managed recovery deploy flow:
   - `COOLIFY_BASE_URL=<coolify-api-base> COOLIFY_TOKEN=<token> APP_UUID=d1r6c08imoq58y5h20d33xuf scripts/coolify_deploy_recovery.sh`
7. Wait for service health to turn green.
8. Re-run `scripts/coolify_prod_readiness.sh` and confirm all required checks pass.

## Go/No-Go validation gates

Gate A: Connectivity

- `dig +short hs.tsunamiautomation.com` returns expected IP.
- Browser reaches `https://hs.tsunamiautomation.com` with valid TLS.

Gate B: Security

- Unauthenticated request receives BasicAuth challenge/denial.
- Authenticated request reaches dashboard UI.
- No direct public reachability on container port `9119`.

Gate C: Application health

- Coolify marks service healthy.
- `/api/status` returns success from service healthcheck path.
- No crash loops for at least 15 minutes in logs.

Gate D: Functional smoke

- Home page loads.
- Session/status screens load.
- Basic dashboard interactions work.

## Incident response

If deployment fails:

1. Check DNS resolution and Cloudflare proxy status.
2. Check Traefik router and middleware labels are attached.
3. Verify `OPENAI_API_KEY` and `BASICAUTH_USERS` are present in Coolify.
4. Inspect Coolify service logs and Hermes logs in `/opt/data`.
5. If API is unstable (`500`/Redis `MISCONF`), stabilize control plane before retriggering deploy.
6. Cancel stale queued/in-progress deployments and keep only one active deployment.

## Rollback plan

1. In Coolify, redeploy last known-good commit/image.
2. Keep the same DNS + domain mapping.
3. Re-run Connectivity/Security/Health gates.
4. Record root cause and corrective actions before retrying rollout.

## Evidence to record after success

- Coolify app UUID and deployment UUID.
- Final deployment status and UTC timestamp.
- Commit SHA deployed by Coolify.
- HTTP status for:
  - `https://hs.tsunamiautomation.com/`
  - `https://hs.tsunamiautomation.com/api/status`
- Artifact files produced by `scripts/coolify_deploy_recovery.sh` (JSON snapshots + run log).
