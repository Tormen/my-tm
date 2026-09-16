# my-tm

Swiss-army knife for Time Machine: **control** the backups (start/stop/eject),
**see** what backups exist, **look up** every version of a file, **search** the
backup history by name, and **browse** any snapshot as an ordinary directory
under `/tm/`.

> **STATUS: IMPLEMENTED.** `my-tm` is one POSIX `sh` file next to this README;
> `my-tm --run-tests` is the self test. This README is the design document and
> the sections marked *spec* are the implementation contract — where a
> measurement on real hardware contradicted the design, the design was
> corrected, not the measurement.

---

## 1. The idea in one screen

```text
my-tm                            # status of every backup location
my-tm backup                      # list the snapshots of location "backup"
my-tm ~/Documents/report.odt          # every version of this file, and where
my-tm 'invoice*.pdf'            # search the history by name -> paths + versions
my-tm k7f2q9                     # what is snapshot k7f2q9  (6-char ID)
my-tm k7f2q9 ~/Doc/report.odt         # that file in that snapshot: path + stat
ls /tm/backup/2026-08-20_1558.05/ # browse any snapshot directly
my-tm --backup start             # the classic: back up, then quiet the disk
```

**Every command starts with `--`; everything without `--` is data** — a
location, a snapshot ID, or a path/name. That is what makes the smart form
unambiguous: a file called `status` in `$PWD` can never be mistaken for a verb.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| **location** | a Time Machine backup disk (`/Volumes/TimeMachine.Backup`), a network store (`<share>/<host>.sparsebundle`), an `ssh` target (`host1:/Volumes/…`), or the pseudo-location `local` (APFS local snapshots, §8) |
| **handle** | your short name for a location — `backup`, `host1`. Set with `--add`. Anywhere `<LOCATION>` appears, a handle or a path both work |
| **snapshot** | one backup inside a location, `2026-08-20_1558.05` |
| **ID** | 6-char handle for one snapshot, `k7f2q9`. Stable, machine-independent (§5). Short enough to double-click-select in a terminal |
| **source volume** | a volume a location backs up (`Macintosh HD - Data`) |
| **lookup** | *where does this exact path exist in the backups* — cheap (§6) |
| **find** | *which file is called X* — index-backed name search (§6, §7) |

## 3. Usage

```text
usage: my-tm [OPTIONS] [<LOCATION>|<ID>] [<PATH>|<GLOB>]

A <LOCATION> is one Time Machine backup store, named either by its path or by
the short handle you gave it in the CONFIG; an <ID> is a 6-char name for one
snapshot inside one location. Everything with -- is interpreted as a command.
A bare `my-tm` runs $DEFAULT_CMD (default --status).

  my-tm                          status of all backup locations
  my-tm <LOCATION>               list its snapshots                   (= --ls)
  my-tm <ID>                     show one snapshot                  (= --show)
  my-tm <PATH> [<LOCATION>]      every version of it [in <LOCATION>] (= --lookup)
  my-tm '<GLOB>'                 search the history by name         (= --find)
  my-tm <ID> <PATH>              that file, in that snapshot
  Each short form takes the same optional arguments as the command it maps to,
  wherever that stays unambiguous.

INSPECT
  --status  [<LOCATION>]         one line per location: snapshots, span, space,
                                 index state; all locations if omitted
  --ls      [<LOCATION>]         snapshot table: when, how much each backup
                                 added, restore size; every location if omitted
  --lookup  <PATH> [<LOCATION>]  the distinct versions of PATH and where they
                                 are; searches the locations backing up PATH's
                                 volume if <LOCATION> is omitted, --all for every
                                 known location
  --find    [<ID>] '<GLOB>' [<LOCATION>]
                                 without <ID>: search the name index over the
                                 whole history -> paths + version counts
                                 with <ID>:    walk that one snapshot live, no
                                 index needed (slow)
                                 <LOCATION> limits it; all locations if omitted
  --show    <ID> [<PATH>]        one snapshot; with <PATH>, just that file in it

USE
  --mount   <ID>|<LOCATION>|--all <TTL> [<PATH>]
                                 expose it and print the mountpoint. <TTL> is
                                 MANDATORY -- how long you need it: 7m / 4h /
                                 5h3m / 2d. <PATH> is where to put it: relative goes
                                 under /tm, absolute is used as given; under /tm
                                 if omitted. See `my-tm --mount --help`
  --umount [-f] <ID>|<LOCATION>|--all
                                 release it early (they expire on their own).
                                 If something still has files open, prints what
                                 is holding it and refuses; -f unmounts anyway
  --open    <ID> <PATH>          open that version (prints the command first)
  --cat     <ID> <PATH>          write that version to stdout
  --cp [-f] <ID> <PATH> [<DEST>] copy it out; <DEST> defaults to $PWD under the
                                 original name. Refuses to overwrite without -f
  --diff    <ID> [<PATH>]        what changed between then and now; the whole
                                 snapshot if <PATH> is omitted (slow, warns first)
  ...or just browse:             ls /tm/<LOCATION>/<SNAPSHOT>/

MAINTAIN
  --index   [<LOCATION>|<ID>...] [--all]
                                 build the name index --find uses. NOTHING is
                                 indexed until you say so: naming a <LOCATION>
                                 opts it in for good (needs root), and without
                                 arguments it indexes what is already opted in.
                                 With --all: every snapshot -- an overnight
                                 job, warns first
  --no-index <LOCATION>...       stop indexing it; its index is kept
  --rm-index <LOCATION>...       stop indexing it and delete its index
  --verify  <ID> [<PATH>...]     re-check the checksums stored at backup time;
                                 the whole snapshot if no <PATH> given
  --local-snap[shot]             take an APFS local snapshot now.
                                 [daemon: taken every LOCAL_SNAP_INTERVAL]
  --health  [<LOCATION>]         run the health checks, exit non-zero on the
                                 worst; all configured locations if omitted.
                                 [daemon: run every HEALTH_INTERVAL]

MAINTAIN -- these need root + Full Disk Access
  --rm      <ID>... go           delete snapshot(s). NOT undoable, no trash
  --thin    [<LOCATION>] ["<POLICY>"] go
                                 delete the snapshots a retention policy does
                                 not keep; every location and the configured
                                 policy if omitted. Dry-run unless you type `go`
  --backup  start|stop [--eject|--no-eject]
                                 run or stop a backup, then do what POST_BACKUP
                                 says with the disk: none | unmount | eject.
                                 [daemon: run on BACKUP_SCHEDULE]

INSTALL & SET UP
  --install [<SSH-HOST>] [go] | --uninstall [<SSH-HOST>] [go]
                                 initial setup: dirs, /tm firmlink, daemons.
                                 Without `go` it only prints what it would do,
                                 every host listed. Needs root + Full Disk
                                 Access locally and on each configured ssh host;
                                 <SSH-HOST> does just that one, all if omitted
  --setup                        interactive setup of Time Machine itself --
                                 destinations, exclusions, quota.
                                 See `--setup --help` for the flags to do it
                                 from a script instead
  --add <FOLDER> [<HANDLE>]      register a location -- appends to
                                 locations.tsv (root); <HANDLE> defaults to a
                                 slug of the volume name
  --forget <HANDLE>              forget a location; locations.tsv only, no
                                 backup is touched (deleting snapshots is --rm)
  --refresh [<LOCATION>]         rebuild caches and the /tm tree; all if omitted
  --create-config [<FILE>]       print the default config, or write it to <FILE>
  --config <FILE>                use this config instead of the search order
  --completion [zsh|bash]        print the completion script
  --run-tests | --help

  ADDED is what a backup WROTE, not what deleting it would free: macOS exposes
  no per-snapshot exclusive size for an APFS Time Machine store, so no column
  here can honestly claim one (see "Exclusive size" below).

OPTIONS
  -S|--source <FOLDER>   use this location only, skip autodetect
  -A|--all               no limits: all locations / all rows / all snapshots
  -L|--limit <N>         stop after N rows
  -J|--json              machine-readable output
  -f|--force             overwrite an existing destination (--cp),
                         force a busy unmount (--umount)
  -V|--verbose           echo each tmutil / mount_apfs / find command before it runs
  -D|--debug [<PATH>]    diagnostics: which ladder rung fired, cache hits,
                         resolved snapshot paths   (implies -V)
  -DD|--deepdebug [<PATH>]  everything above plus shell tracing (set -x)

Quote globs:  my-tm 'invoice*.pdf'   (else the shell expands it first).
```

### The smart dispatch *(spec)*

Anything starting with `-` is a command or an option. The first **bare** word
is classified by this ladder — first match wins, `-V` prints which rung fired:

| # | Test | Mode |
|---|---|---|
| 1 | matches `^[0-9a-z]{6,8}$` **and** hits the snapshot cache | `--show` |
| 2 | is a handle in the config | `--ls` that location |
| 3 | is a path **inside a known backup disk** | `--ls` that location |
| 4 | contains a glob char (`* ? [`) | `--find` (§6); a `/` in the glob anchors it to that directory |
| 5 | contains `/`, **or** is an existing name in `$PWD` | `--lookup` (§6) |
| 6 | any other bare word | `--find` (§6) |
| 7 | nothing classifiable | error listing the near-misses |

Rungs 4–6 answer "is this a path or a name?" the obvious way: `report.odt` in `$PWD`
is a path; `report.odt` that does not exist is a name to search for; `*.odt` is
always a name, `~/a/invoice*.pdf` a name anchored to that directory;
`~/a/report.odt` is always a path. **`my-tm 'invoice*.pdf'` and
`my-tm --find 'invoice*.pdf'` are identical** — the ladder just picks the
command you would have typed. Relative paths resolve against `$PWD` first; give
`--find` an `<ID>` to search the relative form *inside* a snapshot instead.

A second bare word refines, **in either order** — each bare word is classified
independently, so `my-tm <PATH> <LOCATION>` and `my-tm <LOCATION> <PATH>` mean
the same thing: limit to that location. `<ID> <PATH>` (or `<PATH> <ID>`)
addresses one file in one snapshot. Passing both an `<ID>` and a
`<LOCATION>` is an error unless that snapshot really is in that location — the
error names the location the ID actually belongs to.

## 4. Output *(spec)*

Every row **starts with its key**. Fixed-width, no boxes, no colour.

