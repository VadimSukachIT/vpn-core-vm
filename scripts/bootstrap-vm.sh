#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROOT_DIR="${ROOT_DIR:-/opt/vpn-core-vm}"
GENERATED_DIR="${GENERATED_DIR:-/conf/vpn-core-vm}"
RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-${ROOT_DIR}/runtime.env}"
WG_CONFIG_PATH="${WG_CONFIG_PATH:-${GENERATED_DIR}/wg0.conf}"
PEERS_JSON_PATH="${PEERS_JSON_PATH:-${GENERATED_DIR}/peers.json}"
SERVER_PRIVATE_KEY_PATH="${SERVER_PRIVATE_KEY_PATH:-${GENERATED_DIR}/server-private.key}"
SERVER_PUBLIC_KEY_PATH="${SERVER_PUBLIC_KEY_PATH:-${GENERATED_DIR}/server-public.key}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/vadimsukachit/vpn-core-vm-wireguard}"
RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-}"
IMAGE_NAME=""
WG_INTERFACE="${WG_INTERFACE:-}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-}"
KUBE_STATE_METRICS_PORT="${KUBE_STATE_METRICS_PORT:-}"
KUBE_STATE_METRICS_TELEMETRY_PORT="${KUBE_STATE_METRICS_TELEMETRY_PORT:-}"
PING_TARGET="${PING_TARGET:-}"
WG_CONFIG_SECRET_KEY=""
WG_RUNTIME_CONFIG_MOUNT_PATH=""
APT_UPDATED="${APT_UPDATED:-0}"
K3S_CONFIG_DIR="${K3S_CONFIG_DIR:-/etc/rancher/k3s}"
K3S_CONFIG_PATH="${K3S_CONFIG_PATH:-${K3S_CONFIG_DIR}/config.yaml}"
K3S_CONFIG_CHANGED=0
BOOTSTRAP_CLEANUP_ON_ERROR=1

log() {
  printf '%s\n' "$*"
}

on_error() {
  set +e
  log "bootstrap-vm.sh failed at line $1"

  if [ "${BOOTSTRAP_CLEANUP_ON_ERROR}" -eq 1 ]; then
    BOOTSTRAP_CLEANUP_ON_ERROR=0
    log "Running cleanup-vm.sh after bootstrap failure"
    bash "${PROJECT_DIR}/scripts/cleanup-vm.sh" || log "cleanup-vm.sh failed"
  fi

  exit 1
}

trap 'on_error $LINENO' ERR

k() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl "$@"
  else
    k3s kubectl "$@"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Run as root: sudo bash scripts/bootstrap-vm.sh"
    exit 1
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    log "bootstrap-vm.sh must run on Linux."
    exit 1
  fi
}

require_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    log "Cannot detect OS."
    exit 1
  fi

  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    log "bootstrap-vm.sh currently supports Ubuntu only."
    exit 1
  fi
}

apt_update_once() {
  if [ "${APT_UPDATED}" -eq 1 ]; then
    return
  fi

  apt-get update
  APT_UPDATED=1
}

install_apt_packages() {
  apt_update_once
  apt-get install -y "$@"
}

install_host_dependencies_if_missing() {
  packages=""

  if ! command -v python3 >/dev/null 2>&1; then
    packages="${packages} python3"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    packages="${packages} curl"
  fi

  if ! command -v wg >/dev/null 2>&1; then
    packages="${packages} wireguard-tools"
  fi

  if ! command -v k3s >/dev/null 2>&1; then
    if ! dpkg -s ca-certificates >/dev/null 2>&1; then
      packages="${packages} ca-certificates"
    fi
  fi

  if [ -z "${packages}" ]; then
    return
  fi

  log "Installing host dependencies:${packages}"
  # shellcheck disable=SC2086
  install_apt_packages ${packages}
}

write_k3s_config() {
  local desired_config
  desired_config="$(cat <<'EOF'
disable:
  - traefik
  - servicelb
  - metrics-server
  - local-storage
EOF
)"

  install -d -m 0755 "${K3S_CONFIG_DIR}"

  if [ -f "${K3S_CONFIG_PATH}" ] && [ "$(cat "${K3S_CONFIG_PATH}")" = "${desired_config}" ]; then
    return
  fi

  log "Writing k3s config with disabled default addons"
  printf '%s\n' "${desired_config}" > "${K3S_CONFIG_PATH}"
  K3S_CONFIG_CHANGED=1
}

