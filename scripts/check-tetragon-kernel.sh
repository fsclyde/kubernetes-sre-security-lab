#!/usr/bin/env bash
set -euo pipefail

NODE="$(docker ps --filter 'name=agent-security-lab-control-plane' --format '{{.Names}}' | head -n 1)"
if [[ -z "$NODE" ]]; then
  echo "kind control-plane container is not running" >&2
  exit 1
fi

if docker exec "$NODE" sh -c 'test -r /sys/kernel/btf/vmlinux'; then
  echo "BTF is visible from the kind node. Tetragon may be installable; verify the Tetragon chart prerequisites next."
else
  echo "BTF is not visible from the kind node. Skip Tetragon here or use a Linux host/kernel that exposes BTF."
  exit 2
fi