```text
$ my-tm                                            # = --status
 LOC     DESTINATION                   SNAPS  SPAN                     LAST   USED/FREE
 backup  /Volumes/TimeMachine.Backup     412  2025-10-07..2026-08-22     14m  2.4T/1.2T
 host1   host1:/Volumes/TimeMachine.Ext   ~380  2024-11-02..2025-09-28   329d?  -
 local   / + /System/Volumes/Data            3  2026-08-22 13:35..15:56    14m  -
 --> cache 1.4M · index 212M (12/412 snaps, my-tm --index backup) · scanned 3m ago

$ my-tm backup                                     # = --ls backup
 ID      SNAPSHOT             AGE  FILES  ADDED  DRIFT  TOTAL  VOL
 k7f2q9  2026-08-22_1456.25   14m  17.9k   5.3G   1.4x  1.59T   Data
 m3x8b1  2026-08-20_1558.05    2d  12.1k   3.9G   1.0x  1.58T   Data
 q4d7h2  2026-07-30_1558.05   23d  91.2k  84.7G  22.0x! 1.51T  Data
 ...409 more (--all) · ADDED avg 3.8G

$ my-tm ~/Documents/report.odt                     # = --lookup
 ID      SNAPSHOT             AGE   SIZE  STATE
 k7f2q9  2026-08-22_1456.25   14m  12.4K  =live
 m3x8b1  2026-08-20_1558.05    2d  11.9K  changed
 q4d7h2  2026-07-30_1558.05   23d      -  absent
 --> backup/Data · 3 distinct versions in 412 snapshots

$ my-tm 'invoice*.pdf'                             # = --find
 PATH                                     VERSIONS  NEWEST      OLDEST
 /Users/you/Documents/2026/invoice-4.pdf         3  2026-08-20  2026-03-02
 /Users/you/Documents/2025/invoice-9.pdf         1  2025-11-04  2025-11-04
 --> my-tm <path> for the version table · --all to expand every version here
```

Rows from cache for an unmounted location are marked `?`. Anything longer than
~2 lines of prose belongs in `--help`, not in runtime output.

### The size columns, precisely

| Column | Source | Means |
|---|---|---|
| **ADDED** | `stats.changed.physicalSize` | bytes this backup **wrote to the backup disk that were not already there** — the delta against the *previous backup*. The churn |
| **DRIFT** | ADDED ÷ the **median** ADDED | the same number as a ratio, with `!` past `HEALTH_DRIFT_FACTOR`. A normal night is `1.0x`; `22.0x!` means something big got swept in (a VM image, a Downloads folder, a restored archive) — usually something you then want in `--setup`'s exclusions. The median, not the mean: measured on a real store, a handful of huge backups drags a mean so far up that every ordinary night reads `0.0x` and a genuine spike no longer stands out — the outliers would be hiding themselves |
| **TOTAL** | `stats.propagated.logicalSize` | the **absolute** logical size of everything in that snapshot: what a full restore would occupy **on an empty disk**. It is *not* a delta against your current live disk |

The fourth question — *how much would restoring this change my disk as it is
now?* — is a comparison, not a stored statistic: that is `--diff <ID>`, which
walks and therefore is never a table column. It is read-only and harmless, so it
just runs — after printing one warning line with an ETA derived from the
snapshot's file count and the last measured walk rate:
`~4.5M files, roughly 6-9 min. Ctrl-C is safe.`

### Exclusive size: macOS does not tell us

There is deliberately **no "how much would deleting this snapshot free?" column**.
On an APFS Time Machine store macOS exposes no such number:

* `tmutil uniquesize` refuses outright — *"Path is inside an APFS backup"*,
  `pathInAPFSBackup`. It is an HFS+ `Backups.backupdb` measurement, and HFS+
  stores are out of scope (below).
* `diskutil apfs listSnapshots` reports flags (`Purgeable`,
  `LimitingContainerShrink`) but no per-snapshot space at all.
* `tmutil compare` walks two trees and reports a delta between them, which is a
  different question and costs a full traversal.

So the honest columns are the ones the manifest really holds: **ADDED**, what a
backup wrote, and **TOTAL**, what it would restore. Asking for exclusive size
also cost `--index` a second full walk of every snapshot — to fail each time.

## 5. Snapshot IDs *(spec)*

`ID = crock32( md5( <destination-UUID> "|" <timestamp> ) )[0:6]`
— Crockford base32 (no `I L O U`), lowercase.

* **Deterministic** → the same snapshot always has the same ID, on every
  machine, before and after any cache wipe. The cache is an *index*, never the
  authority. Handles are equally stable: they are yours, from the config.
* The pseudo-location `local` has no destination UUID; its IDs use the UUID of
  the snapshotted volume instead — equally stable.
* On a prefix collision inside a location, **every member of the colliding set**
  uses the 7-char form (then 8) — computed from the location's own snapshot
  list, so any machine, and any rebuilt cache, derives the same lengths. A
  prefix clash *across* locations is resolved at parse time instead: the error
  lists the candidates as `<handle>@<ID>`.
* Prefixes of ≥4 chars accepted while unambiguous. Also accepted: `latest`,
  `-1` … `-N`, `<handle>@<date-prefix>` (`backup@2026-08-20`).
* A vanished ID gets a concise, instructive error:
  `k7f2q9: snapshot gone (backup, 2026-08-22 14:56, deleted since 2026-08-23). my-tm --ls backup`

IDs live on the CLI only. Under `/tm` the directories are timestamps (§8) —
there, sorting matters more than typing.

## 6. lookup vs. find *(spec)*

**lookup** — *"where does THIS path exist in the backups?"* A Time Machine
backup mirrors the whole source volume, so a live absolute path maps 1:1 into
every snapshot: no searching, just one `stat` per snapshot. Default scope: the
locations that back up the volume the path lives on (§12); a `<LOCATION>` word
or `-S` narrows, `--all` widens to every known location.

* The path need not exist locally — a **deleted** file looks up the same way;
  my-tm walks up to the nearest existing ancestor to identify the volume.
* Identical versions collapse by **size + mtime**, so you see *distinct
  versions*, not 412 rows. Deliberately not the inode: Time Machine does not
  keep one stable across snapshots of every store -- measured on a network
  sparsebundle, a file untouched since 2020 had a different inode in all 100
  snapshots, which would report 100 versions of a file that never changed.
* Snapshots are immutable, so every answer is a **permanent fact**. my-tm
  keeps them in the version store (§7): a snapshot already covered — fully, by
  an `--index` walk, or for this path, by any earlier lookup of it — is
  answered from the store with
  **no mount at all**. Only uncovered snapshots are touched live: one
  short-lived read-only `mount_apfs` plus one `stat` each, batched into a
  single exec (§8, §15), and the result goes into the store. So lookup cost is
  proportional to the snapshots that are *new since anyone last asked*, not to
  the history.
* The live path is read **in chunks of 16 snapshots**: mount up to 16, `stat`
  them all in one exec, release them, next chunk. Mounting a whole history at
  once measured fine (62 mounts in ~4 s) but pins every snapshot against
  thinning for the length of the run, and releasing them again is not free once
  the OS has started looking at them. Bounding the pins costs one `stat` exec
  per chunk instead of one for the run, which is still nowhere near one per
  snapshot. Measured end to end on a real store: 61 snapshots, cold, ~24 s;
  the same lookup afterwards, from the store, **0.8 s with no mount at all**.

**find** — *"which file is called X, and which versions do I have of it?"*
Answered in two cheap steps rather than one impossible one: the **index** (§7)
turns a name into absolute **paths**, then **lookup** turns each path into its
list of snapshots. So the crucial use case — every version of a file, across
the whole history — never walks 412 trees.

Results are **grouped by path**, one row per path with a version count, because
the same name usually lives in several directories and the directory is what
tells them apart. `--all` expands to one row per version inline.

Given an `<ID>`, `--find` switches to a live tree walk of that one snapshot —
slow, explicit, needs no index, and the right tool when you know the snapshot
but not the name.

## 7. The search index *(spec)*

Built on the `locate` machinery macOS already ships — `locate.mklocatedb`
compresses a path list to ~20 bytes/path, and `locate -d db1:db2:db3` searches
several databases at once, with globs. No dependency, no daemon, no new format.
*(Verified on macOS 26 before this design was written.)*

```text
$CACHE_DIR/index/system.db     -> the live volume: reuse /var/db/locate.database (free)
$CACHE_DIR/index/<loc>.db      -> consolidated union of paths seen in that history
$CACHE_DIR/index/<loc>.inc.NN.db -> per-run increments, folded in on consolidation
$CACHE_DIR/index/<loc>.covered -> snapshot IDs already indexed
$CACHE_DIR/index/<loc>.versions/ -> the version store: per-snapshot delta rows
                                  (path, inode, size, mtime; add/del/mod), §6
```

* **Nothing is indexed until you say so.** `--index <LOCATION>` opts a
  location in for good *and* indexes it now; `--no-index <LOCATION>` stops,
  keeping what was built, and `--rm-index <LOCATION>` stops and deletes it.
  The choice is the `INDEX` column of the shared `locations.tsv`, so the
  daemons read the same answer — which is why writing it needs root.
  `AUTO_INDEX_TM_BACKUP_DISKS=1` opts in this Mac's own backup disks instead
  (a sparsebundle stored on one included); never `local`, whose snapshots are
  a decision rather than a default, and never an ssh location, which its own
  host's config decides for. A per-location choice always wins over the
  setting, in both directions. `--status` reports the result in its `INDEXED`
  column — `no`, or how many of that location's snapshots the index covers —
  and its footer names the command to change it.
* **When it is updated.** An opted-in location is indexed when there is a
  backup its index has not seen — never on a clock alone, so a location that
  has not been backed up since the last walk costs nothing. Two triggers:
  * the **maintenance daemon**, which indexes right after a finished Time
    Machine run. It will not start while Time Machine is still working on the
    same disk: the walk pins one snapshot at a time and TM's thinning would
    block on it. Where Time Machine has **no** schedule of its own
    (`AutoBackup` off), the location's `INDEX_INTERVAL` (default 1 day) paces
    it instead; where it does, a finished run is the pacing and the interval
    is not consulted.
  * the **backup daemon**, which runs backup → re-read that disk's table →
    index → `POST_BACKUP`. The index goes before `POST_BACKUP` on purpose: the
    walk needs the disk spinning, and `POST_BACKUP` is about to park it.

  Neither trigger ever mounts a disk to look. A destination `POST_BACKUP` has
  ejected stays ejected; the index catches up the next time it is there
  anyway.
* **Tier 1, free**: every path that exists *now* is already in the system
  `locate` database, refreshed by macOS. Costs nothing, covers most searches.
* **Tier 2, `--index`**: walks snapshots to catch paths that no longer exist
  anywhere live. `find <snapshot> | locate.mklocatedb` per snapshot, merged with
  `locate.concatdb` — both of which live in `/usr/libexec`, not on `PATH`.
