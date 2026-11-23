#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Prepare a FreeBSD-based VM (OPNsense/pfSense) for pve-bsdmem.
#
#   ./setup-opnsense-vm.sh <vmid> [memory_mb]
#
# Enables the QEMU guest agent device, which is what pve-bsdmem reads real
# memory usage through. The virtio-serial port only appears on a cold boot,
# so this POWER CYCLES the VM. For a firewall that means a short outage; run
# it in a window where that is acceptable.
#
# memory_mb is OPTIONAL and has nothing to do with the reporting fix - it just
# changes the VM's allocation. Leave it off unless you specifically want to
# resize. The graph is corrected by the patch, not by shrinking the VM.
#
# Prerequisite inside the guest (do this first, it needs no reboot):
#   pkg install -y os-qemu-guest-agent
#   sysrc qemu_guest_agent_enable=YES
set -euo pipefail

VMID="${1:?usage: $0 <vmid> [memory_mb]}"
MEMORY="${2:-}"

qm status "$VMID" >/dev/null

echo "==> current config"
grep -e '^agent' -e '^memory' "/etc/pve/qemu-server/$VMID.conf" || true

ARGS=(-agent 1)
if [ -n "$MEMORY" ]; then
    # optional and unrelated to the memory-reporting fix - only pass this if
    # you actually want to change what the VM is allocated
    ARGS+=(-memory "$MEMORY")
fi

echo "==> qm set $VMID ${ARGS[*]}"
qm set "$VMID" "${ARGS[@]}"

echo "==> shutting down (ACPI, 90s grace)"
if ! qm shutdown "$VMID" --timeout 90; then
    echo "    ACPI shutdown failed or timed out; forcing stop"
    qm stop "$VMID"
fi

# qm shutdown can return before the process is really gone
for _ in $(seq 1 30); do
    [ "$(qm status "$VMID")" = "status: stopped" ] && break
    sleep 2
done

echo "==> starting"
qm start "$VMID"

echo "==> waiting for guest agent (up to 180s)"
for _ in $(seq 1 60); do
    if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
        echo "    agent is up"
        qm guest cmd "$VMID" get-osinfo || true
        exit 0
    fi
    sleep 3
done

echo "    WARNING: agent did not come up." >&2
echo "    Check inside the guest: service qemu-guest-agent status" >&2
echo "    and that /dev/vtcon* exists (virtio-serial port present)." >&2
exit 1
