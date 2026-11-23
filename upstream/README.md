# Upstream reports

Material prepared for reporting this properly, rather than only working around
it locally.

| file | where it goes |
|---|---|
| `pr2509-comment.md` | a comment on [freebsd-src PR #2509](https://github.com/freebsd/freebsd-src/pull/2509) — the root cause, and where the real fix lives |
| `proxmox-bugzilla.md` | a report for [bugzilla.proxmox.com](https://bugzilla.proxmox.com) — a host-side estimate being displayed as a guest measurement, and escalated to critical |
| `0001-vmstatus-flag-host-side-memory-fallback.patch` | the patch that accompanies the Proxmox report |

## On the Proxmox patch

The patch in the repository root (`qemuserver-bsdmem.patch`) is **not** what is
proposed upstream, and should not be. It reads a file written by an
out-of-tree helper; Proxmox would rightly not merge that.

`0001-vmstatus-flag-host-side-memory-fallback.patch` is the upstream-shaped
change instead: when balloon stats are unavailable, record that `mem` is a
host-side fallback so the API and UI can stop presenting it as a guest
measurement and stop flagging it critical. It adds a field and sets it on a
path that was already falling back — no existing behaviour changes. Verified
with `perl -c` against `qemu-server 9.1.15`; it must be rebased onto current
master before sending.

## Before sending to Proxmox

Patches go to `pve-devel@lists.proxmox.com`, must apply cleanly to master,
carry a `Signed-off-by:` line, and are only accepted from contributors who
have signed Proxmox's **Harmony CLA**. See
[Developer Documentation](https://pve.proxmox.com/wiki/Developer_Documentation).

Replace the placeholder author and date in the patch header before sending.

## Expect pushback

The honest likelihood is that Proxmox answers "fix the guest driver", and they
would not be wrong — PVE cannot invent data the guest never sends. The
narrower point stands on its own though: a number that can read 100.23% of a
VM's own allocation is not guest memory usage, and should not be rendered as a
critical warning. That is the part worth arguing.
