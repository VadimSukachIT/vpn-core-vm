#!/usr/bin/env python3
import ipaddress
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_env_file(path: Path) -> Dict[str, str]:
    if not path.is_file():
        fail(f"Runtime env file not found: {path}")

    env: Dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"Invalid runtime env line {line_number}: {raw_line}")

        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            fail(f"Empty env key at line {line_number}")
        env[key] = value.strip()

    return env


def getenv(env: Dict[str, str], key: str, default: Optional[str] = None) -> str:
    return os.environ.get(key, env.get(key, default if default is not None else ""))


def require_non_empty(value: str, key: str) -> str:
    if not value:
        fail(f"Required setting is missing: {key}")
    return value


def run_command(argv: List[str], stdin_text: Optional[str] = None) -> str:
    result = subprocess.run(
        argv,
        input=stdin_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail(result.stderr.strip() or f"Command failed: {' '.join(argv)}")
    return result.stdout.strip()


def generate_private_key() -> str:
    return run_command(["wg", "genkey"])


def generate_public_key(private_key: str) -> str:
    return run_command(["wg", "pubkey"], stdin_text=f"{private_key}\n")


def detect_default_interface() -> str:
    routes_output = run_command(["ip", "-o", "route", "show", "default"])
    for line in routes_output.splitlines():
        parts = line.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    fail("Could not detect default network interface for WireGuard masquerade")


def main() -> None:
    runtime_env_path = Path(
        os.environ.get("RUNTIME_ENV_PATH", "/opt/vpn-core-vm/runtime.env")
    )
    generated_dir = Path(
        os.environ.get("GENERATED_DIR", "/opt/vpn-core-vm/generated")
    )
    wg_config_path = Path(
        os.environ.get("WG_CONFIG_PATH", str(generated_dir / "wg0.conf"))
    )
    peers_json_path = Path(
        os.environ.get("PEERS_JSON_PATH", str(generated_dir / "peers.json"))
    )
    server_private_key_path = Path(
        os.environ.get(
            "SERVER_PRIVATE_KEY_PATH", str(generated_dir / "server-private.key")
        )
    )
    server_public_key_path = Path(
        os.environ.get(
            "SERVER_PUBLIC_KEY_PATH", str(generated_dir / "server-public.key")
        )
    )

    env = load_env_file(runtime_env_path)

    wg_interface = getenv(env, "WG_INTERFACE", "wg0")
    wg_address = getenv(env, "WG_ADDRESS", "10.8.0.1/22")
    wg_network = getenv(env, "WG_NETWORK", "10.8.0.0/22")
    wg_listen_port = int(getenv(env, "WG_LISTEN_PORT", "51820"))
    wg_masquerade_interface = getenv(env, "WG_MASQUERADE_INTERFACE")
    if not wg_masquerade_interface:
        wg_masquerade_interface = detect_default_interface()
    wg_peer_count = int(getenv(env, "WG_PEER_COUNT", "1000"))
    wg_endpoint = require_non_empty(getenv(env, "WG_ENDPOINT"), "WG_ENDPOINT")
    wg_client_dns = getenv(env, "WG_CLIENT_DNS", "1.1.1.1,1.0.0.1")
    wg_allowed_ips = getenv(env, "WG_ALLOWED_IPS", "0.0.0.0/0,::/0")
    wg_persistent_keepalive = int(getenv(env, "WG_PERSISTENT_KEEPALIVE", "25"))
    wg_peer_status = getenv(env, "WG_PEER_STATUS", "")

    if wg_peer_count <= 0:
        fail("WG_PEER_COUNT must be greater than zero")

    network = ipaddress.ip_network(wg_network, strict=True)
    server_interface = ipaddress.ip_interface(wg_address)

    if server_interface.version != 4 or network.version != 4:
        fail("Only IPv4 WireGuard networks are supported")
    if server_interface.ip not in network:
        fail("WG_ADDRESS must belong to WG_NETWORK")

    available_peer_ips = [
        ip for ip in network.hosts() if ip != server_interface.ip
    ]
    if len(available_peer_ips) < wg_peer_count:
        fail(
            "WG_NETWORK does not have enough addresses for WG_PEER_COUNT "
            f"({wg_peer_count} peers requested, {len(available_peer_ips)} available)"
        )

    generated_dir.mkdir(parents=True, exist_ok=True)

    server_private_key = generate_private_key()
    server_public_key = generate_public_key(server_private_key)

    server_private_key_path.write_text(f"{server_private_key}\n")
    server_private_key_path.chmod(0o600)
    server_public_key_path.write_text(f"{server_public_key}\n")
    server_public_key_path.chmod(0o600)

    wg_lines = [
        "[Interface]",
        f"Address = {wg_address}",
        f"ListenPort = {wg_listen_port}",
        f"PrivateKey = {server_private_key}",
        "SaveConfig = false",
        (
            "PostUp = "
            f"iptables -C FORWARD -i {wg_interface} -j ACCEPT || "
            f"iptables -A FORWARD -i {wg_interface} -j ACCEPT; "
            f"iptables -C FORWARD -o {wg_interface} -j ACCEPT || "
            f"iptables -A FORWARD -o {wg_interface} -j ACCEPT; "
            f"iptables -t nat -C POSTROUTING -s {wg_network} "
            f"-o {wg_masquerade_interface} -j MASQUERADE || "
            f"iptables -t nat -A POSTROUTING -s {wg_network} "
            f"-o {wg_masquerade_interface} -j MASQUERADE"
        ),
        (
            "PostDown = "
            f"iptables -C FORWARD -i {wg_interface} -j ACCEPT && "
            f"iptables -D FORWARD -i {wg_interface} -j ACCEPT; "
            f"iptables -C FORWARD -o {wg_interface} -j ACCEPT && "
            f"iptables -D FORWARD -o {wg_interface} -j ACCEPT; "
            f"iptables -t nat -C POSTROUTING -s {wg_network} "
            f"-o {wg_masquerade_interface} -j MASQUERADE && "
            f"iptables -t nat -D POSTROUTING -s {wg_network} "
            f"-o {wg_masquerade_interface} -j MASQUERADE"
        ),
    ]

    peers: List[Dict[str, str]] = []
    for peer_ip in available_peer_ips[:wg_peer_count]:
        peer_private_key = generate_private_key()
        peer_public_key = generate_public_key(peer_private_key)
        peer_ip_cidr = f"{peer_ip}/{network.prefixlen}"

        peer_config = "\n".join(
            [
                "[Interface]",
                f"PrivateKey = {peer_private_key}",
                f"Address = {peer_ip_cidr}",
                f"DNS = {wg_client_dns}",
                "",
                "[Peer]",
                f"PublicKey = {server_public_key}",
                f"AllowedIPs = {wg_allowed_ips}",
                f"Endpoint = {wg_endpoint}:{wg_listen_port}",
                f"PersistentKeepalive = {wg_persistent_keepalive}",
                "",
            ]
        )

        peer_item: Dict[str, str] = {
            "publicKey": peer_public_key,
            "privateKey": peer_private_key,
            "ip": peer_ip_cidr,
            "config": peer_config,
        }
        if wg_peer_status:
            peer_item["status"] = wg_peer_status
        peers.append(peer_item)

        wg_lines.extend(
            [
                "",
                "[Peer]",
                f"PublicKey = {peer_public_key}",
                f"AllowedIPs = {peer_ip}/32",
            ]
        )

    wg_config_path.write_text("\n".join(wg_lines) + "\n")
    wg_config_path.chmod(0o600)
    peers_json_path.write_text(json.dumps(peers, indent=2) + "\n")
    peers_json_path.chmod(0o600)


if __name__ == "__main__":
    main()
