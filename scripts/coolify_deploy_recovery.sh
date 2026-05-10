#!/usr/bin/env bash
set -euo pipefail

# Production deployment recovery helper for Coolify-managed Hermes dashboard.
# Requires a Coolify API token with app/deployment permissions.

APP_UUID="${APP_UUID:-d1r6c08imoq58y5h20d33xuf}"
TARGET_HOST="${TARGET_HOST:-hs.tsunamiautomation.com}"
COOLIFY_BASE_URL="${COOLIFY_BASE_URL:-}"
COOLIFY_TOKEN="${COOLIFY_TOKEN:-}"
KEEP_ACTIVE_DEPLOYS="${KEEP_ACTIVE_DEPLOYS:-1}"
STUCK_MINUTES="${STUCK_MINUTES:-20}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/coolify-hermes-recovery}"

pass() { printf "[PASS] %s\n" "$1"; }
warn() { printf "[WARN] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd curl
require_cmd jq
require_cmd date
require_cmd mkdir

[[ -n "${COOLIFY_BASE_URL}" ]] || fail "Set COOLIFY_BASE_URL (example: https://coolify.example.com/api/v1)"
[[ -n "${COOLIFY_TOKEN}" ]] || fail "Set COOLIFY_TOKEN with Coolify API token"

mkdir -p "${ARTIFACT_DIR}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_log="${ARTIFACT_DIR}/recovery-${APP_UUID}-${stamp}.log"

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "${body}" ]]; then
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H "Content-Type: application/json" \
      "${COOLIFY_BASE_URL%/}${path}" \
      -d "${body}"
  else
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      "${COOLIFY_BASE_URL%/}${path}"
  fi
}

log_json() {
  local name="$1"
  local payload="$2"
  printf '%s\n' "${payload}" > "${ARTIFACT_DIR}/${stamp}-${name}.json"
}

now_epoch() {
  date -u +%s
}

ts_to_epoch() {
  local ts="$1"
  date -u -d "${ts}" +%s 2>/dev/null || echo 0
}

phase() { printf "\n== %s ==\n" "$1" | tee -a "${run_log}"; }

phase "Phase A - Control plane health"
health_payload="$(api GET /health || true)"
if [[ -z "${health_payload}" ]]; then
  fail "Coolify health endpoint unavailable"
fi
log_json "coolify-health" "${health_payload}"
pass "Coolify health endpoint reachable"

# Probe APIs that commonly fail during Redis MISCONF events.
apps_payload="$(api GET /applications || true)"
[[ -n "${apps_payload}" ]] || fail "Failed to list applications"
log_json "applications" "${apps_payload}"
pass "Applications API reachable"

phase "Phase B - Deployment queue normalization"
deployments_payload="$(api GET "/applications/${APP_UUID}/deployments" || true)"
[[ -n "${deployments_payload}" ]] || fail "Failed to list deployments for app ${APP_UUID}"
log_json "deployments-before" "${deployments_payload}"

mapfile -t deployment_rows < <(printf '%s\n' "${deployments_payload}" | jq -r '.[] | "\(.uuid) \(.status // "unknown") \(.created_at // "")"')
if [[ "${#deployment_rows[@]}" -eq 0 ]]; then
  warn "No prior deployments found for app ${APP_UUID}"
fi

active_count=0
for row in "${deployment_rows[@]}"; do
  status="$(awk '{print $2}' <<<"${row}")"
  [[ "${status}" == "queued" || "${status}" == "in_progress" ]] && ((active_count+=1))
done

