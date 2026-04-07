#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROOT_DIR="${ROOT_DIR:-/opt/vpn-core-vm}"
GENERATED_DIR="${GENERATED_DIR:-${ROOT_DIR}/generated}"
RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-${ROOT_DIR}/runtime.env}"
WG_CONFIG_PATH="${WG_CONFIG_PATH:-${GENERATED_DIR}/wg0.conf}"
PEERS_JSON_PATH="${PEERS_JSON_PATH:-${GENERATED_DIR}/peers.json}"
SERVER_PRIVATE_KEY_PATH="${SERVER_PRIVATE_KEY_PATH:-${GENERATED_DIR}/server-private.key}"
SERVER_PUBLIC_KEY_PATH="${SERVER_PUBLIC_KEY_PATH:-${GENERATED_DIR}/server-public.key}"
IMAGE_NAME="${IMAGE_NAME:-vpn-core-vm-wireguard:latest}"
IMAGE_TAR="${IMAGE_TAR:-/tmp/vpn-core-vm-wireguard.tar}"

log() {
  printf '%s\n' "$*"
}

on_error() {
  log "bootstrap-vm.sh failed at line $1"
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

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  log "Installing Docker"
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_wireguard_tools_if_missing() {
  if command -v wg >/dev/null 2>&1; then
    return
  fi

  log "Installing wireguard-tools on host"
  apt-get update
  apt-get install -y wireguard-tools
}

install_python3_if_missing() {
  if command -v python3 >/dev/null 2>&1; then
    return
  fi

  log "Installing python3 on host"
  apt-get update
  apt-get install -y python3
}

install_k3s_if_missing() {
  if command -v k3s >/dev/null 2>&1; then
    return
  fi

  log "Installing k3s"
  curl -sfL https://get.k3s.io | sh -
}

wait_for_k3s() {
  log "Waiting for k3s node readiness"
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
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

build_and_import_image() {
  log "Building image ${IMAGE_NAME}"
  docker build -f "${PROJECT_DIR}/docker/Dockerfile" -t "${IMAGE_NAME}" "${PROJECT_DIR}"

  log "Importing image into k3s"
  mkdir -p "$(dirname "${IMAGE_TAR}")"
  docker save "${IMAGE_NAME}" -o "${IMAGE_TAR}"
  mkdir -p /var/lib/rancher/k3s/agent/images
  cp "${IMAGE_TAR}" /var/lib/rancher/k3s/agent/images/
  k3s ctr images import "${IMAGE_TAR}"
}

apply_manifests() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Applying namespace"
  k apply -f "${PROJECT_DIR}/k3s/namespace.yaml"

  log "Creating Secret from ${WG_CONFIG_PATH}"
  k -n vpn-core-vm create secret generic wireguard-config \
    --from-file=wg0.conf="${WG_CONFIG_PATH}" \
    --dry-run=client -o yaml | k apply -f -

  log "Applying deployment and service"
  k apply -f "${PROJECT_DIR}/k3s/deployment.yaml"
  k apply -f "${PROJECT_DIR}/k3s/service.yaml"
}

show_status() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Waiting for deployment"
  k -n vpn-core-vm rollout status deployment/wireguard --timeout=120s

  log "Pods"
  k -n vpn-core-vm get pods -o wide

  log "Service"
  k -n vpn-core-vm get svc wireguard

  log "WireGuard summary"
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

print(f"interface: wg0")
print(f"listen port: {listen_port}")
print(f"peer count: {len(peers)}")
print(f"wg config: {wg_config_path}")
print(f"peers json: {peers_json_path}")
PY
}

require_root
require_linux
require_ubuntu
ensure_runtime_env
install_wireguard_tools_if_missing
install_python3_if_missing
install_docker_if_missing
install_k3s_if_missing
wait_for_k3s
generate_wireguard_artifacts
build_and_import_image
apply_manifests
show_status