* **The same walk fills the version store**, which is what lets my-tm answer
  *"which versions of this file do I have?"* — the question a restore starts
  with — without mounting anything. The walk already visits every entry, so it
  stats them in the same pass (`find -print0 | xargs -0 stat`, batched), and:
  * the **first** indexed snapshot of a location is stored whole, as
    `<loc>.versions/base.<XX>.gz` — bucketed by the last two characters of the
    path, so a single-path query decompresses ~140 KB instead of the lot;
  * every later snapshot is stored as a **delta** against the previous walk
    (`comm` of the two sorted lists), `<loc>.versions/d.<ts>.tsv`.

  Measured on a real 4.4 M-file snapshot: the full listing is 722 MB raw and
  **35 MB gzipped**, and a delta at the observed churn is a few hundred KB. So
  a whole history costs one baseline plus small deltas, not a baseline per
  snapshot. Because snapshots are immutable these rows are facts, never stale;
  `--lookup` serves every covered snapshot from them with no mount (§6), and
  what it still has to read live it files alongside, so coverage grows with use.

  Each new backup is one more snapshot to index, so keeping up is one
  incremental walk — the same work the daemon already wakes up to do.
* **Cost, honestly**: one snapshot walk is minutes, and there is no cheap delta
  — `tmutil compare` walks both trees too. So `--index --all` over 412 snapshots
  is an overnight job. It runs detached, prints progress, and is resumable;
  `.covered` means a re-run only does what is missing.
* **`--index --all` and the sweep.** It starts with a warning naming the
  snapshot count and the ETA, because while it runs Time Machine's thinning is
  blocked on whatever it currently holds. That is acceptable for a run you do
  **once**, which is what this is. So the sweep does not fight it: an indexing
  run marks its mount `indexer` in the mount record (§8) and it is exempt while
  it works. In exchange it **cleans up behind itself** — it holds exactly the one
  snapshot it is walking and releases it before opening the next, so at any
  instant at most one snapshot is pinned, not four hundred. On exit, including
  Ctrl-C, it releases that one and drops the exemption.
* **Sensible default**: `INDEX_BASELINES="newest oldest"` — two walks catch
  everything that exists now plus everything that existed at the start.
  `--index <ID>...` adds specific snapshots; `--index --all` does the lot.
* **Size — measured, not guessed.** A measured system `locate` database holds
  3.5 M filenames in 35 MB: **10.5 bytes per path**,
  7 % of the raw text. So one fully-walked 4.5 M-file snapshot is about
  **47 MB**.
* **Which is only bearable because of dedup.** Storing 412 snapshots
  separately would be 412 × 47 MB ≈ **19 GB**. But consecutive backups share
  almost everything — a measured production manifest shows ~18 k changed of
  4.5 M files, i.e.
  **0.4 % per backup** — so a *union* index over the same history is one
  baseline plus the deltas: roughly 4.5 M + 412 × 18 k ≈ 12 M paths, about
  **125 MB**, and less in practice because "changed" counts modified files, not
  only new paths. Dedup is a ~150× difference, which is why the index is a
  union and not a per-snapshot collection.
* **Yes, it is incremental — natively.** The `locate` tools already provide
  every piece, verified here:
  * `locate.concatdb a.db b.db > c.db` appends one database to another;
  * `locate -d a.db:b.db:c.db` queries a set of them, and returns exactly the
    same results as the concatenated one (tested: 1774 = 1774);
  * `locate -d db '*'` dumps a database back to a plain path list, so a set can
    be consolidated without re-walking anything.

  So the index is kept log-structured: `<loc>.db` is the consolidated union,
  and each `--index` run appends a small `<loc>.inc.<NN>.db`. Queries pass the
  whole set to `locate -d`. **`--index` consolidates at the end of its own run**, once the increments
  exceed `INDEX_INC_MAX`: it dumps them
  all, `sort -u`s, rebuilds one database and drops the increments. Doing it
  there rather than in the maintenance daemon costs a few minutes on a job that
  already took hours, and buys predictability — a heavy `sort -u` never fires
  at an arbitrary moment, and when `--index` returns the index is in its final
  state. Duplicates between increments are
  harmless to a query — they only cost space until the next consolidation,
  which is the usual log-structured trade and the reason an `--index` run never
  has to read the existing index first.
* **my-tm tells you when it is behind**: a `--find` that comes up empty says
  `index covers 12/412 snapshots (my-tm --index backup)` instead of claiming the
  file never existed.

## 8. Browsing: `/tm` *(spec)*

macOS keeps every snapshot reachable, but not browsable:
`/Volumes/.timemachine/<machine-dir>/` only ever shows the snapshots the OS
itself has mounted — touching an unmounted one's path returns `ENOENT`, it does
**not** trigger a mount (measured on macOS 26). What *is* cheap:
`mount_apfs -s` mounts any backup-store or local snapshot read-only **without
root** (verified), in ~70 ms once the disk is awake. So my-tm owns the
mounting, under one typeable tree:

```text
/tm/                                  firmlink -> $MOUNT_ROOT   (§9)
/tm/backup/2026-08-20_1558.05/Data    -> the mount; empty until it is made
/tm/backup/latest -> …                newest snapshot
/tm/backup/by-id/<ts>_<ID>            reach one by the ID my-tm prints
/tm/local/2026-08-22_1556.39/Data     same, for an APFS local snapshot
$MOUNT_ROOT/.mnt/<loc>/<ts>/          where the real mountpoints live
```

**Every snapshot dir is a placeholder until mounted.** `--refresh` writes the
tree, so `ls /tm/backup/` always lists what exists, and each snapshot directory
holds one entry per volume; the volume fills in when you or my-tm mount it —
`--mount` does it explicitly and TTL'd (below), and
`--lookup`, `--find <ID>`, `--open`, `--cat`, `--cp` and `--diff` mount
**transiently** on the way in: released before the command exits (trap-
protected), recorded with a short fallback TTL so the sweep reaps what a
`kill -9` leaks. Once mounted, `cd`, `ls`, `cp`, `rsync -axSHP`, `diff` and
shell TAB-completion all just work.

Layout is **uniform**: always `<location>/<snapshot>/<volume>/…`, even when a
location backs up a single volume, so scripts never have to branch. That
uniformity is why the real mountpoints sit out of the way under
`$MOUNT_ROOT/.mnt/` and `/tm/<loc>/<ts>/<vol>` points into them: a backup-store
snapshot mounts with an inner `<ts>.backup/` wrapper that a local snapshot does
not have, and neither shape should ever reach the person typing the path.

**The list of mounts each run made is kept in a file, not a shell variable** —
every caller reaches the mount helper through `$(…)`, which is a subshell, so a
variable set there would die with it and leave the snapshot mounted. That is
not a cosmetic bug: a leaked mount silently blocks thinning.

**`ssh` locations cannot appear as symlinks** — there is no local path to point
at, and mounting one would mean sshfs and a macFUSE dependency my-tm will not
take. So `/tm/<loc>/` for a remote location holds a single `REMOTE` text file naming
the host and path, and the two things you can actually do with it:

```text
This location lives on another machine:  <host>:<path>
Its snapshots cannot be browsed from here (that would need sshfs/macFUSE).

  my-tm --ls <loc>              list its snapshots from here (over ssh)
  my-tm --cat|--cp|--open <ID> <PATH>   fetch one file from it (over ssh)
  ssh <host>                    log in, then browse /tm/<loc>/ there

my-tm installed there: yes, /usr/local/bin, 2026-08-21_1430.07
```

The last line is the install record, so the file answers "is this host set up,
and since when?" without an `ssh` round trip. When my-tm has never been
installed there it reads `no -- run: my-tm --install <host>`.

Everything else about a remote location — status, snapshot table, sizes — works
normally from here, because that data comes back over `ssh` as JSON (§11).

### `local` — the same mechanism, no backup disk needed

`local` is the APFS snapshots Time Machine keeps *on your own disk*
(`tmutil listlocalsnapshots /` and `/System/Volumes/Data`). They mount exactly
like backup-store snapshots — `mount_apfs -s com.apple.TimeMachine.<ts>.local
/System/Volumes/Data <mnt>`, read-only, no root needed (verified) — and they
earn their place twice over: those ~24 h of hourly snapshots are the only
history you still have when the backup disk is detached, and they are the
fastest thing on the machine to read.

### `--mount` — the TTL'd form

`--mount <ID>|<LOCATION>|--all <TTL> [<PATH>]` mounts under `/tm` by default,
or under `<PATH>` when you give one (with `--all`, each snapshot becomes a
subdirectory of `<PATH>`), and prints the mountpoint. `--mount <LOCATION>`
means its newest snapshot; `--mount <LOCATION> --all <TTL>` mounts every
snapshot of that location — measured at seconds, not minutes. It also covers
what nothing else does: a disk attached from another Mac, an HFS+ store.

### One maintenance job: sweep, refresh, snapshot

`--install` puts a single LaunchDaemon in place, `$MAINT_JOB`
(`local.my-tm.maintenance`), running every `MAINT_INTERVAL` (default 120 s).
It does three cheap things, and a third daemon is not needed for any of them:

1. **releases mounts** (below);
2. **refreshes `/tm`** when a location's `backup_manifest.plist` mtime changed —
   a `stat` per location, then a placeholder/symlink rewrite only if something
   moved, and on the job's first run, which is what builds the tree after
   `--install`. That is what keeps `ls /tm` truthful at all times; without it new
   snapshots are missing from `/tm` and deleted ones leave stale dirs and
   dangling `latest`/`by-id` links until someone happens to run my-tm;
3. **takes a local snapshot** if `LOCAL_SNAP_INTERVAL` says one is due, and
   trims by `LOCAL_SNAP_KEEP_H` / `LOCAL_SNAP_MAX`.

A location on a network volume (SMB, NFS, AFP, WebDAV — read from `mount`,
matched on whole path components) is treated like any other: the expensive
case, a sparsebundle on a share, is refused where it is registered rather than
worked around here — it belongs to the host that stores it and is read there
over ssh (*Network stores*, §11). What a job still needs for a store on a
share is Full Disk
Access, without which it finds an empty directory; `--status`, `--health`,
`--show` and `--refresh` say so where that is the case (§9).

### What the sweep is for

Every mount pins its snapshot: **a mounted snapshot cannot be deleted**, so
macOS's cleanup silently fails against it — on the backup disk, Time Machine's
thinning stops and the store fills; on the boot volume (`local`), macOS frees
space by purging local snapshots, so a forgotten mount can end as a **full
startup disk**. The TTL and the sweep exist to guarantee every mount my-tm
made is released. `latest`/`by-id` symlinks, `REMOTE` files and unmounted
placeholder dirs hold nothing and need neither — which is why the lifetime is
asked for at `--mount` time rather than configured globally: it only ever
applies to a mount you deliberately made.