cancelled=0
if (( active_count > KEEP_ACTIVE_DEPLOYS )); then
  for row in "${deployment_rows[@]}"; do
    uuid="$(awk '{print $1}' <<<"${row}")"
    status="$(awk '{print $2}' <<<"${row}")"
    created_at="$(cut -d' ' -f3- <<<"${row}")"
    [[ "${status}" == "queued" || "${status}" == "in_progress" ]] || continue

    age_ok=1
    if [[ -n "${created_at}" ]]; then
      created_epoch="$(ts_to_epoch "${created_at}")"
      if (( created_epoch > 0 )); then
        age_minutes=$(( ( $(now_epoch) - created_epoch ) / 60 ))
        if (( age_minutes < STUCK_MINUTES )); then
          age_ok=0
        fi
      fi
    fi

    if (( active_count > KEEP_ACTIVE_DEPLOYS )) && (( age_ok == 1 )); then
      if api POST "/deployments/${uuid}/cancel" >/dev/null 2>&1; then
        ((active_count-=1))
        ((cancelled+=1))
        printf '[INFO] Cancelled stale deployment: %s\n' "${uuid}" | tee -a "${run_log}"
      fi
    fi
  done
fi
pass "Queue normalization completed (cancelled=${cancelled})"

phase "Phase C + D - Trigger single deploy and monitor"
trigger_payload="$(api POST "/applications/${APP_UUID}/deploy")"
log_json "deploy-trigger" "${trigger_payload}"
new_deploy_uuid="$(printf '%s\n' "${trigger_payload}" | jq -r '.uuid // .deployment_uuid // empty')"
[[ -n "${new_deploy_uuid}" ]] || fail "Deploy trigger did not return deployment UUID"
pass "Triggered deployment ${new_deploy_uuid}"

start_time="$(now_epoch)"
final_status="unknown"
while true; do
  dep_payload="$(api GET "/deployments/${new_deploy_uuid}" || true)"
  [[ -n "${dep_payload}" ]] || fail "Could not fetch deployment ${new_deploy_uuid}"
  log_json "deployment-${new_deploy_uuid}" "${dep_payload}"
  final_status="$(printf '%s\n' "${dep_payload}" | jq -r '.status // "unknown"')"

  case "${final_status}" in
    success|finished|completed)
      pass "Deployment reached terminal success state (${final_status})"
      break
      ;;
    failed|error|canceled)
      warn "Deployment terminal failure: ${final_status}"
      logs_payload="$(api GET "/deployments/${new_deploy_uuid}/logs" || true)"
      [[ -n "${logs_payload}" ]] && log_json "deployment-${new_deploy_uuid}-logs" "${logs_payload}"
      fail "Deployment failed; see artifacts under ${ARTIFACT_DIR}"
      ;;
  esac

  elapsed=$(( $(now_epoch) - start_time ))
  if (( elapsed > MAX_WAIT_SECONDS )); then
    fail "Deployment polling timed out (${MAX_WAIT_SECONDS}s)"
  fi
  sleep "${POLL_INTERVAL}"
done

phase "Phase E - Edge verification"
root_status="$(curl -sS -o /dev/null -w '%{http_code}' "https://${TARGET_HOST}" || true)"
api_status="$(curl -sS -o /dev/null -w '%{http_code}' "https://${TARGET_HOST}/api/status" || true)"
printf '{"root_http":"%s","api_status_http":"%s"}\n' "${root_status}" "${api_status}" > "${ARTIFACT_DIR}/${stamp}-edge-checks.json"

if [[ "${root_status}" == "200" || "${root_status}" == "401" || "${root_status}" == "403" ]]; then
  pass "Root endpoint reachable with expected response (${root_status})"
else
  warn "Unexpected root endpoint status: ${root_status}"
fi

if [[ "${api_status}" == "200" || "${api_status}" == "401" || "${api_status}" == "403" ]]; then
  pass "/api/status reachable through edge (${api_status})"
else
  warn "Unexpected /api/status response: ${api_status}"
fi

phase "Phase F - Deployment evidence"
app_payload="$(api GET "/applications/${APP_UUID}" || true)"
[[ -n "${app_payload}" ]] && log_json "application-after" "${app_payload}"

printf '%s\n' "Deployment recovery completed." | tee -a "${run_log}"
printf 'Artifacts: %s\n' "${ARTIFACT_DIR}" | tee -a "${run_log}"
printf 'App UUID: %s\nDeployment UUID: %s\nTimestamp UTC: %s\n' "${APP_UUID}" "${new_deploy_uuid}" "${stamp}" | tee -a "${run_log}"
