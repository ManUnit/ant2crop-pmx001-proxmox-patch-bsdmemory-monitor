# pve-bsdmem

**Your OPNsense / pfSense / FreeBSD VM shows 100% memory usage in Proxmox, and
it never goes down.** The guest says it is nearly idle. The graph is flat at
the full allocation, and the bar is red.

Nothing is wrong with the VM. Proxmox is showing you a host-side number because
the guest never tells it anything else. This repository explains exactly why,
and ships a working fix for the host side while the real fix is pending
upstream in FreeBSD.

> **Unofficial.** Not affiliated with, endorsed by, or supported by Proxmox
> Server Solutions GmbH. It modifies a file belonging to the `qemu-server`
> package on your node. Read [Caveats](#caveats) before installing.

---

## Why it happens

Proxmox derives a VM's memory usage from the virtio-balloon statistics
virtqueue, and nothing else. In `PVE/QemuServer.pm`, `vmstatus()` seeds the
value from the cgroup and lets the balloon callback override it:

```perl
$d->{mem} = $d->{memhost};   # default to cgroup, balloon info can override this below
...
if (defined($info->{total_mem}) && defined($info->{free_mem})) {
    $d->{mem} = $info->{total_mem} - $info->{free_mem};
    $d->{freemem} = $info->{free_mem};
}
```

FreeBSD's `vtballoon(4)` **attaches the balloon device but never negotiates
`VIRTIO_BALLOON_F_STATS_VQ`**, so `query-balloon` answers with nothing but
`actual` and `max_mem`. The `if` never fires. `mem` stays at the cgroup figure
— the whole allocation — forever.

Two guests on the same host make it obvious:

```
# Ubuntu 26.04, 5 GB assigned        -> Proxmox correctly shows 0.97 GiB
balloon: actual=5056 max_mem=5056 total_mem=4335 free_mem=3342 \
         mem_swapped_in=0 mem_swapped_out=0 major_page_faults=505 \
         minor_page_faults=1642810 last_update=1795323645

# OPNsense 26.7, 20 GB assigned      -> Proxmox shows 20.00 GiB, flat, forever
balloon: actual=20480 max_mem=20480
```

Meanwhile, inside that OPNsense guest:

```
Mem: 43M Active, 286M Inact, 520M Wired, 2056K Buf, 19G Free
ARC: 200M Total, 53M MFU, 109M MRU, 2655K Anon, 1550K Header, 33M Other
Swap: 8192M Total, 8192M Free
```

Under 1 GB in use out of 20 GB. The reported number is not a measurement at
all — sampling the RRD shows `mem` reading *exactly* `20.00 GiB` on every
sample, never varying by a decimal. It can even exceed 100% (we measured
100.23% of a 4 GiB VM), because the cgroup figure includes QEMU's own overhead.

## Three things that do *not* fix it

**Installing the QEMU guest agent.** This is the most repeated advice on
forums and it is wrong, at least through PVE 9.2:

```
$ grep -rn -i -e 'guest-get-memory' -e 'get_memory_info' \
      /usr/share/perl5/PVE/ /usr/share/pve-manager/
$
```

There is no agent-based memory path in Proxmox at all. The agent is still
needed *here* — but only as the transport this project uses, not as a fix.

**Ballooning.** The FreeBSD driver ignores inflate requests. Target set to
4096 MB on a 20 GB VM, sampled once a minute:

```
t1  actual=20478   VmRSS: 20948076 kB
t2  actual=20478   VmRSS: 20948076 kB
t3  actual=20478   VmRSS: 20950124 kB
t4  actual=20478   VmRSS: 20950124 kB
```

2 MB of movement in four minutes, and host RSS went *up*.

**Lowering the VM's memory.** Frees host RAM, which is worth doing on its own,
but the guest commits whatever it is given — so the bar returns to ~100% of the
smaller number. Worse, if you change memory *while testing a fix*, you can no
longer tell which change moved the graph.

## The real fix is upstream, and it is pending

[freebsd-src PR #2509 — *virtio_balloon: Add memory statistics queue
support*](https://github.com/freebsd/freebsd-src/pull/2509) implements exactly
the missing piece. It is **open, unmerged, and targets `main` only**, and
`virtio_balloon` is compiled into the kernel rather than built as a module — so
adopting it today means maintaining a custom OPNsense kernel across every
update. That trade is not worth it for a firewall.

See [`upstream/`](upstream/) for the reports and a patch proposed to Proxmox.

## What this does instead

```
FreeBSD guest ──(QEMU guest agent, guest-exec sysctl)──► pve-bsdmem (timer, 10s)
                                                               │
                                                               ▼
                                                   /run/pve-bsdmem/<vmid>
                                                   "<ts> <used> <free>"
                                                               │
                                        patched ballooncb() ───┘
                                                               ▼
                                                      Proxmox UI / RRD
```

`free` follows PR #2509's semantics: free + inactive pages, i.e. what the guest
can hand out without swapping.

**It fails safe.** Entries older than 60 s are ignored, so if the timer, the
agent, or the guest stops, Proxmox silently reverts to stock behaviour. The
patched branch is an `elsif` — when a guest *does* supply balloon stats,
nothing about the existing code path changes.

## Requirements

- Proxmox VE node (developed against `pve-manager 9.2.2`, `qemu-server 9.1.15`)
- In the guest: `pkg install -y os-qemu-guest-agent` and
  `sysrc qemu_guest_agent_enable=YES`
- `agent: 1` on the VM, which needs a cold boot for the virtio-serial port to
  appear — `setup-opnsense-vm.sh` does this

Nothing else. In particular **no `patch(1)`**: it is absent on a stock PVE node,
and a node on an isolated management segment has no route to `apt install` it.

## Install

```bash
./setup-opnsense-vm.sh 100     # enables the agent device, power-cycles the VM
./install.sh --check 100       # preflight only, changes nothing
./install.sh 100               # one or more VMIDs
```

Verify:

```bash
/usr/local/bin/pve-bsdmem && cat /run/pve-bsdmem/100
pvesh get /nodes/$(hostname)/qemu/100/status/current --output-format yaml | grep -e '^mem' -e '^maxmem'
```

`mem` should now track real guest usage instead of sitting at the allocation.
`memhost` keeps the host figure, and the difference between the two is how you
confirm the fix is what moved the number.

### Preflight / version check

```
pve-bsdmem 1.0.0 - preflight
  ok    running as root on a PVE node
  ok    python3, perl, systemctl, qm, pvesh present
  ok    pve-manager 9.2.2 (tested)
  ok    qemu-server 9.1.15 (tested)
  anchor:  found (1 occurrence)
  ok    patch anchor present
  ok    VM 100 guest agent responds
preflight clean.
```

Version strings are **advisory** — a mismatch warns and can be overridden with
`--force`. What actually decides compatibility is the **patch anchor**: if
`ballooncb()` no longer contains the expected balloon-stats branch, the install
aborts and nothing is modified. `pve-bsdmem-apply --probe` runs that test alone.

## Uninstall

```bash
./uninstall.sh
```

Restores `QemuServer.pm` from the backup taken at install time (verified
byte-identical with `cmp`).

## Surviving upgrades

`qemu-server` upgrades overwrite `QemuServer.pm`.
`/etc/apt/apt.conf.d/99-pve-bsdmem` runs `pve-bsdmem-reapply` after every dpkg
run, which re-applies the edit and restarts the daemons. If upstream ever
changes that branch, the applier **refuses to edit** and says so rather than
guessing — Proxmox simply goes back to stock behaviour until the patch is
refreshed.

## Gotcha: three daemons cache the module

`pvestatd`, `pvedaemon` and `pveproxy` each load `QemuServer.pm` once at
startup, and they feed different parts of the UI:

| daemon | feeds | symptom if not restarted |
|---|---|---|
| `pvestatd` | RRD / the graphs | graph keeps showing the full allocation |
| `pvedaemon` | `status/current` → VM **Summary** panel | Summary still red at ~100% |
| `pveproxy` | HTTP front end | serves the stale answer |

Restarting only `pvestatd` produces a confusing half-fixed state: the graph
reads correctly while the Summary row above it still says 100%. `install.sh`
restarts all three.

## Caveats

- **It modifies a packaged file.** Reversible, re-applied automatically, and it
  refuses to run blind — but it is still a local modification to Proxmox.
  If you report an unrelated bug to Proxmox, uninstall first.
- Values refresh every 10 s, so the graph is a little coarser than a native
  balloon feed would be.
- Per-node: install on each node a FreeBSD guest may run on.
- Young code. Treat it accordingly.
- **If PR #2509 lands and reaches your guest OS, remove this.** The guest will
  then report natively and none of this is needed.

## Building a release

```bash
./build.sh      # -> dist/pve-bsdmem-<version>.tar.gz + .sha256
```

Refuses to pack unless every file is present, shell and python syntax check
out, both scripts report the version in `VERSION`, and `CHANGELOG.md` has an
entry for it.

## Files

| file | purpose |
|---|---|
| `qemuserver-bsdmem.patch` | the change as a readable unified diff |
| `pve-bsdmem-apply` | applies/reverts without `patch(1)`; idempotent, anchored, backs up |
| `pve-bsdmem` | queries the guest over the agent, writes `/run/pve-bsdmem/<vmid>` |
| `pve-bsdmem.service` / `.timer` | runs the helper every 10 s |
| `pve-bsdmem-reapply` + `99-pve-bsdmem` | re-apply after `qemu-server` upgrades |
| `setup-opnsense-vm.sh` | enables the agent device, power-cycles the VM |
| `install.sh` / `uninstall.sh` / `build.sh` | wire up / tear down / package |
| `upstream/` | bug reports and the patch proposed to Proxmox |

## License

AGPL-3.0-or-later. `qemuserver-bsdmem.patch` contains context lines from
Proxmox VE's `QemuServer.pm`, which is AGPLv3.