### The TTL belongs to the mount, not to the config

**`--mount` requires you to say how long you need it.** There is no global
`MOUNT_TTL_MIN`; the lifetime is an argument:

```text
my-tm --mount k7f2q9 20m          # twenty minutes, under /tm
my-tm --mount local 4h            # four hours
my-tm --mount backup 5h3m /mnt/x  # combined units, at a path you chose
```

`<TTL>` is `<N>m`, `<N>h` or `<N>d`, combinable (`5h3m`). It goes into the mount record
(§below), and the maintenance job reads *that*, not a config variable.

This is deliberate friction. A global default would let the interesting fact —
**a mounted snapshot cannot be deleted, so Time Machine's thinning silently
fails against it** — sit in a config file nobody reads. Asking for the number at
the moment of mounting puts the fact where it is understood, and makes the
answer specific to what you are actually doing.

my-tm then checks the number against the destination's **configured** backup
interval — `AutoBackupInterval` in `/Library/Preferences/com.apple.TimeMachine`
(3600 = hourly), cross-checked against the observed spacing of recent snapshots
— and **warns when it is problematic** — `4h` on an hourly destination blocks three
backups' worth of thinning:

```text
 !!! 4h on 'backup' (backs up hourly) - thinning is blocked for ~4 backups.
     A quarter of the interval is the sane ceiling here: 15m. Continuing.
```

It warns and proceeds — it is your disk — and also raises a notification when
`NOTIFY_MOUNT_WARN=1`, because the mount may well outlive the terminal you
started it in. `--mount --help` (or `--help --mount`) prints the same rule in
four lines, with the reasonable value for *your* destinations filled in.

The sweep then releases a mount when **any** of these is true:

* **its TTL has expired** — time since the mount was made, not idle time: macOS
  gives no reliable atime on a mountpoint, so measuring idleness would be a
  pretence;
* **Time Machine wants to work** — `tmutil status` reports a backup running, or
  the destination's free space fell below `HEALTH_MIN_FREE_PCT`. This overrides
  the TTL: a mount with two hours left still goes if a backup starts.

Either way the sweep checks `lsof` first and leaves any mount with open files,
retrying next round — **one `lsof` for every candidate at once**, never one per
mount: `lsof` costs the better part of a second per call, which turns releasing
a few dozen mounts into minutes.

### The mount record

Every mount my-tm makes is recorded as one TSV line —

```text
ID  location  mountpoint  made-at  ttl-seconds  pid  flags
```

— in `$CACHE_DIR/mounts.cache` when root made it, in that user's
`$CACHE_DIR_USER/mounts.cache` otherwise (the shared dir is root-writable
only, §13); the sweep reads all of them, and nothing else anywhere tracks
mounts. `flags` marks the two special lifetimes: `transient` (a mount a
command makes and releases itself, carrying only the fallback TTL) and
`indexer` (the one snapshot an `--index` run is walking, exempt from the
sweep, §7).

**Every mount, anywhere** — under `/tm` or at any path you passed. A mount at
`/tmp/x` is invisible in the `/tm` tree but fully tracked, which is what lets
`--umount --all`, `--status` and the sweep account for all of them.

The record is reconciled, not trusted: each sweep compares it against the real
mount table, so a mount you released yourself with `umount(8)` is **silently
dropped from the record** rather than reported as an error. The same
reconciliation removes records whose mountpoint no longer exists. And the
record alone never makes root act: the sweep releases only what the live mount
table confirms is a read-only snapshot mount at the recorded path — a record
line that matches nothing real is dropped, not obeyed.

### What lives under `/tm`

| Path | Made by | Why you would use it |
|---|---|---|
| `/tm/README` | `--install` | what this tree is (a) and how to use it (b) — one screen, no scrolling |
| `/tm/<loc>/<ts>/<vol>/` | `--refresh` (placeholder), filled by a mount | browse a snapshot; `--mount` (or any command that goes in) fills it |
| `/tm/<loc>/latest` | `--refresh` (symlink) | the newest snapshot without looking up a date |
| `/tm/<loc>/by-id/<ts>_<ID>` | `--refresh` (symlink) | reach a snapshot by the ID you read off the CLI. **Timestamp first**, so a plain `ls` sorts chronologically — nobody wants a directory sorted by hash |
| `/tm/local/<ts>/<vol>/` | `--mount local` | the last ~24 h — the only history that works with the backup disk detached |
| `/tm/<custom>/` | `--mount … <PATH>` | a mount you placed elsewhere **under `/tm`** on purpose. `--mount … /tmp/x` mounts at `/tmp/x` and is **not** visible under `/tm` |
| `/tm/<loc>/REMOTE` | `--refresh` | an `ssh` location: a text file saying so, and how to reach it. Remote snapshots are **not** browsable locally |

`/tm/<loc>/<ts>/` directories are shown as **empty placeholders** when nothing
is mounted, so `ls` still tells you which snapshots exist. An empty
`/tm/local` means **you have no local APFS snapshots yet**, and
my-tm mounts what does exist for you on `--mount`, `--open`, `--cat`, `--cp`
and `--diff`.

**Making local snapshots.** `--local-snapshot` (`--local-snap`) runs
`tmutil localsnapshot` — an immediate on-disk snapshot, useful right before an
upgrade or a risky edit. **No root needed** (verified on macOS 26: an ordinary
user created one). `--rm <ID> go` deletes one (§10).

They can also be taken on a schedule, by the maintenance job:
`LOCAL_SNAP_INTERVAL` — `<N>m` or `<N>h`, any value from one minute up to a
day (`90m` is fine, it needs no explanation); empty means off.
A short interval is a genuinely useful safety net — a minute-granular undo for
the file you are about to ruin — and it is cheap, because an APFS snapshot is a
metadata operation, not a copy. But **they do not stick around**: macOS treats
local snapshots as purgeable and deletes them under disk or memory pressure, and
`LOCAL_SNAP_MAX` trims the oldest itself. They are an undo buffer for the next
hours, never an archive.

A my-tm snapshot is created by the same `tmutil localsnapshot` call macOS uses
and carries the same `com.apple.TimeMachine.<ts>.local` name, deliberately: that
makes it **fully transparent to `deleted(8)`**, so the OS can reclaim it under
space pressure exactly like its own. A snapshot the system could not purge would
be a way to fill someone's startup disk, which is not a feature.

**Why they disappear, precisely.** Two independent mechanisms, and neither
distinguishes a snapshot my-tm made from one macOS made — they are all
`com.apple.TimeMachine.<ts>.local`:

* **Time Machine's own rotation** — it takes a local snapshot on each backup and
  keeps roughly the last **24 hours**, deleting older ones. The cadence is *your
  setting*, not a law: `AutoBackupInterval` (hourly by default, and macOS 13+
  offers hourly / daily / weekly in System Settings). my-tm reads that value
  rather than assuming, which is also what the `--mount` TTL check uses.
* **Space pressure** — `deleted(8)` reclaims local snapshots as "purgeable
  space" when the boot volume fills, at any age, without warning.

So retention is bounded by macOS whatever my-tm does, and
`LOCAL_SNAP_KEEP_H` (default `24`, matching the OS) is the primary knob;
`LOCAL_SNAP_MAX` is only a cap for the high-frequency case — at
`LOCAL_SNAP_INTERVAL="1m"` you would otherwise accumulate 1440 a day inside that
window. Both thin the oldest first, regardless of who created them, and my-tm
says so before it does.

**`--open`, `--cat`, `--cp` and `--diff` are conveniences, not a filesystem
layer.** Everything they do, `cp` and `rsync -axSHP` do too, on the `/tm` path.
They exist because they resolve `<ID>` for you and mount the snapshot
transiently on the way in; each prints the command it is about to run before
running it. On an `ssh` location they run remotely: `--cat` streams the file
back over `ssh`, `--cp` lands it at the local `<DEST>`, and `--open` fetches it
to a local temp file first and opens that, printing the path. `--cp` **refuses
to overwrite an existing destination** and needs `-f` to do it — deliberately
stricter than `/bin/cp`, since the whole point of pulling a file out of a backup
is that the live copy is the one you are worried about. There is
deliberately **no `--restore`** — `tmutil restore` strips Time Machine metadata
in ways plain `cp` does not, and that surprise is not worth wrapping.

## 9. `--install` / `--uninstall` *(spec, root-only)*

Refuses to run as non-root with one line explaining why. Idempotent; shows every
change before making it.

