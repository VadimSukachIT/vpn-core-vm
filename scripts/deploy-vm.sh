#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_TAG="${1:-}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/vadimsukachit/vpn-core-vm-wireguard}"
IMAGE_NAME="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"

log() {
  printf '%s\n' "$*"
}

on_error() {
  log "deploy-vm.sh failed at line $1"
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
    log "Run as root: sudo bash scripts/deploy-vm.sh <imageTag>"
    exit 1
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    log "deploy-vm.sh must run on Linux."
    exit 1
  fi
}

require_image_tag() {
  if [ -n "${IMAGE_TAG}" ]; then
    return
  fi

  log "Usage: bash scripts/deploy-vm.sh <imageTag>"
  exit 1
}

require_k3s() {
  if command -v k3s >/dev/null 2>&1 || command -v kubectl >/dev/null 2>&1; then
    return
  fi

  log "k3s/kubectl not found on VM."
  exit 1
}

wait_for_node() {
  export KUBECONFIG="${KUBECONFIG_PATH}"
  log "Waiting for node readiness"
  k wait --for=condition=Ready node --all --timeout=120s
}

deploy_wireguard() {
  export KUBECONFIG="${KUBECONFIG_PATH}"

  log "Updating wireguard image to ${IMAGE_NAME}"
  k -n vpn-core-vm set image deployment/wireguard wireguard="${IMAGE_NAME}"

  log "Waiting for wireguard rollout"
  k -n vpn-core-vm rollout status deployment/wireguard --timeout=180s
}

check_monitoring() {
  export KUBECONFIG="${KUBECONFIG_PATH}"

  if k -n vpn-core-vm get daemonset/node-exporter >/dev/null 2>&1; then
    log "Checking node-exporter rollout"
    k -n vpn-core-vm rollout status daemonset/node-exporter --timeout=120s
  fi

  if k -n vpn-core-vm get deployment/kube-state-metrics >/dev/null 2>&1; then
    log "Checking kube-state-metrics rollout"
    k -n vpn-core-vm rollout status deployment/kube-state-metrics --timeout=120s
  fi
}

show_status() {
  export KUBECONFIG="${KUBECONFIG_PATH}"

  log "Wireguard image"
  k -n vpn-core-vm get deployment/wireguard -o jsonpath='{.spec.template.spec.containers[0].image}'
  printf '\n'

  log "Runtime pods"
  k -n vpn-core-vm get pods -o wide
}

require_root
require_linux
require_image_tag
require_k3s
wait_for_node
deploy_wireguard
check_monitoring
show_status
