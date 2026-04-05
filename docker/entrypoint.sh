#!/bin/sh
set -eu

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg0.conf}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"

cleanup() {
  echo "Shutting down ${WG_INTERFACE}"
  wg-quick down "${WG_INTERFACE}" >/dev/null 2>&1 || true
}

trap cleanup INT TERM EXIT

if [ ! -f "${WG_CONFIG_PATH}" ]; then
  echo "WireGuard config not found: ${WG_CONFIG_PATH}" >&2
  exit 1
fi

chmod 600 "${WG_CONFIG_PATH}" || true

echo "Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null || true

echo "Starting ${WG_INTERFACE} via wg-quick"
wg-quick up "${WG_INTERFACE}"

echo "WireGuard interface status"
wg show "${WG_INTERFACE}" || true
ip addr show "${WG_INTERFACE}" || true

echo "Container is ready; keeping process alive"
tail -f /dev/null &
wait $!