1. creates `$CACHE_DIR` and `$MOUNT_ROOT` — owner `root`, group `$TM_GROUP`
   (empty by default: the invoking user's primary group), mode `0750`: root
   writes, the group reads, others see nothing — files inside likewise, `0640`.
   Everything a non-root run needs
   to write goes to that user's own overlay and log dirs (§13), created on
   first use.
2. **excludes `$CACHE_DIR` from Time Machine** (`tmutil addexclusion -p`).
   `$MOUNT_ROOT` lives there and holds mounted snapshots — a backup copied back
   into the backup — plus placeholders `$MAINT_JOB` rewrites every
   `MAINT_INTERVAL`; everything else under it is derived data my-tm rebuilds.
   Without this, `backupd` walks that tree while it changes underneath and logs
   "Failed to read sticky exclusion extended attribute". `--uninstall` removes
   the exclusion again, and `--health` warns if it ever stops being in place.
3. checks `/etc/synthetic.conf` for the firmlink and adds it if missing, with
   exactly one comment line above it:

   ```text
   # my-tm: browse Time Machine snapshots as directories, see `my-tm --help`
   tm	private/var/lib/my-tm/mount
   ```

   Name from `$FIRMLINK` (default `/tm`), added uncommented — it is
   host-independent, since my-tm creates the target everywhere. **Synthetic
   entries only appear after a reboot**; until then my-tm uses `$MOUNT_ROOT`
   directly and says so in one line.
4. writes `/tm/README` (what the tree is, and how to use it) and installs the
   jobs: `$MAINT_JOB` always (§8), `$HEALTH_JOB` if `HEALTH_INTERVAL` is set
   (§11), and `$BACKUP_JOB` on `$BACKUP_SCHEDULE` (§14). Any stale predecessor
   job found is reported. Each plist executes a **root-owned** copy of my-tm at
   a path writable by neither group nor other; `--install` verifies that of the
   binary it registers and refuses a path inside any user-writable tree (such
   as a source checkout), naming the fix.

   It does **not** build the `/tm` tree. Building it reads every store, and on
   a fresh install nothing is cached, so a sparsebundle on a share would have
   to be attached — minutes of waiting, for a tree that `$MAINT_JOB` builds on
   its first run and that only becomes reachable as `/tm` after the reboot.
   `--install` says so in one line and names `my-tm --refresh` for building it
   at once.
5. with `JOBS_RUN_WITH_FULL_DISK_ACCESS=1`, builds the launcher the jobs run
   through (below) and prints the one manual step, granting it Full Disk Access.
6. writes the completion file to the **invoking** user's
   `~/.zsh/completions/_my-tm` (`$SUDO_USER`'s home, owned by them, never
   root's), and only when the content differs — that also happens on every
   ordinary run.

`--uninstall` reverses 1–5: unloads and removes the jobs and the launcher, unmounts everything
under `$MOUNT_ROOT`, and **deletes** the `/etc/synthetic.conf` comment+entry
pair — that file is synced line-by-line across your hosts, so leaving a
commented corpse behind would spread; a diff of the file from before `--install`
to after `--uninstall` must be empty. The `/tm` link itself only disappears
after a reboot, which `--uninstall` says in one line. It asks before deleting
`$CACHE_DIR` — the index is expensive to rebuild.

### Full Disk Access for the jobs

macOS grants Full Disk Access per program. The jobs run `/bin/dash`, and
granting that would give every dash script on the Mac the access — so a small
launcher holds the grant instead, and the jobs run my-tm through it. One config
value decides it, `0` by default; set it in the site's global config and
override it per Mac in the local one, which is loaded on top:

| `JOBS_RUN_WITH_FULL_DISK_ACCESS` | what the jobs do |
|---|---|
| 0 | `HEALTH_VERIFY` checksums fail, and a store on a network volume reads as empty |
| 1 | everything |

The launcher, `my-tm-launcher.c` (carried inside my-tm, byte for byte):

* runs ONE path, compiled in at build time — the installed my-tm — with its
  arguments passed through. It cannot run anything else, and no site path is
  written in its source;
* with no arguments, or exactly `--help`, explains itself and runs nothing;
  `--version` prints the my-tm path and the hash of the source it was built from;
* is built with `clang`, ad-hoc signed (`codesign -s -`) and installed at
  `JOBS_LAUNCHER`, `0700 root:wheel`. `--install` rebuilds it only when it is
  missing or its `--version` no longer matches, and refuses a `JOBS_LAUNCHER`
  inside a group- or world-writable tree. Without `clang` or `codesign` the
  jobs run my-tm directly, and `--install` says so.

**One manual step:** System Settings > Privacy & Security > Full Disk Access >
add the launcher. macOS ties the grant to that exact build: a rebuild needs
granting again, editing my-tm does not. Only the launcher's fixed my-tm gains
the access, and only root can change that file; run from Terminal, the
launcher is covered by Terminal's grant, not its own.

**Hints.** A command mentions this value only where it changed what it did in
that run, in one line naming the value to flip:

* `--health`: a location the jobs cannot see into, and `HEALTH_VERIFY` without
  the access;
* `--status`, `--show` (on its `BROWSE` line) and `--refresh`: a location on a
  network volume whose `/tm` tree the jobs cannot keep current.

Every other command runs with your own access, and says nothing about it.

## 10. Managing the backups *(spec)*

* **`--setup`** — one place for everything that *changes Time Machine's own*
  configuration, each step showing the current value first and writing nothing
  without confirmation: **destinations** (add/remove/list, enable/disable
  automatic backups), **exclusions** (list/add/remove, `-p` sticky, plus a quick
  `isexcluded` check), **quota** (cap how much of a shared disk this Mac may use).
* **`--forget <HANDLE>`** — forget a location: removes its `locations.tsv`
  line, touches no backup, so no confirmation.
* **`--rm <ID>… go`** — delete snapshots (`tmutil delete -d <mount> -t <ts>`;
  root + Full Disk Access) or local snapshots (`tmutil deletelocalsnapshots`,
  no root). Prints what will go and the space it frees, then needs the literal
  word `go`. **There is no trash for this**: deleting an APFS snapshot
  releases its blocks immediately and cannot be undone. Before deleting, the
  ID→snapshot resolution is re-verified against the store itself — the cache
  is an index, never the authority for a destructive call; an ID whose
  snapshot is already gone reports `already deleted` and exits 0.
* **`--thin [<LOCATION>] ["<POLICY>"] go`** — **yes, this works.** Time Machine
  on APFS stores each backup as an *independent* APFS snapshot, not a chain of
  deltas: blocks stay referenced by whichever snapshots still need them, so
  deleting an intermediate snapshot is safe and needs **no relinking**. `--thin`
  therefore just selects what to keep and calls `--rm` for the rest. Dry-run by
  default; `go` performs it.

  Policy syntax — a list of `<SPAN>:<GRANULARITY>` pairs, each span counted
  backwards from *now*, keeping one snapshot per granularity bucket inside it:

  ```text
  THIN_POLICY_TO_KEEP_DEFAULT="24h:hourly 7d:daily 4w:weekly 2y:monthly *:yearly"
  ```

  `<SPAN>` = `<NUMBER><UNIT>` with `h d w m y`, or `*` for everything older than
  the previous span. `<GRANULARITY>` = `hourly daily weekly monthly quarterly
  yearly all none`. `*:none` deletes everything past the last span; leaving `*`
  out entirely means *keep* everything older, untouched — the safe default.

  Resolution order: the CLI argument beats the location's `THIN_POLICY_TO_KEEP`
  (set in `set_location_parameters`, §13), which beats
  `THIN_POLICY_TO_KEEP_DEFAULT`.
* **`--verify <ID> [<PATH>…]`** — `tmutil verifychecksums`, which takes *paths*,
  so it works at **snapshot, directory or single-file** granularity. Whole
  snapshots are slow; a directory or one file is quick. Reports `!` (checksum
  mismatch) and `?` (invalid recorded checksum); files backed up before OS X
  10.11 have none.

## 11. Health *(spec)*

`my-tm --health` runs the checks below, prints one line per finding, and exits
non-zero on the worst — suitable for cron and for a LaunchDaemon.

| Check | Fails when |
|---|---|
| staleness | newest backup older than the location's `HEALTH_MAX_AGE` (`HEALTH_MAX_AGE_DEFAULT`, 48h; `0` = no age expected, the age is only shown) — the #1 real failure, Time Machine fails **silently** |
| destination reachable | configured destination not mounted / not seen for N days |
| free space | backup disk below `HEALTH_MIN_FREE_PCT`, or thinning cannot reclaim |
| stuck backups | leftover `.inprogress` / `.interrupted` dirs above `HEALTH_MAX_INTERRUPTED` |
| stalled run | `tmutil status` sitting in one phase with no byte progress |
| drift spike | ADDED past `HEALTH_DRIFT_FACTOR` × the running average (§4) |
| exclusion drift | a path in `HEALTH_WATCH_PATHS` is excluded from backup (`tmutil isexcluded`) or on a volume no configured location covers — or the reverse: an exclusion set in `--setup` that is being backed up anyway |
| local snapshots | piling up on `/`, or purged so fast that hourly history is gone |
| stale mounts | a my-tm mount past its TTL that `lsof` says is idle but could not be released |
| ownership | destination claimed by another machine (`inheritbackup` needed) |
| jobs | a my-tm LaunchDaemon/Agent is loaded but failing, or points at a path that no longer exists |
| my-tm excluded | `$CACHE_DIR` is no longer excluded from Time Machine (mounted snapshots and rebuildable caches would be backed up) |
| Full Disk Access | missing — reported once, as a pointer (to the launcher when the jobs use one), not a stack of errors |
| checksums | only when `HEALTH_VERIFY` names a path (below) |

Hints about the two job settings (§9) are printed beside the checks and never
change the exit code.

Scheduling: `HEALTH_INTERVAL` (e.g. `4h`, `1d`) — empty / `0` / `false` means
never, and no daemon is installed. `--install` writes
`/Library/LaunchDaemons/$HEALTH_JOB.plist`, `HEALTH_JOB` defaulting to
`local.my-tm.health-check`.

Checksum verification is **off by default** — it is the only check that costs
real I/O. `HEALTH_VERIFY` is not a sample size but a **list of paths**, one per
line: set it to the directories you actually care about and each run verifies
those subtrees in the newest snapshot. Bounded by directories you chose, and it
checks what matters rather than random files.

```sh
HEALTH_VERIFY="
/Users/you/Documents
/Users/you/Projects
"
```

Which locations get scanned: `HEALTH_LOCATIONS`, a list of keywords and/or
paths — `ON-THIS-DISK` (locations on the internal disk), `LOCAL` (internal +
attached external), `ALL` (adds network/remote), an absolute path, a handle, or
an `ssh` target `host1:/Volumes/TimeMachine.Ext`.

**Remote locations go over `ssh`, not SMB.** Walking a Time Machine store over
SMB is unusably slow; instead my-tm re-executes *itself* on the far side
(`ssh host1 my-tm -J --status <path>`) and merges the JSON, so every expensive
step happens local to that disk. The target is `<host>:<path>` and `<host>` is
resolved exactly as `ssh` resolves it — `~/.ssh/config` first, then as a
hostname; a non-default user or port therefore belongs in a `Host` block there,
not in my-tm's config.

### Two remote modes

A `locations.tsv` line (§13) may carry an optional third field, the directory
my-tm is installed in on that host:

```text
# $CACHE_DIR/locations.tsv — HANDLE  TARGET  [REMOTE-INSTALL-DIR]
host1	host1:/Volumes/TimeMachine.Ext	/usr/local/bin
host2	host2:/Volumes/Backup
```

* **Installed (third field present) — the real mode.** `--install` sets that
  host up too: copies my-tm there, creates its cache and log dirs, installs the
  jobs. The remote then has somewhere to *store* things, which matters because
  the search index is the whole reason to care: `--index` on that location runs
  and stays remote, where the disk is.
* **Ephemeral (third field absent).** my-tm `scp`s itself to the remote's temp
  dir, runs, and removes it. Fine for `--status` and `--ls`; the ~200 ms per
  call is not free but is invisible next to the ssh round trips already
  involved. `--index` still **works**, provided `INDEX_REMOTE_COPY=1`: the walk
  happens on the remote where the disk is, and the finished database is copied
  back here, because here is the only place left to keep it. The cost is that
  nothing persists on that host, so installing my-tm there later means building
  the index again from scratch. With `INDEX_REMOTE_COPY=0` and no install dir
  there is nowhere to put the result at all, and `--index` is refused in one
  line saying which of the two to change.

`INDEX_REMOTE_COPY=1` pulls a finished remote index database back to the local
cache, so `--find` still answers for that location while the host is offline.
When the host is installed, the remote copy also **stays** — that is the one
that keeps getting extended, and the local one is a read-only mirror.

**No host is ever probed.** my-tm never makes an extra `ssh` call to ask whether
it is installed somewhere. It simply runs the command; a `command not found`
comes back as one clear line — `host1: my-tm not installed there. Run: my-tm
--install host1` — which is also what you get after adding a new host to the
config. `--install <SSH-HOST>` does that one host; `--install` with no argument
does the local machine and every configured host.

### Network stores: `<host>.sparsebundle` *(spec)*

A Time Machine destination on a NAS or Time Capsule is a **sparsebundle** on an
SMB/AFP share holding an ordinary APFS store -- same manifest, same APFS
snapshots, same size columns.

**A bundle on a share is read where it is STORED, over ssh** — never across the
share. Reading it from here pulls every block over the network: 1060 s measured
for `horse.sparsebundle` on ada, per health run. So detection skips bundles on
network volumes, and `--add` refuses one, naming the host from the mount table:

```text
!!! /Volumes/timeMachine/horse.sparsebundle is on a network share (ada) -- read it where it is stored: my-tm --add ada:<path on ada>/horse.sparsebundle
```

A bundle on a **locally attached** disk is an ordinary location:

```text
my-tm --add /Volumes/<disk>/<host>.sparsebundle usbtm
```

* **Attached read-only, always** (`hdiutil attach -readonly -nobrowse -noverify`):
  the bundle belongs to the Mac that backs up into it, and a writable attach
  could collide with it. Read-only also means no `fsck` and no risk to a backup.
* **Attached only when the store must really be read.** A fresh cache answers
  `--status` and `--ls` with no attach at all; a stale one pays for it once.
* **Kept for `IMAGE_GRACE` (default 10 min) after its last use**, then detached
  by the sweep. Measured against a NAS store: the first command costs **66 s**
  of attach and mount, and every command after it **1 s**. Detaching the moment
  a command ends would make the next one pay the 66 s again. Only images my-tm
  attached itself are ever detached, and `--umount --all` releases them now.
* **Identity comes from `Info.plist`'s `uuid`, readable without attaching**, so
  snapshot IDs are stable while the share is offline and survive the share being
  mounted somewhere else.
* **A bundle that will not open read-only** is a warning when my-tm met it while
  sweeping every location, and an error when the command named that store.
* Bundles belonging to **other** Macs on the same share are never picked up
  automatically -- they are someone else's backups -- but `--add` takes one, and
  the cache then answers for it like any other location.

### What my-tm does not cover

**Legacy HFS+ `Backups.backupdb` stores are deliberately out of scope.** They
have been legacy since macOS 11 (Big Sur, 2020):

* **cannot be created** — macOS 11+ refuses to start a new backup to an HFS+
  destination and insists on reformatting to APFS;
* **can still be read and restored** — the OS keeps mount and browse support for
  an existing hierarchy, including via Migration Assistant, and the dated
  directories are plain directories that `ls`, `cp` and `rsync` already read;
* **cannot be inherited or continued** — an HFS+ chain cannot be extended after
  an upgrade; a fresh APFS chain starts instead.

A store that can no longer grow, and that the OS still opens by itself, does not
justify a second snapshot model threaded through every command here.

Network destinations — a `<host>.sparsebundle` on an SMB/AFP share — **are** in
scope; see `,design-every-kind-of-store.md`.

### Store growth *(spec)*

my-tm samples the store's real disk usage (`df`) and keeps the series, so
`--status` can say how fast it is filling and how long the free space lasts:

```text
 --> backup grows 5.30G/day over 14.2d · 1.99T free · full in ~384d
```

Sampled on **backup events** -- when a new snapshot appears, or when the count
changes because thinning ran -- not on a clock. One sample per change means each
delta is exactly one backup's worth; a fixed interval cannot promise that,
because backups get missed and extra samples between them say nothing.
`USAGE_SAMPLE_INTERVAL` is only a slow heartbeat for drift no snapshot change
explains. Nothing is printed until the series spans long enough to mean
something, and a store that thins as fast as it grows is reported as such rather
than given a doomsday date.

This is ground truth from `df`, unlike ADDED which is Time Machine's own
accounting. It still cannot give the exclusive size of one snapshot (above):
that is a property of the current snapshot set, not of history.

## 12. What a location knows *(spec)*

Read once, cached — and, as it turns out, **without mounting anything at all**:

* `<store>/backup_manifest.plist` sits on the live store volume and is readable
  directly. So `--status` and `--ls` — every size column in §4 — cost one
  `plutil -p` and one `awk` per location and **no mount**. The file is a flat
  array alternating *date, record, date, record…*; a record carries `startDate`,
  `stats.changed.count` and `.physicalSize` (**ADDED**),
  `stats.propagated.logicalSize` (**TOTAL**), `xid`, and `volumeStoreInfo` →
  **source volume UUID + name + role**.
* **Joining manifest records to snapshots**: the date of each pair is exactly
  the snapshot's creation instant. Verified against a real store — 61 of 61
  snapshots matched to the second — so the join is an equality, not a
  nearest-match. (Records that match no snapshot are stale entries and are
  ignored.) The manifest's `xid` belongs to the *source* volume and is a
  different number from the store snapshot's `SnapshotXID`, so it cannot serve
  as the join key.
* `diskutil apfs listSnapshots <device>` → the snapshot list. Deliberately not
  `tmutil listbackups`, which needs Full Disk Access; this needs neither that
  nor root.
* `tmutil destinationinfo` → mounted destinations, IDs, kind (Local/Network).
* the store root listing → `.inprogress` and `.interrupted` leftovers. A
  `<ts>.previous` directory is deliberately **not** reported: it is the working
  copy Time Machine keeps of the last completed backup to compare the next one
  against, so it exists after every successful backup and simply moves to the
  newest. Reporting it as a state made a perfectly healthy newest backup look
  like it was in some peculiar condition.

A `PATH` is *covered* by a location when the volume UUID of `PATH`
(`diskutil info -plist`) is in that location's source-volume set, and
`tmutil isexcluded PATH` says no. Both cheap; neither needs a mount.

## 13. Caches, logs, config *(spec)*

```text
/var/lib/my-tm/            SHARED — root:$TM_GROUP, mode 0750: root writes,
                            the group reads, others see nothing
    locations.tsv           HANDLE, TARGET, remote install dir — maintained by
                            --add / --forget (root), never hand-merged config
    locations.cache         handle, UUID, mountpoint, kind, source volumes,
                            snapshot count, span, scanned-at
    snapshots.cache         one line per snapshot, ALL locations: ID, loc,
                            timestamp, xid, files, added, total, state
    mounts.cache            root's own mount records (§8)
    index/                  the search databases (§7)
    mount/                  the /tm tree (§8)
~/Library/Caches/my-tm/    per-user overlay ($CACHE_DIR_USER): this user's
                            mount records, version-store rows from live
                            lookups, and index increments — everything a
                            non-root run may not write into the shared dir
~/Library/Logs/my-tm/      $LOG_DIR: my-tm.log (+ -D/-DD targets)
```

**The snapshot cache carries its own checksum**, on its first line rather than
in a file beside it, so it is swapped atomically with the content it describes —
several users and root write here, and a separate checksum file would have a
window where the two disagree. A cache that does not verify is discarded and the
store read again; individual rows are validated too, since a checksum only
proves a file is intact, not that what was written made sense. `locations.tsv`
gets no checksum on purpose: it cannot be rebuilt from anything.

The shared copies are written by root — the daemons, and any `sudo my-tm` run;
the index is machine-global fact and expensive to build, so no reason for
several users and root each to rescan. An unprivileged run reads the shared
set and writes what it may not share into its own overlay; index queries pass
both sets to `locate -d`, so an unprivileged `--index` is still useful — to
that user — until a root run folds the work in. Deterministic IDs (§5) mean
concurrent writers can never disagree. Writes are atomic (tmpfile + `mv`), and a written file takes its mode from its
directory: group-readable (`0640`) where the directory lets the group read,
private (`0600`) elsewhere, never world-readable — my-tm runs under `umask 027`.
Caches are line-oriented TSV: greppable, human-readable, rebuilt by `--refresh`.
`--status`'s footer reports their size, so they never grow unnoticed.

**Neutral defaults, site values in the config.** Every default built into
my-tm is generic — `/var/lib/my-tm`, `~/Library/Logs/my-tm` (`$LOG_DIR`, which the daemons use too: each job's stdout goes to `<label>.log`, its stderr to `<label>.err`), job labels under
`local.my-tm.*`, no group, no notifier. Anything that reflects one site's
conventions (a private reverse-domain for launchd labels, a shared admin group,
a site-wide config directory, a preferred notifier) is set in the config file,
which stays local. Nothing that ships carries a hostname, a user name, a private
path or a real document name — not in the code, not in the defaults, not in the
examples in this README. The single exception is the `/LINKS/default` config
location below, and it is deliberate.

Config search order (first wins): `$MY_TM_CONFIG` · `--config FILE` ·
`$SITE_CONF_DIR` **when it was set in the environment** ·
`/LINKS/default/my-tm.conf` (or the bare `/LINKS/default/my-tm`) ·
`$SITE_CONF_DIR/my-tm.conf` · `~/.my-tm.conf` ·
`/etc/my-tm.conf` · `/usr/local/etc/my-tm.conf`. Plain shell, `.`-sourced.
`--create-config` prints it (or writes `FILE`, never overwriting); with no
config anywhere, my-tm names every path it searched, one ready-to-run
`--create-config` line each.

`/LINKS/default` is the one site path written into the code. A search keyed on
a value that lives *inside* a config file cannot find that file, and one gated
on `$LINKS` being exported skips the location silently in a root shell — so the
primary location is spelled out. It is a directory name and reveals nothing;
everything else site-specific stays in the config.

**Two files at the site location.** Where `$SITE_CONF_DIR` is a merged
directory whose entries can come from a shared tree or a host-specific one, the
host-specific file wins and the shared one remains visible beside it as
`my-tm.conf.GLOBAL`. my-tm therefore sources **`my-tm.conf.GLOBAL` first when it
exists, then `my-tm.conf` on top**. `.GLOBAL` only exists when both are present,
so this gives base-then-override layering — put the settings shared by all your
machines in the shared file and only the per-host deltas in the local one — and
degenerates to plain "the local one wins" whenever the local file is complete.
`-D` prints which files were sourced, in order.

`--install` needs a config to exist (`$MY_TM_CONFIG`, `--config`, or one already
in the search order) and refuses with a one-line pointer to `--create-config`
otherwise: it installs job labels, directories and a group that are all
site-specific, and guessing them is worse than asking.

When a plain run would already find a config, `--install` copies **nothing** —
a second copy would only drift — and if that config differs from the one you
pointed it at, it prints the `vimdiff` that merges them. Only when a plain run
would find none does it copy the file to `$SITE_CONF_DIR/my-tm.conf` —
**renamed**, so a `my-tm.local.conf` you keep out of version control lands as
the plain `my-tm.conf`. It never overwrites a different file there (it offers
`vimdiff` instead), and says so when a plain run would not look there either.

```sh
# Locations live in $CACHE_DIR/locations.tsv, maintained by --add / --forget —
# not in this file. ONE shared file, whoever runs my-tm: a location belongs to
# the machine, and the daemons that refresh, check and index it all run as root.
# --add and --forget refuse when that file is not theirs to write, naming the
# command to run again as root. A per-user copy from before this rule is no
# longer read; --status names it and prints an --add line per location in it.
DEFAULT_CMD="--status"          # what a bare `my-tm` runs; params allowed
TM_GROUP=""                     # group with read access to the shared cache;
                                # "" = the invoking user's primary group
CACHE_DIR="/var/lib/my-tm"; CACHE_MODE=0750
CACHE_DIR_USER="$HOME/Library/Caches/my-tm"
LOG_DIR="$HOME/Library/Logs/my-tm"
FIRMLINK="/tm"                  # /etc/synthetic.conf entry made by --install
MOUNT_ROOT="/var/lib/my-tm/mount"
SITE_CONF_DIR="/usr/local/etc"  # where --install puts my-tm.conf; see the
                                # search order above for every place my-tm looks
NOTIFY_MOUNT_WARN=1             # also notify when a --mount TTL looks unsafe
CACHE_TTL=3600                  # s; older -> rescan mounted locations
INDEX_BASELINES="newest oldest" # snapshots --index walks when none are named
INDEX_INC_MAX=16                # consolidate the increments once there are
                                # this many
INDEX_REMOTE_COPY=1             # also keep a local copy of a remote index, so
                                # --find works while that host is offline
AUTO_INDEX_TM_BACKUP_DISKS=0    # 1: this Mac's backup disks are indexed without
                                # --index. Never local snapshots, never ssh
INDEX_INTERVAL_DEFAULT="1d"     # only when Time Machine has no schedule of its
                                # own; with AutoBackup on, a finished run is the
                                # trigger and this is not consulted
ID_LEN=6
# --- retention ---
THIN_POLICY_TO_KEEP_DEFAULT="24h:hourly 7d:daily 4w:weekly 2y:monthly"
# --- health ---
HEALTH_INTERVAL="1d"            # "" / 0 / false -> no daemon installed
HEALTH_JOB="local.my-tm.health-check"
HEALTH_LOCATIONS="LOCAL"        # ON-THIS-DISK | LOCAL | ALL | handles | paths | ssh
HEALTH_VERIFY=""                # "" = off; else a list of paths, one per line
HEALTH_WATCH_PATHS=""           # paths that MUST be covered by a backup; the
                                # exclusion-drift check fails when one is
                                # excluded or on an uncovered volume
HEALTH_MAX_AGE_DEFAULT="48h"; HEALTH_MIN_FREE_PCT=10  # 0 = no age expected
HEALTH_MAX_INTERRUPTED=2; HEALTH_DRIFT_FACTOR=5
# --- jobs installed by --install ---
MAINT_JOB="local.my-tm.maintenance"   # mount sweep + /tm refresh + local snaps
MAINT_INTERVAL=120              # s between maintenance runs
LOCAL_SNAP_INTERVAL=""          # "" = off. <N>m or <N>h, 1 minute .. 1 day.
                                # A short interval is a safety-net undo;
                                # cheap (metadata only), but PURGEABLE — macOS
                                # deletes them under pressure. Not an archive.
LOCAL_SNAP_KEEP_H=24            # h; matches macOS's own ~24h rotation
LOCAL_SNAP_MAX=48               # cap for high-frequency intervals (oldest thinned)
BACKUP_JOB="local.my-tm.backup"
BACKUP_SCHEDULE="on-boot"       # space-separated, combinable. Examples:
                                #   on-boot            -> RunAtLoad
                                #   1800s              -> StartInterval 1800
                                #   03:30              -> daily at 03:30
                                #   on-boot 03:30 15:30 -> RunAtLoad + both times
                                #   Mon 03:30          -> weekly
JOBS_RUN_WITH_FULL_DISK_ACCESS=0 # 1: the jobs run my-tm through JOBS_LAUNCHER (§9)
JOBS_LAUNCHER="/usr/local/sbin/my-tm-launcher"  # built by --install; root:wheel 0700
# --- backup control (from the old my-tm.sh) ---
BACKUP_VOLUME=""                # "" = ask tmutil. Resolved ONCE at startup
POST_BACKUP_DEFAULT="eject"     # none | unmount | eject, when a backup ends
NOTIFY_CMD=""                   # optional external notifier; empty = osascript
NO_EJECT_FLAGFILE="/var/lib/my-tm/no-eject"
LOCKFILE="/var/lib/my-tm/backup.lock"
NOTIFY_BEGIN=0; NOTIFY_END=1    # via $NOTIFY_CMD (§14)
EJECT_RETRIES=10; EJECT_WAIT=5

# --- per location ---
set_location_parameters() {
	case "$LOCATION" in
		backup)     THIN_POLICY_TO_KEEP="24h:hourly 7d:daily 4w:weekly 5y:monthly *:yearly" ;;
		horse@ada)  HEALTH_MAX_AGE="0" ;;
	esac
}
```

**Per-location parameters.** `THIN_POLICY_TO_KEEP`, `POST_BACKUP`,
`HEALTH_MAX_AGE` and `INDEX_INTERVAL` each have a `_DEFAULT` for every location; a config sets one
for a single location in `set_location_parameters()`, which sees the handle in
`$LOCATION`. The site's config and the host's may both define it: the site's is
called first, the host's last, so the host wins where both name a location. At
the top level a config sets only the `_DEFAULT`s. A config that still sets one of
the old names (`THIN_POLICY_TO_KEEP`, `THIN_POLICY_PER_LOCATION`, `POST_BACKUP`,
`POST_BACKUP_PER_LOCATION`, `HEALTH_MAX_AGE_H`) stops my-tm with one line naming
what replaced it.

`my-tm --add /Volumes/X backup` (root — the file is in the shared dir) probes
the folder (§12), prints what it found — volumes, snapshot count, span — and
appends the line to `locations.tsv`.
Handle defaults to a slug of the volume name.

A handle that could be mistaken for a snapshot ID — 6 to 8 chars, all from the
ID alphabet (`0-9a-z` minus `ilou`, §5) — is **refused at `--add` time**, with
a suggestion. So is a handle that is not a usable file name: it becomes
`$FIRMLINK/<handle>`, `usage.<handle>.tsv`, `.manifest.<handle>`,
`<handle>.db`, `<handle>.covered` and one TAB-separated field, so only letters,
digits, `-`, `.` and `@` are allowed, never leading with `-` or `.`
(`horse@ada` is fine; `a/b`, `with space` and a tab are not). `backup` is fine (it contains a `u`), `k7f2q9x` would not be. Rejecting it
once, at the only moment a human chose the name, is far better than making every
later `--rm`/`--ls`/`--mount` disambiguate an ambiguity that never needed to
exist. (Rung 1 of the ladder would win anyway, so such a handle would be
unusable in practice.)

**Detection is always on**, with no setting: what this Mac is set up to back up
to is not a matter of taste. It costs one `tmutil destinationinfo` (14 ms
measured) plus a scan for this Mac's own sparsebundles, cached for
`IMAGE_SCAN_TTL`. A detected disk whose **target** is already registered is
skipped, so the same disk never appears twice — once under the name you gave it
and once under its volume name, which would make every snapshot ID ambiguous.
Snapshot enumeration stays cache-backed and `CACHE_TTL`-gated, never implicit
for a location you did not ask about. Network destinations are never
auto-mounted; they show their last known state with `?`.

## 14. Backup control — replacing `my-tm.sh` *(spec)*

`my-tm --backup start` keeps the old behaviour, cleaned up and config-driven:
single-instance lockfile with a signal trap, optional `diskutil mount` of
`BACKUP_VOLUME`, `tmutil startbackup --block`, notification on the three
outcomes (ok / already running / failed), then whatever `POST_BACKUP` says
unless `--no-eject` planted the flag file. `--backup stop` = `tmutil stopbackup`
plus the same post-backup logic. Both are root-only; everything else runs unprivileged
wherever the OS allows.

### Quieting the disk when the backup ends

An external 2.5" drive costs runtime and makes vibration noise for as long as
it spins, and macOS has no command that spins one down on demand: `pmset
disksleep` is global and idle-based, and on USB the enclosure decides whether
to honour it. The only levers are taking the filesystem away.

`POST_BACKUP` picks one, globally or per location:

| value | what happens | when it is right |
|---|---|---|
| `none` | left mounted | the disk is shared, or something else manages it |
| `unmount` | `diskutil unmountDisk` — the device stays on the bus, the enclosure spins it down on its own timer | a bridge that does not come back after an eject |
| `eject` | `diskutil eject` — parks the drive at once | the default: least runtime, least noise |

Test the enclosure before trusting `eject` to an unattended job: eject the
volume, then check whether `/dev/diskN` is still listed and whether
`diskutil mountDisk /dev/diskN` brings it back without a replug. Some USB
bridges drop off the bus and need the cable pulled — those want `unmount`.

`BACKUP_VOLUME=""` means "ask `tmutil destinationinfo`", resolved once at
startup; the pre-backup mount, the post-backup action and the rule below all
use that one value. More than one destination and my-tm refuses and asks,
rather than picking one.

`--backup start --no-eject` leaves the disk mounted from now on, the unattended
run included, until `--eject` undoes it. Both persist — they plant and remove
`$NO_EJECT_FLAGFILE`, and say so.

**A disk that was put to sleep stays asleep.** `--maintenance` runs every
`MAINT_INTERVAL` seconds and would otherwise mount each destination and stat
its manifest — waking the drive every couple of minutes and defeating the
whole thing. So a location whose `POST_BACKUP` is `unmount` or `eject` is
*quiet*: the daemons never open it, and `--health` answers from the cache,
marking the age it reports `[cached; disk asleep]`. Interactive commands still
mount it — somebody asked.

**my-tm replaces `my-tm.sh` outright** — the old file goes, and `--install` owns
the job: `$BACKUP_JOB` (`local.my-tm.backup`) as a **LaunchDaemon**, so it
runs as root, which the work requires. It reports (and offers to remove) any
stale predecessor, and the *jobs* health check keeps watching for the same
failure later.

`BACKUP_SCHEDULE` covers every shape launchd offers, and `--install` translates
it into the right plist key:

| Value | plist | Fires |
|---|---|---|
| `on-boot` | `RunAtLoad` | once per boot — nothing more, so a Mac that stays up for weeks never repeats |
| `<N>s` / `<N>m` / `<N>h` | `StartInterval` | every N seconds, counted from load |
| `HH:MM` | `StartCalendarInterval` | daily at that time |
| `HH:MM,HH:MM` | several `StartCalendarInterval` entries | at each listed time |
| `Mon HH:MM` | `StartCalendarInterval` with `Weekday` | weekly |

Values combine freely, space-separated: `on-boot 03:30 15:30` means *catch up
after a reboot, and again at 03:30 and 15:30* — `RunAtLoad` plus one
`StartCalendarInterval` entry per time. Any number of times may be listed, with
or without weekdays (`on-boot Mon 03:30 Thu 03:30`).

### Notifications

Notifications are **optional and dependency-free by default**: my-tm calls
`osascript -e 'display notification …'`, which every macOS has. Set `NOTIFY_CMD`
to an external notifier if you prefer one; my-tm probes it at startup and falls
back to `osascript` with a single `-D` line if it is missing, never failing
because of it.

Running as root is the case to get right, since `$BACKUP_JOB` and the
maintenance job are LaunchDaemons: a root process has no GUI session of its own.
The notification is therefore dispatched into the **console user's** session —
`launchctl asuser <uid> sudo -u <user> osascript …`, with the three strings
passed as osascript *arguments* rather than interpolated into a shell command,
so quotes, backslashes and apostrophes in a message cannot break or inject.
If an external `NOTIFY_CMD` handles that itself, my-tm calls it unchanged.

Keeping this a fallback rather than a dependency is deliberate — it is what lets
my-tm be a single self-contained file that works on any Mac, with no companion
tool to install alongside it.

## 15. Language: POSIX `sh` *(spec)*

Measured on macOS 26 / Apple silicon before deciding, because the argument
cuts both ways:

| Task (400 files) | Time |
|---|---|
| `sh`, one `stat` fork **per file** | **761 ms** |
| `sh`, **one** `stat` exec with all paths in argv | **18 ms** |
| `python3`, `os.stat` per file, incl. interpreter startup | **17 ms** |
| bare startup: `/bin/sh -c :` · `/usr/bin/python3 -c pass` · Homebrew 3.14 | 4 ms · 15 ms · ~200 ms cold |

The one place my-tm does real per-item work is `--lookup`: a few hundred `stat`s
across snapshots. Naive shell is **40× slower** there and would be felt. Batched
shell — BSD `stat -f` takes many paths in a single invocation — ties with
Python. So the performance question resolves into a **design rule rather than a
language choice**:

> **Batch every per-item syscall into one exec.** `stat -f '%i %z %m' <many
> paths>`, one `find` per tree, one `plutil` per plist, **one `lsof` for every
> mountpoint at once**. A loop that forks per item is a bug — and it is the bug
> that actually happened here: `lsof` per mount turned `--umount --all` over a
> few dozen mounts into minutes.

The argument list is passed **NUL-separated through `xargs -0`**, never by word
splitting: a path inside a backup can contain spaces, and an unquoted `$(cat
list)` would quietly corrupt exactly those paths.

`--lookup` is the one place with an unavoidable per-snapshot floor — one
`mount_apfs` each, ~70 ms measured — and it stays batched at one `stat` exec
per chunk of 16 snapshots (§6). `--run-tests` asserts the part that matters:
a snapshot already covered by the version store is answered with **no
`mount_apfs` at all**, proven from the stub `PATH` log.

With that rule in place the remaining arguments all point one way:

* the root LaunchDaemons must not depend on Homebrew Python, and the system
  interpreter is the Xcode-CLT stub 3.9 — old enough to fight the user's
  pyright-strict standard, and absent on a fresh install;
* the config format *is* shell, `.`-sourced;
* completion callbacks fire on every TAB, where 4 ms beats 15 ms;
* everything expensive is an external tool (`tmutil`, `mount_apfs`, `diskutil`,
  `find`, `locate.mklocatedb`) that both languages merely orchestrate;
* it matches the sibling tools it will sit beside, and their `run()` / `dbg()` /
  `err()` helpers and `--run-tests` precedent.

**Conclusion: POSIX `sh`, one self-contained file.** Structured data is read
with `plutil -extract`, never a hand-rolled plist parser. BSD userland only — no
GNU flags. `shellcheck -s sh` clean before every commit.

## 16. Tests *(spec)*

`my-tm --run-tests` is part of the one file and must run **with no network, no
real backup disk, and no root**, against a fixture tree built in a temp dir:
synthetic `backup_manifest.plist` files, dated snapshot directories, an
`.interrupted` and an `.inprogress` leftover, two source volumes, a fake config,
and a fixture `locations.tsv` with one `ssh` target. Anything that genuinely needs a
mount or root **skips with a printed reason** — never a silent pass.

**Read-only behaviour**

* dispatch ladder: every rung, plus the ambiguous cases (a file named like a
  handle; a bare name that exists in `$PWD` vs one that does not; a glob; an
  `<ID>` with a `<LOCATION>` that does not contain it)
* ID derivation: determinism across runs, stability after a cache wipe,
  collision escalation 6→7→8, prefix resolution, `latest` / `-N` /
  `<handle>@<date>`, and the "snapshot gone" message
* lookup: absolute, relative-to-`$PWD`, deleted path via nearest existing
  ancestor, version collapsing by size+mtime with differing inodes, coverage
  by volume UUID,
  excluded-path handling; a version-store-covered snapshot is answered with no
  `mount_apfs` call (proven via the stub `PATH` log), and a live-`stat`ed row
  lands in the store so the rerun reads it from there
* index: build from a fixture list, query with globs, multi-database query,
  coverage accounting, and the "index is behind" message
* thin policy: given a fixture of 400 dated snapshots, the exact keep/delete set
  for several policies, the `*` and missing-`*` cases, and CLI > per-location >
  global resolution — **selection only, no deletion**
* table formatting: column widths, key-first ordering, `?` markers, footers
* config: search order, `$MY_TM_CONFIG`, `--config`, `--create-config` to stdout
  and to a file, refusal to overwrite
* usage: `--help` exits 0, every command in the usage block is dispatchable, and
  no command lacks a test

**Everything that writes — the part that gets the most attention**

Each of these runs twice (idempotence), against a fixture root, and asserts the
*content* of what changed, not just that it did:

| Writer | Asserted |
|---|---|
| `--add` / `--forget` | the `locations.tsv` line appears/vanishes; the rest of the file is byte-identical; a duplicate handle is refused; a handle in the ID alphabet is refused; a bad folder is refused before any write |
| `--create-config` | never overwrites; stdout form and file form are identical |
| `--install` | dirs created `root:$TM_GROUP` `0750` *verified by mode*, not by intent; `/etc/synthetic.conf` gains exactly one comment + one tab-separated line; a second run adds nothing; a pre-existing foreign `tm` entry is left alone and reported; the completion file lands in the invoking user's home, owned by them, and an unchanged rerun does not rewrite it; a job binary inside a user-writable tree is refused |
| `--uninstall` | removes exactly what `--install` added and nothing else; a diff of `/etc/synthetic.conf` before-install vs after-uninstall is empty; asks before the cache |
| job plists | each `BACKUP_SCHEDULE` form produces the expected plist keys (`RunAtLoad` / `StartInterval` / `StartCalendarInterval` incl. weekday); the plist parses with `plutil -lint` |
| cache writes | atomic (tmpfile + `mv`); a killed write leaves the old file intact; two concurrent writers converge; a corrupt cache is detected and rebuilt rather than half-read |
| `--refresh` | the `/tm` placeholder dirs and `latest`/`by-id` symlinks match the fixture exactly; stale entries for deleted snapshots are removed; a user-made `/tm/<custom>` mount dir is not touched |
| mount bookkeeping | the record matches the real mount table; a TTL expires exactly once; the sweep respects `lsof`; a mount released behind my-tm's back (`umount(8)`) is silently dropped from the record; a mount whose target vanished is cleaned up; a `transient`-flagged leftover is reaped; TTL parsing of `7m`/`4h`/`5h3m`/`2d` and rejection of `4`, `0m` |
| `--rm` / `--thin` | **dry-run output only** — the dry run *prints* the exact `tmutil delete` command line it would run and the fixture asserts that string; that nothing runs without the literal `go`; and that `go` without root refuses and still runs nothing. No test ever deletes a real snapshot |
| `--local-snap` | skipped by default; enabled only by `--run-tests --with-snapshots`, and then it creates one, finds it in `--ls local`, and deletes it again |
| `--backup` | the `tmutil` / `diskutil` calls are asserted through a stub `PATH`, never executed for real; the lockfile blocks a second instance; the trap removes it on every signal; the eject retry loop honours `EJECT_RETRIES` and the no-eject flag file |

**Regression fixtures**, kept in the file as here-docs: the real
`backup_manifest.plist` shape as macOS 26 writes it (nested `volumeStoreInfo`,
`stats.changed` / `stats.propagated`), a `tmutil destinationinfo` transcript, a
`diskutil info -plist` transcript, and a `tmutil listlocalsnapshots` transcript.
Every parser is tested against the real text, so an output change in a future
macOS shows up as a failing test rather than a wrong number in a table.

**Stubbed externals.** `--run-tests` prepends a stub dir to `PATH` with fake
`tmutil`, `diskutil`, `mount_apfs`, `launchctl` and `$NOTIFY_CMD` that record their
argv to a log and return scripted output. Assertions are then made on the
recorded command lines — which is how every destructive path gets full coverage
without ever being destructive.

## 17. Non-functional *(spec)*

* **Completion**: `_my-tm` written to the invoking user's `~/.zsh/completions/`
  on every run — owned by them even under `sudo`, and only rewritten when the
  content differs — plus a bash file when bash is the caller. Completes
  commands, handles and IDs from the cache, and paths *inside* a snapshot
  after an ID.
* **Full Disk Access**: `tmutil listbackups|compare|delete|verifychecksums` need
  it. my-tm detects the denial and prints one pointer line rather than a stack
  of errors. The jobs get it through a launcher (§9).
* **Verbosity**: `-D` always; `-V` because there are real commands to echo;
  `-DD` for `set -x`. No `-VV` — there is no third level of informational output
  to justify it.
