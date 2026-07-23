# xfstests-zfs-runner

Run the fstests (xfstests) `clone` (reflink), `dedupe`, and `fiemap` groups
against OpenZFS the way zfs-qemu runs ZTS: **set up -> run -> summarize**, with
**all tests enabled** and known failures tracked against a documented,
per-topology baseline instead of being silently skipped.

A run is "green" only when the failing set for each topology matches its
baseline. A **new** failure is a regression; a baseline test that starts
**passing** is surfaced so the baseline can be tightened; **self-skips**
(not-run) are shown with their reasons.

## Committable before the features land

The reflink/dedupe/fiemap tests gate on the feature being present
(`_require_fiemap`, `_require_dedupe`, ...). On a ZFS without FIEMAP or
FIDEDUPERANGE they **notrun**, not fail -- verified: on stock master the whole
fiemap group reports "Passed all 56 tests" (all skipped). So this harness can
be committed upstream now and stays green; it activates progressively as
FIEMAP and FIDEDUPERANGE land, each captured in its baseline at that point.
The `clone` group already runs on stock ZFS (block cloning has been upstream
since 2.2), so that group's baseline plus the generic/733 safety-skip apply
from day one.

## Topology matrix

`TOPOLOGIES` (default `single-a12 single-a9 stripe3 raidz1`):

| name | vdev layout | why |
|---|---|---|
| `single-a12` | 1 disk, ashift=12 | contiguous baseline (4K); where FIEMAP edge cases surface |
| `single-a9`  | 1 disk, ashift=9  | contiguous baseline (512b) |
| `stripe3`    | 3 disks           | cross-vdev allocation, FIEMAP vdev-fold |
| `raidz1`     | raidz1 over 4     | parity-striped physical layout |

No mirror: its redundancy is internal to the vdev, so every block still has one
DVA and FIEMAP/BRT behave exactly as single-disk. Multiple-DVA coverage comes
from the `copies=N` property, exercised by the `fiemap_copies` test on any
topology. ashift needs no extra disks -- it is forced with `zpool create -o
ashift`, so `single-a12` and `single-a9` reuse the same disks.

## Disks

5 block devices: `DISKS[0]` is the persistent TEST pool, `DISKS[1..4]` the
scratch pool (up to 4, for raidz1). 10G each is ample (the largest single
allocation in these groups is generic/679's ~600MB fallocate). File-backed
virtio disks are fine -- ZFS sees them as ordinary vdevs; nothing here needs
real hardware. If `DISKS` is unset the runner makes 5 loop-backed files under
`$SCRATCHROOT` (that is how the CI step runs, needing no extra disks).

## Layout

| file | purpose |
|---|---|
| `setup.sh` | install fstests deps, fetch/build/install implr xfstests, apply topology patch, make users |
| `run-xfstests.sh` | run the groups across the topology matrix; one check log per topology |
| `xfstests-report.sh` | diff logs vs per-topology baselines; print PASS / new-FAIL / known-FAIL / skip |
| `topology.patch` | one-line implr/xfstests patch: honor `ZFS_SCRATCH_VDEV` for the scratch layout |
| `unsafe-excludes.txt` | tests that panic/hang, `-E`-excluded and reported as skipped (generic/733) |
| `baseline/<topology>.txt` | per-topology expected-failure list, with a category + reason per entry |
| `qemu-6-xfstests.sh` | zfs-qemu "Run tests" step (drop-in for qemu-6-tests.sh) |
| `zfs-qemu-xfstests.yml` | the workflow: qemu-1..5 reused verbatim, test step swapped |

## Usage (standalone)

```
sudo ./setup.sh                 # once: build fstests + patch + users
sudo DISKS="/dev/vdc /dev/vdd /dev/vde /dev/vdf /dev/vdg" ./run-xfstests.sh
sudo ./xfstests-report.sh baseline unsafe-excludes.txt \
    single-a12=/mnt/repro/xfstests-results/single-a12.log \
    single-a9=/mnt/repro/xfstests-results/single-a9.log \
    stripe3=/mnt/repro/xfstests-results/stripe3.log \
    raidz1=/mnt/repro/xfstests-results/raidz1.log
```

Seed/refresh a baseline from a run (review before trusting):

```
for t in single-a12 single-a9 stripe3 raidz1; do
  sed -n 's/^Failures: //p' /mnt/repro/xfstests-results/$t.log \
    | tr ' ' '\n' | sed '/^$/d' > baseline/$t.txt
done
```

## Known-failure categories

Each baseline entry is annotated so the list stays auditable:

- `zfs-semantics` -- ZFS legitimately cannot pass (no unwritten/preallocated
  extents, whole-record clone granularity). Permanent.
- `fideduperange-uncommitted` -- fails only because FIDEDUPERANGE is not on the
  branch under test. Remove once it lands. (Note: most FIDEDUPERANGE tests
  *notrun* rather than fail, so this category is usually empty.)
- `investigate` -- not yet triaged; a candidate bug to fix (then remove).
- `upstream-bug` -- a defect outside this work; linked to an issue.

## Safety excludes

`unsafe-excludes.txt` lists tests that crash/hang the kernel and would abort the
run -- currently generic/733 (an upstream master BRT double-free panic,
reproduced here in ~20s; see `~/zfs-733-bug/ISSUE.md`). They are `-E`-excluded
and reported as **skipped**, never counted as pass or fail.
