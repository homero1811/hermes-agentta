#!/usr/bin/env bash
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-hs.tsunamiautomation.com}"
TARGET_URL="https://${TARGET_HOST}"
EXPECTED_IP="${EXPECTED_IP:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.coolify.yml"

pass() { printf "[PASS] %s\n" "$1"; }
warn() { printf "[WARN] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd python3
require_cmd pip3
require_cmd curl

[[ -d "${REPO_ROOT}" ]] || fail "Repo root not found: ${REPO_ROOT}"
[[ -r "${COMPOSE_FILE}" ]] || fail "Compose file not readable: ${COMPOSE_FILE}"
pass "Repository and compose file are present"

# Disk space guardrail (>= 2GB free)
free_kb="$(df -Pk "${REPO_ROOT}" | awk 'NR==2 {print $4}')"
if [[ -z "${free_kb}" ]]; then
  fail "Could not determine free disk space"
fi
if (( free_kb < 2097152 )); then
  fail "Low disk space: < 2GB free"
fi
pass "Disk space check passed"

python3 --version
pip3 --version
pass "Python and pip detected"

if [[ -d "${REPO_ROOT}/.venv" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.venv/bin/activate"
  pass "Using existing .venv"
else
  python3 -m venv "${REPO_ROOT}/.venv"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.venv/bin/activate"
  pass "Created .venv"
fi

python -m pip install --upgrade pip setuptools wheel >/dev/null
pass "Build tooling upgraded"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  warn "Repo .env not found; if needed, create it from .env.example"
fi

if [[ ! -f "${HOME}/.hermes/config.yaml" ]]; then
  warn "~/.hermes/config.yaml is missing (first-run setup likely not completed yet)"
else
  pass "~/.hermes/config.yaml exists"
fi

if [[ ! -f "${HOME}/.hermes/.env" ]]; then
  warn "~/.hermes/.env is missing (provider credentials may be absent)"
else
  pass "~/.hermes/.env exists"
fi

# Validate compose security constraints from the production plan.
if rg -n '^\s*ports:' "${COMPOSE_FILE}" >/dev/null; then
  fail "Compose file uses host port publishing (ports:). Use expose only."
fi
pass "No host port publish in compose"

if rg -n -- '--insecure' "${COMPOSE_FILE}" >/dev/null; then
  fail "Compose file contains --insecure"
fi
pass "Compose does not use --insecure"

rg -n 'traefik\.http\.routers\.hermes-dashboard\.rule=Host\(`hs\.tsunamiautomation\.com`\)' "${COMPOSE_FILE}" >/dev/null \
  || fail "Missing expected Traefik host rule for hs.tsunamiautomation.com"
pass "Traefik host rule present"

rg -n 'basicauth\.users=\$\{BASICAUTH_USERS\}' "${COMPOSE_FILE}" >/dev/null \
  || fail "Missing BasicAuth middleware label"
pass "BasicAuth middleware label present"

resolve_dns_ip() {
  if command -v dig >/dev/null 2>&1; then
    dig +short "${TARGET_HOST}" | tail -n1 | tr -d '[:space:]'
    return
  fi
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "${TARGET_HOST}" | awk 'NR==1 {print $1}'
    return
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "${TARGET_HOST}" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1
    return
  fi
  return 1
}

dns_ip="$(resolve_dns_ip || true)"
if [[ -z "${dns_ip}" ]]; then
  fail "No DNS resolution for ${TARGET_HOST}"
fi
pass "DNS resolves ${TARGET_HOST} -> ${dns_ip}"

if [[ -n "${EXPECTED_IP}" && "${dns_ip}" != "${EXPECTED_IP}" ]]; then
  fail "DNS IP mismatch. expected=${EXPECTED_IP} actual=${dns_ip}"
fi
if [[ -n "${EXPECTED_IP}" ]]; then
  pass "DNS matches expected Coolify IP"
fi

http_code="$(curl -sS -o /dev/null -w '%{http_code}' "${TARGET_URL}" || true)"
if [[ "${http_code}" == "401" || "${http_code}" == "403" || "${http_code}" == "200" ]]; then
  pass "Public URL reachable with expected auth/app response (${http_code})"
else
  warn "Unexpected HTTP status from ${TARGET_URL}: ${http_code}"
fi

if command -v hermes >/dev/null 2>&1; then
  hermes --version >/dev/null
  pass "hermes CLI responds"
else
  warn "hermes executable not on PATH yet"
fi

printf "\nReadiness checks completed for %s\n" "${TARGET_URL}"
