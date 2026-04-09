#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

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
    log "Run as root: sudo bash scripts/cleanup-vm.sh"
    exit 1
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    log "cleanup-vm.sh must run on Linux."
    exit 1
  fi
}

cleanup_manifests() {
  if ! command -v k3s >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    log "k3s/kubectl not found; skipping Kubernetes resource cleanup."
    return
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Deleting monitoring manifests"
  k delete -f "${PROJECT_DIR}/k3s/monitoring" --ignore-not-found=true

  log "Deleting wireguard manifests"
  k delete -f "${PROJECT_DIR}/k3s/service.yaml" --ignore-not-found=true
  k delete -f "${PROJECT_DIR}/k3s/deployment.yaml" --ignore-not-found=true
  k -n vpn-core-vm delete secret wireguard-config --ignore-not-found=true
  k delete -f "${PROJECT_DIR}/k3s/namespace.yaml" --ignore-not-found=true
}

require_root
require_linux
cleanup_manifests
