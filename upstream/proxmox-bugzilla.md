# Draft report for bugzilla.proxmox.com

**Product:** Proxmox VE
**Component:** qemu-server (UI side also affects pve-manager)
**Severity:** minor / enhancement
**Version:** 9.2.2

---

## Summary

VM memory usage is reported from the cgroup when the guest provides no balloon
statistics, is presented as if it were guest memory usage, and can exceed 100%

## Description

When a guest's virtio-balloon driver does not negotiate
`VIRTIO_BALLOON_F_STATS_VQ`, `query-balloon` returns only `actual` and
`max_mem`. `PVE/QemuServer.pm::vmstatus()` then keeps its cgroup-derived
default:

```perl
$d->{mem} = $d->{memhost};   # default to cgroup, balloon info can override this below
...
if (defined($info->{total_mem}) && defined($info->{free_mem})) {
    $d->{mem} = $info->{total_mem} - $info->{free_mem};
    $d->{freemem} = $info->{free_mem};
}
```

`$d->{mem}` is then rendered by the VM Summary panel as "Memory usage" against
`maxmem`, with `criticalThreshold: 0.975`. The result for such guests is a
permanently red bar at ~100%, and because the cgroup figure includes QEMU's own
overhead it can read **above** 100% — which is not a meaningful statement about
a guest's memory usage.

This is not a hypothetical: it affects every FreeBSD-based guest, which
includes OPNsense and pfSense, and is a recurring question on the forum
(e.g. "Memory usage wrong on FreeBSD guests - 9.0.3", "FreeBSD Guest - wrong
ram usage").

To be clear, PVE is doing the only thing it can with the data available — the
missing statistics are the guest driver's doing (see *Upstream* below). The bug
being reported is narrower: **a host-side estimate is displayed as though it
were a guest-side measurement, with no indication of the difference, and is
escalated to a critical warning.**

## Steps to reproduce

1. Create a VM and install OPNsense 26.7 (FreeBSD 15.1-RELEASE-p1) or any
   recent FreeBSD. Assign, say, 20 GB RAM.
2. Leave it idle.
3. Observe the VM Summary panel.

## Actual result

```
Memory usage        100.05% (20.01 GiB of 20.00 GiB)     [red]
Host memory usage   20.01 GiB
```

Flat at exactly `20.00 GiB` on every RRD sample, never varying by a decimal.

Inside the guest at the same moment:

```
Mem: 43M Active, 286M Inact, 520M Wired, 2056K Buf, 19G Free
ARC: 200M Total, 53M MFU, 109M MRU, 2655K Anon, 1550K Header, 33M Other
Swap: 8192M Total, 8192M Free
```

Under 1 GB actually in use.

## Expected result

Either a real guest figure, or a clearly-labelled host-side figure that is not
flagged critical.

## Evidence that the guest is the source of the gap

Two guests on the same host, via QMP `query-balloon`:

```
# Ubuntu 26.04, 5 GB assigned  -> PVE correctly shows 0.97 GiB
balloon: actual=5056 max_mem=5056 total_mem=4335 free_mem=3342 \
         mem_swapped_in=0 mem_swapped_out=0 major_page_faults=505 \
         minor_page_faults=1642810 last_update=1795323645

# OPNsense 26.7, 20 GB assigned -> PVE shows 20.00 GiB
balloon: actual=20480 max_mem=20480
```

`vtballoon0` does attach in the FreeBSD guest; it simply never implements the
stats virtqueue.

Ballooning is not a workaround either — the driver ignores inflate requests.
Target set to 4096 MB, sampled once a minute:

```
t1  actual=20478   VmRSS: 20948076 kB
t2  actual=20478   VmRSS: 20948076 kB
t3  actual=20478   VmRSS: 20950124 kB
t4  actual=20478   VmRSS: 20950124 kB
```

2 MB of movement in four minutes, with host RSS slightly increasing.

## Suggested fix

**(a) Minimal, and the actual ask here.** Mark the value as a fallback so the
API and UI can tell the two apart, and so the UI can avoid flagging a host-side
estimate as critical guest memory pressure. A patch doing the `qemu-server`
half is attached; the `pve-manager` side would be a follow-up.

**(b) Optional, larger.** When balloon stats are unavailable and the guest
agent is enabled, source the figure from the agent instead. Note this needs
caching/asynchrony — `pvestatd` polls every 10s across all guests and must not
block on a `guest-exec` round trip. We implemented this out-of-tree as a
proof of concept and it does produce correct values (424 MiB vs the 4.01 GiB
the cgroup reports for the same VM), but the design is not upstream-shaped and
is offered only as evidence that the approach works.

A note for anyone searching: installing `qemu-guest-agent` does **not** fix the
reporting on its own, contrary to widespread forum advice —
`grep -rn 'guest-get-memory' /usr/share/perl5/PVE/` returns nothing on 9.2,
i.e. there is no agent-based memory path today.

## Upstream

The root cause has an open fix in FreeBSD:
https://github.com/freebsd/freebsd-src/pull/2509 — *virtio_balloon: Add memory
statistics queue support*. It is unmerged and targets `main` only, so even
once it lands it will take a long time to reach OPNsense/pfSense releases.
Something on the PVE side to avoid showing a misleading critical warning in the
meantime still seems worthwhile.

## Environment

- `pve-manager/9.2.2`, `qemu-server 9.1.15`
- Guest: OPNsense 26.7, `FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709`
