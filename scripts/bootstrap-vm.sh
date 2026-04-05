#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-${ROOT_DIR}/config/runtime.env}"
WG_CONFIG_PATH="${WG_CONFIG_PATH:-${ROOT_DIR}/generated/wg0.conf}"
SERVER_PRIVATE_KEY_PATH="${SERVER_PRIVATE_KEY_PATH:-${ROOT_DIR}/generated/server-private.key}"
SERVER_PUBLIC_KEY_PATH="${SERVER_PUBLIC_KEY_PATH:-${ROOT_DIR}/generated/server-public.key}"
IMAGE_NAME="${IMAGE_NAME:-vpn-core-vm-wireguard:latest}"
IMAGE_TAR="${IMAGE_TAR:-/tmp/vpn-core-vm-wireguard.tar}"

log() {
  printf '%s\n' "$*"
}

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

load_runtime_env() {
  # shellcheck disable=SC1090
  . "${RUNTIME_ENV_PATH}"

  : "${WG_INTERFACE:=wg0}"
  : "${WG_ADDRESS:=10.8.0.1/24}"
  : "${WG_NETWORK:=10.8.0.0/24}"
  : "${WG_LISTEN_PORT:=51820}"
  : "${WG_MASQUERADE_INTERFACE:=eth0}"
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
  log "Expected config/runtime.env to exist in the project."
  exit 1
}

generate_wg_config_if_missing() {
  mkdir -p "$(dirname "${WG_CONFIG_PATH}")"

  if [ ! -f "${SERVER_PRIVATE_KEY_PATH}" ]; then
    log "Generating server private key"
    wg genkey > "${SERVER_PRIVATE_KEY_PATH}"
    chmod 600 "${SERVER_PRIVATE_KEY_PATH}"
  fi

  if [ ! -f "${SERVER_PUBLIC_KEY_PATH}" ]; then
    log "Generating server public key"
    wg pubkey < "${SERVER_PRIVATE_KEY_PATH}" > "${SERVER_PUBLIC_KEY_PATH}"
    chmod 600 "${SERVER_PUBLIC_KEY_PATH}"
  fi

  if [ -f "${WG_CONFIG_PATH}" ]; then
    return
  fi

  log "Generating WireGuard config into ${WG_CONFIG_PATH}"
  cat > "${WG_CONFIG_PATH}" <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = $(cat "${SERVER_PRIVATE_KEY_PATH}")
SaveConfig = false
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o ${WG_MASQUERADE_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o ${WG_MASQUERADE_INTERFACE} -j MASQUERADE
EOF
  chmod 600 "${WG_CONFIG_PATH}"
}

build_and_import_image() {
  log "Building image ${IMAGE_NAME}"
  docker build -f "${ROOT_DIR}/docker/Dockerfile" -t "${IMAGE_NAME}" "${ROOT_DIR}"

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
  k apply -f "${ROOT_DIR}/k3s/namespace.yaml"

  log "Creating Secret from ${WG_CONFIG_PATH}"
  k -n vpn-core-vm create secret generic wireguard-config \
    --from-file=wg0.conf="${WG_CONFIG_PATH}" \
    --dry-run=client -o yaml | k apply -f -

  log "Applying deployment and service"
  k apply -f "${ROOT_DIR}/k3s/deployment.yaml"
  k apply -f "${ROOT_DIR}/k3s/service.yaml"
}

show_status() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Waiting for deployment"
  k -n vpn-core-vm rollout status deployment/wireguard --timeout=120s

  log "Pods"
  k -n vpn-core-vm get pods -o wide

  log "Service"
  k -n vpn-core-vm get svc wireguard

  log "WireGuard status"
  k -n vpn-core-vm exec deploy/wireguard -- wg show
}

require_root
require_linux
require_ubuntu
ensure_runtime_env
load_runtime_env
install_wireguard_tools_if_missing
install_docker_if_missing
install_k3s_if_missing
wait_for_k3s
generate_wg_config_if_missing
build_and_import_image
apply_manifests
show_status
