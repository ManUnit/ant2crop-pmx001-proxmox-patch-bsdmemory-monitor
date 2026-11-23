# Changelog

## 1.0.0 — 2026-11-22

First release.

Makes Proxmox report the real memory usage of FreeBSD-based guests
(OPNsense/pfSense) instead of pinning them at ~100%.

- `qemuserver-bsdmem.patch` / `pve-bsdmem-apply` — adds an `elsif` fallback to
  `ballooncb()` in `QemuServer.pm` that reads guest-pushed stats when the guest
  provides no balloon stats virtqueue. Applied without `patch(1)`; idempotent,
  anchored, backs up, and refuses to edit if upstream changed that branch.
- `pve-bsdmem` — queries the guest over the QEMU guest agent and publishes
  `/run/pve-bsdmem/<vmid>`. Entries older than 60 s are ignored, so a failure
  silently reverts PVE to stock behaviour.
- `pve-bsdmem.timer` — refreshes every 10 s.
- `pve-bsdmem-reapply` + `99-pve-bsdmem` — re-applies after `qemu-server`
  package upgrades.
- `setup-opnsense-vm.sh` — enables the guest agent device and power-cycles the
  VM. Memory resizing is an explicitly optional second argument and is
  unrelated to the reporting fix.
- `install.sh --check` — preflight: root, PVE node, required binaries,
  pve-manager/qemu-server versions, patch anchor, guest agent reachability.
  Version mismatches warn; a missing anchor is fatal.

Tested against pve-manager 9.2.2 / qemu-server 9.1.15, guest OPNsense 26.7
(FreeBSD 15.1-RELEASE-p1).

### Notes

- Restarting only `pvestatd` after patching leaves a confusing half-fixed
  state: the RRD graph reads correctly while the VM Summary panel still shows
  ~100%, because `pvedaemon` serves `status/current` and caches the module
  separately. All three of `pvestatd`, `pvedaemon` and `pveproxy` are
  restarted.
- The upstream fix is [freebsd-src PR #2509](https://github.com/freebsd/freebsd-src/pull/2509),
  still open. If it lands and reaches OPNsense, remove this.
