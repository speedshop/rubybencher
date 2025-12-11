#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
SSH_CONFIG="${ROOT_DIR}/ssh_config"
DEST_ROOT="${1:-${ROOT_DIR}/../results/ssh_logs}"

if [[ ! -f "${SSH_CONFIG}" ]]; then
  echo "SSH config not found at ${SSH_CONFIG}. Run bench/generate_ssh_config.sh first." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to fetch logs" >&2
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required to read outputs" >&2
  exit 1
fi

mkdir -p "${DEST_ROOT}"
outputs="$(terraform -chdir="${TF_DIR}" output -json)"
all_instance_ips="$(jq -r '.all_instance_ips.value' <<<"${outputs}")"
instance_providers="$(jq -r '.instance_providers.value' <<<"${outputs}")"
ssh_users="$(jq -r '.ssh_user.value' <<<"${outputs}")"

sanitize() {
  echo "$1" | tr '._' '-' | tr -c 'A-Za-z0-9-_' '-'
}

pull_file() {
  local host_alias="$1"
  local remote_path="$2"
  local dest_path="$3"

  if ssh -F "${SSH_CONFIG}" -o ConnectTimeout=10 "${host_alias}" "test -f ${remote_path}"; then
    scp -F "${SSH_CONFIG}" -q "${host_alias}:${remote_path}" "${dest_path}"
    echo "Fetched ${remote_path} from ${host_alias}"
  else
    echo "No ${remote_path} on ${host_alias}"
  fi
}

jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"${all_instance_ips}" | while read -r name ip; do
  [[ -z "${ip}" ]] && continue
  provider="$(jq -r --arg k "${name}" '.[$k]' <<<"${instance_providers}")"
  user="$(jq -r --arg p "${provider}" '.[$p]' <<<"${ssh_users}")"
  host_alias="bench-$(sanitize "${name}")"
  dest_dir="${DEST_ROOT}/${host_alias}"
  mkdir -p "${dest_dir}"

  pull_file "${host_alias}" "/tmp/bench.log" "${dest_dir}/bench.log" || true
  pull_file "${host_alias}" "/tmp/error.log" "${dest_dir}/error.log" || true
  pull_file "${host_alias}" "/var/log/cloud-init-output.log" "${dest_dir}/cloud-init-output.log" || true
done

echo "Logs saved under ${DEST_ROOT}"
