#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${SAAR_BASE_URL:-http://127.0.0.1:8080}"
API_KEY="${SAAR_API_KEY:-}"
PROFILE_ID=""
INSTANCE_ID=""
CAPABILITY="chat"
MODE="sync"
PHASE="ready_transient"
INPUT_TEXT=""
FILE_URL=""
FILE_NAME="doc.txt"
FILE_MIME="text/plain"
TRACE_ID=""
WAIT_FOR_TASK="false"
WAIT_STATE="completed"
WAIT_ATTEMPTS=60

usage() {
  cat <<'EOF'
Usage:
  scripts/e2e/run.sh <command> [options]

Commands:
  create-agent
  wait-ready
  interact
  delete-agent

Global options:
  --base-url URL         (default: http://127.0.0.1:8080)
  --api-key KEY          (or SAAR_API_KEY env var)
  --profile-id ID        (required for create-agent)
  --instance-id ID       (required for most commands)

Interact options:
  --capability NAME      (default: chat)
  --mode sync|stream|deferred (default: sync)
  --input TEXT           (default: "")
  --file-url URL         (for files input)
  --file-name NAME       (default: doc.txt)
  --file-mime MIME       (default: text/plain)
  --trace-id ID          (optional)
  --wait                (only for deferred; poll task)
  --wait-state STATE     (default: completed)
  --wait-attempts N      (default: 60)

wait-ready options:
  --phase NAME           (default: ready_transient)

Examples:
  SAAR_API_KEY=dev scripts/e2e/run.sh create-agent --profile-id lightrag --instance-id lightrag-1
  SAAR_API_KEY=dev scripts/e2e/run.sh wait-ready --instance-id lightrag-1 --phase ready_continuous
  SAAR_API_KEY=dev scripts/e2e/run.sh interact --instance-id lightrag-1 --capability chat --mode sync --input "hola"
  SAAR_API_KEY=dev scripts/e2e/run.sh interact --instance-id lightrag-1 --capability files --mode sync \
    --file-url "http://127.0.0.1:8080/health" --file-name doc.txt --file-mime text/plain
  SAAR_API_KEY=dev scripts/e2e/run.sh interact --instance-id aider-1 --capability chat --mode deferred --input "hola" --wait
  SAAR_API_KEY=dev scripts/e2e/run.sh delete-agent --instance-id lightrag-1
EOF
}

require_api_key() {
  if [[ -z "${API_KEY}" ]]; then
    echo "Missing --api-key or SAAR_API_KEY" >&2
    exit 1
  fi
}

require_instance_id() {
  if [[ -z "${INSTANCE_ID}" ]]; then
    echo "Missing --instance-id" >&2
    exit 1
  fi
}

json_escape() {
  python3 - <<'PY' "$1"
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local headers=(
    -H "authorization: Bearer ${API_KEY}"
    -H "content-type: application/json"
  )

  local tmp
  tmp=$(mktemp)

  if [[ -n "${body}" ]]; then
    status=$(curl -sS -o "${tmp}" -w "%{http_code}" -X "${method}" "${url}" "${headers[@]}" --data "${body}")
  else
    status=$(curl -sS -o "${tmp}" -w "%{http_code}" -X "${method}" "${url}" "${headers[@]}")
  fi

  body_text=$(<"${tmp}")
  rm -f "${tmp}"

  echo "${status}"
  echo "${body_text}"
}

create_agent() {
  require_api_key

  if [[ -z "${PROFILE_ID}" ]]; then
    echo "Missing --profile-id" >&2
    exit 1
  fi

  require_instance_id

  local payload
  payload="{\"profile_id\":${PROFILE_ID_JSON},\"instance_id\":${INSTANCE_ID_JSON}}"

  read -r status body < <(request "POST" "${BASE_URL}/sys/agents" "${payload}")
  echo "Status: ${status}"
  echo "Body: ${body}"
}

wait_ready() {
  require_api_key
  require_instance_id

  local attempts=60
  while [[ ${attempts} -gt 0 ]]; do
    read -r status body < <(request "GET" "${BASE_URL}/sys/agents/${INSTANCE_ID}/status")
    if [[ "${status}" == "200" ]] && echo "${body}" | grep -q "\"phase\":\"${PHASE}\""; then
      echo "Ready: ${PHASE}"
      return 0
    fi
    sleep 0.2
    attempts=$((attempts - 1))
  done

  echo "Timed out waiting for phase ${PHASE}" >&2
  exit 1
}

interaction_payload() {
  local trace_json
  local trace_value

  if [[ -z "${TRACE_ID}" ]]; then
    TRACE_ID="trace-$(date +%s)"
  fi
  trace_json=$(json_escape "${TRACE_ID}")

  if [[ -n "${FILE_URL}" ]]; then
    local file_url_json
    local file_name_json
    local file_mime_json
    file_url_json=$(json_escape "${FILE_URL}")
    file_name_json=$(json_escape "${FILE_NAME}")
    file_mime_json=$(json_escape "${FILE_MIME}")
    echo "{\"capability\":${CAPABILITY_JSON},\"inputs\":{\"files\":[{\"name\":${file_name_json},\"url\":${file_url_json},\"mime\":${file_mime_json}}]},\"context\":{\"trace_id\":${trace_json}}}"
  else
    local input_json
    input_json=$(json_escape "${INPUT_TEXT}")
    echo "{\"capability\":${CAPABILITY_JSON},\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":${input_json}}]},\"context\":{\"trace_id\":${trace_json}}}"
  fi
}

