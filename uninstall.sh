#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Remove pve-bsdmem and restore the stock QemuServer.pm.
set -euo pipefail
TARGET=/usr/share/perl5/PVE/QemuServer.pm

systemctl disable --now pve-bsdmem.timer 2>/dev/null || true

if [ -x /usr/local/sbin/pve-bsdmem-apply ]; then
    /usr/local/sbin/pve-bsdmem-apply --revert "$TARGET"
elif grep -q 'pve-bsdmem' "$TARGET"; then
    echo "WARNING: applier gone and $TARGET is still patched." >&2
    echo "         run: apt install --reinstall qemu-server" >&2
fi

rm -f /etc/systemd/system/pve-bsdmem.service /etc/systemd/system/pve-bsdmem.timer
rm -f /etc/apt/apt.conf.d/99-pve-bsdmem
rm -f /usr/local/bin/pve-bsdmem
rm -f /usr/local/sbin/pve-bsdmem-apply /usr/local/sbin/pve-bsdmem-reapply
rm -rf /usr/local/share/pve-bsdmem /run/pve-bsdmem
rm -f /etc/pve-bsdmem.conf

systemctl daemon-reload
systemctl restart pvestatd pvedaemon pveproxy
echo done.
