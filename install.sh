#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Install the pve-bsdmem memory-reporting fallback on a Proxmox VE node.
#
#   ./install.sh [--check] [--force] <vmid> [<vmid> ...]
#
#   --check   run the preflight checks only, change nothing
#   --force   install even if a compatibility check warns
#
# Needs nothing but python3 + perl, both already present on a PVE node -
# deliberately no patch(1), since an isolated mgmt segment has no way to
# apt-install it.
set -euo pipefail

TARGET=/usr/share/perl5/PVE/QemuServer.pm
SRC="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"

# versions this release was developed and tested against
TESTED_PVE=9.2.2
TESTED_QEMU_SERVER=9.1.15

CHECK_ONLY=0
FORCE=0
VMIDS=()
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *[!0-9]*) echo "error: unexpected argument '$arg'" >&2; exit 1 ;;
        *) VMIDS+=("$arg") ;;
    esac
done

warn()  { echo "  WARN  $*" >&2; WARNINGS=$((WARNINGS + 1)); }
ok()    { echo "  ok    $*"; }
fatal() { echo "  FAIL  $*" >&2; exit 1; }
WARNINGS=0

echo "pve-bsdmem $VERSION - preflight"

# --- environment -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fatal "must run as root"
[ -d /etc/pve ]      || fatal "/etc/pve missing - this is not a PVE node"
[ -f "$TARGET" ]     || fatal "$TARGET not found"
ok "running as root on a PVE node"

for bin in python3 perl systemctl qm pvesh; do
    command -v "$bin" >/dev/null || fatal "required command not found: $bin"
done
ok "python3, perl, systemctl, qm, pvesh present"

# --- version checks --------------------------------------------------------
PVE_VER="$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([^/]*\)/.*|\1|p')"
QS_VER="$(dpkg-query -W -f='${Version}' qemu-server 2>/dev/null || true)"

if [ -z "$PVE_VER" ]; then
    warn "could not determine pve-manager version"
elif [ "$PVE_VER" = "$TESTED_PVE" ]; then
    ok "pve-manager $PVE_VER (tested)"
else
    warn "pve-manager $PVE_VER differs from tested $TESTED_PVE"
fi

if [ -z "$QS_VER" ]; then
    warn "could not determine qemu-server version"
elif [ "$QS_VER" = "$TESTED_QEMU_SERVER" ]; then
    ok "qemu-server $QS_VER (tested)"
else
    warn "qemu-server $QS_VER differs from tested $TESTED_QEMU_SERVER"
fi

# --- the check that actually matters --------------------------------------
# Version strings are advisory; the anchor is the real compatibility signal.
if ! "$SRC/pve-bsdmem-apply" --probe "$TARGET" | sed 's/^/  /'; then
    fatal "ballooncb() in $TARGET no longer matches this release"
fi
ok "patch anchor present"

# --- already installed? ----------------------------------------------------
INSTALLED="$(cat /usr/local/share/pve-bsdmem/VERSION 2>/dev/null || true)"
if [ -n "$INSTALLED" ]; then
    if [ "$INSTALLED" = "$VERSION" ]; then
        ok "pve-bsdmem $INSTALLED already installed (will refresh)"
    else
        ok "upgrading pve-bsdmem $INSTALLED -> $VERSION"
    fi
fi

# --- guest agent reachability ---------------------------------------------
for vmid in "${VMIDS[@]:-}"; do
    [ -n "$vmid" ] || continue
    if ! qm status "$vmid" >/dev/null 2>&1; then
        warn "VM $vmid does not exist"
    elif qm guest cmd "$vmid" ping >/dev/null 2>&1; then
        ok "VM $vmid guest agent responds"
    else
        warn "VM $vmid guest agent not answering - run setup-opnsense-vm.sh $vmid first"
    fi
done

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "$WARNINGS warning(s)."
    if [ "$CHECK_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
        echo "Re-run with --force to install anyway." >&2
        exit 1
    fi
else
    echo "preflight clean."
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi
if [ "${#VMIDS[@]}" -eq 0 ]; then
    echo "error: no VMIDs given" >&2
    exit 1
fi

# --- install ---------------------------------------------------------------
echo
echo "==> installing helper, applier and units"
install -m 0755 "$SRC/pve-bsdmem"          /usr/local/bin/pve-bsdmem
install -m 0755 "$SRC/pve-bsdmem-apply"    /usr/local/sbin/pve-bsdmem-apply
install -m 0755 "$SRC/pve-bsdmem-reapply"  /usr/local/sbin/pve-bsdmem-reapply
install -d -m 0755 /usr/local/share/pve-bsdmem
install -m 0644 "$SRC/VERSION"                 /usr/local/share/pve-bsdmem/
install -m 0644 "$SRC/qemuserver-bsdmem.patch" /usr/local/share/pve-bsdmem/
install -m 0644 "$SRC/pve-bsdmem.service"  /etc/systemd/system/
install -m 0644 "$SRC/pve-bsdmem.timer"    /etc/systemd/system/
install -m 0644 "$SRC/99-pve-bsdmem"       /etc/apt/apt.conf.d/

echo "==> writing /etc/pve-bsdmem.conf"
{
    echo "# VMIDs whose guest has no balloon stats virtqueue (FreeBSD/OPNsense)"
    echo "# written by pve-bsdmem $VERSION"
    printf '%s\n' "${VMIDS[@]}"
} > /etc/pve-bsdmem.conf

echo "==> patching $TARGET"
/usr/local/sbin/pve-bsdmem-apply "$TARGET"

echo "==> enabling timer"
systemctl daemon-reload
systemctl enable --now pve-bsdmem.timer

# All three load QemuServer.pm once at startup and must pick up the patched
# copy.  pvestatd feeds the RRD graphs, pvedaemon serves status/current (the
# VM Summary panel), pveproxy fronts it.  Restarting only pvestatd leaves the
# Summary showing the old, unpatched value while the graph is already correct.
echo "==> restarting PVE daemons"
systemctl restart pvestatd pvedaemon pveproxy

echo
echo "pve-bsdmem $VERSION installed for VM(s): ${VMIDS[*]}"
echo "verify with:"
echo "  /usr/local/bin/pve-bsdmem && cat /run/pve-bsdmem/${VMIDS[0]}"
echo "  pvesh get /nodes/\$(hostname)/qemu/${VMIDS[0]}/status/current --output-format yaml | grep -e '^mem' -e '^maxmem'"