extract_task_id() {
  python3 - <<'PY' "$1"
import json
import sys

data = json.loads(sys.argv[1])
for key in ("task_id", "taskId", "id"):
    if key in data:
        print(data[key])
        sys.exit(0)
result = data.get("result")
if isinstance(result, dict) and "id" in result:
    print(result["id"])
    sys.exit(0)
print("")
PY
}

wait_for_task() {
  local task_id="$1"

  local attempts=${WAIT_ATTEMPTS}
  while [[ ${attempts} -gt 0 ]]; do
    read -r status body < <(request "GET" "${BASE_URL}/tasks/${task_id}")
    if [[ "${status}" == "200" ]] && echo "${body}" | grep -q "\"state\":\"${WAIT_STATE}\""; then
      echo "Task ${task_id} reached ${WAIT_STATE}"
      echo "Body: ${body}"
      return 0
    fi
    sleep 0.5
    attempts=$((attempts - 1))
  done

  echo "Timed out waiting for task ${task_id} to reach ${WAIT_STATE}" >&2
  exit 1
}

interact() {
  require_api_key
  require_instance_id

  local payload
  payload=$(interaction_payload)

  if [[ "${MODE}" == "stream" ]]; then
    curl --no-buffer -sS -X POST "${BASE_URL}/agents/${INSTANCE_ID}/interact" \
      -H "authorization: Bearer ${API_KEY}" \
      -H "content-type: application/json" \
      --data "${payload}"
    return 0
  fi

  read -r status body < <(request "POST" "${BASE_URL}/agents/${INSTANCE_ID}/interact" "${payload}")
  echo "Status: ${status}"
  echo "Body: ${body}"

  if [[ "${MODE}" == "deferred" ]]; then
    local task_id
    task_id=$(extract_task_id "${body}")
    if [[ -z "${task_id}" ]]; then
      echo "Could not find task_id in response" >&2
      exit 1
    fi
    echo "Task ID: ${task_id}"
    if [[ "${WAIT_FOR_TASK}" == "true" ]]; then
      wait_for_task "${task_id}"
    fi
  fi
}

delete_agent() {
  require_api_key
  require_instance_id

  read -r status body < <(request "DELETE" "${BASE_URL}/sys/agents/${INSTANCE_ID}")
  echo "Status: ${status}"
  echo "Body: ${body}"
}

command="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"; shift 2 ;;
    --api-key)
      API_KEY="$2"; shift 2 ;;
    --profile-id)
      PROFILE_ID="$2"; shift 2 ;;
    --instance-id)
      INSTANCE_ID="$2"; shift 2 ;;
    --capability)
      CAPABILITY="$2"; shift 2 ;;
    --mode)
      MODE="$2"; shift 2 ;;
    --phase)
      PHASE="$2"; shift 2 ;;
    --input)
      INPUT_TEXT="$2"; shift 2 ;;
    --file-url)
      FILE_URL="$2"; shift 2 ;;
    --file-name)
      FILE_NAME="$2"; shift 2 ;;
    --file-mime)
      FILE_MIME="$2"; shift 2 ;;
    --trace-id)
      TRACE_ID="$2"; shift 2 ;;
    --wait)
      WAIT_FOR_TASK="true"; shift 1 ;;
    --wait-state)
      WAIT_STATE="$2"; shift 2 ;;
    --wait-attempts)
      WAIT_ATTEMPTS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

PROFILE_ID_JSON="$(json_escape "${PROFILE_ID}")"
INSTANCE_ID_JSON="$(json_escape "${INSTANCE_ID}")"
CAPABILITY_JSON="$(json_escape "${CAPABILITY}")"

case "${command}" in
  create-agent)
    create_agent
    ;;
  wait-ready)
    wait_ready
    ;;
  interact)
    interact
    ;;
  delete-agent)
    delete_agent
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage
    exit 1
    ;;
esac
