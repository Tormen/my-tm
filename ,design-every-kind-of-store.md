# Design: every kind of Time Machine store

> **STATUS: PROPOSAL, UNDER REVIEW.** Nothing here is implemented. This file is
> the design of record for it and is updated after every comment.

## 1. The gap

my-tm claims to be the swiss-army knife for Time Machine. It is not yet: it can
only see a Time Machine store that is a **mounted APFS volume**, plus the
`local` snapshots and an `ssh` target. On this machine alone it is blind to:

| what is there | why my-tm cannot see it |
|---|---|
| `<share>/<host>.sparsebundle` on an SMB/AFP share (NAS, Time Capsule) | the store is inside a disk image that must be attached first |
| `<share>/<otherhost>.sparsebundle` | same, and it belongs to another Mac |
| a legacy `Backups.backupdb/<host>/<date>/` tree | snapshots are directories, not APFS snapshots |
| a destination whose volume is attached but **not mounted** | `[ -d "$target" ]` is false, so it is skipped in silence |
| a destination that is not attached at all | *(fixed: listed with `?` and the last known table)* |

The first row is not hypothetical: this host's own network backups live in a
`<host>.sparsebundle` beside two other machines' bundles on the same share.

## 2. Vocabulary: a location has a KIND

A **store** is where snapshots live; a **location** binds your handle to one.
Every command already goes through "open the store, list snapshots, read a
path", so the kind is the only thing that has to vary:

| kind | store is | opened by | released by |
|---|---|---|---|
| `apfs-disk` | a mounted APFS TM volume | nothing (already mounted) | nothing |
| `apfs-image` | an APFS TM volume **inside a sparsebundle** | `hdiutil attach -readonly -nobrowse` | `hdiutil detach` |
| `hfs-dir` | a `Backups.backupdb` tree | nothing | nothing |
| `local` | APFS local snapshots | nothing | nothing |
| `ssh` | a store on another Mac | re-exec my-tm there | — |

Snapshots inside a store then work as they do today: `mount_apfs -s` for the
APFS kinds, and for `hfs-dir` there is nothing to mount at all — the dated
directories *are* the snapshots, which makes it the cheapest kind to read.

## 3. Attaching an image, and the risks that come with it

* **Always `-readonly`.** A Time Machine sparsebundle carries a lock naming the
  host that owns it. A writable attach can collide with that host mid-backup;
  read-only cannot, needs no `fsck`, and matches the fact that my-tm never
  writes to a backup.
* **Always `-nobrowse`**, so an attach does not make volumes appear in Finder.
* **One attach per location, reference-counted.** Mounting 16 snapshots inside
  an image must not attach it 16 times, and the last release detaches it.
* **The same TTL and sweep bookkeeping as a snapshot mount**, with the record
  carrying the kind so the sweep calls `hdiutil detach`, not `umount`.
* **Never attach during `--status`.** Status stays a metadata-only command:
  a network store is reported from cache, marked `?`, and only a command that
  needs the contents pays the attach.
* **Slow is the normal case.** Over SMB an attach is seconds and a walk is
  minutes, so `--index` on a network store is a bad idea to do implicitly;
  it is allowed, but always after a warning naming the cost.

## 4. Snapshot model per kind

`apfs-image` is identical to `apfs-disk` once attached: `backup_manifest.plist`
at the volume root, APFS snapshots, every size column as today.

`hfs-dir` has no manifest. Snapshots are `Backups.backupdb/<host>/<ts>/<Volume>/`
directories, so `FILES`, `ADDED` and `TOTAL` are simply unavailable and print
`-`; `UNIQUE` needs a walk as it does everywhere. Everything else — `--lookup`,
`--find`, `--cat`, `--cp`, `--diff` — works, and without a single mount.

## 5. Identity, so IDs stay stable

`ID = crock32(md5(<store-identity>|<timestamp>))` is unchanged; only
*store-identity* has to be defined per kind:

* `apfs-image`: the sparsebundle's own UUID from its `Info.plist`, which is
  readable **without attaching**. Stable across shares, mountpoints and renames.
* `hfs-dir`: the volume UUID of the backing volume, else the store path.

## 6. Finding them

`tmutil destinationinfo` reports network destinations too (`Kind : Network`,
with a URL). Autodetect maps a mounted share to `<share>/<host>.sparsebundle`.
Bundles for *other* hosts on the same share are **not** picked up automatically
— they are someone else's backups — but `--add` takes one explicitly.

## 7. The four states of a destination, and what to say about each

| state | detected by | my-tm says |
|---|---|---|
| mounted | in the mount table | normal row |
| **attached but not mounted** | `diskutil info <name>` → `Mounted: No` | warn: not searched, and the one command that fixes it |
| not attached | `diskutil info` → `Could not find disk` | `?` + last known table |
| network share not mounted | share path absent | `?` + the share to mount |

Two rules follow:

* **`AUTO_MOUNT_DESTINATIONS`** (default `0`): when `1`, my-tm mounts an
  attached-but-unmounted destination, uses it, and **restores exactly the state
  it found** — unmounting only what it mounted itself. Default off because
  ejecting the backup disk is a deliberate act here, and a `my-tm --status`
  that spins a disk back up would be a surprise.
* **A command must name the locations it could not search.** `--lookup` and
  `--find` answering from three of four stores while saying nothing about the
  fourth is the same silent-wrong-answer failure as reporting a file "absent"
  because we looked in the wrong directory.

## 8. Open questions

1. Should `AUTO_MOUNT_DESTINATIONS` default to `1` instead?
2. Are legacy `hfs-dir` (`Backups.backupdb`) stores in scope, or APFS only?
3. Should other hosts' sparsebundles on a shared volume be listable (read-only)?
4. What should happen when a sparsebundle's lock says another host holds it?
5. Build this now, or land the destination-state warnings first and images after?
