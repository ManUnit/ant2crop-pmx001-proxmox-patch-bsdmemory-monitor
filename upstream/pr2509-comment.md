# Draft comment for freebsd-src PR #2509

Paste into https://github.com/freebsd/freebsd-src/pull/2509

---

Real-world data point in support of this PR, with a side-by-side measurement
that isolates the missing stats virtqueue as the cause.

**Host:** Proxmox VE 9.2.2 (`pve-manager/9.2.2`, `qemu-server 9.1.15`)
**Guest:** OPNsense 26.7 — `FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709`

`vtballoon0` attaches fine:

```
virtio_pci0: <VirtIO PCI (legacy) Balloon adapter> at device 3.0 on pci0
vtballoon0: <VirtIO Balloon Adapter> on virtio_pci0
```

Two guests on the same host, queried through QMP `query-balloon`:

```
# Ubuntu 26.04 guest, 5 GB assigned
balloon: actual=5056 max_mem=5056 total_mem=4335 free_mem=3342 \
         mem_swapped_in=0 mem_swapped_out=0 major_page_faults=505 \
         minor_page_faults=1642810 last_update=1795323645

# OPNsense 26.7 guest, 20 GB assigned
balloon: actual=20480 max_mem=20480
```

No `total_mem`, no `free_mem`, no `last_update` from the FreeBSD guest.

## Why that is user-visible

Proxmox only overrides its cgroup-derived figure when the stats are present
(`PVE/QemuServer.pm`, `vmstatus()`):

```perl
$d->{mem} = $d->{memhost};   # default to cgroup, balloon info can override this below
...
if (defined($info->{total_mem}) && defined($info->{free_mem})) {
    $d->{mem} = $info->{total_mem} - $info->{free_mem};
    $d->{freemem} = $info->{free_mem};
}
```

With the stats absent the `if` never fires, so the VM is reported as using its
entire allocation, forever. The Ubuntu guest above was correctly shown at
0.97 GiB; the OPNsense guest sat at a flat **100.05% (20.01 GiB of 20.00 GiB)**
— slightly over 100%, because the cgroup figure includes QEMU's own overhead —
and was flagged critical in the UI.

Meanwhile the guest itself was almost idle:

```
Mem: 43M Active, 286M Inact, 520M Wired, 2056K Buf, 19G Free
ARC: 200M Total, 53M MFU, 109M MRU, 2655K Anon, 1550K Header, 33M Other
Swap: 8192M Total, 8192M Free
```

Sampling Proxmox's RRD confirmed it is not a transient: `mem` read exactly
`20.00 GiB` on every single sample, never varying by even a decimal — the
signature of a value that is reported rather than measured.

## Inflate does not help either

Worth noting for anyone who lands here looking for a workaround: asking the
guest to inflate is also ineffective on FreeBSD. Target set to 4096 MB via the
QEMU monitor, then sampled once a minute:

```
t1  actual=20478   VmRSS: 20948076 kB
t2  actual=20478   VmRSS: 20948076 kB
t3  actual=20478   VmRSS: 20950124 kB
t4  actual=20478   VmRSS: 20950124 kB
```

`actual` moved 2 MB in four minutes and host RSS went slightly *up*. So the
balloon device is attached but effectively inert in both directions, and this
PR's stats queue is the only mechanism that would let the hypervisor see the
truth.

## Workaround in the meantime

For anyone blocked on this: installing `os-qemu-guest-agent` does **not** fix
the reporting, contrary to a lot of forum advice — PVE 9.2 has no
agent-based memory path at all (`grep -rn 'guest-get-memory'
/usr/share/perl5/PVE/` returns nothing). We ended up patching the host to read
stats pushed out of the guest over the agent instead. That is obviously a
local hack; this PR is the right fix.

Happy to test a build if that is useful.