install_k3s_if_missing() {
  write_k3s_config

  if command -v k3s >/dev/null 2>&1; then
    if [ "${K3S_CONFIG_CHANGED}" -eq 1 ]; then
      log "Restarting k3s to apply updated addon config"
      systemctl restart k3s
    fi
    return
  fi

  log "Installing k3s"
  curl -sfL https://get.k3s.io | sh -
}

wait_for_k3s() {
  local attempt=0
  local max_attempts=60

  log "Waiting for k3s node readiness"
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  while [ "${attempt}" -lt "${max_attempts}" ]; do
    if k get nodes --no-headers 2>/dev/null | grep -q .; then
      break
    fi

    attempt=$((attempt + 1))
    sleep 2
  done

  if ! k get nodes --no-headers 2>/dev/null | grep -q .; then
    log "k3s node resource did not appear in time."
    exit 1
  fi

  k wait --for=condition=Ready node --all --timeout=120s
}

ensure_runtime_env() {
  if [ -f "${RUNTIME_ENV_PATH}" ]; then
    return
  fi

  log "Runtime env file not found: ${RUNTIME_ENV_PATH}"
  log "Expected vpn-core to copy runtime config to ${RUNTIME_ENV_PATH} before bootstrap."
  exit 1
}

load_runtime_contract() {
  if [ -f "${RUNTIME_ENV_PATH}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${RUNTIME_ENV_PATH}"
    set +a
  fi

  if [ -z "${RUNTIME_IMAGE_TAG}" ] && [ -f "${RUNTIME_ENV_PATH}" ]; then
    RUNTIME_IMAGE_TAG="$(
      sed -n 's/^RUNTIME_IMAGE_TAG=//p' "${RUNTIME_ENV_PATH}" | tail -n 1
    )"
  fi

  if [ -z "${RUNTIME_IMAGE_TAG}" ]; then
    log "RUNTIME_IMAGE_TAG is required for bootstrap."
    exit 1
  fi

  : "${WG_INTERFACE:=wg0}"
  : "${WG_LISTEN_PORT:=51820}"
  : "${NODE_EXPORTER_PORT:=9100}"
  : "${KUBE_STATE_METRICS_PORT:=8080}"
  : "${PING_TARGET:=1.1.1.1}"

  if [ -z "${KUBE_STATE_METRICS_TELEMETRY_PORT}" ]; then
    KUBE_STATE_METRICS_TELEMETRY_PORT="$((KUBE_STATE_METRICS_PORT + 1))"
  fi

  IMAGE_NAME="${IMAGE_REPOSITORY}:${RUNTIME_IMAGE_TAG}"
  WG_CONFIG_SECRET_KEY="${WG_INTERFACE}.conf"
  WG_RUNTIME_CONFIG_MOUNT_PATH="/etc/wireguard/${WG_INTERFACE}.conf"
}

generate_wireguard_artifacts() {
  log "Generating WireGuard artifacts"
  mkdir -p "${GENERATED_DIR}"

  RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH}" \
  GENERATED_DIR="${GENERATED_DIR}" \
  WG_CONFIG_PATH="${WG_CONFIG_PATH}" \
  PEERS_JSON_PATH="${PEERS_JSON_PATH}" \
  SERVER_PRIVATE_KEY_PATH="${SERVER_PRIVATE_KEY_PATH}" \
  SERVER_PUBLIC_KEY_PATH="${SERVER_PUBLIC_KEY_PATH}" \
  python3 "${PROJECT_DIR}/scripts/generate-wireguard-artifacts.py"

  if [ ! -s "${WG_CONFIG_PATH}" ]; then
    log "WireGuard config was not created: ${WG_CONFIG_PATH}"
    exit 1
  fi

  if [ ! -s "${PEERS_JSON_PATH}" ]; then
    log "Peers metadata was not created: ${PEERS_JSON_PATH}"
    exit 1
  fi
}

apply_manifests() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Applying namespace"
  k apply -f "${PROJECT_DIR}/k3s/namespace.yaml"

  log "Applying monitoring manifests"
  k apply -f "${PROJECT_DIR}/k3s/monitoring"

  log "Creating Secret from ${WG_CONFIG_PATH}"
  k -n vpn-core-vm create secret generic wireguard-config \
    --from-file="${WG_CONFIG_SECRET_KEY}=${WG_CONFIG_PATH}" \
    --dry-run=client -o yaml | k apply -f -

  log "Applying deployment and service"
  k apply -f "${PROJECT_DIR}/k3s/deployment.yaml"
  k apply -f "${PROJECT_DIR}/k3s/service.yaml"

  log "Configuring runtime resources from runtime.env"
  k -n vpn-core-vm patch deployment wireguard --type='strategic' -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "wireguard",
            "env": [
              {
                "name": "WG_CONFIG_PATH",
                "value": "${WG_RUNTIME_CONFIG_MOUNT_PATH}"
              },
              {
                "name": "WG_INTERFACE",
                "value": "${WG_INTERFACE}"
              }
            ],
            "volumeMounts": [
              {
                "name": "wireguard-config",
                "mountPath": "${WG_RUNTIME_CONFIG_MOUNT_PATH}",
                "subPath": "${WG_CONFIG_SECRET_KEY}",
                "readOnly": true
              },
              {
                "name": "lib-modules",
                "mountPath": "/lib/modules",
                "readOnly": true
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
)"

  k -n vpn-core-vm patch service wireguard --type='merge' -p "$(cat <<EOF
{
  "spec": {
    "ports": [
      {
        "name": "wireguard-udp",
        "port": ${WG_LISTEN_PORT},
        "targetPort": ${WG_LISTEN_PORT},
        "protocol": "UDP"
      }
    ]
  }
}
EOF
)"

  k -n vpn-core-vm patch daemonset node-exporter --type='json' -p="$(cat <<EOF
[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args/0",
    "value": "--web.listen-address=:${NODE_EXPORTER_PORT}"
  }
]
EOF
)"

  k -n vpn-core-vm patch deployment kube-state-metrics --type='json' -p="$(cat <<EOF
[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args/0",
    "value": "--port=${KUBE_STATE_METRICS_PORT}"
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args/1",
    "value": "--telemetry-port=${KUBE_STATE_METRICS_TELEMETRY_PORT}"
  }
]
EOF
)"

  log "Updating wireguard image to ${IMAGE_NAME}"
  k -n vpn-core-vm set image deployment/wireguard wireguard="${IMAGE_NAME}"
}

show_status() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Waiting for wireguard deployment"
  k -n vpn-core-vm rollout status deployment/wireguard --timeout=120s

  log "Waiting for monitoring workloads"
  k -n vpn-core-vm rollout status daemonset/node-exporter --timeout=120s
  k -n vpn-core-vm rollout status deployment/kube-state-metrics --timeout=120s

  log "Pods"
  k -n vpn-core-vm get pods -o wide

  log "Service"
  k -n vpn-core-vm get svc wireguard

  log "Runtime summary"
  python3 - <<PY
import json
from pathlib import Path

wg_config_path = Path(${WG_CONFIG_PATH@Q})
peers_json_path = Path(${PEERS_JSON_PATH@Q})

listen_port = "unknown"
for line in wg_config_path.read_text().splitlines():
    if line.startswith("ListenPort = "):
        listen_port = line.split("=", 1)[1].strip()
        break

peers = json.loads(peers_json_path.read_text())

print(f"interface: ${WG_INTERFACE@Q}")
print(f"listen port: {listen_port}")
print(f"peer count: {len(peers)}")
print(f"wg config: {wg_config_path}")
print(f"peers json: {peers_json_path}")
print(f"wireguard image: ${IMAGE_NAME@Q}")
print(f"node exporter: :${NODE_EXPORTER_PORT}")
print(f"kube-state-metrics: :${KUBE_STATE_METRICS_PORT}")
PY
}

verify_runtime() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Verifying wireguard pod readiness"
  k -n vpn-core-vm wait --for=condition=Ready pod -l app=wireguard --timeout=60s

  log "Verifying ${WG_INTERFACE} exists"
  k -n vpn-core-vm exec deploy/wireguard -- ip link show "${WG_INTERFACE}" >/dev/null

  log "Verifying node-exporter endpoint"
  curl -fsS --max-time 5 "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" >/dev/null

  log "Verifying kube-state-metrics endpoint"
  curl -fsS --max-time 5 "http://127.0.0.1:${KUBE_STATE_METRICS_PORT}/metrics" >/dev/null

  log "Verifying outbound network from wireguard runtime"
  k -n vpn-core-vm exec deploy/wireguard -- ping -c 1 -W 5 "${PING_TARGET}" >/dev/null
}

require_root
require_linux
require_ubuntu
ensure_runtime_env
load_runtime_contract
install_host_dependencies_if_missing
install_k3s_if_missing
wait_for_k3s
generate_wireguard_artifacts
apply_manifests
show_status
verify_runtime
BOOTSTRAP_CLEANUP_ON_ERROR=0
