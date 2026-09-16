#!/bin/sh
#
# my-tm -- swiss-army knife for Time Machine.
#
# One self-contained POSIX sh file.  BSD/macOS userland only: no GNU flags.
# Every per-item syscall is batched into one exec (see --help and the README);
# a loop that forks per item is a bug here.
#
# Design document: README.md next to this file.

set -u

## A LaunchDaemon starts with a near-empty environment: no HOME. Under set -u
## the first "$HOME" below then kills the script before it does anything --
## every job --install writes died that way ("HOME: unbound variable"). Take
## the home directory from the passwd entry, the same place login does, and
## export it for the tools my-tm runs. Should even that come back empty, the
## paths built on it degrade instead of the script crashing.
if [ -z "${HOME:-}" ]; then
	HOME=$(id -P 2>/dev/null | awk -F: '{print $9}')
	export HOME
fi

## Nothing my-tm creates is world-readable: its caches and logs describe what is
## in the backups. Files take group-read; the directory they sit in decides
## whether the group can reach them.
umask 027

US="${0##*/}"
MY_TM_VERSION="0.9.2"

#############################################################################
## DEFAULTS -- all neutral.  Site values belong in the config file, never here.
#############################################################################

AUTO_MOUNT_DESTINATIONS=1
DEFAULT_CMD="--status"
TM_GROUP=""
CACHE_DIR="/var/lib/my-tm"
CACHE_MODE=0750
CACHE_DIR_USER="$HOME/Library/Caches/my-tm"
LOG_DIR="$HOME/Library/Logs/my-tm"
FIRMLINK="/tm"
MOUNT_ROOT="/var/lib/my-tm/mount"
## Where the site keeps its config. Honoured from the ENVIRONMENT too: the
## search below needs this value before any config has been read, so a value
## set inside a config file can only ever say where --install WRITES, never
## where my-tm looks.
## Set in the ENVIRONMENT it is an explicit override and outranks the site
## search, exactly like $MY_TM_CONFIG and --config; set anywhere else it only
## says where --install WRITES.
if [ -n "${SITE_CONF_DIR:-}" ]; then SITE_CONF_DIR_FROM_ENV=1; else SITE_CONF_DIR_FROM_ENV=0; fi
SITE_CONF_DIR="${SITE_CONF_DIR:-/usr/local/etc}"
## The value the SEARCH uses, frozen before any config is read: a config may move
## SITE_CONF_DIR (where --install writes), never where a plain run looks.
SITE_CONF_DIR_SEARCH="$SITE_CONF_DIR"
## The site's primary config directory, spelled out: it cannot come from a
## config, because it is where the config is found. A variable only so the suite
## can point it at a scratch directory.
CONFIG_SITE_DIR="/LINKS/default"
NOTIFY_MOUNT_WARN=1
CACHE_TTL=3600
USAGE_SAMPLE_INTERVAL=21600
IMAGE_GRACE=600
IMAGE_SCAN_TTL=300
INDEX_BASELINES="newest oldest"
INDEX_INC_MAX=16
INDEX_REMOTE_COPY=1
ID_LEN=6
## per-location parameters: NAME_DEFAULT here; NAME for one location in a
## config's set_location_parameters() (see loc_param)
THIN_POLICY_TO_KEEP_DEFAULT="24h:hourly 7d:daily 4w:weekly 2y:monthly"
HEALTH_INTERVAL="1d"
HEALTH_JOB="local.my-tm.health-check"
HEALTH_LOCATIONS="LOCAL"
HEALTH_VERIFY=""
HEALTH_WATCH_PATHS=""
# shellcheck disable=SC2034  # read through loc_param, which builds its name
HEALTH_MAX_AGE_DEFAULT="48h"
HEALTH_MIN_FREE_PCT=10
HEALTH_MAX_INTERRUPTED=2
HEALTH_DRIFT_FACTOR=5
MAINT_JOB="local.my-tm.maintenance"
MAINT_INTERVAL=120
LOCAL_SNAP_INTERVAL=""
LOCAL_SNAP_KEEP_H=24
LOCAL_SNAP_MAX=48
BACKUP_JOB="local.my-tm.backup"
BACKUP_SCHEDULE="on-boot"
BACKUP_VOLUME=""
POST_BACKUP_DEFAULT="eject"
NOTIFY_CMD=""
NO_EJECT_FLAGFILE="/var/lib/my-tm/no-eject"
LOCKFILE="/var/lib/my-tm/backup.lock"
NOTIFY_BEGIN=0
NOTIFY_END=1
EJECT_RETRIES=10
EJECT_WAIT=5
LSOF_TIMEOUT=10
JOBS_RUN_WITH_FULL_DISK_ACCESS=0
JOBS_LAUNCHER="/usr/local/sbin/my-tm-launcher"

## how long a mount made on the way into a command lives if the command dies
## without cleaning up.  Not user-tunable: it is a leak-reaper, not a policy.
TRANSIENT_TTL=900

## how many snapshots --lookup holds mounted at once.  Bounded on purpose: each
## mount pins its snapshot against thinning, and releasing one is not free.
LOOKUP_CHUNK=16

## Version-store generation.  Snapshots are immutable, so a recorded stat is
## a permanent fact -- but only if my-tm looked in the RIGHT PLACE. A bug in
## path resolution once recorded "absent" for files that were plainly there,
## and "permanent fact" then means "permanently wrong". Bump this whenever
## anything about how a path inside a snapshot is resolved changes: rows from
## an older generation are discarded rather than trusted.
VS_GENERATION=2

#############################################################################
## RUNTIME STATE (never in the config)
#############################################################################

VRB=0; DBG=0; DEEPDBG=0; DBG_PATH=""
JSON=0; OPT_ALL=0; LIMIT=""; FORCE=0; SRC=""
CONFIG_FILE=""; CONFIG_SOURCED=""
EXIT_RC=0
## set by the daemons only.  A background job may read what is already
## there; it may not SPIN A DISK UP to look, which is the whole point of
## having put it to sleep after the backup.
BACKGROUND_JOB=0
## The mount table, read from this file instead of `mount` when set. Only the
## suite sets it, the way it sets FDA_PROBE.
MOUNT_TABLE_FILE=""
## The program the job plists run: the launcher when the jobs have Full Disk
## Access, otherwise my-tm itself. Set by --install; empty means my-tm.
JOB_PROGRAM=""
## Mountpoints to release when this run ends.  A FILE, not a variable: every
## caller reaches transient_snapshot through $(...), which is a subshell, and a
## variable set there dies with it -- leaving the snapshot mounted, which is
## exactly what blocks Time Machine's thinning.
TRANSIENT_LIST="${TMPDIR:-/tmp}/.my-tm.transient.$$"
## Volumes WE mounted, to be put back exactly as they were. A file for the
## same reason as above: every caller reaches this through a subshell.
TRANSIENT_VOLUMES="${TMPDIR:-/tmp}/.my-tm.volumes.$$"
## Disk images WE attached, to be detached again on the way out.
TRANSIENT_IMAGES="${TMPDIR:-/tmp}/.my-tm.images.$$"

#############################################################################
## OUTPUT
##   >>>  major step        >>   medium        >    minor detail
##   ~~~  debug             ~    fine debug (-DD)
#############################################################################

## Progress and diagnostics go to STDERR; results go to stdout.
##
## Not cosmetic: snap_mount and image_attach are called inside $(...) to capture
## the path they produce, so anything they print on stdout is captured INTO that
## path. Under -V that silently corrupted every mountpoint my-tm handled.
msg()   { printf ' >>> %s\n' "$*" >&2; }
med()   { printf '  >> %s\n' "$*" >&2; }
minor() { printf '    > %s\n' "$*" >&2; }
warn()  { printf ' !!! %s\n' "$*" >&2; }
note()  { printf ' --> %s\n' "$*"; }

dbg() {
	[ "$DBG" = "1" ] || return 0
	printf ' ~~~ %s\n' "$*" >&2
	[ -n "$DBG_PATH" ] && printf '%s %s\n' "$(date '+%Y-%m-%d_%H%M.%S')" "$*" >>"$DBG_PATH"
	return 0
}

dbg2() {
	[ "$DEEPDBG" = "1" ] || return 0
	printf '   ~ %s\n' "$*" >&2
	return 0
}

err() {
	printf ' !!! %s\n' "$1" >&2
	exit "${2:-1}"
}

## run CMD...  -- echo it under -V, then execute it.  The echoed line and the
## executed line come from the same argv, so they can never drift.
run() {
	[ "$VRB" = "1" ] && printf ' >>> %s\n' "$*" >&2
	"$@"
}

## same, but for a command whose output is captured: caller does the exec.
run_echo() {
	[ "$VRB" = "1" ] && printf ' >>> %s\n' "$*" >&2
	return 0
}

## a `    > ` explanation belonging to the command echoed just above
why() {
	[ "$VRB" = "1" ] || return 0
	printf '    > %s\n' "$*" >&2
	return 0
}

#############################################################################
## CONFIG
#############################################################################

_default_config_content() {
	cat <<'_CFG_EOF'
#!/bin/sh
# my-tm configuration.  Plain shell, sourced at startup.
#
# Search order (first existing wins):
#   $MY_TM_CONFIG · --config <FILE> · $SITE_CONF_DIR when it came from the
#   ENVIRONMENT · /LINKS/default/my-tm.conf (or the bare /LINKS/default/my-tm)
#   · $SITE_CONF_DIR/my-tm.conf
#   · ~/.my-tm.conf · /etc/my-tm.conf · /usr/local/etc/my-tm.conf
# /LINKS/default is spelled out on purpose: a search keyed on a value that
# lives INSIDE a config file cannot find that file.
# When both a shared and a host-specific file sit at the site location, the
# host-specific one is my-tm.conf and the shared one is my-tm.conf.GLOBAL;
# my-tm sources .GLOBAL first, then my-tm.conf on top.

# Locations live in $CACHE_DIR/locations.tsv, maintained by --add / --forget --
# not in this file.
AUTO_MOUNT_DESTINATIONS=1       # a destination that is attached but not
                                # mounted is invisible to every read; mount
                                # it, use it, and put it back as it was
DEFAULT_CMD="--status"          # what a bare `my-tm` runs; params allowed
TM_GROUP=""                     # group with read access to the shared cache;
                                # "" = the invoking user's primary group
CACHE_DIR="/var/lib/my-tm"; CACHE_MODE=0750
CACHE_DIR_USER="$HOME/Library/Caches/my-tm"
LOG_DIR="$HOME/Library/Logs/my-tm"
FIRMLINK="/tm"                  # /etc/synthetic.conf entry made by --install
MOUNT_ROOT="/var/lib/my-tm/mount"
SITE_CONF_DIR="/usr/local/etc"  # where --install puts my-tm.conf
NOTIFY_MOUNT_WARN=1             # also notify when a --mount TTL looks unsafe
CACHE_TTL=3600                  # s; older -> rescan mounted locations
INDEX_BASELINES="newest oldest" # snapshots --index walks when none are named
INDEX_INC_MAX=16                # consolidate the increments once there are
                                # this many
INDEX_REMOTE_COPY=1             # also keep a local copy of a remote index, so
                                # --find works while that host is offline
IMAGE_GRACE=600                 # s an attached sparsebundle stays attached after
                                # its last use; attaching one over a share costs
                                # minutes, so back-to-back commands reuse it
ID_LEN=6
# --- retention ---
THIN_POLICY_TO_KEEP_DEFAULT="24h:hourly 7d:daily 4w:weekly 2y:monthly"
                                # what --thin keeps; for one location set
                                # THIN_POLICY_TO_KEEP in set_location_parameters
# --- health ---
HEALTH_INTERVAL="1d"            # "" / 0 / false -> no daemon installed
HEALTH_JOB="local.my-tm.health-check"
HEALTH_LOCATIONS="LOCAL"        # ON-THIS-DISK | LOCAL | ALL | handles | paths
HEALTH_VERIFY=""                # "" = off; else a list of paths, one per line
HEALTH_WATCH_PATHS=""           # paths that MUST be covered by a backup
HEALTH_MAX_AGE_DEFAULT="48h"    # a newer backup is expected within this: <N>s|m|h|d;
                                # 0 = no age expected (the age is only shown)
HEALTH_MIN_FREE_PCT=10
HEALTH_MAX_INTERRUPTED=2; HEALTH_DRIFT_FACTOR=5
# --- jobs installed by --install ---
MAINT_JOB="local.my-tm.maintenance"   # mount sweep + /tm refresh + local snaps
MAINT_INTERVAL=120              # s between maintenance runs
LOCAL_SNAP_INTERVAL=""          # "" = off. <N>m or <N>h, 1 minute .. 1 day.
                                # A short interval is a safety-net undo;
                                # cheap (metadata only), but PURGEABLE -- macOS
                                # deletes them under pressure. Not an archive.
LOCAL_SNAP_KEEP_H=24            # h; matches macOS's own ~24h rotation
LOCAL_SNAP_MAX=48               # cap for high-frequency intervals
BACKUP_JOB="local.my-tm.backup"
BACKUP_SCHEDULE="on-boot"       # on-boot | <N>s|m|h | HH:MM | Mon HH:MM ...
JOBS_RUN_WITH_FULL_DISK_ACCESS=0 # 1: the jobs run my-tm through JOBS_LAUNCHER,
                                # which holds Full Disk Access once it is added in
                                # System Settings > Privacy & Security > Full Disk
                                # Access. --install builds it (needs clang and
                                # codesign) and prints that step. The jobs need the
                                # access to look inside network volumes and for
                                # HEALTH_VERIFY checksums.
JOBS_LAUNCHER="/usr/local/sbin/my-tm-launcher"  # where --install puts it; root:wheel 0700
# --- backup control ---
BACKUP_VOLUME=""                # "" = ask tmutil which destination this is.
                                # Resolved ONCE at startup; the pre-backup
                                # mount, POST_BACKUP and the quiet rule all
                                # use that one value. More than one tmutil
                                # destination = refuse and ask, not guess.
POST_BACKUP_DEFAULT="eject"     # what happens when a backup finishes:
                                #   none     leave it mounted
                                #   unmount  diskutil unmountDisk -- the device
                                #            stays on the bus and the enclosure
                                #            spins it down on its own timer
                                #   eject    diskutil eject -- parks the drive
                                #            at once. Quietest and least
                                #            runtime, but some USB bridges then
                                #            need a replug. Test yours before
                                #            trusting it to an unattended job.
# --- per location ---
# THIN_POLICY_TO_KEEP, POST_BACKUP and HEALTH_MAX_AGE can be set for one
# location; a location not named keeps each _DEFAULT. The site's config and the
# host's may both define this function: the site's runs first, the host's last.
#set_location_parameters() {
#	case "$LOCATION" in
#		horse)      POST_BACKUP="unmount" ;;
#		horse@ada)  HEALTH_MAX_AGE="0" ;;
#	esac
#}
NOTIFY_CMD=""                   # optional external notifier; empty = osascript
NO_EJECT_FLAGFILE="/var/lib/my-tm/no-eject"
LOCKFILE="/var/lib/my-tm/backup.lock"
NOTIFY_BEGIN=0; NOTIFY_END=1
EJECT_RETRIES=10; EJECT_WAIT=5
LSOF_TIMEOUT=10                 # s the mount sweep waits for lsof. lsof walks
                                # EVERY mount, so one unresponsive filesystem
                                # wedges it beyond the reach of any signal; past
                                # this the sweep calls every candidate BUSY and
                                # releases nothing, rather than hanging a daemon.
_CFG_EOF
}

## echo every config file to source, in order (base first, override last)
## Where a config is looked for, in order.  /LINKS/default comes first and is
## SPELLED OUT: a search that depended on $SITE_CONF_DIR could only find the
## value inside the config file it has not found yet, and one gated on $LINKS
## being exported skips the location silently in a root shell.
config_search_dirs() {
	[ "$SITE_CONF_DIR_FROM_ENV" = "1" ] && printf '%s\n' "$SITE_CONF_DIR_SEARCH"
	printf '%s\n' "$CONFIG_SITE_DIR" "$SITE_CONF_DIR_SEARCH" "$HOME" /etc /usr/local/etc
}

## The same list as PATHS, for telling the user where we looked.  One source
## for the search and for the message, so they cannot drift.
config_search_paths() {
	for _cs_d in $(config_search_dirs); do
		case "$_cs_d" in
			"$HOME") printf '%s/.my-tm.conf\n' "$_cs_d" ;;
			## Under /LINKS/default BOTH spellings count: the site's config
			## farm holds some names with a .conf suffix and some without, so
			## knowing only one of them ignores a file sitting right there.
			"$CONFIG_SITE_DIR") printf '%s/my-tm.conf\n%s/my-tm\n' "$_cs_d" "$_cs_d" ;;
			*)       printf '%s/my-tm.conf\n' "$_cs_d" ;;
		esac
	done
}

## Where to OFFER writing one when none was found: the site location first,
## then the system one, then the user's -- ordered by how often each is the
## right answer, which is NOT the search order ($HOME is searched before
## /etc). Each is checked against the real search list, so this can never
## point at a file my-tm would not read.
config_offer_paths() {
	_co_all=$(config_search_paths)
	for _co_p in "$CONFIG_SITE_DIR/my-tm.conf" /etc/my-tm.conf "$HOME/.my-tm.conf"; do
		printf '%s\n' "$_co_all" | grep -qxF "$_co_p" && printf '%s\n' "$_co_p"
	done
	return 0
}

## The first config a plain run finds. It iterates config_search_paths -- the
## very list the missing-config offer is filtered through -- so what my-tm
## offers and what it loads cannot drift. A private directory walk here once
## offered /LINKS/default/my-tm while only ever loading my-tm.conf.
config_search_first() {
	for _f in $(config_search_paths); do
		if [ -f "$_f" ]; then
			[ -f "$_f.GLOBAL" ] && printf '%s\n' "$_f.GLOBAL"
			printf '%s\n' "$_f"
			return 0
		fi
	done
	return 1
}

config_candidates() {
	if [ -n "${MY_TM_CONFIG:-}" ]; then
		printf '%s\n' "$MY_TM_CONFIG"
		return 0
	fi
	if [ -n "$CONFIG_FILE" ]; then
		printf '%s\n' "$CONFIG_FILE"
		return 0
	fi
	config_search_first
}

load_config() {
	_list=$(config_candidates) || {
		dbg "no config found; running on built-in defaults"
		return 1
	}
	_tmp=$(printf '%s\n' "$_list")
	while IFS= read -r _f; do
		[ -n "$_f" ] || continue
		[ -f "$_f" ] || err "config not found: $_f"
		# shellcheck source=/dev/null
		. "$_f"
		CONFIG_SOURCED="$CONFIG_SOURCED $_f"
		dbg "sourced config: $_f"
	done <<_EOF
$_tmp
_EOF
	return 0
}

## Per-location parameters. Each is an uppercase NAME whose default is
## NAME_DEFAULT; a config sets it for one location in set_location_parameters(),
## which sees that location's handle in $LOCATION. Every loaded config file may
## define the function, and each one is called in load order (the site's, then
## the host's). The shell keeps only the LAST function of a name, so each file is
## sourced again right before its own is called. All of it in a subshell: nothing
## set for one location reaches the next, or my-tm itself.
LOCATION_PARAMETERS="THIN_POLICY_TO_KEEP POST_BACKUP HEALTH_MAX_AGE"

loc_param() {
	case " $LOCATION_PARAMETERS " in
		*" $2 "*) : ;;
		*) err "loc_param: '$2' is not a per-location parameter" ;;
	esac
	(
		for _lp_n in $LOCATION_PARAMETERS; do
			eval "$_lp_n=\${${_lp_n}_DEFAULT-}"
		done
		for _lp_f in $CONFIG_SOURCED; do
			unset -f set_location_parameters 2>/dev/null
			# shellcheck source=/dev/null
			. "$_lp_f" >/dev/null 2>&1
			command -v set_location_parameters >/dev/null 2>&1 || continue
			# shellcheck disable=SC2034  # read by the config's set_location_parameters
			LOCATION="$1"
			set_location_parameters
		done
		eval "printf '%s\n' \"\${$2-}\""
	)
}

## Settings that became per-location parameters. A config still setting one is
## stopped, naming what replaced it: ignoring it silently would change what the
## backups keep, and when a disk is ejected.
config_refuse_old_names() {
	for _on in \
		THIN_POLICY_TO_KEEP:THIN_POLICY_TO_KEEP_DEFAULT \
		THIN_POLICY_PER_LOCATION:set_location_parameters \
		POST_BACKUP:POST_BACKUP_DEFAULT \
		POST_BACKUP_PER_LOCATION:set_location_parameters \
		HEALTH_MAX_AGE_H:HEALTH_MAX_AGE_DEFAULT \
		AUTODETECT_LOCAL_TM_BACKUPS:REMOVED \
		JOBS_ACCESS_NETWORK_VOLUMES:REMOVED; do
		_on_old=${_on%%:*}
		eval "_on_set=\${$_on_old+set}"
		[ -n "$_on_set" ] || continue
		## removed outright: there is nothing to use instead, so say why
		case "$_on_old:${_on#*:}" in
			AUTODETECT_LOCAL_TM_BACKUPS:REMOVED)
				err "$_on_old is no longer read (config:$CONFIG_SOURCED) -- detection is always on now; remove the line" ;;
			JOBS_ACCESS_NETWORK_VOLUMES:REMOVED)
				err "$_on_old is no longer read (config:$CONFIG_SOURCED) -- a sparsebundle on a share is read over ssh on the host that stores it; remove the line" ;;
			*:REMOVED) err "$_on_old is no longer read (config:$CONFIG_SOURCED) -- remove the line" ;;
			*) err "$_on_old is no longer read (config:$CONFIG_SOURCED) -- use ${_on#*:} instead; $US --create-config shows the current names" ;;
		esac
	done
	return 0
}

cmd_create_config() {
	_dest="${1:-}"
	if [ -z "$_dest" ]; then
		_default_config_content
		return 0
	fi
	[ -e "$_dest" ] && err "refusing to overwrite: $_dest"
	_default_config_content >"$_dest" || err "cannot write: $_dest"
	msg "wrote default config: $_dest"
	return 0
}

#############################################################################
## PRIMITIVES
#############################################################################

is_root() { [ "$(id -u)" -eq 0 ]; }

## Full Disk Access, which tmutil delete/verifychecksums/listbackups all need.
##
## TCC denies the READ, not the stat, so [ -r ] answers yes and the open then
## fails -- the probe has to actually read a byte. The path is a variable so the
## tests can point it at something unreadable and check the negative case.
FDA_PROBE="/Library/Application Support/com.apple.TCC/TCC.db"

has_full_disk_access() {
	[ -e "$FDA_PROBE" ] || return 0     # nothing to prove it against; assume fine
	head -c 1 "$FDA_PROBE" >/dev/null 2>&1
}

require_root() {
	is_root && return 0
	err "$1 needs root: re-run with sudo."
}

## the user who invoked us, even under sudo -- their home is where per-user
## files (completion, overlay cache) belong, never root's.
invoking_user() { printf '%s\n' "${SUDO_USER:-$(id -un)}"; }

invoking_home() {
	_u=$(invoking_user)
	if [ "$_u" = "$(id -un)" ]; then
		printf '%s\n' "$HOME"
	else
		printf '%s\n' "$(dscl . -read "/Users/$_u" NFSHomeDirectory 2>/dev/null |
			sed -n 's/^NFSHomeDirectory: //p')"
	fi
}

need_dir() {
	[ -d "$1" ] && return 0
	mkdir -p "$1" 2>/dev/null || return 1
	return 0
}

## atomic_write <file>   -- stdin becomes <file>, all-or-nothing.
## The mode of a file my-tm writes is decided by its DIRECTORY: where the group
## may read the directory, the group may read the file (0640); anywhere else it
## stays private (0600). Its group already comes from the directory, which is
## where BSD puts a new file.
file_mode_from_dir() {
	case "$(stat -f '%Sp' "$(dirname "$1")" 2>/dev/null)" in
		????r*) chmod 0640 "$1" 2>/dev/null ;;
		*)      chmod 0600 "$1" 2>/dev/null ;;
	esac
	return 0
}

atomic_write() {
	_f="$1"
	_d=$(dirname "$_f")
	need_dir "$_d" || return 1
	_t=$(mktemp "$_d/.my-tm.XXXXXX") || return 1
	cat >"$_t" || { rm -f "$_t"; return 1; }
	## mktemp makes every temp 0600 and mv carries that onto the target -- which
	## left the shared cache unreadable to the group it is shared with
	file_mode_from_dir "$_t"
	mv -f "$_t" "$_f" || { rm -f "$_t"; return 1; }
	return 0
}

## true when any component of <path> is writable by group or other -- the test
## --install uses to refuse installing a job that runs a binary someone else
## could rewrite.
path_is_user_writable() {
	_p="$1"
	[ -e "$_p" ] || return 1
	while :; do
		## symbolic form (drwxr-xr-x): char 6 is group-write, char 9 other-write.
		## Octal would have to be de-zero-padded before $(( )) reads it as decimal.
		_s=$(stat -f '%Sp' "$_p" 2>/dev/null) || return 1
		case "$_s" in
			?????w????) return 0 ;;
		esac
		case "$_s" in
			????????w?) return 0 ;;
		esac
		[ "$_p" = "/" ] && return 1
		_p=$(dirname "$_p")
	done
}

#############################################################################
## SIZES, TIMES
#############################################################################

human_bytes() {
	awk -v b="${1:-0}" 'BEGIN{
		if (b == "" || b == "-") { print "-"; exit }
		split("B K M G T P", u, " ");
		i = 1;
		while (b >= 1024 && i < 6) { b /= 1024; i++ }
		if (i == 1)      printf "%dB\n", b;
		else if (b < 10) printf "%.2f%s\n", b, u[i];
		else             printf "%.1f%s\n", b, u[i];
	}'
}

## Counting lines.  NEVER `grep -c ... || echo 0`: grep -c PRINTS the count and
## ALSO exits 1 when there are no matches, so the fallback fires on success and
## the caller reads "0\n0".
count_lines() { awk 'length > 0 { n++ } END { print n + 0 }'; }
count_match() { awk -v p="$1" 'index($0, p) > 0 { n++ } END { print n + 0 }'; }

## a size column that is honest about not knowing yet
size_or_q() {
	if [ "${1:--}" = "-" ]; then printf '?'; else human_bytes "$1"; fi
}

human_count() {
	awk -v n="${1:-0}" 'BEGIN{
		if (n == "" || n == "-") { print "-"; exit }
		if (n < 1000)      { printf "%d\n", n; exit }
		if (n < 1000000)   { printf "%.1fk\n", n/1000; exit }
		printf "%.1fM\n", n/1000000;
	}'
}

## seconds -> 14m / 2d / 329d
human_age() {
	awk -v s="${1:-0}" 'BEGIN{
		if (s < 0) s = 0;
		if (s < 3600)  { printf "%dm\n", int(s/60);   exit }
		if (s < 86400) { printf "%dh\n", int(s/3600); exit }
		printf "%dd\n", int(s/86400);
	}'
}

now_epoch() { date '+%s'; }

## snapshot name (2026-08-20-155805) -> epoch, in local time as macOS names them
ts_to_epoch() {
	date -j -f '%Y-%m-%d-%H%M%S' "$1" '+%s' 2>/dev/null
}

## snapshot name -> display form 2026-08-20_1558.05
ts_display() {
	_t="$1"
	_d="${_t%-*}"
	_hms="${_t##*-}"
	case "$_hms" in
		??????) printf '%s_%s.%s\n' "$_d" "${_hms%??}" "${_hms#????}" ;;
		*)      printf '%s\n' "$_t" ;;
	esac
}

## epoch -> snapshot-name form
epoch_to_ts() { date -j -f '%s' "$1" '+%Y-%m-%d-%H%M%S' 2>/dev/null; }

## plist date "2026-03-15 23:19:11 +0000" -> epoch
plist_date_to_epoch() {
	_s="${1% +0000}"
	date -j -u -f '%Y-%m-%d %H:%M:%S' "$_s" '+%s' 2>/dev/null
}

## <TTL> -> seconds.  7m / 4h / 2d / 5h3m.  A bare number, a zero total and
## anything else are refused -- the unit is the point of asking.
parse_ttl() {
	awk -v s="$1" 'BEGIN{
		total = 0; rest = s;
		if (rest !~ /^([0-9]+[mhd])+$/) { exit 1 }
		while (match(rest, /^[0-9]+[mhd]/)) {
			chunk = substr(rest, 1, RLENGTH);
			rest  = substr(rest, RLENGTH + 1);
			unit  = substr(chunk, length(chunk), 1);
			n     = substr(chunk, 1, length(chunk) - 1) + 0;
			if (unit == "m") total += n * 60;
			else if (unit == "h") total += n * 3600;
			else total += n * 86400;
		}
		if (total <= 0) { exit 1 }
		print total;
	}'
}

## <N>s|m|h|d -> seconds (schedules and intervals; bare number = seconds)
parse_interval() {
	awk -v s="$1" 'BEGIN{
		if (s ~ /^[0-9]+$/)      { print s + 0; exit }
		if (s !~ /^[0-9]+[smhd]$/) { exit 1 }
		u = substr(s, length(s), 1); n = substr(s, 1, length(s)-1) + 0;
		if (u == "s") print n;
		else if (u == "m") print n * 60;
		else if (u == "h") print n * 3600;
		else print n * 86400;
	}'
}

#############################################################################
## SNAPSHOT IDs  (deterministic; the cache is an index, never the authority)
#############################################################################

md5_file() {
	if command -v md5 >/dev/null 2>&1; then
		md5 -q "$1" 2>/dev/null
	else
		openssl md5 <"$1" 2>/dev/null | sed 's/.*= *//'
	fi
}

md5_hex() {
	if command -v md5 >/dev/null 2>&1; then
		md5 -q -s "$1"
	else
		printf '%s' "$1" | openssl md5 2>/dev/null | sed 's/.*= *//'
	fi
}

## Crockford base32 (no i l o u), lowercase, from the first 40 bits of a hex
## digest -- 8 characters, of which we normally use the first ID_LEN.
crock32() {
	awk -v h="$1" 'BEGIN{
		alpha = "0123456789abcdefghjkmnpqrstvwxyz";
		hx    = "0123456789abcdef";
		n = 0;
		for (i = 1; i <= 10; i++) {
			v = index(hx, tolower(substr(h, i, 1))) - 1;
			if (v < 0) v = 0;
			n = n * 16 + v;
		}
		out = "";
		for (i = 8; i >= 1; i--) {
			p = 1; for (k = 1; k < i; k++) p = p * 32;
			d = int(n / p); n = n - d * p;
			out = out substr(alpha, d + 1, 1);
		}
		print out;
	}'
}

## snap_id <destination-uuid> <timestamp> [<len>]
snap_id() {
	_len="${3:-$ID_LEN}"
	_full=$(crock32 "$(md5_hex "$1|$2")")
	printf '%s\n' "$(echo "$_full" | cut -c "1-$_len")"
}

## true when a word could be mistaken for an ID: 6..8 chars, all from the ID
## alphabet.  `backup` passes (it has a u, which Crockford excludes).
is_id_word() {
	case "$1" in
		[0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z]|\
		[0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z]|\
		[0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z][0-9a-hjkmnp-tv-z])
			return 0 ;;
	esac
	return 1
}

## a handle proposal -> slug (lowercase, alnum and dashes)
slug() {
	printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' |
		sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

#############################################################################
## CACHE LOCATIONS
##   shared dir is root-written, group-readable; every other user writes to
##   their own overlay.  Readers merge: shared first, overlay on top.
#############################################################################

cache_write_dir() {
	if [ -d "$CACHE_DIR" ] && [ -w "$CACHE_DIR" ]; then
		printf '%s\n' "$CACHE_DIR"
	elif is_root; then
		need_dir "$CACHE_DIR" && printf '%s\n' "$CACHE_DIR" || printf '%s\n' "$CACHE_DIR_USER"
	else
		need_dir "$CACHE_DIR_USER" >/dev/null 2>&1
		printf '%s\n' "$CACHE_DIR_USER"
	fi
}

## Where mounts really go.  $MOUNT_ROOT is the shared location --install
## creates; an ordinary user who has never run --install cannot create it,
## and must still be able to mount a snapshot, so fall back to their own
## overlay.  Resolved once at startup, so every later use agrees.
mount_root_resolve() {
	if [ -d "$MOUNT_ROOT" ] && [ -w "$MOUNT_ROOT" ]; then
		printf '%s\n' "$MOUNT_ROOT"
	elif [ ! -e "$MOUNT_ROOT" ] && mkdir -p "$MOUNT_ROOT" 2>/dev/null; then
		printf '%s\n' "$MOUNT_ROOT"
	else
		printf '%s/mount\n' "$CACHE_DIR_USER"
	fi
	return 0
}

## every dir a reader must consult, shared first
cache_read_dirs() {
	[ -d "$CACHE_DIR" ] && printf '%s\n' "$CACHE_DIR"
	[ -d "$CACHE_DIR_USER" ] && [ "$CACHE_DIR_USER" != "$CACHE_DIR" ] &&
		printf '%s\n' "$CACHE_DIR_USER"
	return 0
}

#############################################################################
## LOCATIONS
##   locations.tsv:  HANDLE <TAB> TARGET <TAB> [REMOTE-INSTALL-DIR]
##   TARGET is a local path, an ssh target host:/path, or the word `local`.
#############################################################################

## ONE list, in the shared cache dir, whoever runs my-tm: a location belongs to
## the MACHINE, not to a person. A per-user copy would be listed for that user
## alone and never refreshed, checked or indexed by the daemons, which run as
## root and read this file.
locations_file() { printf '%s/locations.tsv\n' "$CACHE_DIR"; }

## write the location list from stdin (the tests restore it this way)
cache_write_locations() {
	_cwl=$(locations_file)
	grep -v '^[[:space:]]*$' | atomic_write "$_cwl" 2>/dev/null || true
	return 0
}

## The shared list is root's to write. Refuse in one line that names the very
## command to run again, rather than writing a private copy nobody's daemon
## reads.
locations_writable() {
	_lw_f=$(locations_file)
	if [ -f "$_lw_f" ]; then
		[ -w "$_lw_f" ] && return 0
	else
		need_dir "$(dirname "$_lw_f")" >/dev/null 2>&1
		[ -w "$(dirname "$_lw_f")" ] && return 0
	fi
	err "$_lw_f is the shared location list: needs root -- rerun as root: $US ${1:-}"
}

## a per-user list from before that rule: no longer read, named once so the
## locations in it do not just vanish
locations_user_file() {
	[ -n "${CACHE_DIR_USER:-}" ] || return 1
	[ "$CACHE_DIR_USER" != "$CACHE_DIR" ] || return 1
	[ -f "$CACHE_DIR_USER/locations.tsv" ] || return 1
	printf '%s/locations.tsv\n' "$CACHE_DIR_USER"
}

locations_user_file_note() {
	_luf=$(locations_user_file) || return 0
	_lun=$(grep -cv '^[[:space:]]*\(#.*\)\{0,1\}$' "$_luf" 2>/dev/null) || _lun=0
	[ "$_lun" -gt 0 ] || return 0
	note "$_lun location(s) in $_luf are no longer read -- locations are shared now, add them again as root:"
	awk -F'\t' 'NF && $1 !~ /^[[:space:]]*#/ { printf "  %s --add %s %s\n", us, $2, $1 }' us="$US" "$_luf" |
		while IFS= read -r _lul; do minor "${_lul# }"; done
	return 0
}

## every registered location, shared file first, then this user's own
locations_registered() {
	_lr=$(locations_file)
	[ -f "$_lr" ] || return 0
	grep -v '^[[:space:]]*#' "$_lr" 2>/dev/null | grep -v '^[[:space:]]*$'
	return 0
}

## tmutil's own destinations -> handle <TAB> mountpoint <TAB> "" <TAB> uuid
destinations_scan() {
	## A destination with NO "Mount Point:" line is ejected or otherwise not
	## attached. tmutil still knows it, and it MUST still be listed: dropping it
	## would hide exactly the case --status exists for -- a disk that has not
	## been backed up to for days. Its conventional path stands in as the label
	## while it is away; nothing reads that path until it is really mounted.
	tmutil destinationinfo 2>/dev/null | awk '
		/^Name +:/        { sub(/^[^:]*: */, ""); name = $0 }
		/^Kind +:/        { sub(/^[^:]*: */, ""); kind = $0 }
		/^Mount Point +:/ { sub(/^[^:]*: */, ""); mp   = $0 }
		/^ID +:/          { sub(/^[^:]*: */, ""); id   = $0;
		                    if (name != "") {
		                        if (mp == "") mp = "/Volumes/" name;
		                        printf "%s\t%s\t%s\t%s\n", name, mp, id, kind;
		                    }
		                    name = ""; kind = ""; mp = ""; id = "" }
	'
}

## all locations: registered + (optionally) autodetected + the `local` pseudo
## emits: handle <TAB> target <TAB> installdir
locations_all() {
	_seen=""
	_seenpaths=""
	_reg=$(locations_registered)
	if [ -n "$_reg" ]; then
		while IFS= read -r _l; do
			[ -n "$_l" ] || continue
			_h=$(printf '%s' "$_l" | awk -F'\t' '{print $1}')
			[ -n "$_h" ] || continue
			_seen="$_seen $_h"
			_seenpaths="$_seenpaths $(printf '%s' "$_l" | awk -F'\t' '{print $2}')"
			printf '%s\n' "$_l"
		done <<_EOF
$_reg
_EOF
	fi
	## Time Machine's own destinations, always: what this Mac is set up to back
	## up to is not a matter of taste. A disk already registered is skipped by
	## its TARGET, not just by its handle -- otherwise the same disk appears
	## twice, once under the name you gave it and once under its volume name.
	_dst=$(destinations_scan)
	if [ -n "$_dst" ]; then
		while IFS="$(printf '\t')" read -r _name _mp _id _kind; do
			[ -n "${_mp:-}" ] || continue
			case " $_seenpaths " in *" $_mp "*) continue ;; esac
			_h=$(slug "$_name")
			case " $_seen " in *" $_h "*) continue ;; esac
			## a handle that could read as an ID is unusable (rung 1 wins)
			is_id_word "$_h" && _h="${_h}-tm"
			_seen="$_seen $_h"
			_seenpaths="$_seenpaths $_mp"
			printf '%s\t%s\t\n' "$_h" "$_mp"
		done <<_EOF
$_dst
_EOF
	fi
	## this Mac's own backups inside a sparsebundle on a mounted volume -- a
	## destination it may have stopped using, whose history is still there
	_imgs=$(autodetect_images)
	if [ -n "$_imgs" ]; then
		while IFS= read -r _b; do
			[ -n "$_b" ] || continue
			case " $_seenpaths " in *" $_b "*) continue ;; esac
			_h=$(slug "$(basename "$_b" .sparsebundle)")
			is_id_word "$_h" && _h="${_h}-tm"
			case " $_seen " in *" $_h "*) _h="${_h}-img" ;; esac
			case " $_seen " in *" $_h "*) continue ;; esac
			_seen="$_seen $_h"
			_seenpaths="$_seenpaths $_b"
			printf '%s\t%s\t\n' "$_h" "$_b"
		done <<_EOF
$_imgs
_EOF
	fi
	case " $_seen " in
		*" local "*) : ;;
		*) printf 'local\tlocal\t\n' ;;
	esac
	return 0
}

## A handle ends up in half a dozen file names -- $MOUNT_ROOT/<handle>,
## usage.<handle>.tsv, .manifest.<handle>, <handle>.db, <handle>.covered -- and
## in a TAB-separated row. So: letters, digits, - . @ only, and never leading
## with - or . (an option, or a dotfile). `horse@ada' is exactly why @ is in.
handle_is_sane() {
	case "${1:-}" in
		"" | -* | .*) return 1 ;;
		*[!A-Za-z0-9.@-]*) return 1 ;;
	esac
	return 0
}

## awk must CONSUME the whole pipe here: an early `exit` closes it and the
## producing printf takes a SIGPIPE, which surfaces as a write error.
loc_line() {
	_want="$1"
	locations_all | awk -F'\t' -v w="$_want" '$1 == w && !f { print; f = 1 }
		END { exit(f ? 0 : 1) }'
}

loc_target() { loc_line "$1" | awk -F'\t' '{print $2}'; }
loc_install_dir() { loc_line "$1" | awk -F'\t' '{print $3}'; }

## A sparsebundle is a Time Machine store inside a disk image: the store is
## only readable once the image is attached, but its identity is readable
## from Info.plist without attaching anything.
is_image_target() {
	case "$1" in
		*.sparsebundle|*.sparseimage|*.dmg) return 0 ;;
	esac
	return 1
}

## This Mac's own hardware UUID -- the same value a sparsebundle records in its
## MachineID.plist. Overridable so the tests can pretend to be another Mac.
MAC_UUID="${MAC_UUID:-}"

mac_uuid() {
	if [ -n "$MAC_UUID" ]; then printf '%s\n' "$MAC_UUID"; return 0; fi
	ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
		sed -nE 's/.*"IOPlatformUUID" = "([^"]*)".*/\1/p' | head -n 1
}

## which Mac a sparsebundle holds the backups OF
bundle_host_uuid() {
	_mp="$1/com.apple.TimeMachine.MachineID.plist"
	[ -f "$_mp" ] || return 1
	## the dots are part of the KEY, not a key path -- plutil needs them escaped,
	## or it goes looking for com -> apple -> backupd -> HostUUID and finds nothing
	plutil -extract 'com\.apple\.backupd\.HostUUID' raw -o - "$_mp" 2>/dev/null
}

## A bundle recording THIS Mac's UUID is this Mac's own backup history. That is
## a fact, not a guess -- which is why it can be picked up automatically, while
## another Mac's backups are only ever added by hand.
bundle_is_mine() {
	_bu=$(bundle_host_uuid "$1") || return 1
	[ -n "$_bu" ] || return 1
	[ "$_bu" = "$(mac_uuid)" ]
}

## Sparsebundles on mounted volumes that belong to this Mac.
##
## Cached briefly: locations_all is called many times per run, and a fork per
## bundle per call would be paid over and over for an answer that changes when
## someone plugs something in, not between two lines of the same table.
autodetect_images() {
	_f="$(cache_write_dir)/images.autodetect"
	if [ -f "$_f" ]; then
		_age=$(( $(now_epoch) - $(stat -f '%m' "$_f" 2>/dev/null || echo 0) ))
		[ "$_age" -lt "${IMAGE_SCAN_TTL:-300}" ] && { cat "$_f"; return 0; }
	fi
	## through atomic_write like every other cache file: a list built in /tmp
	## and moved in kept /tmp's group and mktemp's 0600
	for _b in "${VOLUMES_DIR:-/Volumes}"/*/*.sparsebundle; do
		[ -d "$_b" ] || continue
		## a bundle on a SHARE belongs to the host that stores it: reading it
		## from here means pulling every block over the network (1060 s for
		## horse.sparsebundle on ada). It is reached through ssh instead.
		path_on_network_volume "$_b" && continue
		bundle_is_mine "$_b" || continue
		printf '%s\n' "$_b"
	done | atomic_write "$_f" 2>/dev/null
	cat "$_f" 2>/dev/null
	return 0
}

## local | ssh | image | disk
loc_kind() {
	_t=$(loc_target "$1")
	case "$_t" in local) printf 'local\n'; return 0 ;; esac
	is_remote_target "$_t" && { printf 'ssh\n'; return 0; }
	is_image_target "$_t" && { printf 'image\n'; return 0; }
	printf 'disk\n'
	return 0
}

is_remote_target() {
	case "$1" in
		local|/*) return 1 ;;
		*:/*)     return 0 ;;
	esac
	return 1
}

loc_is_remote() { is_remote_target "$(loc_target "$1")"; }

remote_host() { printf '%s\n' "${1%%:*}"; }
remote_path() { printf '%s\n' "${1#*:}"; }

## The directory holding the store: the target itself for a plain disk, and
## for an image the volume inside it, attaching it on demand. Called only
## when the store must really be READ, so a fresh cache costs no attach.
loc_store_path() {
	_h="$1"
	_t=$(loc_target "$_h")
	case "$(loc_kind "$_h")" in
		local) printf '/System/Volumes/Data\n' ;;
		image)
			if _mp=$(image_attach "$_t"); then
				printf '%s\n' "$_mp"
			else
				## warning here, error where a command named this store: this is
				## reached both from a sweep over every location and from a direct
				## request, and only the caller knows which
				warn "$_h: could not open $_t read-only -- it is not readable right now"
				return 1
			fi
			;;
		*) printf '%s\n' "$_t" ;;
	esac
	return 0
}

## the volume whose APFS snapshots this location holds
loc_volume() { loc_store_path "$1"; }

## device node of a mounted volume (disk5s2)
vol_device() {
	_plist=$(mktemp /tmp/my-tm.disk.XXXXXX) || return 1
	if diskutil info -plist "$1" >"$_plist" 2>/dev/null; then
		plutil -extract DeviceIdentifier raw -o - "$_plist" 2>/dev/null
	fi
	rm -f "$_plist"
	return 0
}

## The volume a path lives on. diskutil says nothing useful about a plain file,
## so df names the mountpoint and the mountpoint carries the UUID -- the same
## UUID the backup manifest keys its volumeStoreInfo by.
path_volume_mount() { df -P "$1" 2>/dev/null | awk 'NR == 2 {print $6}'; }

path_volume_uuid() {
	_m=$(path_volume_mount "$1")
	[ -n "$_m" ] || return 1
	vol_uuid "$_m"
}

## the source volumes a store holds backups OF, straight from its manifest
loc_source_uuids() {
	_sp=$(loc_store_path "$1" 2>/dev/null) || return 1
	[ -f "$_sp/backup_manifest.plist" ] || return 1
	plutil -p "$_sp/backup_manifest.plist" 2>/dev/null | awk '
		/"volumeStoreInfo" =>/ { inv = 1; next }
		inv && /^      "[0-9A-Fa-f-]+" => \{/ {
			u = $1; gsub(/"/, "", u); print u; inv = 0
		}
	' | sort -u
}

vol_uuid() {
	_plist=$(mktemp /tmp/my-tm.disk.XXXXXX) || return 1
	if diskutil info -plist "$1" >"$_plist" 2>/dev/null; then
		plutil -extract VolumeUUID raw -o - "$_plist" 2>/dev/null
	fi
	rm -f "$_plist"
	return 0
}

## the UUID snapshot IDs are derived from: the destination ID when tmutil knows
## this store, else the store volume's own UUID.  Both are stable facts of the
## disk, so an ID survives a cache wipe and matches on another machine.
loc_uuid() {
	_h="$1"
	_t=$(loc_target "$_h")
	case "$_t" in
		local) vol_uuid /System/Volumes/Data; return 0 ;;
	esac
	is_remote_target "$_t" && { printf '%s\n' "$_t"; return 0; }
	## a sparsebundle carries its own uuid in Info.plist, readable WITHOUT
	## attaching it -- so snapshot IDs are stable even for a store that is
	## offline, and survive the share being mounted somewhere else
	if is_image_target "$_t" && [ -f "$_t/Info.plist" ]; then
		_iu=$(plutil -extract uuid raw -o - "$_t/Info.plist" 2>/dev/null)
		[ -n "$_iu" ] && { printf '%s\n' "$_iu"; return 0; }
	fi
	_d=$(destinations_scan | awk -F'\t' -v mp="$_t" '$2 == mp && !f { print $3; f = 1 }')
	if [ -n "$_d" ]; then
		printf '%s\n' "$_d"
	else
		vol_uuid "$_t"
	fi
	return 0
}

loc_reachable() {
	_t=$(loc_target "$1")
	case "$_t" in
		local) return 0 ;;
	esac
	is_remote_target "$_t" && return 0
	## an image only has to BE there; opening it is a separate, later cost
	is_image_target "$_t" && { [ -f "$_t/Info.plist" ] || [ -f "$_t" ]; return $?; }
	[ -d "$_t" ]
}

#############################################################################
## SNAPSHOT ENUMERATION
#############################################################################

## snapshot timestamps of a location, oldest first.
## Backup stores: the APFS snapshots of the store volume, which needs neither
## root nor Full Disk Access (tmutil listbackups would need both).
snap_names() {
	_h="$1"
	_t=$(loc_target "$_h")
	case "$_t" in
		local)
			tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null |
				sed -nE 's/^com\.apple\.TimeMachine\.([0-9-]+)\.local$/\1/p' | sort
			return 0
			;;
	esac
	is_remote_target "$_t" && { remote_snap_names "$_h"; return 0; }
	_sp=$(loc_store_path "$_h") || return 0
	[ -d "$_sp" ] || return 0
	_dev=$(vol_device "$_sp")
	[ -n "$_dev" ] || return 0
	diskutil apfs listSnapshots "$_dev" 2>/dev/null |
		sed -nE 's/.*com\.apple\.TimeMachine\.([0-9-]+)\.backup.*/\1/p' | sort
	return 0
}

## the APFS snapshot name for a timestamp in a location
snap_apfs_name() {
	case "$(loc_target "$1")" in
		local) printf 'com.apple.TimeMachine.%s.local\n' "$2" ;;
		*)     printf 'com.apple.TimeMachine.%s.backup\n' "$2" ;;
	esac
}

## in-progress / interrupted leftovers at the store root
snap_states() {
	_t=$(loc_target "$1")
	case "$_t" in local) return 0 ;; esac
	is_remote_target "$_t" && return 0
	_t=$(loc_store_path "$1") || return 0
	[ -d "$_t" ] || return 0
	## Only conditions worth reporting. A <ts>.previous directory is NOT one: it
	## is the working copy Time Machine keeps of the last completed backup, to
	## compare the next one against, so it is present after every successful
	## backup and simply moves to the newest. Reporting it as a state made the
	## newest backup look like it was in some peculiar condition.
	for _e in "$_t"/*.inprogress "$_t"/*.interrupted; do
		[ -e "$_e" ] || continue
		_b=$(basename "$_e")
		printf '%s\t%s\n' "${_b%.*}" "${_b##*.}"
	done
	return 0
}

#############################################################################
## THE MANIFEST
##   <store>/backup_manifest.plist is readable on the live store with NO mount:
##   one plutil + one awk gives every snapshot's stats.  It is a flat array
##   alternating date, record, date, record...; the date of a pair is exactly
##   the snapshot's creation instant, which is what the join below uses.
#############################################################################

manifest_parse() {
	_mp="$1"
	[ -f "$_mp/backup_manifest.plist" ] || return 1
	plutil -p "$_mp/backup_manifest.plist" 2>/dev/null | awk '
		function utc_epoch(s,   y, mo, d, h, mi, se, days, era, yoe, doy, doe, a) {
			y  = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0;
			h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0;
			# days_from_civil (Howard Hinnant): exact, and needs no timezone
			y -= (mo <= 2);
			era = int((y >= 0 ? y : y - 399) / 400);
			yoe = y - era * 400;
			a   = (mo > 2 ? mo - 3 : mo + 9);
			doy = int((153 * a + 2) / 5) + d - 1;
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
			days = era * 146097 + doe - 719468;
			return days * 86400 + h * 3600 + mi * 60 + se;
		}
		/^  [0-9]+ => [0-9][0-9][0-9][0-9]-/ {
			sub(/^[^>]*=> /, ""); pdate = $0; next
		}
		/^  [0-9]+ => \{/ { inrec = 1; cc = ""; cp = ""; pl = ""; vn = ""; xid = ""; next }
		inrec && /^      "changed" =>/    { sec = "c"; next }
		inrec && /^      "propagated" =>/ { sec = "p"; next }
		inrec && /^        "count" =>/ {
			sub(/^[^>]*=> /, ""); if (sec == "c") cc = $0; next
		}
		inrec && /^        "physicalSize" =>/ {
			sub(/^[^>]*=> /, ""); if (sec == "c") cp = $0; next
		}
		inrec && /^        "logicalSize" =>/ {
			sub(/^[^>]*=> /, ""); if (sec == "p") pl = $0; next
		}
		inrec && /^        "name" =>/ {
			sub(/^[^>]*=> /, ""); gsub(/"/, ""); if (vn == "") vn = $0; next
		}
		inrec && /^    "xid" =>/ {
			sub(/^[^>]*=> /, ""); xid = $0; inrec = 0;
			printf "%d\t%s\t%s\t%s\t%s\t%s\n",
			       utc_epoch(pdate), (cc == "" ? "-" : cc), (cp == "" ? "-" : cp),
			       (pl == "" ? "-" : pl), (vn == "" ? "-" : vn), (xid == "" ? "-" : xid);
			next
		}
	'
	return 0
}

#############################################################################
## THE SNAPSHOT TABLE  (cache is an index; the store is the authority)
##   snapshots.cache:  loc ts epoch id xid files added total unique state vol
#############################################################################

## The snapshot cache is DERIVED data, so it can afford to be strict: anything
## that does not verify is thrown away and rescanned rather than half-read.
##
## The checksum lives in the file's own first line, not beside it, so it is
## swapped atomically together with the content -- a separate checksum file
## would have a window where the two disagree, and several users plus root write
## here. Rows are validated as well: a checksum only proves the file is intact,
## not that what was written made sense.
CACHE_MAGIC="#my-tm-cache 1"

## stdin -> <file>, with an integrity header
cache_write_checked() {
	_cf="$1"
	_body=$(mktemp /tmp/my-tm.cw.XXXXXX) || return 1
	cat >"$_body"
	{
		printf '%s %s\n' "$CACHE_MAGIC" "$(md5_file "$_body")"
		cat "$_body"
	} | atomic_write "$_cf"
	_rc=$?
	rm -f "$_body"
	return $_rc
}

## <file> -> its rows on stdout, or nothing at all if it does not verify
cache_read_checked() {
	_cf="$1"
	[ -f "$_cf" ] || return 1
	## exists but unreadable is a permission problem, not a malformed file --
	## say so, or the group silently loses the cache it was meant to share
	if [ ! -r "$_cf" ]; then
		dbg "cannot read $_cf (permission) -- treating the cache as absent"
		return 1
	fi
	_hdr=$(head -n 1 "$_cf" 2>/dev/null)
	case "$_hdr" in
		"$CACHE_MAGIC "*) : ;;
		*)
			## no header at all: an old cache, or something else entirely
			dbg "cache has no integrity header, discarding: $_cf"
			return 1
			;;
	esac
	_want=${_hdr##* }
	_body=$(mktemp /tmp/my-tm.cr.XXXXXX) || return 1
	tail -n +2 "$_cf" >"$_body"
	_have=$(md5_file "$_body")
	if [ "$_want" != "$_have" ]; then
		warn "$_cf is damaged (checksum does not match) -- discarding it and reading the store again"
		rm -f "$_body" "$_cf"
		return 1
	fi
	## structurally sound rows only: a bad row would otherwise be shown as a real
	## snapshot, and non-numeric arithmetic aborts the run outright
	awk -F'\t' '
		NF == 11 && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]$/ &&
		$3 ~ /^[0-9]+$/ { print; next }
		{ bad++ }
		END { if (bad > 0) printf "my-tm: %d unusable row(s) ignored\n", bad > "/dev/stderr" }
	' "$_body"
	rm -f "$_body"
	return 0
}

snapshots_cache_file() { printf '%s/snapshots.cache\n' "$(cache_write_dir)"; }

## build the table for one location, live
snapshots_build() {
	_h="$1"
	_uuid=$(loc_uuid "$_h")
	_names=$(snap_names "$_h")
	[ -n "$_names" ] || return 0

	_tmpd=$(mktemp -d /tmp/my-tm.snap.XXXXXX) || return 1
	## snapshot name -> epoch.  One date(1) per snapshot, and only on a cache
	## miss: BSD date takes a single value per call, and the local-time names
	## cross DST boundaries, so no single offset would be correct.
	while IFS= read -r _ts; do
		[ -n "$_ts" ] || continue
		printf '%s\t%s\n' "$(ts_to_epoch "$_ts")" "$_ts"
	done >"$_tmpd/snaps" <<_EOF
$_names
_EOF

	if [ "$(loc_kind "$_h")" = "local" ]; then
		: >"$_tmpd/manifest"
	else
		_sp=$(loc_store_path "$_h") || _sp=""
		if [ -n "$_sp" ]; then
			manifest_parse "$_sp" >"$_tmpd/manifest" 2>/dev/null || : >"$_tmpd/manifest"
		else
			: >"$_tmpd/manifest"
		fi
	fi
	snap_states "$_h" >"$_tmpd/states" 2>/dev/null || : >"$_tmpd/states"

	awk -F'\t' -v loc="$_h" '
		FILENAME ~ /manifest$/ { mf[$1] = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; next }
		FILENAME ~ /states$/   { st[$1] = $2; next }
		FILENAME ~ /snaps$/ {
			ep = $1; ts = $2;
			files = "-"; added = "-"; total = "-"; vol = "-"; xid = "-";
			if (ep in mf) { split(mf[ep], m, "\t");
				files = m[1]; added = m[2]; total = m[3]; vol = m[4]; xid = m[5] }
			state = (ts in st) ? st[ts] : "ok";
			## every field carries a placeholder, never an empty string: tab is
			## an IFS *whitespace* character, so two adjacent tabs would count
			## as ONE delimiter and shift every later column left.
			printf "%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\t-\t%s\t%s\n",
			       loc, ts, ep, xid, files, added, total, state, vol;
		}
	' "$_tmpd/manifest" "$_tmpd/states" "$_tmpd/snaps" |
	while IFS="$(printf '\t')" read -r _l _ts _ep _id _xid _files _added _total _uniq _state _vol; do
		_id=$(snap_id "$_uuid" "$_ts")
		## the manifest names the volume; a local snapshot has no manifest, and
		## the volume it holds is the Data volume either way
		[ "${_vol:--}" = "-" ] && _vol="Data"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_l" "$_ts" "$_ep" "$_id" "$_xid" "$_files" "$_added" \
			"$_total" "$_uniq" "$_state" "$_vol"
	done
	rm -rf "$_tmpd"
	return 0
}

## ID collisions escalate for the WHOLE colliding set, from the location's own
## snapshot list -- so every machine and every rebuilt cache agrees on lengths.
snapshots_scan() {
	_h="$1"
	_rows=$(snapshots_build "$_h")
	[ -n "$_rows" ] || return 0
	## grow the ID until it is unique inside this location
	_len="$ID_LEN"
	while [ "$_len" -lt 8 ]; do
		_dup=$(printf '%s\n' "$_rows" | awk -F'\t' '{print $4}' | sort | uniq -d | head -n 1)
		[ -z "$_dup" ] && break
		_len=$(( _len + 1 ))
		_uuid=$(loc_uuid "$_h")
		_rows=$(printf '%s\n' "$_rows" | while IFS="$(printf '\t')" read -r a b c d e f g h i j k; do
			d=$(snap_id "$_uuid" "$b" "$_len")
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j" "$k"
		done)
	done
	printf '%s\n' "$_rows"
	return 0
}

## cache-gated table for one location
snapshots_get() {
	_h="$1"
	## A store that is not there cannot be scanned, and its last known table is
	## the only honest answer. Centrally, so every caller agrees: --status,
	## --ls, -J and resolving an <ID> must not each decide this differently.
	if ! loc_reachable "$_h"; then
		snapshots_cached_only "$_h"
		return 0
	fi
	_cf=$(snapshots_cache_file)
	_fresh=0
	if [ -f "$_cf" ]; then
		_age=$(( $(now_epoch) - $(stat -f '%m' "$_cf" 2>/dev/null || echo 0) ))
		[ "$_age" -lt "$CACHE_TTL" ] && _fresh=1
	fi
	## Local snapshots are purgeable and churn constantly, and listing them is
	## one cheap call -- caching that list only ever produces wrong answers.
	[ "$(loc_kind "$_h")" = "local" ] && _fresh=0

	## For a store that is ALREADY open, enumerating snapshot names is two
	## cheap calls, so the cached set is checked against reality rather than
	## trusted for an hour: Time Machine adds and thins snapshots constantly,
	## and "newest backup" is the number this tool exists to get right. An
	## image is exempt -- validating it would mean attaching it over a share.
	if [ "$_fresh" = "1" ] && [ "$(loc_kind "$_h")" = "disk" ] && loc_reachable "$_h"; then
		_live=$(snap_names "$_h" | LC_ALL=C sort)
		_have=$(cache_read_checked "$_cf" 2>/dev/null |
			awk -F'\t' -v l="$_h" '$1 == l {print $2}' | LC_ALL=C sort)
		if [ "$_live" != "$_have" ]; then
			dbg "snapshots: the store no longer matches the cache for '$_h' -- rescanning"
			_fresh=0
		fi
	fi
	if [ "$_fresh" = "1" ]; then
		_cached=$(cache_read_checked "$_cf" 2>/dev/null | awk -F'\t' -v l="$_h" '$1 == l')
		if [ -n "$_cached" ]; then
			dbg "snapshots: cache hit for '$_h'"
			printf '%s\n' "$_cached"
			return 0
		fi
	fi
	dbg "snapshots: scanning '$_h'"
	_rows=$(snapshots_scan "$_h")
	[ -n "$_rows" ] || return 0
	snapshots_cache_put "$_h" "$_rows"
	printf '%s\n' "$_rows"
	return 0
}

snapshots_cache_put() {
	_h="$1"; _rows="$2"
	_cf=$(snapshots_cache_file)
	_old=""
	[ -f "$_cf" ] && _old=$(cache_read_checked "$_cf" 2>/dev/null | awk -F'\t' -v l="$_h" '$1 != l')
	{
		[ -n "$_old" ] && printf '%s\n' "$_old"
		printf '%s\n' "$_rows"
	} | cache_write_checked "$_cf" 2>/dev/null || dbg "snapshots cache not writable: $_cf"
	return 0
}

## Rows straight from the cache, never scanning: what --status and --ls fall
## back to when the disk is not attached. A location that has gone away must
## still report its last known state -- that is the whole point of --status.
snapshots_cached_only() {
	for _d in $(cache_read_dirs); do
		[ -f "$_d/snapshots.cache" ] || continue
		cache_read_checked "$_d/snapshots.cache" 2>/dev/null |
			awk -F'\t' -v l="$1" '$1 == l'
	done
	return 0
}

## every location's rows
snapshots_all() {
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		## open it if that is cheap, but never SKIP it: snapshots_get falls back
		## to the last known table, and an <ID> must stay resolvable while its
		## store is away -- otherwise my-tm prints an ID and then denies it.
		loc_open "$_h" >/dev/null 2>&1 || true
		snapshots_get "$_h"
	done <<_EOF
$_locs
_EOF
	return 0
}

#############################################################################
## RESOLVING AN <ID>
##   accepted: full ID, a >=4 char prefix while unambiguous, `latest`, -1..-N,
##   <handle>@<date-prefix>
#############################################################################

## emits: loc <TAB> ts <TAB> id       (and fails with a message on the CLI)
resolve_id() {
	_w="$1"; _scope="${2:-}"
	_rows=""
	if [ -n "$_scope" ]; then
		_rows=$(snapshots_get "$_scope")
	else
		_rows=$(snapshots_all)
	fi
	[ -n "$_rows" ] || return 1

	case "$_w" in
		latest)
			printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | tail -n 1 |
				awk -F'\t' '{printf "%s\t%s\t%s\n", $1, $2, $4}'
			return 0
			;;
		-[0-9]*)
			_n="${_w#-}"
			printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3nr | sed -n "${_n}p" |
				awk -F'\t' '{printf "%s\t%s\t%s\n", $1, $2, $4}'
			return 0
			;;
		*@*)
			_lh="${_w%%@*}"; _dp="${_w#*@}"
			printf '%s\n' "$_rows" | awk -F'\t' -v l="$_lh" -v d="$_dp" \
				'$1 == l && index($2, d) == 1 {printf "%s\t%s\t%s\n", $1, $2, $4; exit}'
			return 0
			;;
	esac

	_hits=$(printf '%s\n' "$_rows" | awk -F'\t' -v w="$_w" '$4 == w {printf "%s\t%s\t%s\n", $1, $2, $4}')
	if [ -z "$_hits" ] && [ "${#_w}" -ge 4 ]; then
		_hits=$(printf '%s\n' "$_rows" | awk -F'\t' -v w="$_w" \
			'index($4, w) == 1 {printf "%s\t%s\t%s\n", $1, $2, $4}')
	fi
	_n=$(printf '%s\n' "$_hits" | count_lines)
	case "$_n" in
		0) return 1 ;;
		1) printf '%s\n' "$_hits"; return 0 ;;
		*)
			warn "$_w: ambiguous, matches $_n snapshots:"
			printf '%s\n' "$_hits" | awk -F'\t' '{printf "       %s@%s  (%s)\n", $1, $3, $2}' >&2
			exit 1
			;;
	esac
}

## the friendly "it is gone" message the design asks for
snapshot_gone() {
	warn "$1: no such snapshot. Try: $US --ls"
	exit 1
}

#############################################################################
## MOUNTS
##   Real mountpoints live under $MOUNT_ROOT/.mnt/<loc>/<ts>/ ; the browsable
##   tree /tm/<loc>/<ts>/<vol> is a symlink into it.  That is what keeps the
##   layout uniform: a backup-store snapshot mounts with an inner <ts>.backup/
##   wrapper, a local one does not, and neither shape reaches the user.
#############################################################################

## Where an image is attached right now, if it is attached at all -- by us or
## by anyone else. hdiutil knows; the mount table alone does not say which
## volume came from which image.
image_mountpoint() {
	_pl=$(mktemp /tmp/my-tm.hdi.XXXXXX) || return 1
	hdiutil info -plist >"$_pl" 2>/dev/null || { rm -f "$_pl"; return 1; }
	_mp=$(plutil -p "$_pl" 2>/dev/null | awk -v img="$1" '
		/"image-path" =>/ { p = $0; sub(/^[^>]*=> /, "", p); gsub(/"/, "", p);
		                    here = (p == img) }
		here && /"mount-point" =>/ && !f { m = $0; sub(/^[^>]*=> /, "", m);
		                    gsub(/"/, "", m); print m; f = 1 }')
	rm -f "$_pl"
	[ -n "$_mp" ] || return 1
	printf '%s\n' "$_mp"
	return 0
}

## Attach read-only, always: a Time Machine sparsebundle belongs to the Mac
## that backs up into it, and a writable attach could collide with it.
## Read-only also means no fsck and no risk to the backup.
image_attach() {
	_img="$1"
	if _mp=$(image_mountpoint "$_img"); then
		dbg "$_img is already attached at $_mp -- reusing it"
		image_touch "$_img" "$_mp"
		printf '%s\n' "$_mp"
		return 0
	fi
	_pl=$(mktemp /tmp/my-tm.att.XXXXXX) || return 1
	run_echo hdiutil attach -readonly -nobrowse -noverify -noautofsck "$_img"
	why "read-only, so it cannot collide with the Mac that backs up into it"
	## Attaching a sparsebundle over a share takes minutes and hdiutil says
	## NOTHING while it does: -puppetstrings emits no progress for an attach
	## with -noverify (measured -- the man page's "indeterminate" case), so
	## there is no percentage to report and pretending otherwise would be a
	## made-up number. What IS true is how long it has been going, so say
	## that -- and only once it is slow enough to worry about, so a fast
	## local attach stays silent.
	## These lines go to STDERR like every other progress line: this function
	## is called inside $(...) for the path it prints.
	hdiutil attach -readonly -nobrowse -noverify -noautofsck -plist "$_img" \
			>"$_pl" 2>/dev/null &
	_att_pid=$!
	_att_t0=$(now_epoch)
	_att_said=0
	while kill -0 "$_att_pid" 2>/dev/null; do
		sleep 2
		_att_el=$(( $(now_epoch) - _att_t0 ))
		[ "$_att_el" -lt 6 ] && continue
		if [ "$_att_said" = "0" ]; then
			msg "attaching $(basename "$_img") -- this can take minutes over a share"
			_att_said=1
			_att_next=$(( _att_el + 15 ))
		elif [ "$_att_el" -ge "$_att_next" ]; then
			minor "still attaching, ${_att_el}s so far"
			_att_next=$(( _att_el + 15 ))
		fi
	done
	_att_rc=0
	wait "$_att_pid" || _att_rc=1
	if [ "$_att_rc" != "0" ]; then
		rm -f "$_pl"
		[ "$_att_said" = "1" ] && warn "attach of $(basename "$_img") failed after $(( $(now_epoch) - _att_t0 ))s"
		return 1
	fi
	[ "$_att_said" = "1" ] &&
		msg "attached $(basename "$_img") after $(( $(now_epoch) - _att_t0 ))s"
	_mp=$(plutil -p "$_pl" 2>/dev/null |
		awk '/"mount-point" =>/ && !f { m = $0; sub(/^[^>]*=> /, "", m);
		                                gsub(/"/, "", m); print m; f = 1 }')
	rm -f "$_pl"
	[ -n "$_mp" ] || return 1
	image_touch "$_img" "$_mp"
	printf '%s\n' "$_mp"
	return 0
}

## Record the attach, or push its grace period out again because it was just
## used. Attaching a sparsebundle over a share costs minutes, so detaching the
## moment one command ends makes the next command pay it all over again.
image_touch() {
	_img="$1"; _mp="$2"
	mount_record_add "-" "image:$_img" "$_mp" "${IMAGE_GRACE:-600}" "image"
	return 0
}

## Detach only images WE attached, and only after the snapshots mounted
## inside them are gone -- an image with a live mount inside it is busy.
## Images are NOT detached when a command ends: they are recorded with a grace
## period and released by the sweep, so a series of commands against a network
## store pays the attach once instead of once each.
cleanup_images() {
	rm -f "$TRANSIENT_IMAGES"
	return 0
}

## Adopt an image that is attached but unrecorded.
##
## The sweep can only release what it has a record of, so an attach left behind
## by a killed run would stay attached for good. Anything attached that belongs
## to a location my-tm knows is taken over here and given the usual grace, so
## the ordinary machinery ends up releasing it.
images_adopt_orphans() {
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _ih; do
		[ -n "$_ih" ] || continue
		[ "$(loc_kind "$_ih")" = "image" ] || continue
		_ib=$(loc_target "$_ih")
		_imp=$(image_mountpoint "$_ib" 2>/dev/null) || continue
		[ -n "$_imp" ] || continue
		if mounts_read_all | awk -F'\t' -v m="$_imp" '$3 == m {f = 1} END {exit(f ? 0 : 1)}'; then
			continue
		fi
		dbg "adopting an untracked attach of $_ib at $_imp"
		image_touch "$_ib" "$_imp"
	done <<_EOF
$_locs
_EOF
	return 0
}

## detach one, on behalf of the sweep
image_detach() {
	run_echo hdiutil detach "$1"
	hdiutil detach "$1" -quiet >/dev/null 2>&1 ||
		hdiutil detach "$1" -force -quiet >/dev/null 2>&1
}

mnt_private_root() { printf '%s/.mnt\n' "$MOUNT_ROOT"; }
mnt_point_for()    { printf '%s/.mnt/%s/%s\n' "$MOUNT_ROOT" "$1" "$2"; }

## Given where a snapshot IS mounted, the directory holding the volume files.
## A backup-store snapshot carries an inner <ts>.backup/<vol> wrapper; a local
## one is the volume root itself, so its mountpoint already ends in the volume
## name -- ours by construction, and macOS's own by its layout.
snap_volume_root_at() {
	_mp="$1"; _l="$2"; _t="$3"; _v="$4"
	if [ "$(loc_target "$_l")" = "local" ]; then
		case "$_mp" in
			*/"$_v") printf '%s\n' "$_mp" ;;
			*)       printf '%s/%s\n' "$_mp" "$_v" ;;
		esac
	else
		printf '%s/%s.backup/%s\n' "$_mp" "$_t" "$_v"
	fi
	return 0
}

## Where WE would put it -- the stable path the /tm tree points at, whether or
## not anything is mounted right now.
mnt_volume_path_expected() {
	snap_volume_root_at "$(mnt_point_for "$1" "$2")" "$1" "$2" "$3"
}

## Where the files can be read RIGHT NOW: a snapshot macOS has already mounted
## somewhere of its own accord is read there, because a second mount_apfs of
## the same snapshot fails with "Resource busy".
mnt_volume_path() {
	_live=$(mount_table_find_snapshot "$(snap_apfs_name "$1" "$2")")
	if [ -n "$_live" ]; then
		snap_volume_root_at "$_live" "$1" "$2" "$3"
	else
		mnt_volume_path_expected "$1" "$2" "$3"
	fi
	return 0
}

## Where a given APFS snapshot is mounted, if it is mounted at all (anywhere).
mount_table_find_snapshot() {
	mount | awk -v s="$1@" 'index($0, s) == 1 && !f {
			i = index($0, " on "); r = substr($0, i + 4);
			j = index(r, " ("); print substr(r, 1, j - 1); f = 1
		}'
}

mount_table_has() {
	mount | awk -v p="$1" 'index($0, " on " p " (") > 0 { f = 1 } END { exit(f ? 0 : 1) }'
}

## mounted | unmounted | absent -- the three states a destination volume can
## be in, which need three different things said about them
volume_state() {
	_i=$(diskutil info "$1" 2>/dev/null)
	if [ -z "$_i" ] || printf '%s' "$_i" | grep -q "Could not find disk"; then
		printf 'absent\n'
	elif printf '%s' "$_i" | grep -qE '^ *Mounted: *Yes'; then
		printf 'mounted\n'
	else
		printf 'unmounted\n'
	fi
	return 0
}

## Make a location readable if that is cheaply possible. A destination that
## is attached but not mounted is invisible to every read in here, and the
## answer "no backups" would be a lie. Mount it, and remember that WE did,
## so it goes back exactly as it was found.
## Mount points of network filesystems, one per line. The mount table needs no
## Full Disk Access, so a job can read it even where it cannot look inside.
network_mounts() {
	if [ -n "$MOUNT_TABLE_FILE" ]; then cat "$MOUNT_TABLE_FILE"; else mount 2>/dev/null; fi |
		awk '{
			if (!match($0, / on .* \(/)) next
			mp = substr($0, RSTART + 4, RLENGTH - 6)
			fs = substr($0, RSTART + RLENGTH); sub(/[,)].*/, "", fs)
			if (fs ~ /^(smbfs|nfs|afpfs|webdav|cifs|ftp)$/) print mp
		}'
}

## Is this path on a network volume? Matched on whole path components, so
## /Volumes/share does not claim /Volumes/shareX.
## the network mount point a path sits on, if any -- matched on whole path
## components, so /Volumes/tm2 is not "inside" /Volumes/tm
network_volume_of() {
	_nv_p="$1"
	while IFS= read -r _nv_mp; do
		[ -n "$_nv_mp" ] || continue
		case "$_nv_p/" in "$_nv_mp"/*) printf '%s\n' "$_nv_mp"; return 0 ;; esac
	done <<_EOF
$(network_mounts)
_EOF
	return 1
}

path_on_network_volume() { network_volume_of "$1" >/dev/null 2>&1; }

## the host a share comes from, as the mount table spells it:
##   //me@ada/tm on /Volumes/timeMachine (smbfs, ...)  -> ada
##   ada:/export on /Volumes/x (nfs, ...)              -> ada
network_mount_host() {
	if [ -n "$MOUNT_TABLE_FILE" ]; then cat "$MOUNT_TABLE_FILE"; else mount 2>/dev/null; fi |
		awk -v mp="${1:-}" '{
			if (!match($0, / on .* \(/)) next
			m = substr($0, RSTART + 4, RLENGTH - 6)
			if (m != mp) next
			src = $1
			sub(/^\/\//, "", src)
			sub(/^[^@\/]*@/, "", src)
			sub(/[\/:].*$/, "", src)
			if (src != "" && !f) { print src; f = 1 }
		}'
}

## Is LOCATION on a network volume the jobs cannot see into? Reading a share
## needs Full Disk Access, so without it a job finds an empty directory where a
## store is -- worth saying once, rather than reporting the location as gone.
## Nothing gates a command a person runs, and nothing gates RELEASING a mount:
## the sweep does not come through here. Call it in a subshell: loc_target sets
## the same scratch variables its callers use.
jobs_blind_on() {
	[ "${JOBS_RUN_WITH_FULL_DISK_ACCESS:-0}" = "1" ] && return 1
	_jb_t=$(loc_target "$1" 2>/dev/null) || return 1
	case "$_jb_t" in local) return 1 ;; esac
	is_remote_target "$_jb_t" && return 1
	path_on_network_volume "$_jb_t"
}

loc_open() {
	_h="$1"
	_t=$(loc_target "$_h")
	case "$_t" in local) return 0 ;; esac
	is_remote_target "$_t" && return 0
	[ -d "$_t" ] && return 0
	[ "${AUTO_MOUNT_DESTINATIONS:-1}" = "1" ] || return 1
	if [ "$BACKGROUND_JOB" = "1" ] && loc_is_quiet "$_h"; then
		dbg "$_h is quiet (POST_BACKUP put it to sleep) -- not waking it for a daemon"
		return 1
	fi
	_name=$(basename "$_t")
	[ "$(volume_state "$_name")" = "unmounted" ] || return 1
	msg "'$_name' is attached but not mounted -- mounting it"
	why "and unmounting it again when this command is done, so it is left as it was found"
	if ! run diskutil mount "$_name" >/dev/null 2>&1; then
		warn "could not mount $_name -- it will not be searched"
		return 1
	fi
	printf '%s\n' "$_name" >>"$TRANSIENT_VOLUMES"
	return 0
}

## usable now? -- opening it first if that is what it takes
loc_ready() {
	loc_open "$1"
	loc_reachable "$1"
}

## Put back only what we mounted; anything already mounted is left alone.
## Runs AFTER the snapshot mounts are released -- a volume with a snapshot
## still mounted inside it is busy.
cleanup_volumes() {
	[ -f "$TRANSIENT_VOLUMES" ] || return 0
	while IFS= read -r _v; do
		[ -n "$_v" ] || continue
		if run diskutil unmount "$_v" >/dev/null 2>&1; then
			dbg "unmounted $_v again, as it was found"
		else
			warn "could not unmount $_v again -- it was not mounted before this ran"
		fi
	done <"$TRANSIENT_VOLUMES"
	rm -f "$TRANSIENT_VOLUMES"
	return 0
}

## How much of the store is actually in use, sampled over time.
##
## Ground truth from df, unlike ADDED which is Time Machine's own accounting.
## What it CANNOT give is "what would deleting this snapshot free": that is a
## property of the CURRENT snapshot set, not of history -- blocks become shared
## when the next backup keeps them, and exclusive again when a neighbour is
## deleted. What it does give is growth, thinning and a capacity forecast, and
## those need a series -- so sampling starts early and cheaply.
## Sampled on BACKUP EVENTS, not on a clock: one sample per change means each
## delta is exactly one backup's (or one thinning's) worth, which a fixed
## interval cannot promise -- backups get missed, and sampling four times an
## hour between them only adds rows that say nothing. USAGE_SAMPLE_INTERVAL is
## just a slow heartbeat for drift that no snapshot change explains.
##   epoch <TAB> used <TAB> avail <TAB> snapshots <TAB> newest
usage_sample() {
	_h="$1"
	[ "$(loc_kind "$_h")" = "disk" ] || return 0
	loc_reachable "$_h" || return 0
	_f="$(cache_write_dir)/usage.$_h.tsv"
	_now=$(now_epoch)

	_rows=$(snapshots_cached_only "$_h")
	_n=$(printf '%s\n' "$_rows" | count_lines)
	_newest=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n |
		tail -n 1 | awk -F'\t' '{print $2}')
	[ -n "$_newest" ] || _newest="-"

	if [ -f "$_f" ]; then
		_prevline=$(tail -n 1 "$_f" 2>/dev/null)
		_pe=$(printf '%s' "$_prevline" | awk -F'\t' '{print $1 + 0}')
		_pn=$(printf '%s' "$_prevline" | awk -F'\t' '{print $4}')
		_pnew=$(printf '%s' "$_prevline" | awk -F'\t' '{print $5}')
		if [ "$_newest" = "${_pnew:-}" ] && [ "$_n" = "${_pn:-}" ] &&
		   [ $(( _now - ${_pe:-0} )) -lt "${USAGE_SAMPLE_INTERVAL:-21600}" ]; then
			return 0
		fi
	fi

	_sp=$(loc_store_path "$_h" 2>/dev/null) || return 0
	[ -d "$_sp" ] || return 0
	_du=$(df -k "$_sp" 2>/dev/null | awk 'NR == 2 {printf "%s\t%s", $3 * 1024, $4 * 1024}')
	[ -n "$_du" ] || return 0
	need_dir "$(dirname "$_f")" || return 0
	printf '%s\t%s\t%s\t%s\n' "$_now" "$_du" "$_n" "$_newest" >>"$_f" 2>/dev/null || true
	dbg "usage sample for '$_h': $_du, $_n snapshots, newest $_newest"
	return 0
}

## Growth from the series, and how long the free space lasts at that rate.
## Emits: per-day-bytes <TAB> free <TAB> days-left <TAB> span-days <TAB> samples
## Nothing at all until the series is long enough to mean something.
usage_trend() {
	_f="$(cache_write_dir)/usage.$1.tsv"
	[ -f "$_f" ] || return 1
	awk -F'\t' -v minspan="${USAGE_MIN_SPAN:-7200}" '
		NR == 1 { e0 = $1; u0 = $2 }
		{ e1 = $1; u1 = $2; free = $3; n++ }
		END {
			if (n < 2) exit 1;
			span = e1 - e0;
			if (span < minspan) exit 1;
			per = (u1 - u0) * 86400 / span;
			days = (per > 0) ? free / per : -1;
			printf "%d\t%d\t%d\t%.1f\t%d\n", per, free, days, span / 86400, n;
		}
	' "$_f"
}

## the sweep never acts on a record alone: the live mount table must confirm a
## read-only Time Machine snapshot mount at exactly that path.
mount_table_is_snapshot() {
	mount | awk -v p="$1" '
		index($0, " on " p " (") > 0 &&
		index($0, "com.apple.TimeMachine.") == 1 &&
		index($0, "read-only") > 0 { f = 1 }
		END { exit(f ? 0 : 1) }
	'
}

mounts_file() { printf '%s/mounts.cache\n' "$(cache_write_dir)"; }

mounts_read_all() {
	for _d in $(cache_read_dirs); do
		[ -f "$_d/mounts.cache" ] || continue
		cat "$_d/mounts.cache" 2>/dev/null
	done
	return 0
}

## ID  loc  mountpoint  made-at  ttl-seconds  pid  flags
mount_record_add() {
	_f=$(mounts_file)
	_old=""
	[ -f "$_f" ] && _old=$(awk -F'\t' -v m="$3" '$3 != m' "$_f" 2>/dev/null)
	{
		[ -n "$_old" ] && printf '%s\n' "$_old"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(now_epoch)" "$4" "$$" "$5"
	} | atomic_write "$_f" 2>/dev/null || dbg "mount record not writable: $_f"
	return 0
}

mount_record_drop() {
	for _d in $(cache_read_dirs); do
		_f="$_d/mounts.cache"
		[ -f "$_f" ] || continue
		[ -w "$_f" ] || continue
		awk -F'\t' -v m="$1" '$3 != m' "$_f" 2>/dev/null | atomic_write "$_f" 2>/dev/null
	done
	return 0
}

## snap_mount <loc> <ts> <ttl-seconds> <flags> [<mountpoint>]
## echoes the mountpoint it used.  Idempotent: an already-mounted snapshot is
## reused and its record refreshed.
snap_mount() {
	_loc="$1"; _ts="$2"; _ttl="$3"; _flags="$4"; _mp="${5:-}"
	[ -n "$_mp" ] || _mp=$(mnt_point_for "$_loc" "$_ts")
	_vol_src=$(loc_volume "$_loc")
	_apfs=$(snap_apfs_name "$_loc" "$_ts")
	_id=$(snap_id "$(loc_uuid "$_loc")" "$_ts")

	## A local snapshot IS the volume root, so it must be mounted at the path
	## that root is expected at -- mounting one level up would put every file
	## one directory away from where every reader looks for it.
	if [ -z "${5:-}" ] && [ "$(loc_target "$_loc")" = "local" ]; then
		_mp=$(snap_volume_root_at "$_mp" "$_loc" "$_ts" "Data")
	fi

	if mount_table_has "$_mp"; then
		dbg "already mounted: $_mp"
		mount_record_add "$_id" "$_loc" "$_mp" "$_ttl" "$_flags"
		printf '%s\n' "$_mp"
		return 0
	fi

	## Already mounted elsewhere -- macOS mounts local snapshots under
	## /Volumes/com.apple.TimeMachine.localsnapshots/ for its own purposes, and
	## a second mount_apfs of the same snapshot fails with "Resource busy".
	## Use what is there, and never record it as ours: unmounting a mount we
	## did not make is not our business.
	_foreign=$(mount_table_find_snapshot "$_apfs")
	if [ -n "$_foreign" ]; then
		dbg "$_apfs is already mounted by the system at $_foreign -- reusing it"
		printf '%s\n' "$_foreign"
		return 0
	fi
	need_dir "$_mp" || { warn "cannot create mountpoint: $_mp"; return 1; }
	## echo the command, then silence only ITS output: "run cmd >/dev/null 2>&1"
	## swallows the echo too, which made -V hide the very calls it exists to show
	run_echo mount_apfs -s "$_apfs" "$_vol_src" "$_mp"
	if mount_apfs -s "$_apfs" "$_vol_src" "$_mp" >/dev/null 2>&1; then
		why "read-only snapshot mount; no root needed, and it pins the snapshot until released"
		mount_record_add "$_id" "$_loc" "$_mp" "$_ttl" "$_flags"
		printf '%s\n' "$_mp"
		return 0
	fi
	if ! snap_names "$_loc" 2>/dev/null | grep -qx "$_ts"; then
		## Time Machine adds and thins constantly, and local snapshots are
		## purgeable at any age: a list read a minute ago can already be wrong
		warn "$(ts_display "$_ts"): gone from '$_loc' since the list was read ($US --refresh $_loc)"
	else
		warn "mount failed: $_apfs on $_vol_src"
	fi
	rmdir "$_mp" 2>/dev/null
	return 1
}

snap_umount() {
	_mp="$1"; _force="${2:-0}"
	if ! mount_table_has "$_mp"; then
		mount_record_drop "$_mp"
		rmdir "$_mp" 2>/dev/null
		return 0
	fi
	if [ "$_force" = "1" ]; then
		run_echo umount -f "$_mp"
		umount -f "$_mp" >/dev/null 2>&1 || return 1
	else
		run_echo umount "$_mp"
		umount "$_mp" >/dev/null 2>&1 || return 1
	fi
	mount_record_drop "$_mp"
	rmdir "$_mp" 2>/dev/null
	return 0
}

#############################################################################
## TRANSIENT MOUNTS -- made on the way into a command, released on the way out
#############################################################################

cleanup_transient() {
	_rc=$?
	[ -f "$TRANSIENT_LIST" ] || return $_rc
	while IFS= read -r _m; do
		[ -n "$_m" ] || continue
		snap_umount "$_m" 0 >/dev/null 2>&1
	done <"$TRANSIENT_LIST"
	rm -f "$TRANSIENT_LIST"
	return $_rc
}

cleanup_all() { cleanup_transient; cleanup_images; cleanup_volumes; }
trap 'cleanup_all' EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

## transient_snapshot <loc> <ts> -- echo the mountpoint, release it at exit.
## Safe to call from inside $(...): the list it appends to is a file.
transient_snapshot() {
	_mp=$(snap_mount "$1" "$2" "$TRANSIENT_TTL" "transient") || return 1
	if [ ! -f "$TRANSIENT_LIST" ] || ! grep -qxF "$_mp" "$TRANSIENT_LIST" 2>/dev/null; then
		printf '%s\n' "$_mp" >>"$TRANSIENT_LIST"
	fi
	printf '%s\n' "$_mp"
	return 0
}

#############################################################################
## THE SWEEP  (maintenance job, and after every --mount)
#############################################################################

## Which of the mountpoints on stdin have open files -- ONE lsof for all of
## them.  lsof costs seconds per call, so asking it once per mount turns
## releasing a few dozen into minutes.
busy_mounts() {
	_bl=$(mktemp /tmp/my-tm.busy.XXXXXX) || return 0
	cat >"$_bl"
	if [ ! -s "$_bl" ]; then
		rm -f "$_bl"
		return 0
	fi
	_bo=$(mktemp /tmp/my-tm.busyout.XXXXXX) || { rm -f "$_bl"; return 0; }
	_bd="$_bo.done"

	## lsof enumerates EVERY mount on the machine, so one unresponsive
	## filesystem anywhere wedges it -- in an uninterruptible wait, where no
	## signal reaches it, not even KILL. Observed on a live machine: every
	## lsof call blocked for ever, including `lsof /tmp`. A daemon that runs
	## every MAINT_INTERVAL seconds must not be able to stop for good because
	## of that, so the wait is bounded.
	## The sentinel file, not `kill -0`, says it finished: an exited child
	## the shell has not reaped yet still answers kill -0, which would read
	## as a timeout.
	{ tr '\n' '\0' <"$_bl" | xargs -0 lsof -n -P -- 2>/dev/null >"$_bo"; : >"$_bd"; } &
	_bp=$!
	_bi=0
	while [ ! -f "$_bd" ]; do
		[ "$_bi" -ge "$LSOF_TIMEOUT" ] && break
		sleep 1
		_bi=$(( _bi + 1 ))
	done

	if [ ! -f "$_bd" ]; then
		kill "$_bp" 2>/dev/null
		warn "lsof did not answer in ${LSOF_TIMEOUT}s -- every candidate mount is treated as BUSY"
		why "so nothing is released on a guess; the stuck lsof cannot be killed and is left behind"
		cat "$_bl"
		rm -f "$_bl" "$_bo" "$_bd"
		return 0
	fi
	awk 'NR > 1 {print $NF}' "$_bo" | sort -u
	rm -f "$_bl" "$_bo" "$_bd"
	return 0
}

tm_backup_running() {
	tmutil status 2>/dev/null | grep -q 'Running = 1'
}

## free percent of a mounted volume
vol_free_pct() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { if ($2 > 0) printf "%d\n", ($4 * 100) / $2; else print 100 }'
}

## Should the sweep leave this mount alone? Only while the --index run that
## made it is still ALIVE: kill -9 cannot be trapped, and a dead indexer
## would otherwise pin its snapshot against thinning for good.
indexer_still_running() {
	case "${1:-}" in
		*indexer*) : ;;
		*) return 1 ;;
	esac
	[ -n "${2:-}" ] || return 1
	kill -0 "$2" 2>/dev/null
}

sweep() {
	_now=$(now_epoch)
	_records=$(mounts_read_all)
	[ -n "$_records" ] || return 0
	_urgent=0
	tm_backup_running && _urgent=1

	_tmp=$(mktemp /tmp/my-tm.sweep.XXXXXX) || return 1
	printf '%s\n' "$_records" >"$_tmp"
	## one lsof for every recorded mountpoint, before touching any of them
	_busy=$(awk -F'\t' '{print $3}' "$_tmp" | busy_mounts)
	while IFS="$(printf '\t')" read -r _id _loc _mp _made _ttl _pid _flags; do
		[ -n "${_mp:-}" ] || continue
		## reconcile first: a record with nothing real behind it is dropped,
		## never obeyed.
		_isimage=0
		case "${_flags:-}" in *image*) _isimage=1 ;; esac
		if [ "$_isimage" = "1" ]; then
			## an attached image is an ordinary volume, not a snapshot mount
			if ! mount_table_has "$_mp"; then
				dbg "sweep: image record with nothing attached ($_mp)"
				mount_record_drop "$_mp"
				continue
			fi
		elif ! mount_table_is_snapshot "$_mp"; then
			dbg "sweep: stale record dropped ($_mp)"
			mount_record_drop "$_mp"
			continue
		fi
		if indexer_still_running "${_flags:-}" "${_pid:-}"; then
			dbg "sweep: indexer mount exempt, pid $_pid still running ($_mp)"
			continue
		fi
		case "${_flags:-}" in
			*indexer*)
				dbg "sweep: indexer pid ${_pid:-?} is gone -- its mount is no longer exempt ($_mp)"
				_expired_indexer=1
				;;
		esac
		_age=$(( _now - ${_made:-0} ))
		_expired=0
		[ "$_age" -ge "${_ttl:-0}" ] && _expired=1
		[ "${_expired_indexer:-0}" = "1" ] && _expired=1
		_expired_indexer=0
		if [ "$_urgent" = "1" ]; then
			_expired=1
			dbg "sweep: a backup is running -- TTL overridden for $_mp"
		else
			_t=$(loc_target "${_loc:-}" 2>/dev/null || true)
			if [ -n "${_t:-}" ] && [ -d "$_t" ]; then
				_free=$(vol_free_pct "$_t")
				if [ -n "$_free" ] && [ "$_free" -lt "$HEALTH_MIN_FREE_PCT" ]; then
					_expired=1
					dbg "sweep: $_loc below ${HEALTH_MIN_FREE_PCT}% free -- releasing $_mp"
				fi
			fi
		fi
		[ "$_expired" = "1" ] || continue
		if printf '%s\n' "$_busy" | grep -qxF "$_mp" 2>/dev/null; then
			dbg "sweep: $_mp still has open files -- retrying next round"
			continue
		fi
		if [ "$_isimage" = "1" ]; then
			msg "detaching image after its grace period: $_mp"
			if image_detach "$_mp"; then
				mount_record_drop "$_mp"
			else
				warn "could not detach $_mp (retrying next round)"
			fi
			continue
		fi
		msg "releasing expired mount: $_mp"
		snap_umount "$_mp" 0 >/dev/null 2>&1 ||
			warn "could not release $_mp (retrying next round)"
	done <"$_tmp"
	rm -f "$_tmp"
	return 0
}

#############################################################################
## THE /tm TREE
##   <loc>/<ts>/<vol>   symlink into the private mount area (dangling until
##                      that snapshot is mounted -- `ls` still shows what exists)
##   <loc>/latest       symlink to the newest <ts>
##   <loc>/by-id/<ts>_<ID>
##   <loc>/REMOTE       text file for an ssh location
#############################################################################

tm_root() {
	if [ -d "$FIRMLINK" ]; then printf '%s\n' "$FIRMLINK"; else printf '%s\n' "$MOUNT_ROOT"; fi
}

tm_refresh_loc() {
	_h="$1"
	_base="$MOUNT_ROOT/$_h"
	need_dir "$_base" || return 1

	if loc_is_remote "$_h"; then
		_t=$(loc_target "$_h")
		_idir=$(loc_install_dir "$_h")
		{
			printf 'This location lives on another machine:  %s\n' "$_t"
			printf 'Its snapshots cannot be browsed from here (that would need sshfs/macFUSE).\n\n'
			printf '  %s --ls %s              list its snapshots from here (over ssh)\n' "$US" "$_h"
			printf '  %s --cat|--cp|--open <ID> <PATH>   fetch one file from it (over ssh)\n' "$US"
			printf '  ssh %s              log in, then browse %s/%s/ there\n\n' \
				"$(remote_host "$_t")" "$FIRMLINK" "$_h"
			if [ -n "$_idir" ]; then
				printf 'my-tm installed there: yes, %s\n' "$_idir"
			else
				printf 'my-tm installed there: no -- run: %s --install %s\n' "$US" "$(remote_host "$_t")"
			fi
		} | atomic_write "$_base/REMOTE"
		return 0
	fi

	_rows=$(snapshots_get "$_h")
	[ -n "$_rows" ] || return 0

	## what should exist
	_want=$(mktemp /tmp/my-tm.tree.XXXXXX) || return 1
	printf '%s\n' "$_rows" | awk -F'\t' '{print $2}' | sort >"$_want"

	## drop stale snapshot dirs (never touch anything we did not make)
	for _d in "$_base"/*; do
		[ -e "$_d" ] || continue
		_n=$(basename "$_d")
		case "$_n" in
			latest|by-id|REMOTE) continue ;;
		esac
		case "$_n" in
			[0-9][0-9][0-9][0-9]-*) : ;;
			*) continue ;;
		esac
		if ! grep -qx "$_n" "$_want" 2>/dev/null; then
			mount_table_has "$_d" && continue
			rm -rf "$_d" 2>/dev/null
		fi
	done
	rm -f "$_want"

	need_dir "$_base/by-id" || return 1
	_newest=""
	while IFS="$(printf '\t')" read -r _l _ts _ep _id _xid _f _a _t2 _u _st _vol; do
		[ -n "${_ts:-}" ] || continue
		[ "${_vol:-}" = "-" ] && _vol="Data"
		[ -n "${_vol:-}" ] || _vol="Data"
		need_dir "$_base/$_ts" || continue
		_target=$(mnt_volume_path_expected "$_l" "$_ts" "$_vol")
		if [ ! -L "$_base/$_ts/$_vol" ]; then
			rm -rf "${_base:?}/${_ts:?}/${_vol:?}" 2>/dev/null
			ln -s "$_target" "$_base/$_ts/$_vol" 2>/dev/null
		fi
		ln -sfn "../$_ts" "$_base/by-id/${_ts}_${_id}" 2>/dev/null
		_newest="$_ts"
	done <<_EOF
$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n)
_EOF
	[ -n "$_newest" ] && ln -sfn "$_newest" "$_base/latest" 2>/dev/null
	return 0
}

tm_refresh() {
	need_dir "$MOUNT_ROOT" || err "cannot create $MOUNT_ROOT"
	_locs="${1:-}"
	[ -n "$_locs" ] || _locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_ready "$_h" || continue
		dbg "refreshing tree for $_h"
		tm_refresh_loc "$_h"
	done <<_EOF
$_locs
_EOF
	return 0
}

tm_write_readme() {
	[ -d "$MOUNT_ROOT" ] || return 0
	## Name the firmlink, the path the user types -- not tm_root, which is
	## $MOUNT_ROOT until the reboot that creates $FIRMLINK. --install runs
	## BEFORE that reboot, so the text would otherwise be stale the moment it
	## is reachable, and only --refresh could correct it. Written this way it
	## is right once, and --install is its only writer.
	_r="$FIRMLINK"
	cat <<_EOF | atomic_write "$MOUNT_ROOT/README" 2>/dev/null
Time Machine snapshots, browsable as ordinary directories.

  $_r/<location>/<snapshot>/<volume>/...   one backup, as it was
  $_r/<location>/latest/                   the newest one
  $_r/<location>/by-id/<ts>_<ID>           reach one by the ID my-tm prints

A snapshot directory is EMPTY until that snapshot is mounted -- the listing
tells you which backups exist, my-tm fills one in when you ask for it:

  my-tm --mount <ID> 20m      mount it for twenty minutes
  my-tm --ls <location>       what is in there
  my-tm <path>                every version of a file, and where

A mounted snapshot cannot be deleted, so Time Machine's thinning stops against
it -- that is why every mount carries a lifetime and is released again.
_EOF
	return 0
}

#############################################################################
## THE VERSION STORE
##   Snapshots are immutable, so a (path, snapshot) stat is a permanent fact:
##   never invalidated, only ever added to.  --lookup answers from here without
##   mounting, and files in what it had to read live.
##     loc <TAB> ts <TAB> path <TAB> inode <TAB> size <TAB> mtime
##   inode "-" means: verified absent from that snapshot.
#############################################################################

## The version store proper.
##
##   <loc>.versions/base.<XX>.gz   the first indexed snapshot, in 256 buckets
##   <loc>.versions/d.<ts>.tsv     what changed in each later snapshot
##   <loc>.versions/base.ts        which snapshot the baseline is
##
## A full snapshot is ~4.4M rows of path+size+mtime: 722 MB raw, 35 MB gzipped
## (measured). Keeping one per snapshot would be gigabytes, so only the first is
## stored whole and the rest as deltas -- at the measured 0.4 % churn that is a
## couple of hundred KB each. The baseline is bucketed by a hash of the path so
## a single-path query decompresses ~140 KB instead of 35 MB.
vs_dir() { printf '%s/index/%s.versions\n' "$(cache_write_dir)" "$1"; }

## Which baseline bucket a path lives in. Must match vs_write_baseline exactly:
## the last two characters of the path, with anything awkward folded to "_".
vs_bucket() {
	_p="$1"
	case "$_p" in
		?) _l="$_p" ;;
		*) _l=${_p#"${_p%??}"} ;;
	esac
	printf '%s' "$_l" | sed 's/[^0-9a-zA-Z]/_/g'
	printf '\n'
}

## Every version of PATH the index knows about, with no mount at all.
## Emits: ts <TAB> size <TAB> mtime   ("-" for a snapshot that lacks the file)
vs_versions_for() {
	_loc="$1"; _p="$2"
	_d=$(vs_dir "$_loc")
	[ -f "$_d/base.ts" ] || return 1
	_bts=$(cat "$_d/base.ts" 2>/dev/null)
	[ -n "$_bts" ] || return 1
	_b=$(vs_bucket "$_p")
	_cur=$(gzip -cd "$_d/base.$_b.gz" 2>/dev/null |
		awk -F'\t' -v p="$_p" '$1 == p {printf "%s\t%s", $2, $3; exit}')
	[ -n "$_cur" ] || _cur=$(printf -- '-\t-')
	printf '%s\t%s\n' "$_bts" "$_cur"
	## then replay the deltas in time order, carrying the last known state
	for _df in "$_d"/d.*.tsv; do
		[ -f "$_df" ] || continue
		_dts=$(basename "$_df"); _dts=${_dts#d.}; _dts=${_dts%.tsv}
		## if a delta somehow holds both, the file being THERE is the truth
		_row=$(awk -F'\t' -v p="$_p" '
			$1 == p { if ($2 != "-") { printf "%s\t%s", $2, $3; found = 1; exit }
			          else keep = $2 "\t" $3 }
			END { if (!found && keep != "") printf "%s", keep }' "$_df")
		[ -n "$_row" ] && _cur="$_row"
		printf '%s\t%s\n' "$_dts" "$_cur"
	done
	return 0
}

## Write this snapshot's rows: the whole thing if it is the first one indexed
## for this location, otherwise only what differs from the previous walk.
vs_record_snapshot() {
	_loc="$1"; _ts="$2"; _stats="$3"
	_d=$(vs_dir "$_loc")
	need_dir "$_d" || return 1
	_prev="$_d/.prev"

	if [ ! -f "$_d/base.ts" ]; then
		dbg "version store: writing the baseline from $_ts"
		vs_write_baseline "$_d" "$_stats" || return 1
		printf '%s\n' "$_ts" >"$_d/base.ts"
		gzip -c "$_stats" >"$_prev.gz" 2>/dev/null
		return 0
	fi

	## a delta: added and changed rows, plus removals marked absent
	_dl="$_d/d.$_ts.tsv"
	if [ -f "$_prev.gz" ]; then
		_pp=$(mktemp /tmp/my-tm.prev.XXXXXX) || return 1
		gzip -cd "$_prev.gz" >"$_pp" 2>/dev/null
		## Removals are a difference of PATHS, never of whole lines. Comparing
		## lines calls every CHANGED file removed as well -- its old line is gone --
		## so each delta carried both "here it is" and "it is gone" for the same
		## path, and an absent row sorts before a real one (ASCII 45 before 48), so
		## the phantom won every lookup. That is a backup reported as not holding a
		## file it plainly holds.
		_op=$(mktemp /tmp/my-tm.op.XXXXXX) || return 1
		_np=$(mktemp /tmp/my-tm.np.XXXXXX) || return 1
		cut -f1 "$_pp" | LC_ALL=C sort -u >"$_op"
		cut -f1 "$_stats" | LC_ALL=C sort -u >"$_np"
		{
			LC_ALL=C comm -13 "$_pp" "$_stats" || true
			LC_ALL=C comm -23 "$_op" "$_np" | awk 'length > 0 {printf "%s\t-\t-\n", $0}'
		} | LC_ALL=C sort -u >"$_dl" 2>/dev/null
		rm -f "$_op" "$_np"
		dbg "version store: $_ts delta is $(count_lines <"$_dl") rows"
		rm -f "$_pp"
	else
		cp "$_stats" "$_dl" 2>/dev/null
	fi
	gzip -c "$_stats" >"$_prev.gz" 2>/dev/null
	return 0
}

## bucket + compress a full snapshot listing
vs_write_baseline() {
	_d="$1"; _stats="$2"
	_tmp=$(mktemp -d /tmp/my-tm.base.XXXXXX) || return 1
	## Bucket on the last two characters of the path. Written by SORTING on the
	## bucket and closing each file as the key changes: awk keeps every output
	## file open otherwise and runs out of descriptors long before 256 buckets,
	## which silently produced no baseline at all.
	## LC_ALL=C throughout: a real backup contains filenames that are not valid
	## UTF-8, and awk aborts on those in a UTF-8 locale -- which produced an empty
	## baseline while every command still reported success.
	_err=$(mktemp /tmp/my-tm.bkerr.XXXXXX) || return 1
	LC_ALL=C awk -F'\t' '{
		n = length($1);
		if (n == 0) next;
		b = (n >= 2 ? substr($1, n - 1, 2) : $1);
		gsub(/[^0-9a-zA-Z]/, "_", b);
		if (b == "") b = "_";
		print b "\t" $0
	}' "$_stats" 2>>"$_err" | LC_ALL=C sort -k1,1 -s 2>>"$_err" |
	LC_ALL=C awk -F'\t' -v t="$_tmp" '
		$1 == "" { next }
		$1 != b { if (b != "") close(f); b = $1; f = t "/" b }
		f == "" { next }
		{ sub(/^[^\t]*\t/, ""); print > f }
		END { if (b != "") close(f) }
	' 2>>"$_err"
	for _bf in "$_tmp"/*; do
		[ -f "$_bf" ] || continue
		gzip -c "$_bf" >"$_d/base.$(basename "$_bf").gz" 2>/dev/null
	done
	_nb=0
	for _bg in "$_d"/base.*.gz; do
		[ -f "$_bg" ] && _nb=$(( _nb + 1 ))
	done
	rm -rf "$_tmp"
	if [ "$_nb" -le 0 ]; then
		warn "the version baseline could not be written$([ -s "$_err" ] && printf ': %s' "$(head -n 1 "$_err")")"
		rm -f "$_err"
		return 1
	fi
	rm -f "$_err"
	dbg "version baseline: $_nb buckets"
	return 0
}

## Snapshots that Time Machine has thinned, or macOS has purged, are no longer
## covered by the index and must stop being counted as such.
##
## Their DELTA cannot simply be deleted, though: each delta records changes
## against the previous walk, so removing one from the middle would make every
## later snapshot inherit the version before it. A purged snapshot's delta is
## squashed FORWARD into the next one instead -- the later row wins for a path
## both mention, and rows only the older delta had are carried over -- which
## keeps the chain exact and still reclaims the space.
## Repair deltas written before removals were computed by path: a changed file
## was recorded as changed AND removed. Precise -- an absent row is dropped only
## where the SAME delta also has a real row for that path -- and idempotent, so
## a 25-hour index is mended rather than rebuilt.
VS_REPAIR=1
vs_repair_deltas() {
	_d=$(vs_dir "$1")
	[ -d "$_d" ] || return 0
	[ -f "$_d/.repaired.$VS_REPAIR" ] && return 0
	_fixed=0
	for _df in "$_d"/d.*.tsv; do
		[ -f "$_df" ] || continue
		_rt=$(mktemp /tmp/my-tm.rep.XXXXXX) || continue
		if awk -F'\t' '
				NR == FNR { if ($2 != "-") real[$1] = 1; next }
				$2 == "-" && ($1 in real) { dropped++; next }
				{ print }
				END { if (dropped > 0) printf "%d\n", dropped > "/dev/stderr" }
			' "$_df" "$_df" >"$_rt" 2>/dev/null; then
			mv -f "$_rt" "$_df"
			_fixed=$(( _fixed + 1 ))
		else
			rm -f "$_rt"
		fi
	done
	printf '%s\n' "$VS_REPAIR" >"$_d/.repaired.$VS_REPAIR" 2>/dev/null
	[ "$_fixed" -gt 0 ] && dbg "version store: checked $_fixed delta(s) for phantom removals"
	return 0
}

vs_prune() {
	_loc="$1"
	vs_repair_deltas "$_loc"
	_d=$(vs_dir "$_loc")
	_cov=$(index_covered_file "$_loc")
	[ -d "$_d" ] || [ -f "$_cov" ] || return 0
	_live=$(snap_names "$_loc" 2>/dev/null)
	[ -n "$_live" ] || return 0          # cannot tell -- leave everything alone

	## Scratch files go to /tmp, not inside $_d: a location can have coverage
	## from an earlier run and no version store yet, and writing into a directory
	## that does not exist failed the whole prune with a shell error.
	_lf=$(mktemp /tmp/my-tm.live.XXXXXX) || return 0
	printf '%s\n' "$_live" | LC_ALL=C sort >"$_lf"
	_gone=""
	[ -f "$_cov" ] && _gone=$(LC_ALL=C sort "$_cov" | LC_ALL=C comm -23 - "$_lf")
	[ -n "$_gone" ] || return 0

	_n=0
	for _gts in $_gone; do
		[ -n "$_gts" ] || continue
		_n=$(( _n + 1 ))
		_gd="$_d/d.$_gts.tsv"
		[ -f "$_gd" ] || continue
		## the next delta in time order, if there is one
		_next=$(for _dn in "$_d"/d.*.tsv; do
				[ -f "$_dn" ] || continue
				_db=$(basename "$_dn"); _db=${_db#d.}; printf '%s\n' "${_db%.tsv}"
			done | LC_ALL=C sort | awk -v g="$_gts" '$0 > g {print; exit}')
		if [ -n "$_next" ]; then
			_nd="$_d/d.$_next.tsv"
			_merged=$(mktemp /tmp/my-tm.sq.XXXXXX) || continue
			awk -F'\t' '
				FILENAME == later { seen[$1] = 1; print; next }
				!($1 in seen) { print }
			' later="$_nd" "$_nd" "$_gd" | LC_ALL=C sort -u >"$_merged"
			mv -f "$_merged" "$_nd" 2>/dev/null
			dbg "version store: squashed the delta of purged $_gts into $_next"
		fi
		rm -f "$_gd"
	done

	## and stop claiming to cover what is not there
	if [ -f "$_cov" ]; then
		LC_ALL=C sort "$_cov" | LC_ALL=C comm -12 - "$_lf" >"$_cov.new" 2>/dev/null &&
			mv -f "$_cov.new" "$_cov"
		rm -f "$_cov.new"
	fi
	rm -f "$_lf"
	dbg "version store: $_n snapshot(s) no longer exist and were pruned from '$_loc'"
	return 0
}

vs_file() { printf '%s/index/versions.tsv\n' "$(cache_write_dir)"; }

## Discard a store written by a different generation of the path logic.
vs_check_generation() {
	for _d in $(cache_read_dirs); do
		[ -f "$_d/index/versions.tsv" ] || continue
		_g=""
		[ -f "$_d/index/versions.gen" ] && _g=$(cat "$_d/index/versions.gen" 2>/dev/null)
		[ "$_g" = "$VS_GENERATION" ] && continue
		dbg "version store in $_d was written by generation ${_g:-0}, not $VS_GENERATION -- discarding it"
		rm -f "$_d/index/versions.tsv" 2>/dev/null
		printf '%s\n' "$VS_GENERATION" >"$_d/index/versions.gen" 2>/dev/null || true
	done
	return 0
}

vs_lookup() {
	_loc="$1"; _ts="$2"; _p="$3"
	vs_check_generation
	for _d in $(cache_read_dirs); do
		_f="$_d/index/versions.tsv"
		[ -f "$_f" ] || continue
		_hit=$(awk -F'\t' -v l="$_loc" -v t="$_ts" -v p="$_p" \
			'$1 == l && $2 == t && $3 == p { printf "%s\t%s\t%s\n", $4, $5, $6; exit }' "$_f")
		[ -n "$_hit" ] && { printf '%s\n' "$_hit"; return 0; }
	done
	return 1
}

## vs_put reads rows from stdin: ts <TAB> path <TAB> inode <TAB> size <TAB> mtime
vs_put() {
	_loc="$1"
	vs_check_generation
	_f=$(vs_file)
	need_dir "$(dirname "$_f")" || return 1
	_new=$(mktemp /tmp/my-tm.vs.XXXXXX) || return 1
	awk -F'\t' -v l="$_loc" '{printf "%s\t%s\t%s\t%s\t%s\t%s\n", l, $1, $2, $3, $4, $5}' >"$_new"
	{
		[ -f "$_f" ] && cat "$_f"
		cat "$_new"
	} | sort -u | atomic_write "$_f" 2>/dev/null || dbg "version store not writable: $_f"
	printf '%s\n' "$VS_GENERATION" >"$(dirname "$_f")/versions.gen" 2>/dev/null || true
	rm -f "$_new"
	return 0
}

vs_covered_count() {
	_loc="$1"
	for _d in $(cache_read_dirs); do
		_f="$_d/index/versions.tsv"
		[ -f "$_f" ] || continue
		awk -F'\t' -v l="$_loc" '$1 == l {seen[$2] = 1} END {print length(seen)}' "$_f"
		return 0
	done
	printf '0\n'
	return 0
}

#############################################################################
## THE SEARCH INDEX  (locate(1) machinery: no new format, no daemon)
#############################################################################

index_dir() { printf '%s/index\n' "$(cache_write_dir)"; }

## The locate build tools ship in /usr/libexec and are NOT on PATH. Calling
## them by bare name exits 127, which would leave --index cheerfully
## reporting success while building nothing at all.
locate_tool() {
	if command -v "$1" >/dev/null 2>&1; then
		command -v "$1"
		return 0
	fi
	if [ -x "/usr/libexec/$1" ]; then
		printf '/usr/libexec/%s\n' "$1"
		return 0
	fi
	return 1
}

## every database to query for a location, colon-joined, system db first
index_dbs() {
	_loc="$1"; _list=""
	[ -f /var/db/locate.database ] && _list="/var/db/locate.database"
	for _d in $(cache_read_dirs); do
		for _f in "$_d/index/$_loc.db" "$_d/index/$_loc".inc.*.db; do
			[ -f "$_f" ] || continue
			if [ -z "$_list" ]; then _list="$_f"; else _list="$_list:$_f"; fi
		done
	done
	printf '%s\n' "$_list"
	return 0
}

index_covered_file() { printf '%s/%s.covered\n' "$(index_dir)" "$1"; }

## every snapshot of a location the index already covers
unique_cache_dump() {
	for _d in $(cache_read_dirs); do
		_f="$_d/index/$1.covered"
		[ -f "$_f" ] || continue
		cat "$_f" 2>/dev/null
	done
	return 0
}

index_covered_count() {
	unique_cache_dump "$1" | awk -F'\t' '{seen[$1] = 1} END {print length(seen) + 0}'
}

index_mark_covered() {
	_loc="$1"; _ts="$2"
	_f=$(index_covered_file "$_loc")
	need_dir "$(dirname "$_f")" || return 1
	_old=""
	[ -f "$_f" ] && _old=$(awk -F'\t' -v t="$_ts" '$1 != t' "$_f" 2>/dev/null)
	{
		[ -n "$_old" ] && printf '%s\n' "$_old"
		printf '%s\n' "$_ts"
	} | atomic_write "$_f" 2>/dev/null
	return 0
}

#############################################################################
## --status
#############################################################################

cmd_status() {
	_only="${1:-}"
	_locs=$(locations_all)
	[ -n "$_locs" ] || { note "no locations. Add one: $US --add <FOLDER> [<HANDLE>]"; return 0; }

	## Open every store BEFORE the table starts: mounting one prints a line, and
	## a line printed between the header and a row splits the table in half.
	while IFS="$(printf '\t')" read -r _h _t _idir; do
		[ -n "${_h:-}" ] || continue
		[ -n "$_only" ] && [ "$_h" != "$_only" ] && continue
		## never ATTACH for a status line: opening a sparsebundle on a share costs
		## a minute, and `my-tm` with no arguments must stay instant. It is shown
		## from what is already known, marked "?" like any store we cannot see.
		[ "$(loc_kind "$_h")" = "image" ] && continue
		loc_open "$_h" || true
	done <<_EOF
$_locs
_EOF

	## the LOC column is as wide as the widest handle: truncating a handle would
	## make the one word the reader has to type back unusable
	_w=$(printf '%s\n' "$_locs" | awk -F'\t' '{if (length($1) > m) m = length($1)} END {print (m < 3 ? 3 : m)}')
	printf " %-${_w}s %-30s %6s  %-24s %6s  %s\n" \
		LOC DESTINATION SNAPS SPAN LAST USED/FREE
	_now=$(now_epoch)
	while IFS="$(printf '\t')" read -r _h _t _idir; do
		[ -n "${_h:-}" ] || continue
		[ -n "$_only" ] && [ "$_h" != "$_only" ] && continue

		_dest="$_t"
		[ "$_t" = "local" ] && _dest="/ + /System/Volumes/Data"
		_snaps="-"; _span="-"; _last="-"; _space="-"; _mark=""

		if [ "$(loc_kind "$_h")" = "image" ]; then
			## an image is reported from what has already been read, never by
			## attaching it here (see above)
			_rows=$(snapshots_cached_only "$_h")
			[ -n "$_rows" ] || _mark="?"
		elif loc_ready "$_h"; then
			_rows=$(snapshots_get "$_h")
		else
			## not attached (ejected, unplugged, network destination): show the
			## last known table marked "?", never nothing -- a disk that has not
			## been written to for weeks is the thing --status exists to surface
			_mark="?"
			_rows=$(snapshots_cached_only "$_h")
		fi
		if [ -n "$_rows" ]; then
			_snaps=$(printf '%s\n' "$_rows" | count_lines)
			_sorted=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n)
			_first=$(printf '%s\n' "$_sorted" | head -n 1 | awk -F'\t' '{print $2}')
			_lastts=$(printf '%s\n' "$_sorted" | tail -n 1 | awk -F'\t' '{print $2}')
			_lastep=$(printf '%s\n' "$_sorted" | tail -n 1 | awk -F'\t' '{print $3}')
			_span="${_first%-*}..${_lastts%-*}"
			_span=$(printf '%s' "$_span" | cut -c1-24)
			[ -n "$_lastep" ] && _last=$(human_age $(( _now - _lastep )))
		fi
		if [ "$_t" != "local" ] && [ -d "$_t" ]; then
			_space=$(df -k "$_t" 2>/dev/null | awk 'NR == 2 {printf "%s/%s\n", $3 * 1024, $4 * 1024}')
			_used=$(human_bytes "${_space%%/*}")
			_free=$(human_bytes "${_space##*/}")
			_space="$_used/$_free"
		fi
		printf " %-${_w}s %-30s %6s  %-24s %5s%1s  %s\n" \
			"$_h" "$(printf '%s' "$_dest" | cut -c1-30)" \
			"$_snaps" "$_span" "$_last" "$_mark" "$_space"
	done <<_EOF
$_locs
_EOF

	## locations the jobs cannot see into, each named once with the setting that
	## would change it -- nothing for any other location
	while IFS="$(printf '\t')" read -r _nh _nt _ni; do
		[ -n "$_nh" ] || continue
		[ -n "$_only" ] && [ "$_nh" != "$_only" ] && continue
		( jobs_blind_on "$_nh" ) &&
			note "$_nh is on a network volume the jobs cannot see into: not in $(tm_root), no daily checks -- JOBS_RUN_WITH_FULL_DISK_ACCESS=1"
	done <<_EOF
$_locs
_EOF

	locations_user_file_note

	## footer: what the caches cost, and whether the index is behind
	_csize="-"
	_cf=$(snapshots_cache_file)
	[ -f "$_cf" ] && _csize=$(human_bytes "$(wc -c <"$_cf" | tr -d ' ')")
	_isize="-"
	[ -d "$(index_dir)" ] &&
		_isize=$(human_bytes "$(find "$(index_dir)" -type f -exec wc -c {} + 2>/dev/null |
			awk 'END {print $1 + 0}')")
	_scanned=""
	if [ -f "$_cf" ]; then
		_sa=$(( $(now_epoch) - $(stat -f '%m' "$_cf" 2>/dev/null || now_epoch) ))
		_scanned=" · scanned $(human_age "$_sa") ago"
	fi
	## the store is open right here, so a sample costs one df
	for _uh in $(printf '%s\n' "$_locs" | awk -F'\t' '{print $1}'); do
		usage_sample "$_uh"
	done
	_note="cache $_csize · index $_isize"
	_first_loc=$(printf '%s\n' "$_locs" | awk -F'\t' '$2 != "local" && !f {print $1; f = 1}')
	if [ -n "$_first_loc" ]; then
		_cov=$(index_covered_count "$_first_loc")
		_tot=$(snapshots_get "$_first_loc" | count_lines)
		[ "$_tot" -gt 0 ] && _note="$_note ($_cov/$_tot snaps, $US --index $_first_loc)"
	fi
	note "$_note$_scanned"

	## growth, only once the series says something
	printf '%s\n' "$_locs" | awk -F'\t' '{print $1}' | while IFS= read -r _th; do
		[ -n "$_th" ] || continue
		[ -n "$_only" ] && [ "$_th" != "$_only" ] && continue
		_tr=$(usage_trend "$_th") || continue
		[ -n "$_tr" ] || continue
		_per=$(printf '%s' "$_tr" | cut -f1)
		_free=$(printf '%s' "$_tr" | cut -f2)
		_days=$(printf '%s' "$_tr" | cut -f3)
		_span=$(printf '%s' "$_tr" | cut -f4)
		if [ "$_per" -gt 0 ] 2>/dev/null; then
			note "$_th grows $(human_bytes "$_per")/day over ${_span}d · $(human_bytes "$_free") free · full in ~${_days}d"
		else
			note "$_th is not growing over ${_span}d (thinning keeps up) · $(human_bytes "$_free") free"
		fi
	done
	return 0
}

#############################################################################
## --ls
#############################################################################

## the typical ADDED of a location, as a median over its snapshot rows
added_median() {
	printf '%s\n' "$1" | awk -F'\t' '$7 != "-" && $7 != "" {print $7}' | sort -n |
		awk '{v[NR] = $1} END {
			if (NR == 0) { print 0 }
			else if (NR % 2) { printf "%d\n", v[(NR + 1) / 2] }
			else { printf "%d\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }
		}'
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

## the machine-readable form of the snapshot table -- this is what a remote
## my-tm answers with, so nothing has to re-parse a human table over ssh.
json_ls() {
	_locs="$1"
	printf '[\n'
	_first=1
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		_cached=false
		loc_ready "$_h" 2>/dev/null || _cached=true
		_rows=$(snapshots_get "$_h")
		[ -n "$_rows" ] || continue
		printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3nr |
		while IFS="$(printf '\t')" read -r _l _ts _ep _id _xid _f _a _t2 _u _st _vol; do
			[ -n "${_ts:-}" ] || continue
			[ "$_first" = "1" ] && _first=0 || printf ',\n'
			printf '  {"location": "%s", "snapshot": "%s", "id": "%s", "epoch": %s,' \
				"$(json_escape "$_l")" "$_ts" "$_id" "${_ep:-0}"
			printf ' "files": "%s", "added": "%s", "total": "%s",' \
				"${_f:--}" "${_a:--}" "${_t2:--}"
			printf ' "state": "%s", "volume": "%s", "from_cache": %s}' \
				"${_st:-ok}" "$(json_escape "${_vol:--}")" "$_cached"
		done
	done <<_EOF
$_locs
_EOF
	printf '\n]\n'
	return 0
}

cmd_ls() {
	_only="${1:-}"
	if [ -n "$_only" ]; then
		loc_line "$_only" >/dev/null 2>&1 || err "$_only: no such location. Try: $US --status"
		_locs="$_only"
	else
		_locs=$(locations_all | awk -F'\t' '{print $1}')
	fi
	if [ "$JSON" = "1" ]; then
		json_ls "$_locs"
		return 0
	fi
	_now=$(now_epoch)
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		_detached=0
		if loc_ready "$_h"; then
			_rows=$(snapshots_get "$_h")
		else
			## the disk is away: the last known table is still worth showing
			_rows=$(snapshots_cached_only "$_h")
			_detached=1
		fi
		if [ -z "$_rows" ]; then
			## asked about ONE location and there is nothing to show: say why.
			## Printing nothing reads like "no backups exist", which may be the
			## opposite of the truth -- the disk may simply be detached.
			if [ -n "$_only" ]; then
				if [ "$_detached" = "1" ]; then
					note "$_h is not attached, and nothing is remembered about it yet -- attach it, then: $US --refresh $_h"
				else
					note "$_h has no snapshots"
				fi
			fi
			continue
		fi
		[ -z "$_only" ] && printf '\n%s:\n' "$_h"
		[ "$_detached" = "1" ] &&
			note "$_h is not attached -- this is the last known table"

		_max="${LIMIT:-20}"
		[ "$OPT_ALL" = "1" ] && _max=0
		_total=$(printf '%s\n' "$_rows" | count_lines)
		## the MEDIAN, not the mean: a handful of huge backups (a VM image, a
		## restored archive) drag a mean up until every ordinary night reads
		## 0.0x and a real spike no longer stands out.
		_avg=$(added_median "$_rows")

		printf ' %-8s %-20s %5s %6s %6s %6s %6s  %s\n' \
			ID SNAPSHOT AGE FILES ADDED DRIFT TOTAL VOL
		printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3nr |
		{
			_i=0
			while IFS="$(printf '\t')" read -r _l _ts _ep _id _xid _files _added _total2 _uniq _state _vol; do
				_i=$(( _i + 1 ))
				[ "$_max" -gt 0 ] && [ "$_i" -gt "$_max" ] && break
				_age=$(human_age $(( _now - ${_ep:-0} )))
				_drift="-"
				if [ "${_added:-}" != "-" ] && [ "$_avg" -gt 0 ]; then
					_drift=$(awk -v a="$_added" -v m="$_avg" -v f="$HEALTH_DRIFT_FACTOR" \
						'BEGIN {r = a / m; printf "%.1fx%s\n", r, (r >= f ? "!" : "")}')
				fi
				_st=""
				[ "${_state:-ok}" != "ok" ] && _st=" [$_state]"
				printf ' %-8s %-20s %5s %6s %6s %6s %6s  %s%s\n' \
					"$_id" "$(ts_display "$_ts")" "$_age" \
					"$(human_count "$_files")" "$(human_bytes "$_added")" "$_drift" \
					"$(human_bytes "$_total2")" \
					"${_vol:--}" "$_st"
			done
		}
		## local snapshots carry no manifest, so there is no ADDED to average:
		## saying "median 0" would state a measurement that was never made
		_med=""
		[ "$_avg" -gt 0 ] && _med=" · ADDED median $(human_bytes "$_avg")"
		if [ "$_max" -gt 0 ] && [ "$_total" -gt "$_max" ]; then
			note "$(( _total - _max )) more (--all)$_med"
		else
			note "$_total snapshots$_med"
		fi
	done <<_EOF
$_locs
_EOF
	return 0
}

#############################################################################
## --lookup
##   Covered snapshots come from the version store with no mount at all.  The
##   rest are mounted, stat'ed in ONE exec for all of them, released, and filed.
#############################################################################

## which locations back up the volume a path lives on
locs_covering_path() {
	_p="$1"
	if [ -n "$SRC" ]; then printf '%s\n' "$SRC"; return 0; fi
	if [ "$OPT_ALL" = "1" ]; then
		locations_all | awk -F'\t' '{print $1}'
		return 0
	fi
	## nearest existing ancestor identifies the volume even for a deleted file
	_a="$_p"
	while [ ! -e "$_a" ] && [ "$_a" != "/" ]; do _a=$(dirname "$_a"); done
	_uuid=$(path_volume_uuid "$_a")
	_any=0
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_ready "$_h" || continue
		loc_is_remote "$_h" && continue
		if [ "$(loc_kind "$_h")" = "local" ]; then
			[ "$_uuid" = "$(path_volume_uuid /System/Volumes/Data)" ] &&
				{ printf '%s\n' "$_h"; _any=1; }
			continue
		fi
		## A store that is open can say exactly which volumes it holds. One that is
		## away cannot, and assuming it does NOT cover the path would answer "no
		## backups" about a disk we simply cannot see -- so it stays in the list.
		_su=$(loc_source_uuids "$_h" 2>/dev/null) || _su=""
		if [ -n "$_su" ] && [ -n "$_uuid" ]; then
			if printf '%s\n' "$_su" | grep -qxF "$_uuid"; then
				printf '%s\n' "$_h"; _any=1
			fi
			continue
		fi
		printf '%s\n' "$_h"; _any=1
	done <<_EOF
$_locs
_EOF
	[ "$_any" = "1" ] || locations_all | awk -F'\t' '$2 != "local" {print $1}'
	return 0
}

## the path as it appears inside a snapshot's volume dir
path_in_volume() {
	_p="$1"
	case "$_p" in
		/System/Volumes/Data/*) printf '%s\n' "${_p#/System/Volumes/Data}" ;;
		*) printf '%s\n' "$_p" ;;
	esac
}

## Collapse consecutive snapshots holding the SAME version into one row.
##
## The key is size+mtime, deliberately NOT the inode. Time Machine does not
## keep an inode stable across snapshots of every store: measured on a
## network sparsebundle, a file untouched since 2020 had a different inode
## in all 100 snapshots, which reported 100 "distinct versions" of a file
## that never changed. Size+mtime is right in both cases.
lookup_collapse() {
	awk -F'\t' '
		{
			key = $5 "|" $6;
			if (NR > 1 && key == prev) next;
			prev = key;
			print $0;
		}
	'
}

## stat one chunk of mounted snapshots in a single exec, file the facts, and
## release that chunk again.  <workdir> <location> <relative path>
lookup_flush() {
	_w="$1"; _loc="$2"; _relp="$3"
	if [ -s "$_w/paths" ]; then
		## NUL-separated into one stat: a path inside a backup can contain
		## spaces, so word-splitting an argument list would corrupt it
		cut -f4 "$_w/paths" | tr '\n' '\0' |
			xargs -0 stat -f '%N%t%i %z %m' >"$_w/stats" 2>/dev/null || true
		awk -F'\t' '
			FILENAME ~ /stats$/ { st[$1] = $2; next }
			FILENAME ~ /paths$/ {
				v = ($4 in st) ? st[$4] : "- - -";
				split(v, a, " ");
				printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, a[1], a[2], a[3];
			}
		' "$_w/stats" "$_w/paths" >"$_w/chunk_known"
		cat "$_w/chunk_known" >>"$_w/known"
		## snapshots are immutable, so these rows are permanent facts
		awk -F'\t' -v p="$_relp" '{printf "%s\t%s\t%s\t%s\t%s\n", $1, p, $4, $5, $6}' \
			"$_w/chunk_known" | vs_put "$_loc"
	fi
	if [ -s "$_w/mnts" ]; then
		while IFS= read -r _m; do
			[ -n "$_m" ] || continue
			snap_umount "$_m" 0 >/dev/null 2>&1
		done <"$_w/mnts"
	fi
	: >"$_w/paths"; : >"$_w/mnts"
	return 0
}

cmd_lookup() {
	_p="$1"; _scope="${2:-}"
	case "$_p" in
		/*) : ;;
		*)  _p="$PWD/$_p" ;;
	esac
	_rel=$(path_in_volume "$_p")

	## the live file, for the =live / changed comparison
	_live=$(stat -f '%i %z %m' "$_p" 2>/dev/null || true)
	_live_i=$(printf '%s' "$_live" | awk '{print $1}')
	_live_s=$(printf '%s' "$_live" | awk '{print $2}')
	_live_m=$(printf '%s' "$_live" | awk '{print $3}')

	if [ -n "$_scope" ]; then _locs="$_scope"; else _locs=$(locs_covering_path "$_p"); fi

	_any=0
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		_rows=$(snapshots_get "$_h")
		[ -n "$_rows" ] || continue
		_any=1

		_work=$(mktemp -d /tmp/my-tm.lk.XXXXXX) || return 1
		: >"$_work/known"
		: >"$_work/todo"
		## what the index walk already recorded: every covered snapshot, no mount
		vs_versions_for "$_h" "$_rel" >"$_work/indexed" 2>/dev/null || : >"$_work/indexed"
		_nidx=$(count_lines <"$_work/indexed")
		[ "$_nidx" -gt 0 ] && dbg "lookup $_h: $_nidx snapshots answered from the index"
		while IFS="$(printf '\t')" read -r _l _ts _ep _id _x _f _a _t2 _u _st _vol; do
			[ -n "${_ts:-}" ] || continue
			if _hit=$(awk -F'\t' -v t="$_ts" '$1 == t {printf "-\t%s\t%s", $2, $3; exit}' \
					"$_work/indexed"); [ -n "$_hit" ]; then
				printf '%s\t%s\t%s\t%s\n' "$_ts" "$_ep" "$_id" "$_hit" >>"$_work/known"
			elif _hit=$(vs_lookup "$_h" "$_ts" "$_rel"); then
				printf '%s\t%s\t%s\t%s\n' "$_ts" "$_ep" "$_id" "$_hit" >>"$_work/known"
			else
				[ "${_vol:--}" = "-" ] && _vol="Data"
				printf '%s\t%s\t%s\t%s\n' "$_ts" "$_ep" "$_id" "$_vol" >>"$_work/todo"
			fi
		done <<_EOF
$_rows
_EOF
		_ntodo=$(count_lines < "$_work/todo")
		_nknown=$(count_lines < "$_work/known")
		dbg "lookup $_h: $_nknown from the version store, $_ntodo to read live"

		if [ "$_ntodo" -gt 0 ]; then
			[ "$_ntodo" -gt "$LOOKUP_CHUNK" ] &&
				msg "reading $_ntodo snapshots of '$_h' (first touch on a sleeping disk can take a while)"
			## In chunks: mount up to LOOKUP_CHUNK snapshots, stat them all in ONE
			## exec, release them, next chunk.  Mounting the whole history at once
			## would pin every snapshot against Time Machine's thinning for as long
			## as the run lasts, and releasing them again is not free.
			: >"$_work/paths"; : >"$_work/mnts"; _inchunk=0
			while IFS="$(printf '\t')" read -r _ts _ep _id _vol; do
				[ -n "${_ts:-}" ] || continue
				_mp=$(transient_snapshot "$_h" "$_ts") || continue
				printf '%s\n' "$_mp" >>"$_work/mnts"
				printf '%s\t%s\t%s\t%s\n' "$_ts" "$_ep" "$_id" \
					"$(mnt_volume_path "$_h" "$_ts" "$_vol")$_rel" >>"$_work/paths"
				_inchunk=$(( _inchunk + 1 ))
				if [ "$_inchunk" -ge "$LOOKUP_CHUNK" ]; then
					lookup_flush "$_work" "$_h" "$_rel"
					_inchunk=0
				fi
			done <"$_work/todo"
			lookup_flush "$_work" "$_h" "$_rel"
			## could-not-read is NOT the same answer as not-there
			_got=$(count_lines < "$_work/known")
			_missed=$(( _nknown + _ntodo - _got ))
			if [ "$_missed" -gt 0 ]; then
				warn "$_missed of $_ntodo snapshots could not be read (see the errors above) -- that is not the same as the file being absent from them"
			fi
		fi

		## collapse identical versions (inode+size+mtime), newest row per group
		printf ' %-8s %-20s %5s %6s  %s\n' ID SNAPSHOT AGE SIZE STATE
		_now=$(now_epoch)
		sort -t"$(printf '\t')" -k2,2nr "$_work/known" | lookup_collapse >"$_work/distinct"

		_ndist=0
		while IFS="$(printf '\t')" read -r _ts _ep _id _i _s _m; do
			[ -n "${_ts:-}" ] || continue
			_ndist=$(( _ndist + 1 ))
			## Presence is decided by SIZE, never by the inode. The version store
			## records path, size and mtime -- there is no inode in it, so testing
			## one reported every indexed snapshot as "absent" whatever it held.
			## Identity is size+mtime everywhere else here too, because an inode is
			## not stable across snapshots of every store (see the collapse in §6).
			if [ "${_s:--}" = "-" ]; then
				_state="absent"; _size="-"
			elif [ "$_s" = "${_live_s:-x}" ] && [ "$_m" = "${_live_m:-x}" ]; then
				_state="=live"; _size=$(human_bytes "$_s")
			else
				_state="changed"; _size=$(human_bytes "$_s")
			fi
			printf ' %-8s %-20s %5s %6s  %s\n' \
				"$_id" "$(ts_display "$_ts")" "$(human_age $(( _now - _ep )))" "$_size" "$_state"
		done <"$_work/distinct"

		_tot=$(printf '%s\n' "$_rows" | count_lines)
		note "$_h · $_ndist distinct versions in $_tot snapshots"
		rm -rf "$_work"
	done <<_EOF
$_locs
_EOF
	[ "$_any" = "1" ] || note "no location backs up $_p (--all to search every location)"
	return 0
}

#############################################################################
## --find
#############################################################################

cmd_find() {
	_glob="$1"; _scope="${2:-}"
	if [ -n "$_scope" ] && printf '%s' "$_scope" | grep -q '^[0-9a-z]'; then
		if _hit=$(resolve_id "$_scope" 2>/dev/null) && [ -n "$_hit" ]; then
			cmd_find_in_snapshot "$_hit" "$_glob"
			return $?
		fi
	fi
	if [ -n "$_scope" ]; then _locs="$_scope"; else _locs=$(locations_all | awk -F'\t' '{print $1}'); fi

	_pattern="$_glob"
	case "$_pattern" in
		*[*?[]*) : ;;
		*) _pattern="*$_pattern*" ;;
	esac

	_hits=$(mktemp /tmp/my-tm.find.XXXXXX) || return 1
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		_dbs=$(index_dbs "$_h")
		[ -n "$_dbs" ] || continue
		run_echo locate -d "$_dbs" "$_pattern"
		locate -d "$_dbs" "$_pattern" 2>/dev/null | sed -e 's|^.*\.backup/[^/]*||' |
			grep '^/' >>"$_hits" 2>/dev/null || true
	done <<_EOF
$_locs
_EOF

	_n=$(sort -u "$_hits" | count_lines)
	if [ "$_n" -eq 0 ]; then
		rm -f "$_hits"
		_l=$(printf '%s\n' "$_locs" | head -n 1)
		_cov=$(index_covered_count "$_l")
		_tot=$(snapshots_get "$_l" 2>/dev/null | count_lines)
		note "no match · index covers $_cov/$_tot snapshots ($US --index $_l)"
		return 0
	fi

	printf ' %-48s %8s  %-10s  %s\n' PATH VERSIONS NEWEST OLDEST
	_max="${LIMIT:-20}"
	[ "$OPT_ALL" = "1" ] && _max=0
	_i=0
	sort -u "$_hits" | while IFS= read -r _p; do
		_i=$(( _i + 1 ))
		[ "$_max" -gt 0 ] && [ "$_i" -gt "$_max" ] && break
		_vers="?"; _new="-"; _old="-"
		_vrows=$(for _d in $(cache_read_dirs); do
			[ -f "$_d/index/versions.tsv" ] || continue
			awk -F'\t' -v p="$_p" '$3 == p && $4 != "-" {print $2}' "$_d/index/versions.tsv"
		done | sort -u)
		if [ -n "$_vrows" ]; then
			_vers=$(printf '%s\n' "$_vrows" | count_lines)
			_new=$(printf '%s\n' "$_vrows" | tail -n 1 | cut -c1-10)
			_old=$(printf '%s\n' "$_vrows" | head -n 1 | cut -c1-10)
		fi
		printf ' %-48s %8s  %-10s  %s\n' "$(printf '%s' "$_p" | cut -c1-48)" "$_vers" "$_new" "$_old"
	done
	[ "$_max" -gt 0 ] && [ "$_n" -gt "$_max" ] &&
		note "$(( _n - _max )) more (--all) · $US <path> for the version table"
	rm -f "$_hits"
	return 0
}

## --find <ID> <GLOB>: a live walk of one snapshot, no index involved
cmd_find_in_snapshot() {
	_hit="$1"; _glob="$2"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	_mp=$(transient_snapshot "$_loc" "$_ts") || err "could not mount $_ts"
	_base=$(mnt_volume_path "$_loc" "$_ts" "$_vol")
	msg "walking $(ts_display "$_ts") live (no index needed, and slow)"
	run find "$_base" -name "$_glob" 2>/dev/null | sed "s|^$_base||"
	cleanup_transient
	return 0
}

#############################################################################
## --show
#############################################################################

cmd_show() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	[ -n "$_hit" ] || snapshot_gone "$1"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_id=$(printf '%s' "$_hit" | awk -F'\t' '{print $3}')
	_path="${2:-}"

	_row=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t')
	_ep=$(printf '%s' "$_row" | awk -F'\t' '{print $3}')
	_files=$(printf '%s' "$_row" | awk -F'\t' '{print $6}')
	_added=$(printf '%s' "$_row" | awk -F'\t' '{print $7}')
	_total=$(printf '%s' "$_row" | awk -F'\t' '{print $8}')
	_uniq=$(printf '%s' "$_row" | awk -F'\t' '{print $9}')
	_state=$(printf '%s' "$_row" | awk -F'\t' '{print $10}')
	_vol=$(printf '%s' "$_row" | awk -F'\t' '{print $11}')
	[ "${_vol:--}" = "-" ] && _vol="Data"

	if [ -z "$_path" ]; then
		printf ' %-10s %s\n' ID "$_id"
		printf ' %-10s %s\n' SNAPSHOT "$(ts_display "$_ts")"
		printf ' %-10s %s\n' LOCATION "$_loc"
		printf ' %-10s %s\n' AGE "$(human_age $(( $(now_epoch) - ${_ep:-0} )))"
		printf ' %-10s %s\n' FILES "$(human_count "$_files")"
		printf ' %-10s %s\n' ADDED "$(human_bytes "$_added")"
		printf ' %-10s %s\n' TOTAL "$(human_bytes "$_total")"
		printf ' %-10s %s\n' VOLUME "$_vol"
		printf ' %-10s %s\n' STATE "${_state:-ok}"
		## only advertise the browsable path when it is really there: a tree
		## that --refresh has never built is a path that does not exist
		_browse="$(tm_root)/$_loc/$_ts/$_vol"
		if [ -e "$_browse" ]; then
			printf ' %-10s %s\n' BROWSE "$_browse"
		elif [ -L "$_browse" ] || [ -d "$(dirname "$_browse")" ]; then
			## the tree entry is there; it is simply not mounted yet
			printf ' %-10s %s  (%s --mount %s <TTL> to fill it)\n' \
				BROWSE "$_browse" "$US" "$_id"
		else
			_why=""
			( jobs_blind_on "$_loc" ) &&
				_why="; the jobs cannot see into network volumes -- JOBS_RUN_WITH_FULL_DISK_ACCESS=1 keeps it built"
			printf ' %-10s %s  (%s --refresh %s to build the tree%s)\n' \
				BROWSE "$_browse" "$US" "$_loc" "$_why"
		fi
		return 0
	fi

	_rel=$(path_in_volume "$(abs_path "$_path")")
	_mp=$(transient_snapshot "$_loc" "$_ts") || err "could not mount $_ts"
	_full="$(mnt_volume_path "$_loc" "$_ts" "$_vol")$_rel"
	if [ -e "$_full" ]; then
		_st=$(stat -f '%z%t%Sm%t%Sp %Su:%Sg' "$_full" 2>/dev/null)
		printf ' %-10s %s\n' PATH "$_rel"
		printf ' %-10s %s\n' IN "$_id ($(ts_display "$_ts"))"
		printf ' %-10s %s\n' SIZE "$(human_bytes "$(printf '%s' "$_st" | cut -f1)")"
		printf ' %-10s %s\n' MTIME "$(printf '%s' "$_st" | cut -f2)"
		printf ' %-10s %s\n' MODE "$(printf '%s' "$_st" | cut -f3)"
		printf ' %-10s %s\n' FULL "$_full"
	else
		note "$_rel: not in $_id ($(ts_display "$_ts"))"
	fi
	cleanup_transient
	return 0
}

abs_path() {
	case "$1" in
		/*) _ap="$1" ;;
		*)  _ap="$PWD/$1" ;;
	esac
	## "./my-tm.sh" would otherwise read back as "/some/dir/./my-tm.sh"
	printf '%s\n' "$_ap" | sed -e 's|/\./|/|g' -e 's|//*|/|g'
}

#############################################################################
## NOTIFICATIONS  (dependency-free by default; root reaches the GUI session)
#############################################################################

notify() {
	_title="my-tm"; _msg="$1"
	if [ -n "$NOTIFY_CMD" ] && [ -x "$NOTIFY_CMD" ]; then
		"$NOTIFY_CMD" -- "$_msg" >/dev/null 2>&1 && return 0
		dbg "NOTIFY_CMD failed, falling back to osascript"
	elif [ -n "$NOTIFY_CMD" ]; then
		dbg "NOTIFY_CMD not executable ($NOTIFY_CMD), falling back to osascript"
	fi
	## strings go in as osascript ARGUMENTS: quotes and backslashes in a
	## message can then neither break the script nor inject into it.
	if is_root; then
		_cu=$(stat -f '%Su' /dev/console 2>/dev/null)
		[ -n "$_cu" ] && [ "$_cu" != "root" ] || return 0
		_uid=$(id -u "$_cu" 2>/dev/null) || return 0
		launchctl asuser "$_uid" sudo -u "$_cu" osascript \
			-e 'on run argv' \
			-e 'display notification (item 2 of argv) with title (item 1 of argv)' \
			-e 'end run' "$_title" "$_msg" >/dev/null 2>&1
	else
		osascript \
			-e 'on run argv' \
			-e 'display notification (item 2 of argv) with title (item 1 of argv)' \
			-e 'end run' "$_title" "$_msg" >/dev/null 2>&1
	fi
	return 0
}

#############################################################################
## --mount / --umount
#############################################################################

## the destination's configured backup interval, in seconds
backup_interval_of() {
	_h="$1"
	_v=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackupInterval 2>/dev/null)
	case "${_v:-}" in
		[0-9]*) printf '%s\n' "$_v"; return 0 ;;
	esac
	## no preference readable -> use the observed spacing of recent snapshots
	snapshots_get "$_h" | sort -t"$(printf '\t')" -k3,3nr | head -n 6 |
		awk -F'\t' '{e[NR] = $3} END {
			if (NR < 2) { print 3600; exit }
			for (i = 1; i < NR; i++) { d = e[i] - e[i+1]; if (d > 0) { s += d; n++ } }
			if (n) printf "%d\n", s / n; else print 3600
		}'
	return 0
}

ttl_sanity_warn() {
	_h="$1"; _ttl="$2"
	_iv=$(backup_interval_of "$_h")
	[ -n "$_iv" ] && [ "$_iv" -gt 0 ] || return 0
	_ceiling=$(( _iv / 4 ))
	[ "$_ttl" -le "$_ceiling" ] && return 0
	_blocked=$(( _ttl / _iv ))
	[ "$_blocked" -lt 1 ] && _blocked=1
	_ivh=$(awk -v s="$_iv" 'BEGIN {
		if (s % 86400 == 0) printf "every %dd\n", s / 86400;
		else if (s % 3600 == 0) printf "%s\n", (s == 3600 ? "hourly" : sprintf("every %dh", s / 3600));
		else printf "every %dm\n", s / 60 }')
	_sane=$(awk -v c="$_ceiling" 'BEGIN {
		if (c >= 3600) printf "%dh\n", c / 3600; else printf "%dm\n", int(c / 60) }')
	warn "$(awk -v t="$_ttl" 'BEGIN {printf "%s", (t >= 3600 ? sprintf("%dh", t/3600) : sprintf("%dm", t/60))}') on '$_h' (backs up $_ivh) - thinning is blocked for ~$_blocked backups."
	printf '     A quarter of the interval is the sane ceiling here: %s. Continuing.\n' "$_sane" >&2
	[ "$NOTIFY_MOUNT_WARN" = "1" ] &&
		notify "mount on '$_h' outlives $_sane - thinning is blocked while it lasts"
	return 0
}

cmd_mount() {
	_what="${1:-}"; _ttl_s="${2:-}"; _where="${3:-}"
	[ -n "$_what" ] || err "--mount needs <ID>|<LOCATION>|--all and a <TTL> (7m / 4h / 2d). See --mount --help"
	[ -n "$_ttl_s" ] || err "--mount needs a <TTL>: how long you need it (7m / 4h / 5h3m / 2d). It is asked for because a mounted snapshot cannot be deleted -- see --mount --help"
	_ttl=$(parse_ttl "$_ttl_s") ||
		err "'$_ttl_s' is not a TTL. Use <N>m, <N>h or <N>d, combinable: 7m / 4h / 5h3m / 2d"
	[ -n "$_ttl" ] ||
		err "'$_ttl_s' is not a TTL. Use <N>m, <N>h or <N>d, combinable: 7m / 4h / 5h3m / 2d"

	## a location: its newest snapshot, or every one with --all
	if loc_line "$_what" >/dev/null 2>&1; then
		_h="$_what"
		ttl_sanity_warn "$_h" "$_ttl"
		if [ "$OPT_ALL" = "1" ]; then
			_list=$(snapshots_get "$_h" | sort -t"$(printf '\t')" -k3,3n | awk -F'\t' '{print $2"\t"$11}')
		else
			_list=$(snapshots_get "$_h" | sort -t"$(printf '\t')" -k3,3nr | head -n 1 | awk -F'\t' '{print $2"\t"$11}')
		fi
		[ -n "$_list" ] || err "$_h: no snapshots"
		while IFS="$(printf '\t')" read -r _ts _vol; do
			[ -n "${_ts:-}" ] || continue
			[ "${_vol:--}" = "-" ] && _vol="Data"
			_mp=""
			if [ -n "$_where" ]; then
				_mp="$(abs_path "$_where")/$_ts"
				need_dir "$_mp"
			fi
			_got=$(snap_mount "$_h" "$_ts" "$_ttl" "" "$_mp") || continue
			## print where the files ACTUALLY are: a snapshot macOS already had
			## mounted is reused where it sits, not at our tree path
			snap_volume_root_at "$_got" "$_h" "$_ts" "$_vol"
		done <<_EOF
$_list
_EOF
		return 0
	fi

	_hit=$(resolve_id "$_what") || snapshot_gone "$_what"
	[ -n "$_hit" ] || snapshot_gone "$_what"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	ttl_sanity_warn "$_loc" "$_ttl"
	_mp=""
	[ -n "$_where" ] && { _mp=$(abs_path "$_where"); need_dir "$_mp"; }
	_got=$(snap_mount "$_loc" "$_ts" "$_ttl" "" "$_mp") || err "mount failed"
	snap_volume_root_at "$_got" "$_loc" "$_ts" "$_vol"
	return 0
}

cmd_umount() {
	_what="${1:-}"
	## take over anything attached that nothing is tracking, so it can be released
	images_adopt_orphans
	_records=$(mounts_read_all)
	[ -n "$_records" ] || { note "nothing mounted by $US"; return 0; }
	_tmp=$(mktemp /tmp/my-tm.um.XXXXXX) || return 1
	printf '%s\n' "$_records" >"$_tmp"
	_hitloc=""; _hitid=""
	if [ "$OPT_ALL" != "1" ] && [ -n "$_what" ]; then
		if loc_line "$_what" >/dev/null 2>&1; then
			_hitloc="$_what"
		else
			_h=$(resolve_id "$_what") || snapshot_gone "$_what"
			_hitid=$(printf '%s' "$_h" | awk -F'\t' '{print $3}')
		fi
	fi
	_n=0
	## one lsof for the whole set, not one per mount
	_busy=""
	[ "$FORCE" = "1" ] || _busy=$(awk -F'\t' '{print $3}' "$_tmp" | busy_mounts)
	while IFS="$(printf '\t')" read -r _id _loc _mp _made _ttl _pid _flags; do
		[ -n "${_mp:-}" ] || continue
		[ -n "$_hitloc" ] && [ "$_loc" != "$_hitloc" ] && continue
		[ -n "$_hitid" ] && [ "$_id" != "$_hitid" ] && continue
		if ! mount_table_has "$_mp"; then mount_record_drop "$_mp"; continue; fi
		if [ "$FORCE" != "1" ] && printf '%s\n' "$_busy" | grep -qxF "$_mp" 2>/dev/null; then
			warn "$_mp is busy:"
			lsof -n -P -- "$_mp" 2>/dev/null | head -n 5 >&2
			warn "still needed? leave it. Otherwise: $US --umount -f $_what"
			continue
		fi
		case "${_flags:-}" in
			*image*)
				if image_detach "$_mp"; then
					mount_record_drop "$_mp"
					msg "detached $_mp"
					_n=$(( _n + 1 ))
				else
					warn "could not detach $_mp"
				fi
				continue
				;;
		esac
		if snap_umount "$_mp" "$FORCE"; then
			msg "released $_mp"
			_n=$(( _n + 1 ))
		else
			warn "could not release $_mp"
		fi
	done <"$_tmp"
	rm -f "$_tmp"
	note "$_n mount(s) released"
	return 0
}

#############################################################################
## --open / --cat / --cp / --diff
#############################################################################

## resolve <ID> <PATH> to a live filesystem path inside a transient mount
## echoes: loc <TAB> ts <TAB> id <TAB> fullpath <TAB> relpath
snapshot_file() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	[ -n "$_hit" ] || snapshot_gone "$1"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_id=$(printf '%s' "$_hit" | awk -F'\t' '{print $3}')
	_rel=$(path_in_volume "$(abs_path "$2")")
	if loc_is_remote "$_loc"; then
		printf '%s\t%s\t%s\t\t%s\n' "$_loc" "$_ts" "$_id" "$_rel"
		return 0
	fi
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	transient_snapshot "$_loc" "$_ts" >/dev/null || err "could not mount $(ts_display "$_ts")"
	printf '%s\t%s\t%s\t%s\t%s\n' "$_loc" "$_ts" "$_id" \
		"$(mnt_volume_path "$_loc" "$_ts" "$_vol")$_rel" "$_rel"
	return 0
}

cmd_cat() {
	_i=$(snapshot_file "$1" "$2")
	_loc=$(printf '%s' "$_i" | awk -F'\t' '{print $1}')
	_full=$(printf '%s' "$_i" | awk -F'\t' '{print $4}')
	_rel=$(printf '%s' "$_i" | awk -F'\t' '{print $5}')
	if loc_is_remote "$_loc"; then
		_t=$(loc_target "$_loc")
		_ts=$(printf '%s' "$_i" | awk -F'\t' '{print $2}')
		run ssh "$(remote_host "$_t")" "$(remote_install_cmd "$_loc") --cat $_ts$_rel" && return 0
		err "remote cat failed"
	fi
	[ -f "$_full" ] || err "$_rel: not in that snapshot"
	run cat "$_full"
	return 0
}

cmd_open() {
	_i=$(snapshot_file "$1" "$2")
	_full=$(printf '%s' "$_i" | awk -F'\t' '{print $4}')
	_rel=$(printf '%s' "$_i" | awk -F'\t' '{print $5}')
	_loc=$(printf '%s' "$_i" | awk -F'\t' '{print $1}')
	if loc_is_remote "$_loc"; then
		_tmpf="${TMPDIR:-/tmp}/$(basename "$_rel")"
		cmd_cat "$1" "$2" >"$_tmpf" || err "could not fetch the remote file"
		msg "fetched to $_tmpf"
		run open "$_tmpf"
		return 0
	fi
	[ -e "$_full" ] || err "$_rel: not in that snapshot"
	## a transient mount would be released the moment we return, so promote it
	_loc2=$(printf '%s' "$_i" | awk -F'\t' '{print $1}')
	_ts2=$(printf '%s' "$_i" | awk -F'\t' '{print $2}')
	rm -f "$TRANSIENT_LIST"
	snap_mount "$_loc2" "$_ts2" 1800 "" >/dev/null
	why "kept for 30 minutes so the application can still read it"
	run open "$_full"
	return 0
}

cmd_cp() {
	_i=$(snapshot_file "$1" "$2")
	_full=$(printf '%s' "$_i" | awk -F'\t' '{print $4}')
	_rel=$(printf '%s' "$_i" | awk -F'\t' '{print $5}')
	_loc=$(printf '%s' "$_i" | awk -F'\t' '{print $1}')
	_dest="${3:-}"
	[ -n "$_dest" ] || _dest="$PWD/$(basename "$_rel")"
	[ -d "$_dest" ] && _dest="$_dest/$(basename "$_rel")"
	if [ -e "$_dest" ] && [ "$FORCE" != "1" ]; then
		err "$_dest exists. The live copy is the one you are worried about -- pass -f to overwrite."
	fi
	if loc_is_remote "$_loc"; then
		cmd_cat "$1" "$2" >"$_dest" || err "remote copy failed"
		msg "wrote $_dest"
		return 0
	fi
	[ -e "$_full" ] || err "$_rel: not in that snapshot"
	run cp -p "$_full" "$_dest" || err "copy failed"
	msg "wrote $_dest"
	return 0
}

cmd_diff() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	_files=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $6; exit}')
	transient_snapshot "$_loc" "$_ts" >/dev/null || err "could not mount $(ts_display "$_ts")"
	_base=$(mnt_volume_path "$_loc" "$_ts" "$_vol")

	if [ -n "${2:-}" ]; then
		_rel=$(path_in_volume "$(abs_path "$2")")
		run diff -r "$_base$_rel" "$(abs_path "$2")"
		return 0
	fi
	if [ "${_files:--}" != "-" ]; then
		_eta=$(awk -v n="$_files" 'BEGIN {
			lo = n / 15000 / 60; hi = n / 8000 / 60;
			printf "roughly %d-%d min", (lo < 1 ? 1 : lo), (hi < 2 ? 2 : hi) }')
		note "$(human_count "$_files") files, $_eta. Ctrl-C is safe."
	fi
	run tmutil compare "$_base" "/System/Volumes/Data"
	return 0
}

#############################################################################
## --index
#############################################################################

cmd_index() {
	## check the toolchain BEFORE walking anything: discovering it is missing
	## after a twenty-minute walk would be a poor way to find out
	locate_tool locate.mklocatedb >/dev/null ||
		err "locate.mklocatedb not found (looked on PATH and in /usr/libexec). The name index --find uses cannot be built without it."
	_targets="$*"
	## drop what has been thinned away since the last run, before adding more
	for _ph in $(locations_all | awk -F'\t' '$2 != "local" || 1 {print $1}'); do
		loc_reachable "$_ph" && vs_prune "$_ph"
	done
	_locs=""
	_snaps=""
	if [ -z "$_targets" ]; then
		_locs=$(locations_all | awk -F'\t' '$2 != "local" {print $1}')
	else
		for _t in $_targets; do
			if loc_line "$_t" >/dev/null 2>&1; then
				_locs="$_locs $_t"
			else
				_snaps="$_snaps $_t"
			fi
		done
	fi

	if [ -n "$_snaps" ]; then
		for _s in $_snaps; do
			_hit=$(resolve_id "$_s") || snapshot_gone "$_s"
			index_one "$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')" \
			          "$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')"
		done
		index_consolidate_all "$_locs"
		return 0
	fi

	for _h in $_locs; do
		loc_reachable "$_h" || { warn "$_h: not reachable, skipped"; continue; }
		loc_is_remote "$_h" && { index_remote "$_h"; continue; }
		_rows=$(snapshots_get "$_h" | sort -t"$(printf '\t')" -k3,3n)
		[ -n "$_rows" ] || continue
		_list=""
		if [ "$OPT_ALL" = "1" ]; then
			_list=$(printf '%s\n' "$_rows" | awk -F'\t' '{print $2}')
			_n=$(printf '%s\n' "$_list" | count_lines)
			warn "$_h: walking all $_n snapshots. This is an overnight job, and Time Machine's thinning is blocked on the one snapshot being walked at a time. Ctrl-C is safe."
		else
			for _b in $INDEX_BASELINES; do
				case "$_b" in
					newest) _list="$_list
$(printf '%s\n' "$_rows" | tail -n 1 | awk -F'\t' '{print $2}')" ;;
					oldest) _list="$_list
$(printf '%s\n' "$_rows" | head -n 1 | awk -F'\t' '{print $2}')" ;;
				esac
			done
		fi
		while IFS= read -r _ts; do
			[ -n "$_ts" ] || continue
			index_one "$_h" "$_ts"
		done <<_EOF
$_list
_EOF
		index_consolidate "$_h"
	done
	return 0
}

## walk ONE snapshot: path list -> locate db, plus its exclusive size.
## Exactly one snapshot is pinned at a time, and it is released before the next.
index_one() {
	_h="$1"; _ts="$2"
	if unique_cache_dump "$_h" | awk -F'\t' -v t="$_ts" '$1 == t {found = 1} END {exit(found ? 0 : 1)}'; then
		dbg "index: $_ts already covered"
		return 0
	fi
	_vol=$(snapshots_get "$_h" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"

	_id=$(snap_id "$(loc_uuid "$_h")" "$_ts")
	_mp=$(mnt_point_for "$_h" "$_ts")
	msg "indexing $(ts_display "$_ts") of '$_h'"
	snap_mount "$_h" "$_ts" 86400 "indexer" >/dev/null || { warn "$_ts: mount failed"; return 1; }
	why "held only while this one snapshot is walked, and exempt from the sweep meanwhile"

	_base=$(mnt_volume_path "$_h" "$_ts" "$_vol")
	_dir=$(index_dir)
	need_dir "$_dir" || { snap_umount "$_mp"; return 1; }
	_n=0
	while [ -f "$_dir/$_h.inc.$(printf '%02d' "$_n").db" ]; do _n=$(( _n + 1 )); done
	_inc="$_dir/$_h.inc.$(printf '%02d' "$_n").db"

	_paths=$(mktemp /tmp/my-tm.idx.XXXXXX) || { snap_umount "$_mp"; return 1; }
	## One walk, stats included: path + size + mtime for every entry, batched
	## through xargs so it is one stat exec per batch and not one per file. The
	## stats are what makes "which versions of this file do I have" answerable
	## later without mounting anything.
	run_echo find "$_base" -print0 \| xargs -0 stat -f '%N%t%z%t%m'
	_stats=$(mktemp /tmp/my-tm.stat.XXXXXX) || { snap_umount "$_mp"; return 1; }
	## the same locale discipline for the walk itself
	find "$_base" -print0 2>/dev/null |
		xargs -0 stat -f '%N%t%z%t%m' 2>/dev/null |
		LC_ALL=C sed "s|^$_base||" |
		LC_ALL=C awk -F'\t' 'length($1) > 0' |
		LC_ALL=C sort >"$_stats"
	cut -f1 "$_stats" >"$_paths"
	_count=$(count_lines < "$_paths")
	if [ "$_count" -gt 0 ]; then
		if _mk=$(locate_tool locate.mklocatedb); then
			if ! "$_mk" <"$_paths" >"$_inc" 2>/dev/null || [ ! -s "$_inc" ]; then
				warn "$_ts: building the name index failed -- nothing was written"
				rm -f "$_inc"
			fi
		else
			warn "locate.mklocatedb not found (looked on PATH and in /usr/libexec) -- the name index cannot be built"
			rm -f "$_paths"
			snap_umount "$_mp" >/dev/null 2>&1
			return 1
		fi
	fi

	## No exclusive size here: macOS does not expose one for an APFS Time
	## Machine snapshot (tmutil uniquesize refuses with pathInAPFSBackup, and
	## diskutil reports no per-snapshot space), so asking cost a second full
	## walk of the disk to fail every time.
	vs_record_snapshot "$_h" "$_ts" "$_stats"
	index_mark_covered "$_h" "$_ts"
	msg "$(human_count "$_count") paths indexed"
	rm -f "$_stats"
	rm -f "$_paths"
	snap_umount "$_mp" >/dev/null 2>&1
	return 0
}

## fold the increments into one database when there are too many of them
index_consolidate() {
	_h="$1"
	_dir=$(index_dir)
	_incs=0
	for _f in "$_dir/$_h".inc.*.db; do
		[ -f "$_f" ] && _incs=$(( _incs + 1 ))
	done
	[ "$_incs" -ge "$INDEX_INC_MAX" ] || { dbg "index: $_incs increments, no consolidation yet"; return 0; }
	msg "consolidating $_incs index increments for '$_h'"
	why "one sort -u now, in a run that already took a while, instead of at an arbitrary later moment"
	_mk=$(locate_tool locate.mklocatedb) || {
		warn "locate.mklocatedb not found -- leaving the increments as they are"
		return 1
	}
	_all=$(mktemp /tmp/my-tm.cons.XXXXXX) || return 1
	for _f in "$_dir/$_h.db" "$_dir/$_h".inc.*.db; do
		[ -f "$_f" ] || continue
		locate -d "$_f" '*' 2>/dev/null >>"$_all"
	done
	LC_ALL=C sort -u "$_all" | "$_mk" >"$_dir/$_h.db.new" 2>/dev/null &&
		mv -f "$_dir/$_h.db.new" "$_dir/$_h.db" &&
		rm -f "$_dir/$_h".inc.*.db
	rm -f "$_all" "$_dir/$_h.db.new"
	return 0
}

index_consolidate_all() {
	for _h in $1; do index_consolidate "$_h"; done
	return 0
}

index_remote() {
	_h="$1"
	_idir=$(loc_install_dir "$_h")
	if [ -z "$_idir" ] && [ "$INDEX_REMOTE_COPY" != "1" ]; then
		err "$_h: nowhere to keep the index -- give it a remote install dir in locations.tsv, or set INDEX_REMOTE_COPY=1"
	fi
	_t=$(loc_target "$_h")
	msg "indexing '$_h' on $(remote_host "$_t") (the walk stays where the disk is)"
	run ssh "$(remote_host "$_t")" "$(remote_install_cmd "$_h") --index $(remote_path "$_t")" || return 1
	if [ "$INDEX_REMOTE_COPY" = "1" ]; then
		_dir=$(index_dir); need_dir "$_dir"
		run scp "$(remote_host "$_t"):$CACHE_DIR/index/*.db" "$_dir/" 2>/dev/null ||
			dbg "no remote index database to copy back yet"
	fi
	return 0
}

## how to invoke my-tm on a remote host: the installed copy, or a shipped one
remote_install_cmd() {
	_idir=$(loc_install_dir "$1")
	if [ -n "$_idir" ]; then printf '%s/my-tm\n' "$_idir"; else printf 'my-tm\n'; fi
}

remote_snap_names() {
	_t=$(loc_target "$1")
	## the command line is deliberately built HERE and sent as one string: the
	## remote copy of my-tm answers in JSON, so nothing has to be re-parsed.
	# shellcheck disable=SC2029  # local expansion is the point
	ssh "$(remote_host "$_t")" "$(remote_install_cmd "$1") -J --ls $(remote_path "$_t")" 2>/dev/null |
		sed -nE 's/.*"snapshot": *"([0-9-]+)".*/\1/p' | sort
	return 0
}

#############################################################################
## --verify
#############################################################################

cmd_verify() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	shift
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	transient_snapshot "$_loc" "$_ts" >/dev/null || err "could not mount"
	_base=$(mnt_volume_path "$_loc" "$_ts" "$_vol")
	## tmutil verifychecksums says NOTHING when everything is fine, which is
	## indistinguishable from "the check never ran". Report the outcome.
	_probs=0; _checked=0
	if [ "$#" -eq 0 ]; then
		note "verifying the whole snapshot is slow; a directory or one file is quick"
		set -- "$_base"
		_whole=1
	else
		_whole=0
	fi
	for _p in "$@"; do
		if [ "$_whole" = "1" ]; then _t="$_p"; else
			_t="$_base$(path_in_volume "$(abs_path "$_p")")"
		fi
		if [ ! -e "$_t" ]; then
			warn "not in that snapshot: $_p"
			continue
		fi
		_checked=$(( _checked + 1 ))
		run_echo tmutil verifychecksums "$_t"
		_out=$(tmutil verifychecksums "$_t" 2>&1)
		if [ -n "$_out" ]; then
			printf '%s\n' "$_out"
			_n=$(printf '%s\n' "$_out" | count_lines)
			_probs=$(( _probs + _n ))
		fi
	done
	if [ "$_checked" -eq 0 ]; then
		note "nothing was checked"
	elif [ "$_probs" -eq 0 ]; then
		note "$_checked path(s) verified against the checksums stored at backup time: no problems"
	else
		note "$_probs problem(s) reported -- ! is a mismatch, ? an unusable stored checksum"
	fi
	[ "$_probs" -eq 0 ]
}

#############################################################################
## --local-snapshot
#############################################################################

cmd_local_snap() {
	run tmutil localsnapshot || err "could not take a local snapshot"
	why "an APFS snapshot: metadata only, and PURGEABLE -- macOS deletes it under pressure"
	return 0
}

local_snap_trim() {
	_names=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null |
		sed -nE 's/^com\.apple\.TimeMachine\.([0-9-]+)\.local$/\1/p' | sort)
	[ -n "$_names" ] || return 0
	_n=$(printf '%s\n' "$_names" | count_lines)
	_now=$(now_epoch)
	_cut=$(( _now - LOCAL_SNAP_KEEP_H * 3600 ))
	_drop=""
	while IFS= read -r _ts; do
		[ -n "$_ts" ] || continue
		_e=$(ts_to_epoch "$_ts")
		[ -n "$_e" ] || continue
		[ "$_e" -lt "$_cut" ] && _drop="$_drop $_ts"
	done <<_EOF
$_names
_EOF
	_over=$(( _n - LOCAL_SNAP_MAX ))
	if [ "$_over" -gt 0 ]; then
		_extra=$(printf '%s\n' "$_names" | head -n "$_over")
		_drop="$_drop $_extra"
	fi
	for _ts in $_drop; do
		msg "thinning local snapshot $_ts (oldest first, mine and macOS's alike)"
		run tmutil deletelocalsnapshots "$_ts" >/dev/null 2>&1
	done
	return 0
}

#############################################################################
## --health
#############################################################################

HEALTH_RC=0
health_say() {
	_lvl="$1"; shift
	case "$_lvl" in
		fail) printf ' !!! %s\n' "$*"; [ "$HEALTH_RC" -lt 2 ] && HEALTH_RC=2 ;;
		warn) printf '  >> %s\n' "$*"; [ "$HEALTH_RC" -lt 1 ] && HEALTH_RC=1 ;;
		hint) printf '  >> %s\n' "$*" ;;
		*)    printf '    > %s\n' "$*" ;;
	esac
	return 0
}

cmd_health() {
	BACKGROUND_JOB=1
	_only="${1:-}"
	if [ -n "$_only" ]; then
		_locs="$_only"
	else
		case "$HEALTH_LOCATIONS" in
			ALL) _locs=$(locations_all | awk -F'\t' '{print $1}') ;;
			ON-THIS-DISK) _locs="local" ;;
			LOCAL|"") _locs=$(locations_all | awk -F'\t' '{print $1}') ;;
			*) _locs=$(printf '%s\n' "$HEALTH_LOCATIONS" | tr ' ' '\n') ;;
		esac
	fi
	_now=$(now_epoch)

	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_line "$_h" >/dev/null 2>&1 || continue
		## A destination my-tm itself put to sleep is not "not reachable" --
		## it is exactly where it was left. Answer from the cache instead of
		## spinning it up, and say so, because a cached age is a fact about
		## the last time anyone looked.
		_asleep=0
		if ! loc_reachable "$_h"; then
			if loc_is_quiet "$_h"; then
				_asleep=1
				dbg "$_h is quiet and asleep -- answering from the cache"
			else
				health_say fail "$_h: destination not reachable"
				continue
			fi
		fi
		_t=$(loc_target "$_h")
		if [ "$_asleep" = "1" ]; then
			_rows=$(snapshots_cached_only "$_h")
		else
			_rows=$(snapshots_get "$_h")
		fi
		if [ -z "$_rows" ]; then
			health_say fail "$_h: no snapshots found"
			continue
		fi
		_from=""
		[ "$_asleep" = "1" ] && _from=" [cached; disk asleep]"
		_lastep=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | tail -n 1 | awk -F'\t' '{print $3}')
		_agh=$(( (_now - _lastep) / 3600 ))
		## the age this location's newest backup should stay under; 0 = none. A
		## number without a unit is refused: parse_interval would read 48 as seconds
		_hma=$(loc_param "$_h" HEALTH_MAX_AGE)
		_hmas=""
		case "$_hma" in *[smhd]) _hmas=$(parse_interval "$_hma") || _hmas="" ;; esac
		if [ "$_hma" = "0" ]; then
			health_say ok "$_h: newest backup ${_agh}h old$_from [no age expected: HEALTH_MAX_AGE=0]"
		elif [ -z "$_hmas" ]; then
			health_say warn "$_h: HEALTH_MAX_AGE is '$_hma' -- give it a unit (48h, 2d), or 0 for no age expected"
		elif [ $(( _now - _lastep )) -gt "$_hmas" ]; then
			health_say fail "$_h: newest backup is ${_agh}h old (limit $_hma)$_from -- Time Machine fails silently, this is the one to watch"
		else
			health_say ok "$_h: newest backup ${_agh}h old$_from"
		fi

		if [ "$_t" != "local" ] && [ -d "$_t" ]; then
			_free=$(vol_free_pct "$_t")
			if [ -n "$_free" ] && [ "$_free" -lt "$HEALTH_MIN_FREE_PCT" ]; then
				health_say fail "$_h: ${_free}% free (limit ${HEALTH_MIN_FREE_PCT}%)"
			else
				health_say ok "$_h: ${_free}% free"
			fi
		fi

		_bad=$(printf '%s\n' "$_rows" | awk -F'\t' '$10 == "inprogress" || $10 == "interrupted"' | count_lines)
		[ "$_bad" -gt "$HEALTH_MAX_INTERRUPTED" ] &&
			health_say fail "$_h: $_bad interrupted/in-progress leftovers (limit $HEALTH_MAX_INTERRUPTED)"

		_avg=$(added_median "$_rows")
		if [ "$_avg" -gt 0 ]; then
			_spike=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3nr | head -n 1 |
				awk -F'\t' -v m="$_avg" -v f="$HEALTH_DRIFT_FACTOR" \
					'$7 != "-" && $7 >= m * f {printf "%.1f\n", $7 / m}')
			[ -n "$_spike" ] &&
				health_say warn "$_h: last backup wrote ${_spike}x the average -- something big got swept in ($US --setup to exclude it)"
		fi
	done <<_EOF
$_locs
_EOF

	## local snapshots present at all?
	_lsn=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null | count_match 'com.apple')
	[ "$_lsn" -eq 0 ] &&
		health_say warn "no local APFS snapshots -- the only history that works with no backup disk attached"

	## paths that MUST be backed up
	if [ -n "$HEALTH_WATCH_PATHS" ]; then
		while IFS= read -r _p; do
			[ -n "$_p" ] || continue
			[ -e "$_p" ] || { health_say warn "watched path does not exist: $_p"; continue; }
			if tmutil isexcluded "$_p" 2>/dev/null | grep -q '\[Excluded\]'; then
				health_say fail "watched path is EXCLUDED from backup: $_p"
			else
				health_say ok "watched path is covered: $_p"
			fi
		done <<_EOF
$HEALTH_WATCH_PATHS
_EOF
	fi

	## a mount that outlived its TTL and could not be released
	_stale=$(mounts_read_all | awk -F'\t' -v now="$_now" '$4 + $5 < now' | count_lines)
	[ "$_stale" -gt 0 ] &&
		health_say warn "$_stale mount(s) past their TTL -- a mounted snapshot blocks thinning ($US --umount --all)"

	## checksums, only for the paths the user named
	if [ -n "$HEALTH_VERIFY" ]; then
		_newest=$(snapshots_all | sort -t"$(printf '\t')" -k3,3nr | head -n 1)
		if [ -n "$_newest" ]; then
			_l=$(printf '%s' "$_newest" | awk -F'\t' '{print $1}')
			_ts=$(printf '%s' "$_newest" | awk -F'\t' '{print $2}')
			_vol=$(printf '%s' "$_newest" | awk -F'\t' '{print $11}')
			[ "${_vol:--}" = "-" ] && _vol="Data"
			transient_snapshot "$_l" "$_ts" >/dev/null && {
				_base=$(mnt_volume_path "$_l" "$_ts" "$_vol")
				while IFS= read -r _p; do
					[ -n "$_p" ] || continue
					if tmutil verifychecksums "$_base$(path_in_volume "$_p")" >/dev/null 2>&1; then
						health_say ok "checksums verified: $_p"
					else
						health_say fail "checksum problem under $_p"
					fi
				done <<_EOF
$HEALTH_VERIFY
_EOF
				cleanup_transient
			}
		fi
	fi

	## Full Disk Access -- one pointer, not a stack of errors from each command
	## that would have needed it
	if ! has_full_disk_access; then
		if [ "${JOBS_RUN_WITH_FULL_DISK_ACCESS:-0}" = "1" ]; then
			health_say warn "no Full Disk Access: --rm, --verify and Time Machine's own listings will fail. Grant it in System Settings > Privacy & Security > Full Disk Access -- to your terminal, or for the jobs to $JOBS_LAUNCHER"
		else
			health_say warn "no Full Disk Access: --rm, --verify and Time Machine's own listings will fail. Grant it in System Settings > Privacy & Security > Full Disk Access, to the program that runs my-tm (your terminal, or the job binary)"
		fi
	else
		health_say ok "Full Disk Access is granted"
	fi

	## the job access setting -- a line only where it changed what the jobs
	## could do today
	for _gh in $(locations_all | awk -F'\t' '{print $1}'); do
		( jobs_blind_on "$_gh" ) &&
			health_say hint "$_gh is on a network volume, but the jobs lack Full Disk Access to see inside -- JOBS_RUN_WITH_FULL_DISK_ACCESS=1"
	done
	if [ -n "$HEALTH_VERIFY" ] && [ "${JOBS_RUN_WITH_FULL_DISK_ACCESS:-0}" != "1" ] && ! has_full_disk_access; then
		health_say hint "HEALTH_VERIFY needs Full Disk Access in the jobs -- JOBS_RUN_WITH_FULL_DISK_ACCESS=1"
	fi
	_lufh=$(locations_user_file) && health_say warn "$_lufh is no longer read -- locations are shared now ($US --status lists what to add again as root)"

	## my-tm's own tree, which --install excludes
	if ! tmutil isexcluded "$CACHE_DIR" 2>/dev/null | grep -q '\[Excluded\]'; then
		health_say warn "$CACHE_DIR is NOT excluded from Time Machine -- it holds mounted snapshots and caches my-tm rebuilds: tmutil addexclusion -p $CACHE_DIR"
	fi

	## the jobs we installed
	for _j in "$MAINT_JOB" "$HEALTH_JOB" "$BACKUP_JOB"; do
		_pl="/Library/LaunchDaemons/$_j.plist"
		[ -f "$_pl" ] || continue
		_prog=$(plutil -extract ProgramArguments.0 raw -o - "$_pl" 2>/dev/null)
		[ -n "$_prog" ] && [ ! -x "$_prog" ] &&
			health_say fail "job $_j points at a path that is not executable: $_prog"
	done

	case "$HEALTH_RC" in
		0) note "all checks passed" ;;
		1) note "warnings above" ;;
		*) note "FAILURES above" ;;
	esac
	return "$HEALTH_RC"
}

#############################################################################
## --rm   (snapshots; forgetting a location is --forget)
#############################################################################

cmd_rm() {
	_go=0; _ids=""
	for _a in "$@"; do
		case "$_a" in
			go) _go=1 ;;
			*)  _ids="$_ids $_a" ;;
		esac
	done
	[ -n "$_ids" ] || err "--rm needs one or more <ID> and the literal word go"

	_plan=$(mktemp /tmp/my-tm.rm.XXXXXX) || return 1
	for _w in $_ids; do
		_hit=$(resolve_id "$_w") || { warn "$_w: no such snapshot"; continue; }
		[ -n "$_hit" ] || { warn "$_w: no such snapshot"; continue; }
		_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
		_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
		_id=$(printf '%s' "$_hit" | awk -F'\t' '{print $3}')
		## The cache is an index, never the authority for a destructive call, so
		## the store itself is asked. But "I cannot see the store" is NOT "the
		## snapshot is gone": saying so about a detached disk would report a
		## deletion that never happened.
		if ! loc_reachable "$_loc"; then
			warn "$_id: cannot verify against '$_loc' -- it is not attached, so nothing here can be deleted. Attach it and run this again."
			continue
		fi
		if ! snap_names "$_loc" | grep -qx "$_ts"; then
			note "$_id ($(ts_display "$_ts")): already deleted"
			continue
		fi
		_u=$(unique_cache_dump "$_loc" | awk -F'\t' -v t="$_ts" '$1 == t {print $2; exit}')
		printf '%s\t%s\t%s\t%s\n' "$_loc" "$_ts" "$_id" "${_u:--}" >>"$_plan"
	done

	if [ ! -s "$_plan" ]; then
		rm -f "$_plan"
		return 0
	fi
	printf ' %-8s %-20s %-10s %s\n' ID SNAPSHOT LOCATION FREES
	_sum=0
	while IFS="$(printf '\t')" read -r _loc _ts _id _u; do
		printf ' %-8s %-20s %-10s %s\n' "$_id" "$(ts_display "$_ts")" "$_loc" \
			"$(size_or_q "${_u:--}")"
		case "${_u:--}" in [0-9]*) _sum=$(( _sum + _u )) ;; esac
	done <"$_plan"
	note "frees about $(human_bytes "$_sum") · there is NO trash for this: an APFS snapshot's blocks go immediately"

	if [ "$_go" != "1" ]; then
		## show the exact command line, so a dry run is reviewable as such
		while IFS="$(printf '\t')" read -r _loc _ts _id _u; do
			if [ "$(loc_target "$_loc")" = "local" ]; then
				minor "would run: tmutil deletelocalsnapshots $_ts"
			else
				minor "would run: tmutil delete -d $(loc_target "$_loc") -t $_ts"
			fi
		done <"$_plan"
		note "dry run. Add the literal word 'go' to do it."
		rm -f "$_plan"
		return 0
	fi

	## root is needed for any backup-store snapshot; check once, before anything
	if awk -F'\t' '{print $1}' "$_plan" | while IFS= read -r _l; do
		[ "$(loc_target "$_l")" = "local" ] || { printf 'need\n'; break; }
	done | grep -q need; then
		require_root "deleting a backup snapshot"
	fi

	_rm_locs=""
	while IFS="$(printf '\t')" read -r _loc _ts _id _u; do
		_rm_locs="$_rm_locs $_loc"
		if [ "$(loc_target "$_loc")" = "local" ]; then
			run tmutil deletelocalsnapshots "$_ts" || warn "$_id: delete failed"
		else
			run tmutil delete -d "$(loc_store_path "$_loc")" -t "$_ts" || warn "$_id: delete failed"
		fi
	done <"$_plan"
	rm -f "$_plan"
	## drop the table of each store deleted from, and nothing else: the cache
	## also holds the last known table of every disk that is away
	for _rm_h in $(printf '%s' "$_rm_locs" | tr ' ' '\n' | sort -u); do
		snapshots_cache_drop "$_rm_h"
	done
	return 0
}

snapshots_cache_invalidate() {
	_cf=$(snapshots_cache_file)
	[ -f "$_cf" ] && rm -f "$_cf"
	return 0
}

## Forget ONE location's rows. Every other location keeps its last known
## table -- for a disk that is away, the only one there is until it is back.
snapshots_cache_drop() {
	_scd_cf=$(snapshots_cache_file)
	[ -f "$_scd_cf" ] || return 0
	## read it all before writing: the writer replaces the very file being read,
	## and a cache that cannot be read is left alone rather than emptied
	_scd_all=$(cache_read_checked "$_scd_cf" 2>/dev/null) || return 0
	_scd_keep=$(printf '%s\n' "$_scd_all" | awk -F'\t' -v l="$1" 'NF && $1 != l')
	{ [ -z "$_scd_keep" ] || printf '%s\n' "$_scd_keep"; } |
		cache_write_checked "$_scd_cf" 2>/dev/null || dbg "snapshots cache not writable: $_scd_cf"
	return 0
}

#############################################################################
## --thin   (selection only; the deleting is --rm's job)
#############################################################################

## policy -> keep/del decision per snapshot.
## Spans are counted backwards from now and are cumulative: "24h:hourly 7d:daily"
## means hourly inside the last 24h, then daily out to 7 days.  Anything older
## than the last span is KEPT unless the policy ends in a `*:` rule.
thin_select() {
	_policy="$1"; _now="$2"
	awk -F'\t' -v policy="$_policy" -v now="$_now" '
		function bucket(gran, ts, ep) {
			if (gran == "hourly")    return substr(ts, 1, 13);
			if (gran == "daily")     return substr(ts, 1, 10);
			if (gran == "weekly")    return int(ep / 604800);
			if (gran == "monthly")   return substr(ts, 1, 7);
			if (gran == "quarterly") return substr(ts, 1, 4) "Q" int((substr(ts, 6, 2) - 1) / 3);
			if (gran == "yearly")    return substr(ts, 1, 4);
			if (gran == "all")       return ts;          # every one is its own bucket
			return "";                                    # none: no bucket, nothing kept
		}
		function span_seconds(s,   n, u) {
			if (s == "*") return -1;
			u = substr(s, length(s), 1); n = substr(s, 1, length(s) - 1) + 0;
			if (u == "h") return n * 3600;
			if (u == "d") return n * 86400;
			if (u == "w") return n * 604800;
			if (u == "m") return n * 2629746;
			if (u == "y") return n * 31556952;
			return 0;
		}
		BEGIN {
			np = split(policy, parts, " ");
			for (i = 1; i <= np; i++) {
				if (parts[i] == "") continue;
				split(parts[i], kv, ":");
				nrule++;
				rspan[nrule] = span_seconds(kv[1]);
				rgran[nrule] = kv[2];
			}
		}
		{
			ts[NR] = $1; ep[NR] = $2; n = NR;
		}
		END {
			# newest first, so the first snapshot in a bucket is the one kept
			for (i = n; i >= 1; i--) {
				age = now - ep[i];
				rule = 0; lower = 0;
				for (r = 1; r <= nrule; r++) {
					if (rspan[r] == -1) { rule = r; break }        # `*`: everything older
					if (age <= rspan[r]) { rule = r; break }
					lower = rspan[r];
				}
				if (rule == 0) { print "keep\t" ts[i]; continue }  # outside every span
				g = rgran[rule];
				if (g == "none") { print "del\t" ts[i]; continue }
				b = rule "|" bucket(g, ts[i], ep[i]);
				if (b in taken) print "del\t" ts[i];
				else { taken[b] = 1; print "keep\t" ts[i] }
			}
		}
	'
}

cmd_thin() {
	_go=0; _loc=""; _policy=""
	for _a in "$@"; do
		case "$_a" in
			go) _go=1 ;;
			*:*) _policy="$_policy $_a" ;;
			*) [ -z "$_loc" ] && _loc="$_a" ;;
		esac
	done
	_policy=$(printf '%s' "$_policy" | sed 's/^ //')

	if [ -n "$_loc" ]; then _locs="$_loc"; else
		_locs=$(locations_all | awk -F'\t' '{print $1}')
	fi
	_now=$(now_epoch)

	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		## kept apart: the functions called below set _h themselves
		_thin_h="$_h"
		loc_ready "$_h" || continue
		## the CLI beats the location's THIN_POLICY_TO_KEEP (its _DEFAULT unless
		## set_location_parameters says otherwise)
		_p="$_policy"
		[ -n "$_p" ] || _p=$(loc_param "$_h" THIN_POLICY_TO_KEEP)
		[ -n "$_p" ] || continue

		_rows=$(snapshots_get "$_h" | sort -t"$(printf '\t')" -k3,3n | awk -F'\t' '{print $2"\t"$3}')
		[ -n "$_rows" ] || continue
		_dec=$(printf '%s\n' "$_rows" | thin_select "$_p" "$_now")
		_ndel=$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "del"' | count_lines)
		_nkeep=$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "keep"' | count_lines)

		printf '\n%s  policy: %s\n' "$_h" "$_p"
		printf ' %-8s %-20s %s\n' ID SNAPSHOT ACTION
		printf '%s\n' "$_dec" | while IFS="$(printf '\t')" read -r _act _ts; do
			[ "$_act" = "del" ] || continue
			_id=$(snapshots_get "$_h" | awk -F'\t' -v t="$_ts" '$2 == t {print $4; exit}')
			printf ' %-8s %-20s %s\n' "$_id" "$(ts_display "$_ts")" "DELETE"
		done
		note "$_nkeep kept, $_ndel to delete"

		if [ "$_go" != "1" ]; then
			note "dry run. Add the literal word 'go' to do it."
			continue
		fi
		printf '%s\n' "$_dec" | awk -F'\t' '$1 == "del" {print $2}' |
		while IFS= read -r _ts; do
			[ -n "$_ts" ] || continue
			if [ "$(loc_target "$_h")" = "local" ]; then
				run tmutil deletelocalsnapshots "$_ts" || warn "$_ts: delete failed"
			else
				run tmutil delete -d "$(loc_store_path "$_h")" -t "$_ts" || warn "$_ts: delete failed"
			fi
		done
		snapshots_cache_drop "$_thin_h"
	done <<_EOF
$_locs
_EOF
	return 0
}

#############################################################################
## --backup   (what my-tm.sh used to do)
#############################################################################

backup_cleanup() {
	_rc=$?
	[ -n "${BACKUP_LOCK_HELD:-}" ] && rm -f "$LOCKFILE"
	cleanup_transient
	exit $_rc
}

## The backup destination, resolved ONCE and then reused.  BACKUP_VOLUME
## names it outright; empty means ASK TMUTIL -- because `tmutil startbackup`
## writes to that destination whatever my-tm thinks, and a tool that backs up
## to a disk it refuses to name cannot mount it, eject it, or leave it alone
## on purpose.  Every consumer below calls this, none calls tmutil itself.
backup_volume() {
	if [ -n "${BACKUP_VOLUME_RESOLVED+x}" ]; then
		printf '%s\n' "$BACKUP_VOLUME_RESOLVED"
		return 0
	fi
	if [ -n "$BACKUP_VOLUME" ]; then
		BACKUP_VOLUME_RESOLVED="$BACKUP_VOLUME"
	else
		_bv_out=$(tmutil destinationinfo 2>/dev/null)
		## "Mount Point" is printed only while the destination is MOUNTED. A disk
		## my-tm ejected after the last backup has none, and resolving to nothing
		## silently skipped both the pre-backup mount and POST_BACKUP -- seen on
		## horse. Fall back to the destination's Name, which is always printed.
		_bv_mp=$(printf '%s\n' "$_bv_out" |
			sed -nE 's/^[[:space:]]*Mount Point[[:space:]]*:[[:space:]]*(.*)$/\1/p')
		[ -n "$_bv_mp" ] || _bv_mp=$(printf '%s\n' "$_bv_out" |
			sed -nE 's/^[[:space:]]*Name[[:space:]]*:[[:space:]]*(.*)$/\1/p')
		_bv_n=$(printf '%s\n' "$_bv_mp" | count_lines)
		case "$_bv_n" in
			0) BACKUP_VOLUME_RESOLVED="" ;;
			1) BACKUP_VOLUME_RESOLVED=$(printf '%s\n' "$_bv_mp" | sed -n '1p')
			   BACKUP_VOLUME_RESOLVED="${BACKUP_VOLUME_RESOLVED##*/}" ;;
			*) err "tmutil reports $_bv_n destinations -- name the one to act on with BACKUP_VOLUME in the config; guessing is worse than asking" ;;
		esac
	fi
	printf '%s\n' "$BACKUP_VOLUME_RESOLVED"
	return 0
}

## Time Machine's own record of the last attempt on a destination. 0 is a
## success; anything else is a failure. tmutil's exit code is NOT that answer:
## on horse `tmutil startbackup --block` exited 0 while Time Machine recorded
## 704 and wrote no snapshot at all.
TM_PREFS_PLIST="/Library/Preferences/com.apple.TimeMachine.plist"
## where mounted volumes appear; overridden by the tests only
VOLUMES_DIR="/Volumes"

tm_result_for() {
	_tr_id="${1:-}"
	[ -n "$_tr_id" ] || return 1
	[ -f "$TM_PREFS_PLIST" ] || return 1
	_tr_n=0
	while [ "$_tr_n" -lt 32 ]; do
		_tr_d=$(plutil -extract "Destinations.$_tr_n.DestinationID" raw -o - "$TM_PREFS_PLIST" 2>/dev/null) || return 1
		if [ "$_tr_d" = "$_tr_id" ]; then
			## no RESULT yet (a destination never backed up to) counts as 0
			plutil -extract "Destinations.$_tr_n.RESULT" raw -o - "$TM_PREFS_PLIST" 2>/dev/null ||
				printf '0\n'
			return 0
		fi
		_tr_n=$(( _tr_n + 1 ))
	done
	return 1
}

## the destination id tmutil knows a volume by -- matched on the volume NAME or
## on the last component of its mount point, since "Mount Point" is printed
## only while it is mounted
backup_destination_id() {
	tmutil destinationinfo 2>/dev/null | awk -v v="${1:-}" '
		/^Name/ { sub(/^[^:]*: */, ""); name = $0 }
		/^Mount Point/ { sub(/^[^:]*: */, ""); mp = $0 }
		/^ID/ { sub(/^[^:]*: */, ""); id = $0
			n = mp; sub(/.*\//, "", n)
			if (!f && (name == v || n == v)) { print id; f = 1 }
			name = ""; mp = ""; id = "" }
		END { exit(f ? 0 : 1) }'
}

## What happens to the disk when a backup finishes, for one location: its
## POST_BACKUP (set_location_parameters), else POST_BACKUP_DEFAULT. An unknown
## value is a config error, not a silent fallback.
post_backup_policy() {
	_pb_v=$(loc_param "${1:-}" POST_BACKUP)
	case "$_pb_v" in
		none|unmount|eject) printf '%s\n' "$_pb_v" ;;
		*) err "POST_BACKUP${1:+ for $1} is '$_pb_v' -- it must be none, unmount or eject" ;;
	esac
	return 0
}

## A location my-tm puts back to sleep is QUIET: a background job must not
## wake it just to look.  One rule, no allowlist -- interactive commands are
## unaffected, because someone asked.
loc_is_quiet() {
	_lq_t=$(loc_target "${1:-}" 2>/dev/null) || return 1
	case "$_lq_t" in local) return 1 ;; esac
	is_remote_target "$_lq_t" && return 1
	_lq_v=$(backup_volume)
	[ -n "$_lq_v" ] || return 1
	[ "$(basename "$_lq_t")" = "$_lq_v" ] || return 1
	[ "$(post_backup_policy "$1")" = "none" ] && return 1
	return 0
}

## Give the disk back to the hardware.  `eject` parks it at once and is the
## quietest; `unmount` leaves the device on the bus and lets the enclosure
## spin it down on its own timer, which is what an enclosure that does not
## survive an eject needs.  Retries are shared: both can lose to a straggler
## holding the volume open.
## An interrupted run leaves .inprogress / .interrupted directories behind, and
## Time Machine's structure check then refuses the whole store ("Expected
## SnapshotInProgressContainer metadata type ..."). Naming them turns an opaque
## RESULT into something actionable.
backup_leftovers_hint() {
	_bl_v="${1:-}"
	## the directory volumes appear under; a variable so the tests can look
	## somewhere they are allowed to create one
	_bl_d="${VOLUMES_DIR:-/Volumes}/$_bl_v"
	[ -n "$_bl_v" ] && [ -d "$_bl_d" ] || return 0
	_bl_n=$(find "$_bl_d" -maxdepth 1 \( -name '*.inprogress' -o -name '*.interrupted' \) 2>/dev/null | count_lines)
	[ "$_bl_n" -gt 0 ] || return 0
	note "$_bl_n interrupted leftover(s) on $_bl_v -- Time Machine refuses the store until they are gone ($US --health lists them)"
	return 0
}

do_post_backup() {
	_pv=$(backup_volume)
	[ -n "$_pv" ] || {
		## silence here once hid a POST_BACKUP that never ran
		warn "no backup destination to act on -- POST_BACKUP did nothing; name one with BACKUP_VOLUME in the config"
		return 0
	}
	## the location this volume IS, so its own POST_BACKUP applies: the same
	## match loc_is_quiet makes (the target's last component is the volume)
	_pv_h="${1:-}"
	[ -n "$_pv_h" ] || _pv_h=$(locations_all | awk -F'\t' -v v="$_pv" '
		$2 == "local" || $2 ~ /:/ { next }
		{ n = $2; sub(/.*\//, "", n) } n == v && !f { print $1; f = 1 }')
	_pol=$(post_backup_policy "$_pv_h")
	if [ -f "$NO_EJECT_FLAGFILE" ]; then
		msg "leaving $_pv mounted [policy $_pol suppressed by $NO_EJECT_FLAGFILE]"
		why "--eject removes that file and the policy applies again"
		return 0
	fi
	case "$_pol" in
		none)
			msg "leaving $_pv mounted [POST_BACKUP=none]"
			return 0 ;;
		unmount) set -- diskutil unmountDisk "/Volumes/$_pv" ;;
		eject)   set -- diskutil eject "/Volumes/$_pv" ;;
	esac
	_i=1
	while [ "$_i" -le "$EJECT_RETRIES" ]; do
		sync
		if run "$@" >/dev/null 2>&1; then
			msg "$_pol done on $_pv (attempt $_i)"
			[ "$_pol" = "eject" ] &&
				why "the drive parks now; the next backup brings it back"
			[ "$_pol" = "unmount" ] &&
				why "the device stays on the bus; the enclosure spins it down on its own timer"
			return 0
		fi
		dbg "$_pol attempt $_i/$EJECT_RETRIES failed; waiting ${EJECT_WAIT}s"
		sleep "$EJECT_WAIT"
		_i=$(( _i + 1 ))
	done
	warn "could not $_pol $_pv after $EJECT_RETRIES attempts"
	return 1
}

cmd_backup() {
	_action="${1:-}"
	shift 2>/dev/null || true
	for _a in "$@"; do
		case "$_a" in
			## --set-* are the old spellings, kept working.  The flag is named
			## for what it does; that it PERSISTS is said in the output.
			--no-eject|--set-no-eject)
				run touch "$NO_EJECT_FLAGFILE" || err "cannot create $NO_EJECT_FLAGFILE"
				msg "the disk is left mounted after every backup from now on"
				why "including the unattended $BACKUP_JOB run -- until --eject clears it" ;;
			--eject|--set-eject)
				run rm -f "$NO_EJECT_FLAGFILE"
				msg "POST_BACKUP applies again after every backup"
				why "the disk is put back the way POST_BACKUP says, from now on" ;;
		esac
	done
	case "$_action" in
		start|stop) : ;;
		"") return 0 ;;
		*) err "--backup takes start or stop" ;;
	esac
	require_root "--backup"

	if [ -e "$LOCKFILE" ]; then
		err "$LOCKFILE exists -- another run is in progress." 2
	fi
	need_dir "$(dirname "$LOCKFILE")"
	touch "$LOCKFILE" || err "cannot create $LOCKFILE"
	BACKUP_LOCK_HELD=1
	trap 'backup_cleanup' EXIT INT TERM HUP

	if [ "$_action" = "stop" ]; then
		run tmutil stopbackup
		do_post_backup
		return 0
	fi

	_bv=$(backup_volume)
	if [ -n "$_bv" ] && [ ! -d "/Volumes/$_bv" ]; then
		run diskutil mount "$_bv" || err "could not mount $_bv"
	fi
	[ "$NOTIFY_BEGIN" = "1" ] && notify "Time Machine backup starting"
	run tmutil startbackup --block
	## its own name: the cache writers below set _rc
	_bk_rc=$?
	## tmutil's exit code alone is not the truth: ask Time Machine what it
	## recorded for this destination, and print both next to the conclusion
	_bk_res=""
	_bk_did=$(backup_destination_id "$_bv") && _bk_res=$(tm_result_for "$_bk_did")
	_bk_raw="rc $_bk_rc, Time Machine RESULT ${_bk_res:-?}"
	case "$_bk_rc" in
		0) if [ -n "$_bk_res" ] && [ "$_bk_res" != "0" ]; then
			   warn "Time Machine recorded a FAILURE for ${_bv:-the destination} [$_bk_raw] -- nothing was written"
			   backup_leftovers_hint "$_bv"
			   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup FAILED (RESULT $_bk_res)"
			   _bk_rc=1
		   else
			   msg "backup finished [$_bk_raw]"
			   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup finished"
		   fi ;;
		3) msg "a backup was already running [$_bk_raw]"
		   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup already in progress" ;;
		*) warn "backup FAILED [$_bk_raw]"
		   backup_leftovers_hint "$_bv"
		   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup FAILED ($_bk_rc)" ;;
	esac
	## re-read the table of the disk just backed up WHILE it is still mounted:
	## POST_BACKUP may eject it next, and a disk that is away only shows its
	## last known table
	for _bk_h in $(locations_all | awk -F'\t' -v t="/Volumes/$_bv" '$2 == t {print $1}'); do
		snapshots_cache_drop "$_bk_h"
		snapshots_get "$_bk_h" >/dev/null
	done
	## A backup my-tm did not start is STILL WRITING to that disk: parking it
	## now cuts the run off. Seen on horse -- "a backup was already running",
	## then eject, and Time Machine's run ended there.
	if [ "$_bk_rc" = "3" ]; then
		minor "leaving ${_bv:-the destination} mounted -- POST_BACKUP does not end a backup my-tm did not start"
	else
		do_post_backup
	fi
	return "$_bk_rc"
}

#############################################################################
## --add / --forget / --refresh
#############################################################################

## What a sparsebundle can say about itself WITHOUT being attached -- which is
## the point, since attaching one over a share costs a minute or more.
bundle_show() {
	_b="$1"; _i="${2:-}"; _n="${3:-}"
	_name=$(basename "$_b")
	_host=$(bundle_host_uuid "$_b" 2>/dev/null)
	_model=$(plutil -extract 'com\.apple\.backupd\.ModelID' raw -o - \
		"$_b/com.apple.TimeMachine.MachineID.plist" 2>/dev/null)
	_size=$(plutil -extract size raw -o - "$_b/Info.plist" 2>/dev/null)
	_last=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$_b" 2>/dev/null)
	printf '\n'
	[ -n "$_i" ] && med "[$_i/$_n] $_name"
	[ -n "$_i" ] || med "$_name"
	minor "path        $_b"
	if bundle_is_mine "$_b"; then
		minor "belongs to  THIS Mac"
	else
		minor "belongs to  another Mac (HostUUID ${_host:-unknown})"
	fi
	[ -n "$_model" ] && minor "model       $_model"
	[ -n "$_size" ] && minor "capacity    $(human_bytes "$_size")"
	[ -n "$_last" ] && minor "last change $_last"
	if locations_registered | awk -F'\t' -v b="$_b" '$2 == b {f = 1} END {exit(f ? 0 : 1)}'; then
		minor "registered  yes, already known to my-tm"
	else
		minor "registered  no"
	fi
	return 0
}

## Offer each Time Machine bundle found in a directory, one at a time.
## Its own variables are prefixed: add_one below sets _n and _b as well, and
## shell has no locals -- the count changed under the loop and it walked off
## the end of the list.
add_pick() {
	_pk_list="$1"
	_pk_n=$(printf '%s\n' "$_pk_list" | count_lines)
	_pk_i=1
	_pk_added=0
	_pk_asked=0
	while [ "$_pk_i" -le "$_pk_n" ]; do
		_pk_b=$(printf '%s\n' "$_pk_list" | sed -n "${_pk_i}p")
		bundle_show "$_pk_b" "$_pk_i" "$_pk_n"
		printf 'add / skip / back / quit  [a/s/b/q]? ' >&2
		## Whether anyone is there to answer is decided by whether an answer
		## ARRIVES, not by whether stdin is a terminal: answers piped in are a
		## perfectly good way to drive this, and EOF is the honest signal that
		## nobody is choosing.
		if ! read -r _pk_ans; then
			printf '\n' >&2
			if [ "$_pk_asked" = "0" ]; then
				note "$_pk_n Time Machine backups here, and nothing to answer with; add one by name:"
				printf '%s\n' "$_pk_list" | while IFS= read -r _pk_lb; do
					[ -n "$_pk_lb" ] && minor "$US --add $_pk_lb"
				done
				return 1
			fi
			break
		fi
		_pk_asked=1
		case "$_pk_ans" in
			a|A)
				if add_one "$_pk_b" ""; then _pk_added=$(( _pk_added + 1 )); fi
				_pk_i=$(( _pk_i + 1 ))
				;;
			s|S|"") _pk_i=$(( _pk_i + 1 )) ;;
			b|B)
				if [ "$_pk_i" -gt 1 ]; then _pk_i=$(( _pk_i - 1 )); else note "already at the first one"; fi
				;;
			q|Q) break ;;
			*) warn "answer a, s, b or q" ;;
		esac
	done
	note "$_pk_added added"
	return 0
}

cmd_add() {
	_folder="${1:-}"; _handle="${2:-}"
	[ -n "$_folder" ] || err "--add needs a <FOLDER> (or host:/path), optionally a <HANDLE>"

	## A directory that CONTAINS Time Machine bundles rather than being a store
	## itself: offer what is in it instead of refusing.
	if ! is_remote_target "$_folder" && ! is_image_target "$_folder"; then
		_probe=$(abs_path "$_folder")
		if [ -d "$_probe" ] && [ ! -f "$_probe/backup_manifest.plist" ]; then
			_found=""
			for _sb in "$_probe"/*.sparsebundle; do
				[ -d "$_sb" ] || continue
				_found="$_found$_sb
"
			done
			_found=$(printf '%s' "$_found" | grep -v '^$' || true)
			if [ -n "$_found" ]; then
				add_pick "$_found"
				return $?
			fi
		fi
	fi
	add_one "$_folder" "$_handle"
	return $?
}

add_one() {
	_folder="${1:-}"; _handle="${2:-}"

	if ! is_remote_target "$_folder"; then
		_folder=$(abs_path "$_folder")
		[ -d "$_folder" ] || err "$_folder: not a directory"
	fi
	if [ -z "$_handle" ]; then
		if is_remote_target "$_folder"; then
			_handle=$(slug "$(remote_host "$_folder")")
		elif is_image_target "$_folder"; then
			## "macado.sparsebundle" would slug to "macado-sparsebundle"
			_handle=$(slug "$(basename "$_folder" | sed 's/\.[^.]*$//')")
		else
			_handle=$(slug "$(basename "$_folder")")
		fi
	fi
	handle_is_sane "$_handle" ||
		err "'$_handle' cannot be a handle: letters, digits, '-', '.' and '@' only, and not starting with '-' or '.'. It names a directory under $FIRMLINK and several cache files."
	if is_image_target "$_folder" && _ad_nv=$(network_volume_of "$_folder"); then
		_ad_h=$(network_mount_host "$_ad_nv")
		err "$_folder is on a network share (${_ad_h:-another host}) -- read it where it is stored: $US --add ${_ad_h:-<host>}:<path on ${_ad_h:-that host}>/$(basename "$_folder")"
	fi
	is_id_word "$_handle" &&
		err "'$_handle' reads like a snapshot ID (6-8 characters, all from the ID alphabet), so my-tm could never tell them apart. Try '$_handle-tm'."
	## awk's `exit` still runs END, so END's status would win -- use a flag
	locations_registered | awk -F'\t' -v h="$_handle" '$1 == h {f = 1} END {exit(f ? 0 : 1)}' &&
		err "handle '$_handle' is already registered"

	## probe before writing anything
	if is_image_target "$_folder"; then
		## a store inside a disk image: its manifest is only readable once the
		## image is attached, but Info.plist identifies it without attaching
		if [ -f "$_folder/Info.plist" ]; then
			minor "disk image store, uuid $(plutil -extract uuid raw -o - "$_folder/Info.plist" 2>/dev/null)"
		else
			warn "$_folder has no Info.plist -- it does not look like a sparsebundle"
		fi
	elif ! is_remote_target "$_folder"; then
		_vols=$(manifest_parse "$_folder" 2>/dev/null | awk -F'\t' '{print $5}' | sort -u | tr '\n' ' ')
		if [ -z "$(printf '%s' "$_vols" | tr -d ' ')" ]; then
			warn "$_folder has no readable backup_manifest.plist -- adding it anyway, but it may not be a Time Machine store"
		else
			minor "volumes: $(printf '%s' "$_vols" | sed 's/ $//')"
		fi
	fi

	_f=$(locations_file)
	locations_writable "--add $_folder${2:+ $2}"
	{
		[ -f "$_f" ] && cat "$_f"
		printf '%s\t%s\t\n' "$_handle" "$_folder"
	} | atomic_write "$_f" || err "cannot write $_f"
	msg "added location '$_handle' -> $_folder"

	if ! is_remote_target "$_folder"; then
		_n=$(snap_names "$_handle" | count_lines)
		minor "$_n snapshots"
	fi
	return 0
}

cmd_forget() {
	_handle="${1:-}"
	[ -n "$_handle" ] || err "--forget needs a <HANDLE>"
	_f=$(locations_file)
	[ -f "$_f" ] || err "no locations file at $_f"
	awk -F'\t' -v h="$_handle" '$1 == h {found = 1} END {exit(found ? 0 : 1)}' "$_f" ||
		err "$_handle: not a registered location"
	locations_writable "--forget $_handle"
	awk -F'\t' -v h="$_handle" '$1 != h' "$_f" | atomic_write "$_f" || err "cannot write $_f"
	msg "forgot location '$_handle' -- no backup was touched"
	why "deleting snapshots is a different verb: $US --rm <ID> go"
	return 0
}

cmd_refresh() {
	_only="${1:-}"
	## re-read every table that CAN be read; a disk that is away keeps its last
	## known one, since nothing could replace it
	for _rf_h in ${_only:-$(locations_all | awk -F'\t' '{print $1}')}; do
		loc_reachable "$_rf_h" && snapshots_cache_drop "$_rf_h"
	done
	## drop remembered per-file facts too: --refresh is what someone reaches
	## for when they suspect my-tm is telling them something stale or wrong
	for _d in $(cache_read_dirs); do
		rm -f "$_d/index/versions.tsv" 2>/dev/null
	done
	for _ph in $(locations_all | awk -F'\t' '{print $1}'); do
		[ -n "$_only" ] && [ "$_ph" != "$_only" ] && continue
		loc_reachable "$_ph" && vs_prune "$_ph"
	done
	if [ -n "$_only" ]; then
		snapshots_get "$_only" >/dev/null
		tm_refresh "$_only"
	else
		snapshots_all >/dev/null
		tm_refresh
	fi
	msg "caches and $(tm_root) rebuilt"
	for _rh in ${_only:-$(locations_all | awk -F'\t' '{print $1}')}; do
		( jobs_blind_on "$_rh" ) &&
			note "built $_rh; the jobs cannot see into it to keep it current -- JOBS_RUN_WITH_FULL_DISK_ACCESS=1"
	done
	return 0
}

#############################################################################
## --setup   (changes Time Machine's OWN configuration)
#############################################################################

cmd_setup() {
	case "${1:-}" in
		--help|-h)
			cat <<_EOF
usage: $US --setup [OPTIONAL] parameters.

Interactive when given no flags. The scriptable form:

  --add-destination <PATH>     add a Time Machine destination
  --rm-destination <ID|PATH>   remove one
  --enable | --disable         automatic backups on/off
  --exclude <PATH> [-p]        exclude a path (-p: sticky, survives a move)
  --unexclude <PATH>           remove an exclusion
  --is-excluded <PATH>         ask about one path
  --quota <GB>                 cap how much of a shared disk this Mac may use
_EOF
			return 0
			;;
		--add-destination) shift; require_root "--setup --add-destination"
			run tmutil setdestination -a "$1"; return $? ;;
		--rm-destination) shift; require_root "--setup --rm-destination"
			run tmutil removedestination "$1"; return $? ;;
		--enable)  require_root "--setup --enable";  run tmutil enable;  return $? ;;
		--disable) require_root "--setup --disable"; run tmutil disable; return $? ;;
		--exclude) shift
			_p="$1"; _sticky=""
			[ "${2:-}" = "-p" ] && _sticky="-p"
			if [ -n "$_sticky" ]; then run tmutil addexclusion -p "$_p"; else run tmutil addexclusion "$_p"; fi
			return $? ;;
		--unexclude) shift; run tmutil removeexclusion "$1"; return $? ;;
		--is-excluded) shift; run tmutil isexcluded "$1"; return $? ;;
		--quota) shift; require_root "--setup --quota"
			run tmutil setquota "$1"; return $? ;;
	esac

	msg "Time Machine setup -- nothing is written without your confirmation"
	printf '\n'
	med "destinations now:"
	tmutil destinationinfo 2>/dev/null | sed 's/^/    /' || minor "(none configured)"
	printf '\n'
	med "automatic backups:"
	_auto=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null || echo "?")
	minor "AutoBackup = $_auto  (1 = on)"
	_iv=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackupInterval 2>/dev/null || echo "?")
	minor "AutoBackupInterval = $_iv seconds"
	printf '\n'
	med "exclusions (first 20):"
	tmutil listexclusions 2>/dev/null | head -n 20 | sed 's/^/    /' ||
		minor "(cannot list exclusions -- Full Disk Access?)"
	printf '\n'
	note "to change any of it, see: $US --setup --help"
	return 0
}

#############################################################################
## JOB PLISTS
#############################################################################

## the <key>…</key> block for a BACKUP_SCHEDULE-style string
plist_schedule() {
	_sched="$1"
	_runatload=0; _interval=""; _cal=""; _wd=""
	for _tok in $_sched; do
		case "$_tok" in
			on-boot) _runatload=1 ;;
			Mon) _wd=1 ;; Tue) _wd=2 ;; Wed) _wd=3 ;; Thu) _wd=4 ;;
			Fri) _wd=5 ;; Sat) _wd=6 ;; Sun) _wd=0 ;;
			[0-9]*[smhd]) _interval=$(parse_interval "$_tok") ;;
			[0-9][0-9]:[0-9][0-9])
				_hh="${_tok%%:*}"; _mm="${_tok##*:}"
				_cal="$_cal		<dict>
"
				[ -n "$_wd" ] && _cal="$_cal			<key>Weekday</key><integer>$_wd</integer>
"
				_cal="$_cal			<key>Hour</key><integer>$(printf '%d' "$_hh")</integer>
			<key>Minute</key><integer>$(printf '%d' "$_mm")</integer>
		</dict>
"
				_wd=""
				;;
			*) warn "unknown schedule token: $_tok" ;;
		esac
	done
	[ "$_runatload" = "1" ] && printf '\t<key>RunAtLoad</key>\n\t<true/>\n'
	[ -n "$_interval" ] && printf '\t<key>StartInterval</key>\n\t<integer>%s</integer>\n' "$_interval"
	if [ -n "$_cal" ]; then
		printf '\t<key>StartCalendarInterval</key>\n\t<array>\n%s\t</array>\n' "$_cal"
	fi
	return 0
}

## write_job <label> <schedule> <arg>...
## The launcher's C source, carried INSIDE my-tm: the installed copy has no
## source tree beside it and must not know where one lives. The project's
## my-tm-launcher.c holds the same bytes, and the suite fails if they differ.
launcher_source() {
	cat <<'_LAUNCHER_C_EOF'
/*
 * my-tm-launcher -- runs ONE program, fixed when this file is compiled, with
 * the arguments it was given, and nothing else.
 *
 * It exists to hold macOS Full Disk Access for my-tm's LaunchDaemons. macOS
 * grants that access per program; the jobs would otherwise run /bin/dash,
 * and a grant on /bin/dash would cover every dash script on the Mac.
 *
 * Built by `my-tm --install` when JOBS_RUN_WITH_FULL_DISK_ACCESS=1: compiled,
 * then ad-hoc signed. The program path and the hash of this source are
 * compiled in, never written here:
 *     -DMY_TM_PATH='"/path/to/my-tm"' -DLAUNCHER_SOURCE_HASH='"<md5>"'
 * macOS ties the grant to that exact build, so a rebuild needs granting again.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef MY_TM_PATH
#error "build with -DMY_TM_PATH='\"/path/to/my-tm\"'"
#endif
#ifndef LAUNCHER_SOURCE_HASH
#define LAUNCHER_SOURCE_HASH "unknown"
#endif

static void explain(FILE *out)
{
	fprintf(out,
	    "usage: my-tm-launcher [--help] [--version] <MY-TM-ARGUMENTS>\n"
	    "\n"
	    "Runs %s with the arguments given, and nothing else.\n"
	    "It holds Full Disk Access for the my-tm LaunchDaemons, so the jobs can\n"
	    "look inside network volumes and verify backups. That access is granted in\n"
	    "System Settings > Privacy & Security > Full Disk Access.\n"
	    "Built and installed by `my-tm --install` (JOBS_RUN_WITH_FULL_DISK_ACCESS=1).\n",
	    MY_TM_PATH);
}

int main(int argc, char *argv[])
{
	if (argc == 1) {
		explain(stderr);
		return 64;
	}
	if (argc == 2 && strcmp(argv[1], "--help") == 0) {
		explain(stdout);
		return 0;
	}
	if (argc == 2 && strcmp(argv[1], "--version") == 0) {
		printf("my-tm-launcher (runs %s, source %s)\n", MY_TM_PATH, LAUNCHER_SOURCE_HASH);
		return 0;
	}
	argv[0] = (char *)MY_TM_PATH;
	execv(MY_TM_PATH, argv);
	perror("my-tm-launcher: cannot run " MY_TM_PATH);
	return 126;
}
_LAUNCHER_C_EOF
}

## md5 of that source -- what the launcher's --version reports, so a stale
## build is recognisable.
launcher_source_hash() {
	_lh_f=$(mktemp /tmp/my-tm.lsrc.XXXXXX) || return 1
	launcher_source >"$_lh_f"
	md5_file "$_lh_f"
	rm -f "$_lh_f"
}

## Build the launcher for MY-TM-PATH into OUT: compile with that path and the
## source hash baked in, then ad-hoc sign it as my-tm-launcher. OUT is written
## only when both steps succeed. The path is pasted into a compiler define, so
## a quote or backslash in it would inject code: such a path is refused.
launcher_build() {
	_lb_bin="$1"; _lb_out="$2"
	case "$_lb_bin" in
		/*) : ;;
		*) warn "the launcher needs an absolute my-tm path, not '$_lb_bin'"; return 1 ;;
	esac
	case "$_lb_bin" in
		*'"'*|*\\*) warn "cannot build the launcher for a path with a quote or backslash: $_lb_bin"; return 1 ;;
	esac
	for _lb_tool in clang codesign; do
		command -v "$_lb_tool" >/dev/null 2>&1 ||
			{ warn "cannot build the launcher: $_lb_tool is not installed"; return 1; }
	done
	_lb_dir=$(mktemp -d /tmp/my-tm.launcher.XXXXXX) || return 1
	launcher_source >"$_lb_dir/my-tm-launcher.c"
	_lb_hash=$(md5_file "$_lb_dir/my-tm-launcher.c")
	if ! run clang -Wall -Wextra -Werror -O2 \
			-DMY_TM_PATH="\"$_lb_bin\"" -DLAUNCHER_SOURCE_HASH="\"$_lb_hash\"" \
			-o "$_lb_dir/my-tm-launcher" "$_lb_dir/my-tm-launcher.c" >"$_lb_dir/build.log" 2>&1; then
		warn "the launcher did not compile:"
		sed 's/^/     /' "$_lb_dir/build.log" >&2
		rm -rf "$_lb_dir"
		return 1
	fi
	if ! run codesign -s - -f -i my-tm-launcher "$_lb_dir/my-tm-launcher" >"$_lb_dir/sign.log" 2>&1; then
		warn "the launcher could not be signed:"
		sed 's/^/     /' "$_lb_dir/sign.log" >&2
		rm -rf "$_lb_dir"
		return 1
	fi
	mv -f "$_lb_dir/my-tm-launcher" "$_lb_out" || { rm -rf "$_lb_dir"; return 1; }
	rm -rf "$_lb_dir"
	return 0
}

## Is the launcher at LAUNCHER the one --install would build for MY-TM-PATH
## today? Judged by what it REPORTS -- the program it runs and the hash of its
## source -- not by file dates, which say nothing about either.
launcher_is_current() {
	[ -x "$1" ] || return 1
	[ "$("$1" --version 2>/dev/null)" = "my-tm-launcher (runs $2, source $(launcher_source_hash))" ]
}

## Put a launcher for MY-TM-PATH at LAUNCHER, unless the one there is current.
## Built beside its destination, owned root:wheel 0700, then moved into place,
## so a failed build never leaves a half-made launcher where the jobs look.
launcher_install() {
	_li_path="$1"; _li_bin="$2"
	if launcher_is_current "$_li_path" "$_li_bin"; then
		minor "launcher:   $_li_path is current"
		return 0
	fi
	need_dir "$(dirname "$_li_path")" || { warn "cannot create $(dirname "$_li_path")"; return 1; }
	_li_new="$(dirname "$_li_path")/.my-tm-launcher.new.$$"
	launcher_build "$_li_bin" "$_li_new" || return 1
	if ! run chown root:wheel "$_li_new" || ! run chmod 0700 "$_li_new" ||
	   ! run mv -f "$_li_new" "$_li_path"; then
		rm -f "$_li_new"
		warn "could not install the launcher at $_li_path"
		return 1
	fi
	msg "built the launcher $_li_path"
	note "grant it Full Disk Access: System Settings > Privacy & Security > Full Disk Access > add $_li_path"
	why "a rebuilt launcher is a new program to macOS -- an earlier grant does not carry over"
	return 0
}

## How the jobs will reach the stores, as --install shows it. A function, so
## the suite can read it without root.
install_access_plan() {
	if [ "$JOBS_RUN_WITH_FULL_DISK_ACCESS" = "1" ]; then
		minor "access:     JOBS_RUN_WITH_FULL_DISK_ACCESS=1 -- the jobs run through $JOBS_LAUNCHER"
	else
		minor "access:     JOBS_RUN_WITH_FULL_DISK_ACCESS=0 -- the jobs run my-tm directly"
		why "without Full Disk Access a job cannot read a store on a network volume, nor verify checksums"
	fi
	return 0
}

## The LaunchDaemon plist for one job, on stdout. Both output streams are
## captured -- <label>.log for stdout, <label>.err for stderr: a job without
## StandardOutPath discards everything it prints, and --health reports on stdout.
job_plist() {
	_jp_label="$1"; _jp_sched="$2"; shift 2
	_jp_args=""
	for _jp_a in "$@"; do
		_jp_args="$_jp_args		<string>$_jp_a</string>
"
	done
	printf '<?xml version="1.0" encoding="UTF-8"?>\n'
	printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
	printf '<plist version="1.0">\n<dict>\n'
	printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$_jp_label"
	printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>%s</string>\n%s\t</array>\n' \
		"${JOB_PROGRAM:-$MY_TM_BIN}" "$_jp_args"
	plist_schedule "$_jp_sched"
	printf '\t<key>StandardOutPath</key>\n\t<string>%s/%s.log</string>\n' "$LOG_DIR_ROOT" "$_jp_label"
	printf '\t<key>StandardErrorPath</key>\n\t<string>%s/%s.err</string>\n' "$LOG_DIR_ROOT" "$_jp_label"
	printf '</dict>\n</plist>\n'
}

write_job() {
	_label="$1"; _sched="$2"; shift 2
	_prog="${JOB_PROGRAM:-$MY_TM_BIN}"
	_pl="/Library/LaunchDaemons/$_label.plist"
	job_plist "$_label" "$_sched" "$@" >"$_pl" || return 1
	plutil -lint "$_pl" >/dev/null 2>&1 || { warn "$_pl did not lint"; return 1; }
	msg "installed job $_label"
	minor "$_pl -> $_prog $*"
	run launchctl unload "$_pl" >/dev/null 2>&1
	run launchctl load "$_pl" >/dev/null 2>&1 || warn "could not load $_label"
	return 0
}

#############################################################################
## --install / --uninstall
#############################################################################

SYNTH_COMMENT="# my-tm: browse Time Machine snapshots as directories, see \`my-tm --help\`"

## Where --install puts the config it was run with. A plain run -- no --config,
## no $MY_TM_CONFIG -- that already finds one needs no copy: a second copy only
## drifts. Where the two differ, the user merges them; nothing is overwritten.
install_config() {
	_ic_src="$1"
	[ -n "$_ic_src" ] || return 0
	_ic_plain=$(config_search_first 2>/dev/null | tail -n 1)
	if [ -n "$_ic_plain" ]; then
		if cmp -s "$_ic_src" "$_ic_plain"; then
			minor "config:     $_ic_plain"
		else
			warn "a plain '$US' reads $_ic_plain, not $_ic_src"
			minor "merge them: vimdiff $_ic_src $_ic_plain"
		fi
		return 0
	fi
	_ic_dst="$SITE_CONF_DIR/my-tm.conf"
	if [ -f "$_ic_dst" ]; then
		if ! cmp -s "$_ic_src" "$_ic_dst"; then
			warn "$_ic_dst exists and differs -- left as it is"
			minor "merge them: vimdiff $_ic_src $_ic_dst"
		fi
	elif [ -d "$SITE_CONF_DIR" ]; then
		run cp "$_ic_src" "$_ic_dst" && minor "copied $_ic_src -> $_ic_dst"
	else
		warn "$SITE_CONF_DIR does not exist -- the config was not copied"
		return 0
	fi
	## a copy a plain run will not read is no help: offer where it does look
	if ! config_search_paths | grep -qxF "$_ic_dst"; then
		warn "a plain '$US' will not look at $_ic_dst"
		note "put it where it does look, most common place first:"
		config_offer_paths | while IFS= read -r _ic_p; do
			if [ -f "$_ic_p" ]; then minor "vimdiff $_ic_dst $_ic_p"; else minor "cp $_ic_dst $_ic_p"; fi
		done
	fi
	return 0
}

cmd_install() {
	_go=0; _host=""
	for _a in "$@"; do
		case "$_a" in
			go) _go=1 ;;
			*) _host="$_a" ;;
		esac
	done

	if [ -n "$_host" ]; then
		install_remote "$_host" "$_go"
		return $?
	fi

	require_root "--install"
	if [ -z "$CONFIG_SOURCED" ]; then
		warn "--install needs a config: job labels, directories and the group are site-specific, and guessing them is worse than asking."
		note "no config found -- write one, most common place first:"
		config_offer_paths | while IFS= read -r _cp; do
			minor "$US --create-config > $_cp"
		done
		why "$US --help lists every place searched, in search order"
		exit 1
	fi

	MY_TM_BIN=$(abs_path "$0")
	## the daemons log where the config says, like every other my-tm run
	LOG_DIR_ROOT="$LOG_DIR"
	_group="$TM_GROUP"
	[ -n "$_group" ] || _group=$(id -gn "$(invoking_user)" 2>/dev/null || echo wheel)
	_synth="/etc/synthetic.conf"
	_fl="${FIRMLINK#/}"
	_target="${MOUNT_ROOT#/}"
	case "$_target" in
		var/*) _target="private/$_target" ;;
	esac

	msg "my-tm --install$([ "$_go" = "1" ] || printf ' (dry run -- add the word go to do it)')"
	minor "binary:     $MY_TM_BIN"
	minor "cache:      $CACHE_DIR  (root:$_group $CACHE_MODE)"
	minor "mounts:     $MOUNT_ROOT"
	minor "firmlink:   $FIRMLINK -> /$_target  (via $_synth, after a reboot)"
	minor "jobs:       $MAINT_JOB${HEALTH_INTERVAL:+, $HEALTH_JOB}${BACKUP_SCHEDULE:+, $BACKUP_JOB}"
	minor "tree:       built by $MAINT_JOB on its first run, not here"
	minor "logs:       $LOG_DIR_ROOT"
	minor "exclude:    $CACHE_DIR from Time Machine backups"
	install_access_plan

	## a job must not run a binary anyone but root can rewrite
	if path_is_user_writable "$MY_TM_BIN"; then
		err "$MY_TM_BIN is inside a group- or world-writable tree, so a LaunchDaemon running it as root would execute whatever someone puts there. Install a root-owned copy (e.g. /usr/local/sbin/my-tm, root:wheel 0755) and run --install from that."
	fi
	## the same for the launcher, which runs as root AND holds Full Disk Access
	if [ "$JOBS_RUN_WITH_FULL_DISK_ACCESS" = "1" ] && path_is_user_writable "$(dirname "$JOBS_LAUNCHER")"; then
		err "$(dirname "$JOBS_LAUNCHER") is inside a group- or world-writable tree -- JOBS_LAUNCHER must sit where only root can write."
	fi

	[ "$_go" = "1" ] || return 0

	## 1. directories
	for _d in "$CACHE_DIR" "$MOUNT_ROOT" "$CACHE_DIR/index" "$LOG_DIR_ROOT"; do
		need_dir "$_d" || err "cannot create $_d"
	done
	run chown -R "root:$_group" "$CACHE_DIR" || warn "chown failed on $CACHE_DIR"
	run chmod "$CACHE_MODE" "$CACHE_DIR" "$MOUNT_ROOT" || warn "chmod failed"
	why "root writes, the group reads, others see nothing -- the daemons act on what is in here"

	## Time Machine must not back up my-tm's own tree: $MOUNT_ROOT holds mounted
	## snapshots -- a backup inside the backup -- and placeholders $MAINT_JOB
	## rewrites every MAINT_INTERVAL, while the rest is derived data my-tm
	## rebuilds. Seen on horse: backupd walking mount/local/... while the entries
	## vanished under it ("Failed to read sticky exclusion extended attribute").
	if run tmutil addexclusion -p "$CACHE_DIR"; then
		msg "excluded $CACHE_DIR from Time Machine backups"
	else
		warn "could not exclude $CACHE_DIR from Time Machine -- run: tmutil addexclusion -p $CACHE_DIR"
	fi

	## 2. the firmlink
	if [ -f "$_synth" ] && grep -qE "^${_fl}[[:space:]]" "$_synth"; then
		_have=$(awk -v f="$_fl" '$1 == f {print $2; exit}' "$_synth")
		if [ "$_have" = "$_target" ]; then
			minor "$_synth already has the $FIRMLINK entry"
		else
			warn "$_synth already maps $_fl to '$_have', not '$_target' -- left untouched"
		fi
	else
		{
			[ -f "$_synth" ] && cat "$_synth"
			printf '%s\n' "$SYNTH_COMMENT"
			printf '%s\t%s\n' "$_fl" "$_target"
		} | atomic_write "$_synth" || err "cannot write $_synth"
		msg "added the $FIRMLINK entry to $_synth"
		minor "synthetic entries only appear after a reboot; until then my-tm uses $MOUNT_ROOT"
	fi

	## 3. the launcher, when the jobs are to run with Full Disk Access; if it
	## cannot be built, the jobs run my-tm directly and that is said
	JOB_PROGRAM="$MY_TM_BIN"
	if [ "$JOBS_RUN_WITH_FULL_DISK_ACCESS" = "1" ]; then
		if launcher_install "$JOBS_LAUNCHER" "$MY_TM_BIN"; then
			JOB_PROGRAM="$JOBS_LAUNCHER"
		else
			warn "the jobs run my-tm directly, without Full Disk Access"
		fi
	fi

	## 4. the /tm README + jobs
	## The browse tree is NOT built here. Building it reads every store, and
	## on a fresh install nothing is cached, so a sparsebundle on a share has
	## to be attached -- minutes of waiting, for a tree $MAINT_JOB builds on
	## its first run and that is only reachable as $FIRMLINK after the reboot.
	tm_write_readme
	write_job "$MAINT_JOB" "${MAINT_INTERVAL}s" --maintenance
	if [ -n "$HEALTH_INTERVAL" ] && [ "$HEALTH_INTERVAL" != "0" ] && [ "$HEALTH_INTERVAL" != "false" ]; then
		_hi=$(parse_interval "$HEALTH_INTERVAL") || _hi=86400
		write_job "$HEALTH_JOB" "${_hi}s" --health
	else
		minor "HEALTH_INTERVAL is empty -- no health daemon installed"
	fi
	[ -n "$BACKUP_SCHEDULE" ] && write_job "$BACKUP_JOB" "$BACKUP_SCHEDULE" --backup start
	note "the $FIRMLINK tree is built by $MAINT_JOB on its first run -- to build it now: $US --refresh"

	## 5. the config -- copied only where a plain run would otherwise find none
	install_config "$(printf '%s' "$CONFIG_SOURCED" | awk '{print $NF}')"

	## 6. completion, for the human who ran sudo -- never root's home
	write_completion_file

	## every configured ssh host, too
	_rem=$(locations_all | awk -F'\t' '$2 ~ /:/ {print $2}')
	if [ -n "$_rem" ]; then
		while IFS= read -r _t; do
			[ -n "$_t" ] || continue
			install_remote "$(remote_host "$_t")" "$_go"
		done <<_EOF
$_rem
_EOF
	fi
	msg "installed"
	return 0
}

install_remote() {
	_h="$1"; _go="$2"
	_loc=$(locations_all | awk -F'\t' -v h="$_h" '$2 ~ ("^" h ":") && !f {print $1; f = 1}')
	_idir=$(loc_install_dir "${_loc:-}")
	[ -n "$_idir" ] || _idir="/usr/local/sbin"
	msg "remote install on $_h -> $_idir/my-tm"
	if [ "$_go" != "1" ]; then
		minor "dry run -- add the word go"
		return 0
	fi
	run scp "$(abs_path "$0")" "$_h:$_idir/my-tm" || { warn "$_h: copy failed"; return 1; }
	run ssh "$_h" "chmod 0755 $_idir/my-tm && $_idir/my-tm --install go" ||
		warn "$_h: remote --install failed"
	return 0
}

cmd_uninstall() {
	_go=0
	for _a in "$@"; do [ "$_a" = "go" ] && _go=1; done
	require_root "--uninstall"
	_synth="/etc/synthetic.conf"
	_fl="${FIRMLINK#/}"

	msg "my-tm --uninstall$([ "$_go" = "1" ] || printf ' (dry run -- add the word go to do it)')"
	minor "jobs:      $MAINT_JOB $HEALTH_JOB $BACKUP_JOB"
	minor "unmounts:  everything under $MOUNT_ROOT"
	minor "$_synth:   the comment + entry pair for $FIRMLINK"
	minor "keeps:     $CACHE_DIR (asked about separately -- the index is expensive)"
	minor "exclusion: $CACHE_DIR goes back into Time Machine's backups"
	[ -e "$JOBS_LAUNCHER" ] &&
		minor "launcher:  $JOBS_LAUNCHER (its Full Disk Access entry stays in System Settings -- remove it there)"
	[ "$_go" = "1" ] || return 0

	if [ -e "$JOBS_LAUNCHER" ]; then
		run rm -f "$JOBS_LAUNCHER" && msg "removed the launcher $JOBS_LAUNCHER"
	fi

	for _j in "$MAINT_JOB" "$HEALTH_JOB" "$BACKUP_JOB"; do
		_pl="/Library/LaunchDaemons/$_j.plist"
		[ -f "$_pl" ] || continue
		run launchctl unload "$_pl" >/dev/null 2>&1
		run rm -f "$_pl"
		msg "removed job $_j"
	done

	_records=$(mounts_read_all)
	if [ -n "$_records" ]; then
		printf '%s\n' "$_records" | awk -F'\t' '{print $3}' | while IFS= read -r _mp; do
			[ -n "$_mp" ] || continue
			snap_umount "$_mp" 1 >/dev/null 2>&1
		done
	fi

	## remove exactly the pair we added, so a diff before/after is empty
	if [ -f "$_synth" ]; then
		awk -v c="$SYNTH_COMMENT" -v f="$_fl" '
			$0 == c { skip = 1; next }
			$1 == f { skip = 0; next }
			{ print }
		' "$_synth" | atomic_write "$_synth" && msg "cleaned $_synth"
		minor "$FIRMLINK itself disappears at the next reboot"
	fi

	run tmutil removeexclusion -p "$CACHE_DIR" >/dev/null 2>&1 &&
		msg "removed the Time Machine exclusion for $CACHE_DIR"

	printf 'delete %s too? the index is expensive to rebuild [y/N] ' "$CACHE_DIR"
	read -r _ans
	case "$_ans" in
		y|Y) run rm -rf "$CACHE_DIR"; msg "removed $CACHE_DIR" ;;
		*) minor "kept $CACHE_DIR" ;;
	esac
	return 0
}

#############################################################################
## --maintenance   (what the LaunchDaemon runs: sweep, refresh, local snaps)
#############################################################################

## Rebuild the /tm tree of each location whose backups changed since the last
## run, and re-read THAT location's snapshot table only. The loop's variables
## carry their own prefix: snap_names and tm_refresh_loc use _h and _t.
maint_refresh_trees() {
	_mrt_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _mrt_h; do
		[ -n "$_mrt_h" ] || continue
		loc_ready "$_mrt_h" || continue
		_mrt_t=$(loc_target "$_mrt_h")
		_mrt_stamp="$(cache_write_dir)/.manifest.$_mrt_h"
		_mrt_m=0
		[ "$_mrt_t" != "local" ] && [ -f "$_mrt_t/backup_manifest.plist" ] &&
			_mrt_m=$(stat -f '%m' "$_mrt_t/backup_manifest.plist" 2>/dev/null || echo 0)
		## local has no manifest: its stamp is the set of local snapshots, which
		## changes only when one is taken or purged
		[ "$_mrt_t" = "local" ] &&
			_mrt_m=$(snap_names local | cksum | awk '{print $1 "." $2}')
		_mrt_old=0
		[ -f "$_mrt_stamp" ] && _mrt_old=$(cat "$_mrt_stamp" 2>/dev/null || echo 0)
		if [ "$_mrt_m" != "$_mrt_old" ]; then
			dbg "maintenance: $_mrt_h changed ($_mrt_old -> $_mrt_m), refreshing"
			snapshots_cache_drop "$_mrt_h"
			snapshots_get "$_mrt_h" >/dev/null
			tm_refresh_loc "$_mrt_h"
			printf '%s\n' "$_mrt_m" >"$_mrt_stamp" 2>/dev/null || true
		fi
	done <<_EOF
$_mrt_locs
_EOF
	return 0
}

cmd_maintenance() {
	BACKGROUND_JOB=1
	images_adopt_orphans
	dbg "maintenance: usage samples"
	for _uh in $(locations_all | awk -F'\t' '{print $1}'); do
		usage_sample "$_uh"
	done
	dbg "maintenance: sweep"
	sweep
	dbg "maintenance: /tm refresh"
	maint_refresh_trees
	if [ -n "$LOCAL_SNAP_INTERVAL" ]; then
		_iv=$(parse_interval "$LOCAL_SNAP_INTERVAL") || _iv=""
		if [ -n "$_iv" ]; then
			_last=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null |
				sed -nE 's/^com\.apple\.TimeMachine\.([0-9-]+)\.local$/\1/p' | sort | tail -n 1)
			_due=1
			if [ -n "$_last" ]; then
				_le=$(ts_to_epoch "$_last")
				[ -n "$_le" ] && [ $(( $(now_epoch) - _le )) -lt "$_iv" ] && _due=0
			fi
			if [ "$_due" = "1" ]; then
				dbg "maintenance: a local snapshot is due"
				cmd_local_snap
			fi
			local_snap_trim
		fi
	fi
	return 0
}

#############################################################################
## COMPLETION
#############################################################################

completion_zsh() {
	cat <<'_EOF'
#compdef my-tm
_my-tm() {
  local -a cmds
  cmds=(
    '--status:status of every backup location'
    '--ls:snapshot table'
    '--lookup:every version of a path'
    '--find:search the history by name'
    '--show:one snapshot'
    '--mount:expose a snapshot (needs a TTL)'
    '--umount:release a mount'
    '--open:open a version'
    '--cat:write a version to stdout'
    '--cp:copy a version out'
    '--diff:what changed since then'
    '--index:build the name index'
    '--verify:re-check stored checksums'
    '--local-snapshot:take an APFS local snapshot'
    '--health:run the health checks'
    '--rm:delete snapshots'
    '--thin:apply a retention policy'
    '--backup:start or stop a backup'
    '--install:set up dirs, firmlink, daemons'
    '--uninstall:undo --install'
    '--setup:configure Time Machine itself'
    '--add:register a location'
    '--forget:forget a location'
    '--refresh:rebuild caches and the tree'
    '--create-config:print the default config'
    '--config:use a specific config file'
    '--completion:print the completion script'
    '--run-tests:run the built-in tests'
    '--help:this'
  )
  if (( CURRENT == 2 )); then
    _describe 'command' cmds
    _alternative "handles:location:($(my-tm --completion --handles 2>/dev/null))"
  else
    _files
  fi
}
_my-tm "$@"
_EOF
}

completion_bash() {
	cat <<'_EOF'
_my_tm() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmds="--status --ls --lookup --find --show --mount --umount --open --cat
    --cp --diff --index --verify --local-snapshot --health --rm --thin
    --backup --install --uninstall --setup --add --forget --refresh
    --create-config --config --completion --run-tests --help"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
  else
    COMPREPLY=( $(compgen -W "$(my-tm --completion --handles 2>/dev/null)" -- "$cur") $(compgen -f -- "$cur") )
  fi
}
complete -F _my_tm my-tm
_EOF
}

## written on every ordinary run, but only when the content actually differs
write_completion_file() {
	_home=$(invoking_home)
	[ -n "$_home" ] && [ -d "$_home" ] || return 0
	_dir="$_home/.zsh/completions"
	_f="$_dir/_my-tm"
	_new=$(completion_zsh)
	if [ -f "$_f" ] && [ "$(cat "$_f" 2>/dev/null)" = "$_new" ]; then
		dbg "completion is current: $_f"
		return 0
	fi
	need_dir "$_dir" || return 0
	printf '%s\n' "$_new" >"$_f" 2>/dev/null || return 0
	## under sudo this must belong to the human, not to root
	_u=$(invoking_user)
	[ "$_u" != "$(id -un)" ] && chown "$_u" "$_f" "$_dir" 2>/dev/null
	dbg "wrote completion: $_f"
	return 0
}

cmd_completion() {
	case "${1:-zsh}" in
		--handles) locations_all | awk -F'\t' '{print $1}' | tr '\n' ' ' ;;
		bash) completion_bash ;;
		*) completion_zsh ;;
	esac
	return 0
}

#############################################################################
## USAGE
#############################################################################

usage() {
	cat <<_EOF
usage: $US [OPTIONS] [<LOCATION>|<ID>] [<PATH>|<GLOB>]

A <LOCATION> is one Time Machine backup store, named either by its path or by
the short handle you gave it with --add; an <ID> is a 6-char name for one
snapshot inside one location. Everything with -- is interpreted as a command.
A bare \`$US\` runs \$DEFAULT_CMD (default --status).

  $US                          status of all backup locations
  $US <LOCATION>               list its snapshots                   (= --ls)
  $US <ID>                     show one snapshot                  (= --show)
  $US <PATH> [<LOCATION>]      every version of it [in <LOCATION>] (= --lookup)
  $US '<GLOB>'                 search the history by name         (= --find)
  $US <ID> <PATH>              that file, in that snapshot
  The two bare words may come in either order.

INSPECT
  --status  [<LOCATION>]         one line per location: snapshots, span, space,
                                 index state; all locations if omitted
  --ls      [<LOCATION>]         snapshot table: when, how much each backup
                                 added, restore size, exclusive size*;
                                 every location if omitted
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
                                 5h3m / 2d. <PATH> is where to put it: relative
                                 goes under $FIRMLINK, absolute is used as given;
                                 under $FIRMLINK if omitted. A location alone
                                 means its newest snapshot; --all means each of
                                 them. See \`$US --mount --help\`
  --umount [-f] <ID>|<LOCATION>|--all
                                 release it early (they expire on their own).
                                 If something still has files open, prints what
                                 is holding it and refuses; -f unmounts anyway
  --open    <ID> <PATH>          open that version (prints the command first)
  --cat     <ID> <PATH>          write that version to stdout
  --cp [-f] <ID> <PATH> [<DEST>] copy it out; <DEST> defaults to \$PWD under the
                                 original name. Refuses to overwrite without -f
  --diff    <ID> [<PATH>]        what changed between then and now; the whole
                                 snapshot if <PATH> is omitted (slow, warns first)
  ...or just browse:             ls $FIRMLINK/<LOCATION>/<SNAPSHOT>/

MAINTAIN
  --index   [<LOCATION>|<ID>...] [--all]
                                 build the name index --find uses, and record
                                 each snapshot's exclusive size* on the same
                                 pass. Without arguments: the baselines of every
                                 location. With --all: every snapshot -- an
                                 overnight job, warns first
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
                                 policy if omitted. Dry-run unless you type \`go\`
  --backup  start|stop [--eject|--no-eject]
                                 run or stop a backup, then do what POST_BACKUP
                                 says with the disk: none | unmount | eject.
                                 --no-eject leaves it mounted from now on,
                                 --eject undoes that. Both persist, the
                                 unattended run included.
                                 [daemon: run on BACKUP_SCHEDULE]

INSTALL & SET UP
  --install [<SSH-HOST>] [go] | --uninstall [<SSH-HOST>] [go]
                                 initial setup: dirs, $FIRMLINK firmlink, daemons.
                                 Without \`go\` it only prints what it would do,
                                 every host listed. Needs root + Full Disk
                                 Access locally and on each configured ssh host;
                                 <SSH-HOST> does just that one, all if omitted.
                                 The jobs get Full Disk Access only with
                                 JOBS_RUN_WITH_FULL_DISK_ACCESS=1 -- through a
                                 launcher --install builds, granted once in
                                 System Settings. A command says so where that
                                 changed what it did
  --setup                        interactive setup of Time Machine itself --
                                 destinations, exclusions, quota.
                                 See \`--setup --help\` for the flags to do it
                                 from a script instead
  --add <FOLDER> [<HANDLE>]      register a location; <HANDLE> defaults to a
                                 slug of the volume name
  --forget <HANDLE>              forget a location; no backup is touched
                                 (deleting snapshots is --rm <ID> go)
  --refresh [<LOCATION>]         rebuild caches and the $FIRMLINK tree; all if omitted
  --create-config [<FILE>]       print the default config, or write it to <FILE>
  --config <FILE>                use this config instead of the search order
  --completion [zsh|bash]        print the completion script
  --run-tests | --version | --help

  ADDED is what a backup WROTE, not what deleting it would free: macOS exposes
  no per-snapshot exclusive size for an APFS Time Machine store, so no column
  here can honestly claim one. See the README.

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

Quote globs:  $US 'invoice*.pdf'   (else the shell expands it first).
_EOF
	return 0
}

usage_mount() {
	cat <<_EOF
usage: $US --mount [OPTIONS] <ID>|<LOCATION>|--all <TTL> [<PATH>] parameters.

<TTL> is mandatory because a mounted snapshot CANNOT BE DELETED: while it is
held, Time Machine's thinning silently fails against it, and on the startup
disk macOS cannot purge local snapshots to free space.
Give the shortest time you really need: 7m / 4h / 5h3m / 2d.
A quarter of your backup interval is the sane ceiling; my-tm warns past it and
continues -- it is your disk.
_EOF
	return 0
}

#############################################################################
## THE DISPATCH LADDER
##   Anything starting with - is a command or an option; every bare word is
##   data, classified here.  -V prints which rung fired.
#############################################################################

## which rung fired is -V material: it is the answer to "why did my-tm do THAT
## with my word?", which is exactly what someone reaches for -V to find out.
rung() {
	[ "$VRB" = "1" ] || return 0
	printf '    > %s\n' "$*" >&2
	return 0
}

## classify_one <word> -> "id|loc|glob|path <TAB> value"
classify_one() {
	_w="$1"
	if is_id_word "$_w" && resolve_id "$_w" >/dev/null 2>&1; then
		rung "ladder rung 1: '$_w' is a snapshot ID"
		printf 'id\t%s\n' "$_w"; return 0
	fi
	if loc_line "$_w" >/dev/null 2>&1; then
		rung "ladder rung 2: '$_w' is a location handle"
		printf 'loc\t%s\n' "$_w"; return 0
	fi
	case "$_w" in
		/*)
			_h=$(locations_all | awk -F'\t' -v p="$_w" \
				'$2 != "local" && index(p, $2) == 1 && !f {print $1; f = 1}')
			if [ -n "$_h" ]; then
				rung "ladder rung 3: '$_w' is inside backup disk '$_h'"
				printf 'loc\t%s\n' "$_h"; return 0
			fi
			;;
	esac
	case "$_w" in
		*[*?[]*)
			rung "ladder rung 4: '$_w' has a glob character -> a name to search for"
			printf 'glob\t%s\n' "$_w"; return 0
			;;
	esac
	case "$_w" in
		*/*)
			rung "ladder rung 5: '$_w' contains a slash -> a path"
			printf 'path\t%s\n' "$_w"; return 0
			;;
	esac
	if [ -e "$PWD/$_w" ]; then
		rung "ladder rung 5: '$_w' exists in \$PWD -> a path"
		printf 'path\t%s\n' "$_w"; return 0
	fi
	rung "ladder rung 6: '$_w' is a bare name -> search for it"
	printf 'glob\t%s\n' "$_w"
	return 0
}

## the smart form: up to two bare words, in either order
dispatch_bare() {
	_c1=$(classify_one "$1")
	_t1=$(printf '%s' "$_c1" | awk -F'\t' '{print $1}')
	_v1=$(printf '%s' "$_c1" | awk -F'\t' '{print $2}')
	if [ "$#" -lt 2 ]; then
		case "$_t1" in
			id)   cmd_show "$_v1" ;;
			loc)  cmd_ls "$_v1" ;;
			path) cmd_lookup "$_v1" ;;
			glob) cmd_find "$_v1" ;;
		esac
		return $?
	fi
	_c2=$(classify_one "$2")
	_t2=$(printf '%s' "$_c2" | awk -F'\t' '{print $1}')
	_v2=$(printf '%s' "$_c2" | awk -F'\t' '{print $2}')

	## normalise the order: <ID>/<LOCATION> first, the path/glob second
	case "$_t2" in
		id|loc)
			case "$_t1" in
				path|glob)
					_tmp_t="$_t1"; _tmp_v="$_v1"
					_t1="$_t2"; _v1="$_v2"; _t2="$_tmp_t"; _v2="$_tmp_v"
					;;
			esac
			;;
	esac

	case "$_t1:$_t2" in
		id:path)  cmd_show "$_v1" "$_v2" ;;
		id:glob)  cmd_find "$_v2" "$_v1" ;;
		loc:path) cmd_lookup "$_v2" "$_v1" ;;
		loc:glob) cmd_find "$_v2" "$_v1" ;;
		id:loc|loc:id)
			_hit=$(resolve_id "$_v1" 2>/dev/null)
			_in=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
			err "$_v1 is a snapshot of '$_in', not of '$_v2'."
			;;
		*) err "cannot make sense of '$1' and '$2' together. See --help" ;;
	esac
	return $?
}

#############################################################################
## MAIN
#############################################################################

main() {
	CMD=""
	_n=$#
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_a="$1"; shift; _i=$(( _i + 1 ))
		case "$_a" in
			-h) usage; exit 0 ;;
			--help)
				if [ "$CMD" = "--mount" ]; then usage_mount; exit 0; fi
				CMD="--help"
				;;
			-V|--verbose) VRB=1 ;;
			-DD|--deepdebug)
				DEEPDBG=1
				case "${1:-}" in
					-*|"") : ;;
					*) DBG_PATH="$1"; shift; _i=$(( _i + 1 )) ;;
				esac
				;;
			-D|--debug)
				DBG=1
				case "${1:-}" in
					-*|"") : ;;
					*) DBG_PATH="$1"; shift; _i=$(( _i + 1 )) ;;
				esac
				;;
			-A|--all) OPT_ALL=1 ;;
			-J|--json) JSON=1 ;;
			-f|--force) FORCE=1 ;;
			-L|--limit) LIMIT="${1:-}"; shift; _i=$(( _i + 1 )) ;;
			--limit=*) LIMIT="${_a#*=}" ;;
			-S|--source) SRC="${1:-}"; shift; _i=$(( _i + 1 )) ;;
			--source=*) SRC="${_a#*=}" ;;
			--config) CONFIG_FILE="${1:-}"; shift; _i=$(( _i + 1 )) ;;
			--config=*) CONFIG_FILE="${_a#*=}" ;;
			--create-config=*) CMD="--create-config"; set -- "$@" "${_a#*=}" ;;
			--*)
				if [ -z "$CMD" ]; then CMD="$_a"; else set -- "$@" "$_a"; fi
				;;
			*) set -- "$@" "$_a" ;;
		esac
	done

	## the implication chain, enforced once
	[ "$DEEPDBG" = "1" ] && DBG=1
	[ "$DBG" = "1" ] && VRB=1
	[ "$DEEPDBG" = "1" ] && { PS4='+ '; set -x; }

	load_config || true
	case "${CMD:-}" in
		--run-tests|--create-config|--help|--version) : ;;
		*) config_refuse_old_names ;;
	esac

	## Without --install there is no maintenance daemon, so nothing would ever
	## reap a mount leaked by a kill -9. Reconcile and release expired ones on
	## ordinary runs; a mount still inside its TTL is never touched.
	case "${CMD:-}" in
		--run-tests|--maintenance|--sweep|--umount) : ;;
		*)
			if [ ! -f "/Library/LaunchDaemons/$MAINT_JOB.plist" ] &&
			   [ -n "$(mounts_read_all)" ]; then
				dbg "no maintenance daemon installed -- sweeping opportunistically"
				sweep >/dev/null 2>&1 || true
			fi
			;;
	esac

	## a mount root we cannot write to is no mount root at all
	_mr=$(mount_root_resolve)
	if [ "$_mr" != "$MOUNT_ROOT" ]; then
		dbg "$MOUNT_ROOT is not writable; mounting under $_mr instead (run --install to share one)"
		MOUNT_ROOT="$_mr"
	fi

	## a bare name given to -D/-DD is a file in the per-user log dir
	case "${DBG_PATH:-}" in
		"") : ;;
		/*) : ;;
		*)  need_dir "$LOG_DIR" && DBG_PATH="$LOG_DIR/$DBG_PATH" ;;
	esac

	## every ordinary run keeps the completion file current (content-compared)
	case "${CMD:-}" in
		--run-tests|--completion) : ;;
		*) write_completion_file ;;
	esac

	if [ -z "$CMD" ] && [ "$#" -eq 0 ]; then
		# shellcheck disable=SC2086  # DEFAULT_CMD may carry parameters on purpose
		set -- $DEFAULT_CMD
		CMD="$1"; shift
	fi

	case "${CMD:-}" in
		"")             dispatch_bare "$@" ;;
		--help)         usage ;;
		--status)       cmd_status "$@" ;;
		--ls)           cmd_ls "$@" ;;
		--lookup)       [ "$#" -ge 1 ] || err "--lookup needs a <PATH>"; cmd_lookup "$@" ;;
		--find)         [ "$#" -ge 1 ] || err "--find needs a <GLOB>"
		                if [ "$#" -ge 2 ]; then cmd_find "$2" "$1"; else cmd_find "$1"; fi ;;
		--show)         [ "$#" -ge 1 ] || err "--show needs an <ID>"; cmd_show "$@" ;;
		--mount)        cmd_mount "$@" ;;
		--umount)       cmd_umount "$@" ;;
		--open)         [ "$#" -ge 2 ] || err "--open needs <ID> <PATH>"; cmd_open "$@" ;;
		--cat)          [ "$#" -ge 2 ] || err "--cat needs <ID> <PATH>"; cmd_cat "$@" ;;
		--cp)           [ "$#" -ge 2 ] || err "--cp needs <ID> <PATH> [<DEST>]"; cmd_cp "$@" ;;
		--diff)         [ "$#" -ge 1 ] || err "--diff needs an <ID>"; cmd_diff "$@" ;;
		--index)        cmd_index "$@" ;;
		--verify)       [ "$#" -ge 1 ] || err "--verify needs an <ID>"; cmd_verify "$@" ;;
		--local-snap|--local-snapshot) cmd_local_snap ;;
		--health)       cmd_health "$@" ;;
		--maintenance)  cmd_maintenance ;;
		--sweep)        sweep ;;
		--rm)           cmd_rm "$@" ;;
		--thin)         cmd_thin "$@" ;;
		--backup)       cmd_backup "$@" ;;
		--install)      cmd_install "$@" ;;
		--uninstall)    cmd_uninstall "$@" ;;
		--setup)        cmd_setup "$@" ;;
		--add)          cmd_add "$@" ;;
		--forget)       cmd_forget "$@" ;;
		--refresh)      cmd_refresh "$@" ;;
		--create-config) cmd_create_config "${1:-}" ;;
		--completion)   cmd_completion "${1:-}" ;;
		--version)
			## name the FILE and its date, not just the number: my-tm is copied to
			## a root-owned path for the daemons rather than symlinked, so a
			## checkout and an installed copy can differ while looking identical
			_vb=$(abs_path "$0")
			printf '%s %s\n' "$US" "$MY_TM_VERSION"
			printf '  %s\n' "$_vb"
			printf '  %s\n' "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$_vb" 2>/dev/null)"
			;;
		--run-tests)    run_tests "$@" ;;
		*)              err "unknown command: $CMD  (see --help)" ;;
	esac
	EXIT_RC=$?
	return "$EXIT_RC"
}

#############################################################################
## TESTS
##   No network, no real backup disk, no root.  Everything destructive goes
##   through a stub PATH and is asserted on the recorded argv.
#############################################################################

T_PASS=0; T_FAIL=0; T_SKIP=0; T_ROOT=""
T_MYTM=""

t_ok()   { T_PASS=$(( T_PASS + 1 )); printf '   ok   %s\n' "$1"; }
t_bad()  { T_FAIL=$(( T_FAIL + 1 )); printf ' FAIL   %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
t_skip() { T_SKIP=$(( T_SKIP + 1 )); printf ' skip   %s  (%s)\n' "$1" "$2"; }

t_eq() {
	if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected '$3', got '$2'"; fi
}
t_ne() {
	if [ "$2" != "$3" ]; then t_ok "$1"; else t_bad "$1" "expected something other than '$3'"; fi
}
t_true()  { if "$@" >/dev/null 2>&1; then t_ok "$1"; else t_bad "$1" "command failed"; fi; }
t_match() {
	if printf '%s' "$2" | grep -q "$3"; then t_ok "$1"; else t_bad "$1" "'$2' does not match /$3/"; fi
}

t_stub_dir() { printf '%s/stub\n' "$T_ROOT"; }

## Append rows to the snapshot cache the way my-tm does, so its integrity
## header stays correct -- appending raw lines is exactly the damage the
## checksum exists to catch.
t_cache_add() {
	_cf=$(snapshots_cache_file)
	{ cache_read_checked "$_cf" 2>/dev/null; cat; } | cache_write_checked "$_cf"
}
t_calls()    { printf '%s/calls.log\n' "$T_ROOT"; }

t_make_stubs() {
	_s=$(t_stub_dir)
	mkdir -p "$_s"
	cat >"$_s/tmutil" <<_EOF
#!/bin/sh
printf 'tmutil %s\n' "\$*" >>"$(t_calls)"
case "\$1" in
  destinationinfo) printf '====================================================\nName          : TestStore\nKind          : Local\nMount Point   : $T_ROOT/store\nID            : 11111111-2222-3333-4444-555555555555\n====================================================\nName          : EjectedStore\nKind          : Local\nID            : 99999999-8888-7777-6666-555555555555\n' ;;
  listlocalsnapshots) printf 'Snapshots for disk %s:\ncom.apple.TimeMachine.2026-08-23-005931.local\ncom.apple.TimeMachine.2026-08-23-020001.local\n' "\$2" ;;
  verifychecksums) case "\$2" in *BADSUM*) printf '! %s\n' "\$2" ;; esac ;;
  status) printf 'Backup session status:\n{\n    Running = 0;\n}\n' ;;
  isexcluded) if grep -qxF "\$2" "$T_ROOT/tm.excluded" 2>/dev/null; then printf '[Excluded]  %s\n' "\$2"; else printf '[Included]    %s\n' "\$2"; fi ;;
  addexclusion) printf '%s\n' "\$3" >>"$T_ROOT/tm.excluded" ;;
  removeexclusion) grep -vxF "\$3" "$T_ROOT/tm.excluded" >"$T_ROOT/tm.excluded.new" 2>/dev/null; mv -f "$T_ROOT/tm.excluded.new" "$T_ROOT/tm.excluded" 2>/dev/null ;;
  *) : ;;
esac
exit 0
_EOF
	cat >"$_s/diskutil" <<_EOF
#!/bin/sh
printf 'diskutil %s\n' "\$*" >>"$(t_calls)"
case "\$1" in
  mount|unmount) exit 0 ;;
esac
if [ "\$1" = "info" ] && [ "\$2" != "-plist" ]; then
  case "\$2" in
    UnmountedStore) printf '   Volume Name: UnmountedStore\n   Mounted: No\n' ;;
    MountedStore)   printf '   Volume Name: MountedStore\n   Mounted: Yes\n' ;;
    *)              printf 'Could not find disk: %s\n' "\$2" ;;
  esac
  exit 0
fi
case "\$1 \$2" in
  "info -plist")
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk9s1</string><key>VolumeUUID</key><string>AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111</string></dict></plist>\n' ;;
  "apfs listSnapshots")
    printf 'Snapshots for disk9s1\n|\n+-- F3888E2B-595F-4B7D-A126-FF7E7449EDB8\n|   Name:        com.apple.TimeMachine.2026-08-20-155805.backup\n|   XID:         924\n+-- A2888E2B-595F-4B7D-A126-FF7E7449EDB9\n|   Name:        com.apple.TimeMachine.2026-08-22-145625.backup\n|   XID:         925\n' ;;
esac
exit 0
_EOF
	cat >"$_s/mount_apfs" <<_EOF
#!/bin/sh
printf 'mount_apfs %s\n' "\$*" >>"$(t_calls)"
exit 0
_EOF
	cat >"$_s/launchctl" <<_EOF
#!/bin/sh
printf 'launchctl %s\n' "\$*" >>"$(t_calls)"
exit 0
_EOF
	cat >"$_s/locate.mklocatedb" <<_EOF
#!/bin/sh
printf 'mklocatedb\n' >>"$(t_calls)"
cat >/dev/null
printf 'FAKEDB\n'
exit 0
_EOF
	chmod 0755 "$_s"/*
	return 0
}

## the real macOS 26 manifest shape, so a future OS change fails a test rather
## than quietly producing a wrong number
t_make_manifest() {
	cat >"$T_ROOT/store/backup_manifest.plist" <<'_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<date>2026-08-20T13:58:05Z</date>
	<dict>
		<key>maximumFileID</key>
		<integer>12067179</integer>
		<key>startDate</key>
		<date>2026-08-20T13:56:46Z</date>
		<key>stats</key>
		<dict>
			<key>changed</key>
			<dict>
				<key>count</key>
				<integer>51312</integer>
				<key>logicalSize</key>
				<integer>41459394501</integer>
				<key>physicalSize</key>
				<integer>41633693696</integer>
			</dict>
			<key>propagated</key>
			<dict>
				<key>count</key>
				<integer>4205393</integer>
				<key>logicalSize</key>
				<integer>1617166291587</integer>
				<key>physicalSize</key>
				<integer>1543881437184</integer>
			</dict>
		</dict>
		<key>volumeStoreInfo</key>
		<dict>
			<key>48F8675E-3FC9-4D16-8044-E3F0B3D4E0C6</key>
			<dict>
				<key>groupUUID</key>
				<string>48F8675E-3FC9-4D16-8044-E3F0B3D4E0C6</string>
				<key>name</key>
				<string>Data</string>
				<key>role</key>
				<integer>64</integer>
			</dict>
		</dict>
		<key>xid</key>
		<integer>250008</integer>
	</dict>
</array>
</plist>
_EOF
	return 0
}

t_setup() {
	T_ROOT=$(mktemp -d /tmp/my-tm.test.XXXXXX) || err "cannot create a test dir"
	T_MYTM=$(abs_path "$0")
	mkdir -p "$T_ROOT/store" "$T_ROOT/cache" "$T_ROOT/ucache" "$T_ROOT/mount" "$T_ROOT/home"
	mkdir -p "$T_ROOT/store/2026-08-23-101010.inprogress" "$T_ROOT/store/2026-08-19-090000.interrupted"
	: >"$(t_calls)"
	t_make_stubs
	t_make_manifest
	CACHE_DIR="$T_ROOT/cache"
	CACHE_DIR_USER="$T_ROOT/ucache"
	MOUNT_ROOT="$T_ROOT/mount"
	LOG_DIR="$T_ROOT/log"
	FIRMLINK="$T_ROOT/mount"
	CACHE_TTL=3600
	## hermetic: loc_param re-reads the loaded config files
	CONFIG_SOURCED=""
	HOME="$T_ROOT/home"
	PATH="$(t_stub_dir):$PATH"
	export PATH HOME
	printf 'store\t%s\t\n' "$T_ROOT/store" >"$T_ROOT/cache/locations.tsv"
	printf 'remote\thost1:/Volumes/TM.Ext\t/usr/local/sbin\n' >>"$T_ROOT/cache/locations.tsv"
	return 0
}

t_teardown() {
	[ -n "$T_ROOT" ] && [ -d "$T_ROOT" ] && rm -rf "$T_ROOT"
	return 0
}

#### the tests ##############################################################

t_test_ids() {
	printf '\nIDs\n'
	_a=$(snap_id "UUID-1" "2026-08-20-155805")
	_b=$(snap_id "UUID-1" "2026-08-20-155805")
	t_eq "ID is deterministic across calls" "$_a" "$_b"
	t_eq "ID is ID_LEN chars" "${#_a}" "$ID_LEN"
	_c=$(snap_id "UUID-2" "2026-08-20-155805")
	t_ne "a different destination gives a different ID" "$_c" "$_a"
	_d=$(snap_id "UUID-1" "2026-08-20-155806")
	t_ne "a different timestamp gives a different ID" "$_d" "$_a"
	_l7=$(snap_id "UUID-1" "2026-08-20-155805" 7)
	t_eq "escalation to 7 keeps the 6-char prefix" "$(printf '%s' "$_l7" | cut -c1-6)" "$_a"
	_full=$(crock32 "$(md5_hex "x")")
	t_eq "crock32 yields 8 characters" "${#_full}" "8"
	if printf '%s' "$_full" | grep -q '[ilou]'; then
		t_bad "crock32 excludes i l o u" "got '$_full'"
	else
		t_ok "crock32 excludes i l o u"
	fi
	## a cache wipe must not change anything
	rm -f "$(snapshots_cache_file)"
	t_eq "ID survives a cache wipe" "$(snap_id "UUID-1" "2026-08-20-155805")" "$_a"
}

t_test_handles() {
	printf '\nHandles vs IDs\n'
	if is_id_word "backup"; then
		t_bad "'backup' is allowed as a handle" "it contains a 'u', which Crockford excludes"
	else
		t_ok "'backup' is allowed as a handle (it has a u)"
	fi
	t_true is_id_word "k7f2q9"
	if is_id_word "k7f2q9x"; then t_ok "'k7f2q9x' reads as an ID (refused as a handle)"
	else t_bad "'k7f2q9x' should read as an ID" ""; fi
	if is_id_word "my-store"; then t_bad "'my-store' should not read as an ID" ""
	else t_ok "'my-store' is a fine handle"; fi
	if is_id_word "abcde"; then t_bad "5 chars should not read as an ID" ""
	else t_ok "5 chars is too short to be an ID"; fi
}

t_test_ttl() {
	printf '\nTTL parsing\n'
	t_eq "7m"    "$(parse_ttl 7m)"    "420"
	t_eq "4h"    "$(parse_ttl 4h)"    "14400"
	t_eq "5h3m"  "$(parse_ttl 5h3m)"  "18180"
	t_eq "2d"    "$(parse_ttl 2d)"    "172800"
	if parse_ttl "4" >/dev/null 2>&1; then t_bad "a bare '4' must be refused" ""
	else t_ok "a bare '4' is refused (the unit is the point)"; fi
	if parse_ttl "0m" >/dev/null 2>&1; then t_bad "'0m' must be refused" ""
	else t_ok "'0m' is refused"; fi
	if parse_ttl "4x" >/dev/null 2>&1; then t_bad "'4x' must be refused" ""
	else t_ok "'4x' is refused"; fi
}

t_test_format() {
	printf '\nFormatting\n'
	t_eq "bytes: 1024"        "$(human_bytes 1024)"        "1.00K"
	t_eq "bytes: 1590000000000" "$(human_bytes 1590000000000)" "1.45T"
	t_eq "bytes: -"           "$(human_bytes -)"           "-"
	t_eq "count: 17900"       "$(human_count 17900)"       "17.9k"
	t_eq "count: 4500000"     "$(human_count 4500000)"     "4.5M"
	t_eq "age: 840s"          "$(human_age 840)"           "14m"
	t_eq "age: 2 days"        "$(human_age 180000)"        "2d"
	t_eq "timestamp display"  "$(ts_display 2026-08-20-155805)" "2026-08-20_1558.05"
	t_eq "epoch roundtrip"    "$(ts_to_epoch 2026-08-20-155805)" \
	                          "$(date -j -f '%Y-%m-%d-%H%M%S' 2026-08-20-155805 '+%s')"
}

t_test_manifest() {
	printf '\nManifest parser (real macOS shape)\n'
	_out=$(manifest_parse "$T_ROOT/store")
	_rows=$(printf '%s\n' "$_out" | count_lines)
	t_eq "one row per snapshot record" "$_rows" "1"
	_want=$(date -j -u -f '%Y-%m-%d %H:%M:%S' '2026-08-20 13:58:05' '+%s')
	t_eq "date -> epoch (awk civil days == date(1))" "$(printf '%s' "$_out" | cut -f1)" "$_want"
	t_eq "changed.count"          "$(printf '%s' "$_out" | cut -f2)" "51312"
	t_eq "changed.physicalSize"   "$(printf '%s' "$_out" | cut -f3)" "41633693696"
	t_eq "propagated.logicalSize" "$(printf '%s' "$_out" | cut -f4)" "1617166291587"
	t_eq "volume name"            "$(printf '%s' "$_out" | cut -f5)" "Data"
	t_eq "xid"                    "$(printf '%s' "$_out" | cut -f6)" "250008"
}

t_test_states() {
	printf '\nSnapshot states\n'
	_st=$(snap_states store)
	t_match "the .inprogress leftover is seen" "$_st" "2026-08-23-101010.*inprogress"
	t_match "the .interrupted leftover is seen" "$_st" "2026-08-19-090000.*interrupted"
}

t_test_thin() {
	printf '\nThin policy (selection only, nothing is deleted)\n'
	_now=$(date -j -f '%Y-%m-%d-%H%M%S' '2026-08-24-120000' '+%s')
	_rows=$(mktemp "$T_ROOT/thin.XXXXXX")
	## four backups inside one hour, then one a day for 10 days, then monthly
	for _h in 00 15 30 45; do
		_ts="2026-08-24-11${_h}00"
		printf '%s\t%s\n' "$_ts" "$(ts_to_epoch "$_ts")" >>"$_rows"
	done
	for _d in 14 15 16 17 18 19 20 21 22 23; do
		_ts="2026-08-${_d}-030000"
		printf '%s\t%s\n' "$_ts" "$(ts_to_epoch "$_ts")" >>"$_rows"
	done
	for _m in 02 03 04 05; do
		_ts="2026-${_m}-10-030000"
		printf '%s\t%s\n' "$_ts" "$(ts_to_epoch "$_ts")" >>"$_rows"
	done

	_dec=$(thin_select "24h:hourly 7d:daily" "$_now" <"$_rows")
	_keep=$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "keep"' | count_lines)
	_del=$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "del"' | count_lines)
	t_eq "hourly bucket keeps one of four same-hour backups" \
		"$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "keep" && $2 ~ /2026-08-24-11/' | count_lines)" "1"
	t_eq "the newest of the hour is the keeper" \
		"$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "keep" && $2 ~ /2026-08-24-11/ {print $2}')" \
		"2026-08-24-114500"
	t_eq "everything older than the last span is kept (no * rule)" \
		"$(printf '%s\n' "$_dec" | awk -F'\t' '$1 == "keep" && $2 ~ /2026-0[2345]/' | count_lines)" "4"
	t_eq "total decisions == rows in" "$(( _keep + _del ))" "$(count_lines < "$_rows")"

	_dec2=$(thin_select "24h:hourly 7d:daily *:none" "$_now" <"$_rows")
	t_eq "*:none deletes everything past the last span" \
		"$(printf '%s\n' "$_dec2" | awk -F'\t' '$1 == "keep" && $2 ~ /2026-0[2345]/' | count_lines)" "0"

	_dec3=$(thin_select "24h:hourly 7d:daily *:yearly" "$_now" <"$_rows")
	t_eq "*:yearly keeps one per year" \
		"$(printf '%s\n' "$_dec3" | awk -F'\t' '$1 == "keep" && $2 ~ /2026-0[2345]/' | count_lines)" "1"

	_dec4=$(thin_select "*:all" "$_now" <"$_rows")
	t_eq "*:all keeps everything" \
		"$(printf '%s\n' "$_dec4" | awk -F'\t' '$1 == "del"' | count_lines)" "0"
	rm -f "$_rows"
}

## Per-location parameters. Adversarial: the host's set_location_parameters
## must run AFTER the site's and win, the site's must still apply where the host
## says nothing, nothing set for one location may leak into my-tm, a location
## nobody names gets the _DEFAULT, HEALTH_MAX_AGE=0 must not fail and a bare
## number must not be read as seconds, and a config still setting an old name
## must stop my-tm instead of being ignored.
t_test_location_parameters() {
	printf '\nPer-location parameters\n'
	_lp_save="$CONFIG_SOURCED"; _lp_thin="$THIN_POLICY_TO_KEEP_DEFAULT"
	## a site config loaded before the tests may still carry the old name
	unset THIN_POLICY_TO_KEEP
	unset -f set_location_parameters 2>/dev/null
	THIN_POLICY_TO_KEEP_DEFAULT="24h:hourly"
	# shellcheck disable=SC2016  # writing config files: $LOCATION is their own
	{
		printf 'set_location_parameters() {\n'
		printf '\tcase "$LOCATION" in\n'
		printf '\t\tstore) THIN_POLICY_TO_KEEP="site-store"; HEALTH_MAX_AGE="0" ;;\n'
		printf '\t\tother) THIN_POLICY_TO_KEEP="site-other" ;;\n'
		printf '\tesac\n}\n'
	} >"$T_ROOT/site.conf"
	# shellcheck disable=SC2016  # same
	{
		printf 'set_location_parameters() {\n'
		printf '\tcase "$LOCATION" in\n'
		printf '\t\tstore) THIN_POLICY_TO_KEEP="host-store" ;;\n'
		printf '\tesac\n}\n'
	} >"$T_ROOT/host.conf"
	CONFIG_SOURCED=" $T_ROOT/site.conf $T_ROOT/host.conf"
	t_eq "the host's value wins over the site's" "$(loc_param store THIN_POLICY_TO_KEEP)" "host-store"
	t_eq "the site's still applies where the host says nothing" "$(loc_param store HEALTH_MAX_AGE)" "0"
	t_eq "and for a location only the site names" "$(loc_param other THIN_POLICY_TO_KEEP)" "site-other"
	t_eq "a location nobody names gets THIN_POLICY_TO_KEEP_DEFAULT" "$(loc_param nosuch THIN_POLICY_TO_KEEP)" "24h:hourly"
	loc_param store THIN_POLICY_TO_KEEP >/dev/null
	_lp_fn=undefined; command -v set_location_parameters >/dev/null 2>&1 && _lp_fn=defined
	t_eq "nothing leaks into my-tm itself" "${THIN_POLICY_TO_KEEP-unset} $_lp_fn" "unset undefined"

	## HEALTH_MAX_AGE per location, as --health reads it
	# shellcheck disable=SC2016  # writing a config file
	printf 'set_location_parameters() { case "$LOCATION" in store) HEALTH_MAX_AGE="0" ;; esac; }\n' >"$T_ROOT/age.conf"
	CONFIG_SOURCED=" $T_ROOT/age.conf"
	_lp_h=$(cmd_health store 2>&1)
	t_match "HEALTH_MAX_AGE=0 shows the age as information" "$_lp_h" "no age expected"
	t_eq "and does not fail it" "$(printf '%s\n' "$_lp_h" | count_match 'store: newest backup is')" "0"
	# shellcheck disable=SC2016  # writing a config file
	printf 'set_location_parameters() { case "$LOCATION" in store) HEALTH_MAX_AGE="48" ;; esac; }\n' >"$T_ROOT/age.conf"
	_lp_h=$(cmd_health store 2>&1)
	t_match "a HEALTH_MAX_AGE without a unit is refused, not read as seconds" "$_lp_h" "give it a unit"
	CONFIG_SOURCED=""
	_lp_h=$(cmd_health store 2>&1)
	t_match "HEALTH_MAX_AGE_DEFAULT still fails an old backup" "$_lp_h" "store: newest backup is"
	CONFIG_SOURCED="$_lp_save"; THIN_POLICY_TO_KEEP_DEFAULT="$_lp_thin"

	## an old name stops my-tm, and names what replaced it
	printf 'POST_BACKUP_PER_LOCATION="store none"\n' >"$T_ROOT/old.conf"
	_lp_out=$(MY_TM_CONFIG="$T_ROOT/old.conf" dash "$T_MYTM" --status 2>&1)
	t_match "a config setting an old name is refused" "$_lp_out" "POST_BACKUP_PER_LOCATION is no longer read"
	t_match "and the replacement is named" "$_lp_out" "use set_location_parameters instead"
	rm -f "$T_ROOT/site.conf" "$T_ROOT/host.conf" "$T_ROOT/age.conf" "$T_ROOT/old.conf"
	return 0
}

t_test_config() {
	printf '\nConfig\n'
	_f="$T_ROOT/gen.conf"
	cmd_create_config "$_f" >/dev/null
	t_true test -f "$_f"
	_stdout=$(cmd_create_config)
	t_eq "stdout form and file form are identical" "$(cat "$_f")" "$_stdout"
	## err() exits, so every "must be refused" case runs in a subshell
	if ( cmd_create_config "$_f" ) >/dev/null 2>&1; then
		t_bad "--create-config must refuse to overwrite" ""
	else
		t_ok "--create-config refuses to overwrite"
	fi
	t_true sh -n "$_f"
	t_match "the default config carries no site-specific values" \
		"$(count_match 'TM_GROUP=""' < "$_f")" "1"
}

## One shared location list. Adversarial: a per-user copy used to be written
## whenever the shared dir was not writable, and read back only for that user --
## so a location added that way looked registered while no daemon (all root)
## ever saw it. It must not be written, must not be read, and must not vanish
## silently either.
t_test_one_shared_location_list() {
	printf '\nOne shared location list\n'
	_sl_cd="$CACHE_DIR"; _sl_cu="$CACHE_DIR_USER"

	t_eq "the list is the shared one, whoever runs my-tm" \
		"$(locations_file)" "$CACHE_DIR/locations.tsv"

	## a per-user list is not read ...
	mkdir -p "$CACHE_DIR_USER"
	printf 'mine\t%s/store\t\n' "$T_ROOT" >"$CACHE_DIR_USER/locations.tsv"
	t_eq "a per-user list is not read" \
		"$(locations_registered | count_match 'mine')" "0"
	## ... and not passed off as a location
	t_eq "so it is no location either" "$(locations_all | count_match 'mine')" "0"
	## ... but it is named, with what to do about it
	_sl_out=$(cmd_status 2>&1)
	t_match "--status names the file that is no longer read" "$_sl_out" "no longer read"
	t_match "and how to add it again as root" "$_sl_out" "add $T_ROOT/store mine"
	rm -f "$CACHE_DIR_USER/locations.tsv"
	t_eq "with no such file, --status says nothing about it" \
		"$(cmd_status 2>&1 | count_match 'no longer read')" "0"

	## writing it where it is not ours to write: refuse, and name the command
	_sl_ro="$T_ROOT/ro-cache"
	mkdir -p "$_sl_ro"; : >"$_sl_ro/locations.tsv"; chmod 0444 "$_sl_ro/locations.tsv"
	CACHE_DIR="$_sl_ro"
	_sl_err=$( ( cmd_add "$T_ROOT/store" newloc ) 2>&1 >/dev/null )
	t_match "--add refuses a list it cannot write" "$_sl_err" "needs root"
	t_match "and names the command to run again" "$_sl_err" "add $T_ROOT/store newloc"
	t_eq "and wrote nothing" "$(count_match 'newloc' < "$_sl_ro/locations.tsv")" "0"
	chmod 0644 "$_sl_ro/locations.tsv"; rm -rf "$_sl_ro"
	CACHE_DIR="$_sl_cd"; CACHE_DIR_USER="$_sl_cu"
	return 0
}

## A handle is a file name and a TAB-separated field, not free text.
## Adversarial: --add took ANY handle, so "a/b" would have written outside
## $FIRMLINK, a tab would have split the row into different columns, and "-f"
## would have read as an option wherever the handle is passed on.
t_test_handle_characters() {
	printf '\nHandles are file names, and checked as such\n'
	_hc_f=$(locations_file)
	_hc_before=$(cat "$_hc_f" 2>/dev/null)
	for _hc_bad in "a/b" "with space" "-dash" ".dot" "tab$(printf '\t')ped" 'semi;colon' 'star*'; do
		_hc_out=$( ( cmd_add "$T_ROOT/store" "$_hc_bad" ) 2>&1 >/dev/null )
		t_match "refused: '$_hc_bad'" "$_hc_out" "cannot be a handle"
	done
	t_eq "and none of them was written" "$(cat "$_hc_f" 2>/dev/null)" "$_hc_before"

	## the one the design needs
	cmd_add "$T_ROOT/store" "horse@ada" >/dev/null 2>&1
	t_eq "horse@ada is a handle" \
		"$(locations_registered | awk -F'\t' '$1 == "horse@ada"' | count_lines)" "1"
	## ... and it works as a location, file names and all
	t_eq "and resolves to its target" "$(loc_target 'horse@ada')" "$T_ROOT/store"
	printf '%s\n' "$_hc_before" | cache_write_locations
	return 0
}

t_test_locations() {
	printf '\nLocations (--add / --forget)\n'
	_f="$T_ROOT/cache/locations.tsv"
	_before=$(cat "$_f")
	mkdir -p "$T_ROOT/store2"
	( cmd_add "$T_ROOT/store2" "extra" ) >/dev/null 2>&1
	t_match "the new line appears" "$(cat "$_f")" "^extra	"
	t_eq "the rest of the file is byte-identical" \
		"$(grep -v '^extra	' "$_f")" "$_before"
	if ( cmd_add "$T_ROOT/store2" "extra" ) >/dev/null 2>&1; then
		t_bad "a duplicate handle must be refused" ""
	else
		t_ok "a duplicate handle is refused"
	fi
	if ( cmd_add "$T_ROOT/store2" "k7f2q9" ) >/dev/null 2>&1; then
		t_bad "a handle in the ID alphabet must be refused" ""
	else
		t_ok "a handle in the ID alphabet is refused"
	fi
	if ( cmd_add "$T_ROOT/does-not-exist" "nope" ) >/dev/null 2>&1; then
		t_bad "a bad folder must be refused" ""
	else
		t_ok "a bad folder is refused before any write"
	fi
	t_eq "nothing was written for the refused adds" \
		"$(awk -F'\t' '$1 == "nope" || $1 == "k7f2q9"' "$_f" | count_lines)" "0"
	( cmd_forget "extra" ) >/dev/null 2>&1
	t_eq "--forget removes exactly its line" "$(cat "$_f")" "$_before"
	if ( cmd_forget "nosuch" ) >/dev/null 2>&1; then
		t_bad "--forget must refuse an unknown handle" ""
	else
		t_ok "--forget refuses an unknown handle"
	fi
}

t_test_ladder() {
	printf '\nDispatch ladder\n'
	t_eq "a handle is rung 2"        "$(classify_one store  | cut -f1)" "loc"
	t_eq "a glob is rung 4"          "$(classify_one 'inv*.pdf' | cut -f1)" "glob"
	t_eq "a glob with a slash stays a glob" \
	                                 "$(classify_one '/tmp/inv*.pdf' | cut -f1)" "glob"
	t_eq "a slashed word is a path"  "$(classify_one '/etc/hosts' | cut -f1)" "path"
	t_eq "a bare unknown name is a search" \
	                                 "$(classify_one 'report-xyz.odt' | cut -f1)" "glob"
	_probe="$T_ROOT/inpwd.txt"; : >"$_probe"
	_old="$PWD"; cd "$T_ROOT" || return 1
	t_eq "a name that exists in \$PWD is a path" "$(classify_one inpwd.txt | cut -f1)" "path"
	cd "$_old" || return 1
	t_eq "a path inside a known store is rung 3" \
		"$(classify_one "$T_ROOT/store/2026-08-23-101010.inprogress" | cut -f1)" "loc"
	rm -f "$_probe"
}

t_test_mount_records() {
	printf '\nMount bookkeeping\n'
	_mp="$T_ROOT/mount/.mnt/store/2026-08-20-155805"
	mkdir -p "$_mp"
	mount_record_add "abc123" "store" "$_mp" 900 "transient"
	t_eq "the record is written" "$(mounts_read_all | awk -F'\t' -v m="$_mp" '$3 == m' | count_lines)" "1"
	_ttl=$(mounts_read_all | awk -F'\t' -v m="$_mp" '$3 == m {print $5}')
	t_eq "the TTL is stored"  "$_ttl" "900"
	_flags=$(mounts_read_all | awk -F'\t' -v m="$_mp" '$3 == m {print $7}')
	t_eq "the flag is stored" "$_flags" "transient"
	mount_record_add "abc123" "store" "$_mp" 1800 ""
	t_eq "re-recording replaces rather than duplicates" \
		"$(mounts_read_all | awk -F'\t' -v m="$_mp" '$3 == m' | count_lines)" "1"
	## nothing is really mounted, so the sweep must drop the record, not act on it
	sweep >/dev/null 2>&1
	t_eq "the sweep drops a record with no real mount behind it" \
		"$(mounts_read_all | awk -F'\t' -v m="$_mp" '$3 == m' | count_lines)" "0"
	t_eq "and it never called umount" \
		"$(count_match 'umount ' < "$(t_calls)")" "0"
	mount_record_drop "$_mp"
}

t_test_version_store() {
	printf '\nVersion store\n'
	printf '2026-08-20-155805\t/Users/x/a.txt\t111\t222\t333\n' | vs_put store
	_hit=$(vs_lookup store 2026-08-20-155805 /Users/x/a.txt)
	t_eq "a stored fact comes back" "$_hit" "$(printf '111\t222\t333')"
	if vs_lookup store 2026-08-20-155805 /Users/x/missing.txt >/dev/null 2>&1; then
		t_bad "an unknown path must miss" ""
	else
		t_ok "an unknown path misses"
	fi
	printf '2026-08-21-155805\t/Users/x/a.txt\t-\t-\t-\n' | vs_put store
	t_eq "a verified absence is a fact too" \
		"$(vs_lookup store 2026-08-21-155805 /Users/x/a.txt)" "$(printf -- '-\t-\t-')"
	t_eq "two snapshots are covered for this path" "$(vs_covered_count store)" "2"
}

t_test_atomic() {
	printf '\nAtomic writes\n'
	_f="$T_ROOT/atomic.txt"
	printf 'first\n' | atomic_write "$_f"
	t_eq "content lands" "$(cat "$_f")" "first"
	printf 'second\n' | atomic_write "$_f"
	t_eq "content is replaced" "$(cat "$_f")" "second"
	t_eq "no temp files are left behind" \
		"$(find "$T_ROOT" -name '.my-tm.*' | count_lines)" "0"

	## REGRESSION: mktemp makes 0600 and mv carried that onto every target, so
	## the shared cache was unreadable to the group it is shared with. The
	## directory decides now.
	_ad="$T_ROOT/grp"; mkdir -p "$_ad"; chmod 0750 "$_ad"
	printf 'x\n' | atomic_write "$_ad/f"
	t_eq "in a group-readable directory the group may read it" \
		"$(stat -f '%Sp' "$_ad/f")" "-rw-r-----"
	chmod 0600 "$_ad/f"
	printf 'y\n' | atomic_write "$_ad/f"
	t_eq "a rewrite restores that, instead of keeping 0600" \
		"$(stat -f '%Sp' "$_ad/f")" "-rw-r-----"
	_pd="$T_ROOT/priv"; mkdir -p "$_pd"; chmod 0700 "$_pd"
	printf 'z\n' | atomic_write "$_pd/f"
	t_eq "in a private directory it stays private" \
		"$(stat -f '%Sp' "$_pd/f")" "-rw-------"
	rm -rf "$_ad" "$_pd"
	## and what my-tm writes by plain redirection is never world-readable.
	## Adversarial: start the script under launchd's permissive umask 022 --
	## an in-process check inherits whatever the caller's umask happens to be,
	## and passed without the fix whenever that was already restrictive.
	# shellcheck disable=SC2016  # $0 and $1 belong to the child shell
	(umask 022; /bin/dash -c '"$0" --create-config "$1" >/dev/null 2>&1' "$T_MYTM" "$T_ROOT/umask.conf")
	t_eq "a file written by plain redirect is not world-readable, even under umask 022" \
		"$(stat -f '%Sp' "$T_ROOT/umask.conf" 2>/dev/null | cut -c8-10)" "---"
	rm -f "$T_ROOT/umask.conf"
}

t_test_plists() {
	printf '\nJob plists\n'
	_out=$(plist_schedule "on-boot")
	t_match "on-boot -> RunAtLoad" "$_out" "RunAtLoad"
	_out=$(plist_schedule "1800s")
	t_match "1800s -> StartInterval" "$_out" "<integer>1800</integer>"
	_out=$(plist_schedule "03:30")
	t_match "HH:MM -> StartCalendarInterval" "$_out" "StartCalendarInterval"
	t_match "the hour is parsed"   "$_out" "<key>Hour</key><integer>3</integer>"
	t_match "the minute is parsed" "$_out" "<key>Minute</key><integer>30</integer>"
	_out=$(plist_schedule "Mon 03:30")
	t_match "a weekday is parsed" "$_out" "<key>Weekday</key><integer>1</integer>"
	_out=$(plist_schedule "on-boot 03:30 15:30")
	t_match "combined: RunAtLoad survives" "$_out" "RunAtLoad"
	t_eq "combined: two calendar entries" \
		"$(printf '%s' "$_out" | count_match '<key>Hour</key>')" "2"

	## the whole plist must lint
	_pl="$T_ROOT/test.plist"
	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
		printf '<plist version="1.0">\n<dict>\n'
		printf '\t<key>Label</key>\n\t<string>test</string>\n'
		plist_schedule "on-boot Mon 03:30"
		printf '</dict>\n</plist>\n'
	} >"$_pl"
	if plutil -lint "$_pl" >/dev/null 2>&1; then
		t_ok "the generated plist lints"
	else
		t_bad "the generated plist does not lint" "$(plutil -lint "$_pl" 2>&1)"
	fi
}

t_test_rm_dryrun() {
	printf '\n--rm (dry run only: no test ever deletes a snapshot)\n'
	snapshots_cache_invalidate
	_rows=$(snapshots_get store)
	_id=$(printf '%s\n' "$_rows" | head -n 1 | awk -F'\t' '{print $4}')
	_ts=$(printf '%s\n' "$_rows" | head -n 1 | awk -F'\t' '{print $2}')
	if [ -z "$_id" ]; then
		t_skip "--rm dry run" "no snapshots enumerated from the stub"
		return 0
	fi
	: >"$(t_calls)"
	_out=$( ( cmd_rm "$_id" ) 2>&1 )
	t_match "the dry run names the snapshot" "$_out" "$_id"
	t_match "it says it is a dry run" "$_out" "dry run"
	t_match "the dry run shows the exact command line that would run" \
		"$_out" "would run: tmutil delete -d $T_ROOT/store -t $_ts\$"
	t_eq "nothing was deleted without the word go" \
		"$(count_match 'tmutil delete' < "$(t_calls)")" "0"

	## with `go`, a backup-store snapshot needs root: unprivileged must refuse,
	## and must still not have run anything.
	: >"$(t_calls)"
	_out=$( ( cmd_rm "$_id" go ) 2>&1 )
	t_match "with go but without root it refuses" "$_out" "needs root"
	t_eq "and still nothing was deleted" \
		"$(count_match 'tmutil delete' < "$(t_calls)")" "0"
}

t_test_help() {
	printf '\n--help and command coverage\n'
	_u=$(usage)
	## the usage line names the tool as it was INVOKED (my-tm, my-tm.sh, ...)
	t_match "usage starts with the standard line" "$_u" "^usage: $US \[OPTIONS\]"
	t_match "--mount --help explains the TTL" "$(usage_mount)" "CANNOT BE DELETED"
	## every --command named in the usage block must be dispatchable
	_missing=""
	for _c in $(printf '%s\n' "$_u" | sed -nE 's/^ *(--[a-z-]+).*/\1/p' | sort -u); do
		case "$_c" in
			--all|--limit|--json|--force|--verbose|--debug|--deepdebug|--source) continue ;;
		esac
		## a command is "dispatchable" when some case arm names it -- either in
		## the command switch or, like --config, in the option parser
		grep -qE "^[[:space:]]*(--[a-z-]+\|)*${_c}[)|=]" "$0" 2>/dev/null ||
			_missing="$_missing $_c"
	done
	if [ -z "$_missing" ]; then
		t_ok "every command in the usage block is dispatchable"
	else
		t_bad "commands in --help with no dispatch arm" "$_missing"
	fi
}

t_test_paths() {
	printf '\nPath helpers\n'
	t_eq "a Data-volume path loses its prefix" \
		"$(path_in_volume /System/Volumes/Data/Users/x/a.txt)" "/Users/x/a.txt"
	t_eq "an ordinary path is unchanged" \
		"$(path_in_volume /Users/x/a.txt)" "/Users/x/a.txt"
	t_eq "abs_path leaves absolutes alone" "$(abs_path /tmp/x)" "/tmp/x"
	mkdir -p "$T_ROOT/wtest"
	chmod 0755 "$T_ROOT/wtest"
	if path_is_user_writable "$T_ROOT/wtest"; then
		t_ok "a group-writable ancestor is detected (temp dirs are)"
	else
		t_ok "a 0755 dir under a private root is not group-writable"
	fi
	chmod 0777 "$T_ROOT/wtest"
	t_true path_is_user_writable "$T_ROOT/wtest"
}

t_test_local_snapshots() {
	printf '\nLocal snapshots\n'
	if [ "${T_WITH_SNAPSHOTS:-0}" != "1" ]; then
		t_skip "taking a real local snapshot" "needs --run-tests --with-snapshots"
		return 0
	fi
	_sd="$(t_stub_dir):"
	PATH="${PATH#"$_sd"}"
	export PATH
	_before=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null | count_match 'com.apple')
	cmd_local_snap >/dev/null 2>&1
	_after=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null | count_match 'com.apple')
	if [ "$_after" -gt "$_before" ]; then
		t_ok "a local snapshot was created"
		_new=$(tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null |
			sed -nE 's/^com\.apple\.TimeMachine\.([0-9-]+)\.local$/\1/p' | sort | tail -n 1)
		if tmutil deletelocalsnapshots "$_new" >/dev/null 2>&1; then
			t_ok "and deleted again"
		else
			t_bad "could not delete $_new" ""
		fi
	else
		t_bad "no local snapshot appeared" ""
	fi
	PATH="$(t_stub_dir):$PATH"
	export PATH
}

## REGRESSION: a Time Machine destination that is ejected has no "Mount Point:"
## line in tmutil destinationinfo. It used to be dropped on the floor, so the
## backup disk silently VANISHED from --status -- hiding the one failure the
## tool exists to report. It must be listed, marked "?", with its last known
## snapshot table intact.
## Detection is not a matter of taste, and it must not double-list a disk.
## Adversarial: the stub reports TestStore at the very path registered as
## "store", so a dedup that only compares handles lists the same disk twice --
## once as store, once as teststore -- and every count, sweep and health row
## then treats one disk as two.
t_test_detection_dedup() {
	printf '\nDetection, deduplicated by target\n'
	_dd=$(locations_all)
	t_eq "the registered handle is listed once" "$(printf '%s\n' "$_dd" | awk -F'\t' '$1 == "store"' | count_lines)" "1"
	t_eq "and the same disk is not listed again under its volume name" \
		"$(printf '%s\n' "$_dd" | awk -F'\t' -v t="$T_ROOT/store" '$2 == t' | count_lines)" "1"
	t_eq "a destination that is not registered still shows up" \
		"$(printf '%s\n' "$_dd" | awk -F'\t' '$1 == "ejectedstore"' | count_lines)" "1"
	## and no config knob decides any of this. The NAME still appears -- the
	## refusal reads it through eval -- so what must be zero is any EXPANSION
	## of it. The pattern is built in two pieces so this very line, and the
	## refusal's own, cannot match themselves.
	if [ -r "$T_MYTM" ]; then
		_dd_v='\$\{?'"AUTODETECT_LOCAL_TM_BACKUPS"
		t_eq "no setting gates detection any more" "$(grep -cE "$_dd_v" "$T_MYTM")" "0"
	else
		t_skip "no setting gates detection" "not a readable checkout"
	fi
	return 0
}

t_test_ejected_destination() {
	printf '\nEjected / unattached destinations\n'
	_d=$(destinations_scan)
	t_eq "both destinations are reported, mounted or not" \
		"$(printf '%s\n' "$_d" | count_lines)" "2"
	t_match "the ejected one is present" "$_d" "EjectedStore"
	t_eq "and stands in with its conventional path" \
		"$(printf '%s\n' "$_d" | awk -F'\t' '$1 == "EjectedStore" {print $2}')" \
		"/Volumes/EjectedStore"
	t_eq "its destination ID survives, so snapshot IDs stay stable" \
		"$(printf '%s\n' "$_d" | awk -F'\t' '$1 == "EjectedStore" {print $3}')" \
		"99999999-8888-7777-6666-555555555555"

	_all=$(locations_all)
	t_match "it becomes a location" "$_all" "ejectedstore"

	## give it a remembered snapshot, as a real cache would have
	_cf=$(snapshots_cache_file)
	printf 'ejectedstore\t2026-08-20-155805\t1755698285\tzz1234\t-\t100\t200\t300\t-\tok\tData\n' | t_cache_add
	t_eq "the cache-only reader finds it without touching the disk" \
		"$(snapshots_cached_only ejectedstore | count_lines)" "1"

	_st=$(cmd_status 2>&1)
	t_match "--status still lists the detached disk" "$_st" "ejectedstore"
	t_match "with its last known snapshot count" "$_st" "ejectedstore.* 1 "
	t_match "and marked as not-current" "$_st" "?"

	_ls=$(cmd_ls ejectedstore 2>&1)
	t_match "--ls falls back to the remembered table" "$_ls" "2026-08-20_1558.05"
	t_match "and says why it may be out of date" "$_ls" "not attached"

	## this row HAS an ADDED figure, so a median is owed
	t_match "a location with size data still reports its median" "$_ls" "median"

	## local snapshots carry no manifest and therefore no ADDED at all:
	## the footer must stay silent rather than report a median of zero
	_lsl=$(cmd_ls local 2>&1)
	t_eq "no ADDED data -> no median claimed" \
		"$(printf '%s\n' "$_lsl" | count_match 'median')" "0"
	t_match "but the snapshots are still listed" "$_lsl" "2026-08-23"


	## REGRESSION: detached AND nothing remembered used to print NOTHING at
	## all, which reads as "this disk has no backups" -- the opposite of the
	## truth. It must say why and what to do about it.
	cache_read_checked "$_cf" 2>/dev/null | grep -v '^ejectedstore' | cache_write_checked "$_cf"
	_empty=$(cmd_ls ejectedstore 2>&1)
	t_ne "an empty answer is never silent" "$_empty" ""
	t_match "it says the disk is away" "$_empty" "not attached"
	t_match "and what to do about it" "$_empty" "refresh"

}

## REGRESSION: a local snapshot IS the volume root. my-tm used to mount it one
## level up and then look for <mnt>/Data/..., a path that cannot exist -- so
## every file in every local snapshot came back "absent". Silently wrong
## answers about whether a backup holds your file is the worst failure this
## tool has, so the path arithmetic is pinned here.
t_test_volume_paths() {
	printf '\nVolume paths inside a mounted snapshot\n'
	_ts=2026-08-20-155805
	t_eq "a backup snapshot has the <ts>.backup wrapper" \
		"$(snap_volume_root_at /m/base store "$_ts" Data)" \
		"/m/base/$_ts.backup/Data"
	t_eq "a local snapshot mounted one level up gets the volume appended" \
		"$(snap_volume_root_at /m/local/$_ts local "$_ts" Data)" \
		"/m/local/$_ts/Data"
	t_eq "a local snapshot mounted AT the volume root is left alone" \
		"$(snap_volume_root_at /m/local/$_ts/Data local "$_ts" Data)" \
		"/m/local/$_ts/Data"
	_exp=$(mnt_volume_path_expected local "$_ts" Data)
	t_eq "so the volume name is never doubled" \
		"$(printf '%s' "$_exp" | count_match '/Data/Data')" "0"
	t_match "and the expected path ends at the volume" "$_exp" "/Data\$"

	## REGRESSION: --show advertised a browsable path even when the tree had
	## never been built, sending the reader to a directory that is not there
	_rows=$(snapshots_get store)
	_id=$(printf '%s\n' "$_rows" | head -n 1 | awk -F'\t' '{print $4}')
	if [ -n "$_id" ]; then
		_sh=$(cmd_show "$_id" 2>&1)
		t_match "an unbuilt tree says how to build it" "$_sh" "refresh"
	fi

	## REGRESSION: macOS mounts local snapshots itself, and --mount reuses
	## those. It used to print our tree path regardless, sending the reader to
	## an empty directory while the files sat somewhere else entirely.
	if true; then
		_sys=/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/h/2026-08-20-155805/Data
		t_eq "a system-mounted local snapshot is reported where it really is" \
			"$(snap_volume_root_at "$_sys" local 2026-08-20-155805 Data)" "$_sys"
	fi
}

## REGRESSION: without --install an ordinary user cannot create /var/lib/my-tm,
## so every mount failed and --lookup answered "0 versions" -- indistinguishable
## from "your file was never backed up".
t_test_mount_root_fallback() {
	printf '\nMount root without --install\n'
	_saved="$MOUNT_ROOT"
	MOUNT_ROOT="$T_ROOT/mount"
	t_eq "a writable mount root is used as configured" \
		"$(mount_root_resolve)" "$T_ROOT/mount"
	mkdir -p "$T_ROOT/nowrite/mount"
	chmod 0555 "$T_ROOT/nowrite/mount"
	MOUNT_ROOT="$T_ROOT/nowrite/mount"
	t_eq "an unwritable one falls back to the per-user overlay" \
		"$(mount_root_resolve)" "$CACHE_DIR_USER/mount"
	MOUNT_ROOT="$T_ROOT/nowrite/mount/cannot/be/made"
	t_eq "and so does one that cannot be created" \
		"$(mount_root_resolve)" "$CACHE_DIR_USER/mount"
	chmod 0755 "$T_ROOT/nowrite/mount"
	MOUNT_ROOT="$_saved"
}

## REGRESSION: a recorded stat is a permanent fact only if my-tm looked in the
## right place. When a path bug recorded false absences, they were served
## forever without ever being re-checked.
t_test_version_store_generation() {
	printf '\nVersion store generation\n'
	_f=$(vs_file)
	need_dir "$(dirname "$_f")"
	printf 'store\t2026-08-20-155805\t/x/y.txt\t-\t-\t-\n' >"$_f"
	printf '1\n' >"$(dirname "$_f")/versions.gen"
	t_eq "a row from an older generation is not trusted" \
		"$(vs_lookup store 2026-08-20-155805 /x/y.txt >/dev/null 2>&1 && echo served || echo discarded)" \
		"discarded"
	t_eq "the stale store file is gone" "$([ -f "$_f" ] && echo present || echo gone)" "gone"
	printf '2026-08-20-155805\t/x/y.txt\t111\t222\t333\n' | vs_put store
	t_eq "a freshly written store carries the current generation" \
		"$(cat "$(dirname "$_f")/versions.gen" 2>/dev/null)" "$VS_GENERATION"
	t_eq "and its rows are served again" \
		"$(vs_lookup store 2026-08-20-155805 /x/y.txt)" "$(printf '111\t222\t333')"
	rm -f "$_f"
}

## REGRESSION: local snapshots are purgeable -- macOS deletes them at any age.
## A cached list produced mounts of snapshots that no longer existed.
## Commands that change a store re-read THAT store. Adversarial: --rm, --thin,
## --backup and --refresh must each keep the last known table of a disk that is
## away (nothing can read it again until the disk is back), and still drop the
## stale table of the store they changed. Nothing is deleted: tmutil and
## diskutil are the stubs, and the test refuses to run without them.
t_test_commands_keep_other_tables() {
	printf '\nCommands re-read only the store they changed\n'
	case "$(command -v tmutil)" in
		"$(t_stub_dir)"/*) : ;;
		*) t_skip "commands keep other tables" "tmutil is not the stub"; return 0 ;;
	esac
	_ck_cf=$(snapshots_cache_file)
	_ck_lf="$T_ROOT/cache/locations.tsv"
	cp -p "$_ck_lf" "$T_ROOT/locations.ck"
	## no ssh fixture: resolving an ID and --refresh read every location
	awk -F'\t' '$1 != "remote"' "$T_ROOT/locations.ck" >"$_ck_lf"
	## --refresh also drops the version store; put it back afterwards
	for _ck_d in "$T_ROOT/cache" "$T_ROOT/ucache"; do
		[ -f "$_ck_d/index/versions.tsv" ] && cp -p "$_ck_d/index/versions.tsv" "$_ck_d/index/versions.tsv.ck"
	done
	_ck_away() {
		snapshots_cache_drop awaydisk
		printf 'awaydisk\t2026-01-01-000000\t1767225600\taway01\t-\t-\t-\t-\t-\tok\tData\n' | t_cache_add
	}
	_ck_count() {
		cache_read_checked "$_ck_cf" 2>/dev/null | awk -F'\t' -v l="$1" '$1 == l { n++ } END { print n + 0 }'
	}

	## --rm <ID> go, as root: is_root answers yes inside the subshell only
	_ck_id=$(snapshots_get store 2>/dev/null | head -n 1 | awk -F'\t' '{print $4}')
	if [ -n "$_ck_id" ]; then
		_ck_away
		( is_root() { return 0; }; cmd_rm "$_ck_id" go ) >/dev/null 2>&1
		t_eq "--rm go keeps the away disk's table" "$(_ck_count awaydisk)" "1"
		t_eq "and drops the table of the store it deleted from" "$(_ck_count store)" "0"
	else
		t_skip "--rm go keeps other tables" "no snapshots enumerated from the stub"
	fi

	## --thin <LOCATION> <POLICY> go
	snapshots_get store >/dev/null 2>&1
	_ck_away
	cmd_thin store "*:none" go >/dev/null 2>&1
	t_eq "--thin go keeps the away disk's table" "$(_ck_count awaydisk)" "1"
	t_eq "and drops the table of the store it thinned" "$(_ck_count store)" "0"

	## --backup start: the disk just backed up is re-read before POST_BACKUP
	printf 'testvol\t/Volumes/TestVol\t\n' >>"$_ck_lf"
	printf 'testvol\t2025-01-01-000000\t1735689600\tstale1\t-\t-\t-\t-\t-\tok\tData\n' | t_cache_add
	_ck_away
	## a subshell on purpose: cmd_backup's EXIT trap ends it, and these settings
	## must not outlive it
	# shellcheck disable=SC2030  # the changes are meant to stay in the subshell
	( is_root() { return 0; }
	  LOCKFILE="$T_ROOT/backup.lock"; BACKUP_VOLUME="TestVol"; unset BACKUP_VOLUME_RESOLVED
	  POST_BACKUP_DEFAULT="none"; NOTIFY_BEGIN=0; NOTIFY_END=0; NO_EJECT_FLAGFILE="$T_ROOT/no-eject.ck"
	  cmd_backup start ) >/dev/null 2>&1
	t_eq "--backup keeps the away disk's table" "$(_ck_count awaydisk)" "1"
	t_eq "and drops the stale table of the disk it backed up" "$(_ck_count testvol)" "0"

	## --refresh <LOCATION>, then --refresh, with the away disk registered
	printf 'awaydisk\t%s/gone-disk\t\n' "$T_ROOT" >>"$_ck_lf"
	_ck_away
	( tm_refresh() { :; }; cmd_refresh store ) >/dev/null 2>&1
	t_eq "--refresh store keeps the away disk's table" "$(_ck_count awaydisk)" "1"
	_ck_away
	( tm_refresh() { :; }; cmd_refresh ) >/dev/null 2>&1
	t_eq "--refresh keeps the away disk's table" "$(_ck_count awaydisk)" "1"

	mv -f "$T_ROOT/locations.ck" "$_ck_lf"
	snapshots_cache_drop awaydisk
	snapshots_cache_drop testvol
	for _ck_d in "$T_ROOT/cache" "$T_ROOT/ucache"; do
		[ -f "$_ck_d/index/versions.tsv.ck" ] && mv -f "$_ck_d/index/versions.tsv.ck" "$_ck_d/index/versions.tsv"
	done
	rm -f "$T_ROOT/backup.lock" "$T_ROOT/no-eject.ck"
	return 0
}

## The maintenance daemon re-reads what changed. Adversarial: a run must not
## throw away the last known table of a disk that is away (nothing can read it
## again until the disk is back), must not rebuild local when no local snapshot
## changed, and must rebuild it when one did.
t_test_maintenance_keeps_other_tables() {
	printf '\nThe maintenance daemon re-reads only what changed\n'
	_mk_cf=$(snapshots_cache_file)
	_mk_log="$T_ROOT/refreshed.log"
	rm -f "$(cache_write_dir)"/.manifest.* "$_mk_log"
	printf 'awaydisk\t2026-01-01-000000\t1767225600\taway01\t-\t-\t-\t-\t-\tok\tData\n' | t_cache_add

	## record which trees get rebuilt, without building them
	( tm_refresh_loc() { printf '%s\n' "$1" >>"$_mk_log"; }; maint_refresh_trees ) >/dev/null 2>&1
	t_eq "the first run rebuilds local" "$(awk '$0 == "local" { n++ } END { print n + 0 }' "$_mk_log")" "1"
	t_eq "and keeps the table of a disk that is away" \
		"$(cache_read_checked "$_mk_cf" 2>/dev/null | count_match 'away01')" "1"

	: >"$_mk_log"
	# shellcheck disable=SC2329  # overrides my-tm's now_epoch, which maint_refresh_trees calls
	( now_epoch() { echo $(( $(date '+%s') + 120 )); }
	  tm_refresh_loc() { printf '%s\n' "$1" >>"$_mk_log"; }; maint_refresh_trees ) >/dev/null 2>&1
	t_eq "a second run with no new local snapshot does not rebuild local" \
		"$(awk '$0 == "local" { n++ } END { print n + 0 }' "$_mk_log")" "0"

	## a local snapshot appears, one more daemon interval later
	_mk_stub="$(t_stub_dir)/tmutil"
	cp -p "$_mk_stub" "$T_ROOT/tmutil.orig"
	# shellcheck disable=SC2016  # writing a script: its $1 and $@ are the stub's own
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" = "listlocalsnapshots" ]; then\n'
		printf '\t"%s" "$@"\n' "$T_ROOT/tmutil.orig"
		printf '\tprintf "com.apple.TimeMachine.2026-08-24-010101.local\\n"\n'
		printf '\texit 0\n'
		printf 'fi\n'
		printf 'exec "%s" "$@"\n' "$T_ROOT/tmutil.orig"
	} >"$_mk_stub"
	chmod 0755 "$_mk_stub"
	: >"$_mk_log"
	# shellcheck disable=SC2329  # overrides my-tm's now_epoch, which maint_refresh_trees calls
	( now_epoch() { echo $(( $(date '+%s') + 240 )); }
	  tm_refresh_loc() { printf '%s\n' "$1" >>"$_mk_log"; }; maint_refresh_trees ) >/dev/null 2>&1
	t_eq "a new local snapshot makes the next run rebuild local" \
		"$(awk '$0 == "local" { n++ } END { print n + 0 }' "$_mk_log")" "1"
	t_eq "and the away disk's table is still there" \
		"$(cache_read_checked "$_mk_cf" 2>/dev/null | count_match 'away01')" "1"

	mv -f "$T_ROOT/tmutil.orig" "$_mk_stub"
	rm -f "$_mk_log" "$(cache_write_dir)"/.manifest.*
}

t_test_local_list_never_cached() {
	printf '\nLocal snapshot list is never served from cache\n'
	_cf=$(snapshots_cache_file)
	snapshots_get local >/dev/null 2>&1
	printf 'local\t1999-01-01-000000\t915148800\tgone01\t-\t-\t-\t-\t-\tok\tData\n' | t_cache_add
	_rows=$(snapshots_get local)
	t_eq "a snapshot macOS no longer lists is not reported" \
		"$(printf '%s\n' "$_rows" | count_match '1999-01-01')" "0"
	t_match "while the live ones still are" "$_rows" "2026-08-23"
}

## REGRESSION: a destination that is attached but NOT mounted was skipped in
## silence, so my-tm answered "no backups" about a disk that was sitting right
## there. It is mounted, used, and put back exactly as it was found -- and
## anything that was already mounted is never touched.
t_test_auto_mount_destinations() {
	printf '\nAttached but unmounted destinations\n'
	_saved="$AUTO_MOUNT_DESTINATIONS"
	_savedv="$TRANSIENT_VOLUMES"
	TRANSIENT_VOLUMES="$T_ROOT/volumes.list"
	rm -f "$TRANSIENT_VOLUMES"

	t_eq "an unmounted volume is recognised" "$(volume_state UnmountedStore)" "unmounted"
	t_eq "a mounted one is recognised"       "$(volume_state MountedStore)"   "mounted"
	t_eq "an absent one is recognised"       "$(volume_state NoSuchThing)"    "absent"

	## a location pointing at a volume that is attached but not mounted
	printf 'unmounted\t/Volumes/UnmountedStore\t\n' >>"$T_ROOT/cache/locations.tsv"
	AUTO_MOUNT_DESTINATIONS=1
	: >"$(t_calls)"
	loc_open unmounted >/dev/null 2>&1
	t_eq "it is mounted" "$(count_match 'diskutil mount UnmountedStore' < "$(t_calls)")" "1"
	t_eq "and remembered as ours to put back" \
		"$(count_match 'UnmountedStore' < "$TRANSIENT_VOLUMES")" "1"

	: >"$(t_calls)"
	cleanup_volumes >/dev/null 2>&1
	t_eq "and unmounted again when the command is done" \
		"$(count_match 'diskutil unmount UnmountedStore' < "$(t_calls)")" "1"
	t_eq "the list is cleared" "$([ -f "$TRANSIENT_VOLUMES" ] && echo left || echo gone)" "gone"

	## the important half: what we did NOT mount, we must NOT unmount
	printf 'alreadyup\t/Volumes/MountedStore\t\n' >>"$T_ROOT/cache/locations.tsv"
	: >"$(t_calls)"
	loc_open alreadyup >/dev/null 2>&1
	t_eq "an already-mounted destination is not touched" \
		"$(count_match 'diskutil mount' < "$(t_calls)")" "0"
	t_eq "and never recorded for unmounting" \
		"$([ -f "$TRANSIENT_VOLUMES" ] && echo recorded || echo clean)" "clean"

	## and it stays off when it is switched off
	AUTO_MOUNT_DESTINATIONS=0
	: >"$(t_calls)"
	loc_open unmounted >/dev/null 2>&1
	t_eq "AUTO_MOUNT_DESTINATIONS=0 mounts nothing" \
		"$(count_match 'diskutil mount' < "$(t_calls)")" "0"

	grep -vE '^(unmounted|alreadyup)\t' "$T_ROOT/cache/locations.tsv" \
		>"$T_ROOT/cache/l.tmp" && mv "$T_ROOT/cache/l.tmp" "$T_ROOT/cache/locations.tsv"
	rm -f "$TRANSIENT_VOLUMES"
	AUTO_MOUNT_DESTINATIONS="$_saved"
	TRANSIENT_VOLUMES="$_savedv"
}

## REGRESSION: tmutil verifychecksums prints nothing when a file is intact, so
## --verify used to produce no output whatsoever -- a clean bill of health and
## a check that never ran looked exactly alike.
t_test_verify_reports() {
	printf '\nChecksum verification always reports\n'
	_f="$T_ROOT/vfy_good.txt"; : >"$_f"
	_out=$( ( cmd_verify_report_probe "$_f" ) 2>&1 )
	t_match "a clean verify says so" "$_out" "no problems"
	_bad="$T_ROOT/BADSUM.txt"; : >"$_bad"
	_out=$( ( cmd_verify_report_probe "$_bad" ) 2>&1 )
	t_match "a problem is surfaced" "$_out" "problem"
	t_match "and the offending line is shown" "$_out" "!"
}

## the reporting half of --verify, without needing a real snapshot to mount
cmd_verify_report_probe() {
	_probs=0; _checked=0
	for _p in "$@"; do
		[ -e "$_p" ] || continue
		_checked=$(( _checked + 1 ))
		_out=$(tmutil verifychecksums "$_p" 2>&1)
		if [ -n "$_out" ]; then
			printf '%s\n' "$_out"
			_probs=$(( _probs + $(printf '%s\n' "$_out" | count_lines) ))
		fi
	done
	if [ "$_probs" -eq 0 ]; then
		note "$_checked path(s) verified against the checksums stored at backup time: no problems"
	else
		note "$_probs problem(s) reported -- ! is a mismatch, ? an unusable stored checksum"
	fi
	return 0
}

## REGRESSION: locate.mklocatedb and locate.concatdb live in /usr/libexec and
## are NOT on PATH. my-tm called them by bare name, so every --index run exited
## 127 per snapshot and built an empty index while reporting success.
t_test_locate_toolchain() {
	printf '\nlocate toolchain\n'
	_mk=$(locate_tool locate.mklocatedb) || _mk=""
	if [ -z "$_mk" ]; then
		t_skip "locate.mklocatedb" "not present on this system"
		return 0
	fi
	t_true test -x "$_mk"
	t_eq "a missing tool is reported, not invented" \
		"$(locate_tool no.such.tool.here >/dev/null 2>&1 && echo found || echo missing)" "missing"

	## and the primitive actually works end to end, through the resolver
	case "$_mk" in
		/usr/libexec/*)
			_db="$T_ROOT/t.db"
			printf '/a/one.txt\n/a/two.pdf\n' | LC_ALL=C sort | "$_mk" >"$_db" 2>/dev/null
			t_true test -s "$_db"
			t_eq "a glob query finds the right path" \
				"$(locate -d "$_db" '*.pdf' 2>/dev/null)" "/a/two.pdf"
			;;
		*) t_skip "index build through the real tool" "a stub is on PATH" ;;
	esac
}

## REGRESSION: an --index run marks its mount exempt from the sweep. A killed
## indexer (kill -9 cannot be trapped) left that exemption in place forever,
## pinning a snapshot against Time Machine's thinning for good.
t_test_indexer_exemption_expires() {
	printf '\nIndexer exemption dies with its process\n'
	## a pid that has certainly exited: started and reaped right here
	( exit 0 ) & _dead=$!
	wait "$_dead" 2>/dev/null

	t_true indexer_still_running "indexer" "$$"
	t_eq "a dead indexer is no longer exempt" \
		"$(indexer_still_running "indexer" "$_dead" && echo exempt || echo swept)" "swept"
	t_eq "an indexer record with no pid is not exempt" \
		"$(indexer_still_running "indexer" "" && echo exempt || echo swept)" "swept"
	t_eq "an ordinary transient mount is never exempt" \
		"$(indexer_still_running "transient" "$$" && echo exempt || echo swept)" "swept"
	t_eq "and neither is an unflagged one" \
		"$(indexer_still_running "" "$$" && echo exempt || echo swept)" "swept"
}

## REGRESSION: the collapse used to key on inode+size+mtime, on the assumption
## that an unchanged file keeps its inode across snapshots. It does not: on a
## network sparsebundle a file untouched since 2020 had a different inode in
## every one of 100 snapshots, so my-tm reported 100 distinct versions of a
## file that had never changed.
t_test_lookup_collapse() {
	printf '\nCollapsing identical versions\n'
	_in="$T_ROOT/collapse.in"
	## same size+mtime, different inode every time -- one version, not three
	{
		printf '2026-08-03-000000\t300\tc3\t1072655\t14\t1584627176\n'
		printf '2026-08-02-000000\t200\tb2\t5206697\t14\t1584627176\n'
		printf '2026-08-01-000000\t100\ta1\t6410596\t14\t1584627176\n'
	} >"$_in"
	t_eq "an unchanged file is one version, whatever the inode says" \
		"$(lookup_collapse <"$_in" | count_lines)" "1"
	t_eq "and it is the newest row that is kept" \
		"$(lookup_collapse <"$_in" | head -n 1 | cut -f1)" "2026-08-03-000000"

	## a real change must still show up
	printf '2026-08-04-000000\t400\td4\t99\t22\t1584627999\n' >"$T_ROOT/c2.in"
	cat "$_in" >>"$T_ROOT/c2.in"
	t_eq "a changed size or mtime is a new version" \
		"$(lookup_collapse <"$T_ROOT/c2.in" | count_lines)" "2"

	## present -> absent -> present must not be flattened
	{
		printf '2026-08-03-000000\t300\tc3\t1\t14\t100\n'
		printf '2026-08-02-000000\t200\tb2\t-\t-\t-\n'
		printf '2026-08-01-000000\t100\ta1\t2\t14\t100\n'
	} >"$T_ROOT/c3.in"
	t_eq "a gap in the middle is kept" \
		"$(lookup_collapse <"$T_ROOT/c3.in" | count_lines)" "3"
}

## REGRESSION: the snapshot list for a mounted store was trusted for a whole
## CACHE_TTL. Time Machine adds and thins constantly, so --status reported
## "newest backup 1h ago" three minutes after a backup, and offered snapshot
## IDs that had already been thinned away. For a store that is already open,
## the cached set is checked against reality instead of trusted.
t_test_snapshot_set_is_validated() {
	printf '\nCached snapshot set is checked against the store\n'
	_cf=$(snapshots_cache_file)
	snapshots_get store >/dev/null 2>&1
	_before=$(snapshots_get store | count_lines)
	t_ne "the fixture store has snapshots" "$_before" "0"

	## a snapshot the store does not have (thinned away since the scan)
	printf 'store\t1999-12-31-235959\t946684799\tgone99\t-\t-\t-\t-\t-\tok\tData\n' | t_cache_add
	_rows=$(snapshots_get store)
	t_eq "a snapshot that is no longer there is not offered" \
		"$(printf '%s\n' "$_rows" | count_match '1999-12-31')" "0"
	t_eq "and the real ones are still listed" \
		"$(printf '%s\n' "$_rows" | count_lines)" "$_before"

	## --status says how old its picture is, rather than implying it is current
	t_match "the footer dates the scan" "$(cmd_status 2>&1)" "scanned .* ago"
}

## REGRESSION: the design promised an "exclusive size" column from tmutil
## uniquesize. That tool refuses on an APFS Time Machine store
## ("pathInAPFSBackup"), and nothing else on macOS reports per-snapshot space,
## so the column could never be filled -- while --index paid for a second full
## walk of every snapshot to ask.
t_test_no_exclusive_size_claims() {
	printf '\nNo column claims a number macOS will not give\n'
	t_eq "--ls has no UNIQUE column" \
		"$(cmd_ls store 2>&1 | count_match 'UNIQUE')" "0"
	t_eq "--help offers no --unique" "$(usage | count_match '--unique')" "0"
	t_match "and says why there is no such column" "$(usage)" "no per-snapshot exclusive size"
	: >"$(t_calls)"
	_rows=$(snapshots_get store)
	_ts=$(printf '%s\n' "$_rows" | head -n 1 | awk -F'\t' '{print $2}')
	index_one store "$_ts" >/dev/null 2>&1
	t_eq "--index never calls uniquesize" \
		"$(count_match 'tmutil uniquesize' < "$(t_calls)")" "0"
}

## REGRESSION: SITE_CONF_DIR is used to FIND the config, but was only settable
## INSIDE a config -- which is circular, so a site that keeps its config outside
## /etc or /usr/local/etc could never be found, including the one --install had
## just written there.
t_test_site_conf_dir_from_env() {
	printf '\nConfig search honours SITE_CONF_DIR from the environment\n'
	_d="$T_ROOT/site"; mkdir -p "$_d"
	printf 'CACHE_TTL=4242\n' >"$_d/my-tm.conf"
	printf 'CACHE_TTL=1111\nID_LEN=7\n' >"$_d/my-tm.conf.GLOBAL"
	_out=$(SITE_CONF_DIR="$_d" MY_TM_CONFIG='' "$T_MYTM" -D --version 2>&1)
	t_match "the site config is found" "$_out" "$_d/my-tm.conf"
	t_match "and the shared base is sourced first" "$_out" "my-tm.conf.GLOBAL"
	_order=$(printf '%s\n' "$_out" | grep -c "GLOBAL")
	t_eq "both files are sourced" "$_order" "1"
	## base first, override on top: the local value must win
	_ttl=$(SITE_CONF_DIR="$_d" MY_TM_CONFIG='' "$T_MYTM" -D --version 2>&1 | count_match "my-tm.conf")
	t_ne "the search really ran" "$_ttl" "0"
}

## REGRESSION: a store that is not attached answered -J with an empty array and
## made every <ID> in it unresolvable, so --rm/--show/--mount all said "no such
## snapshot" about backups my-tm had listed a moment earlier. The last known
## table is the honest answer, and one place decides it for every caller.
t_test_detached_store_still_answers() {
	printf '\nA detached store answers from its last known table\n'
	_cf=$(snapshots_cache_file)
	printf 'gonestore\t/Volumes/NotHere\t\n' >>"$T_ROOT/cache/locations.tsv"
	printf 'gonestore\t2026-08-20-155805\t1755698285\tzz9999\t-\t1\t2\t3\t-\tok\tData\n' | t_cache_add

	t_eq "snapshots_get falls back to the cache" \
		"$(snapshots_get gonestore | count_lines)" "1"
	t_match "an ID in it still resolves" "$(resolve_id zz9999 2>/dev/null)" "gonestore"
	_j=$(JSON=1 cmd_ls gonestore 2>/dev/null)
	t_match "-J reports the snapshot" "$_j" "2026-08-20-155805"
	t_match "and flags that it came from cache" "$_j" '"from_cache": true'

	grep -v '^gonestore' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/l.tmp" && mv "$T_ROOT/l.tmp" "$T_ROOT/cache/locations.tsv"
	cache_read_checked "$_cf" 2>/dev/null | grep -v '^gonestore' | cache_write_checked "$_cf"
}

## REGRESSION: --rm verifies against the store before deleting. When the store
## was not attached that check found nothing and reported "already deleted" --
## a deletion that never happened, about a backup that is very likely still
## there. Unverifiable is its own answer.
t_test_rm_needs_the_store() {
	printf '\n--rm will not guess about a store it cannot see\n'
	_cf=$(snapshots_cache_file)
	printf 'gonestore\t/Volumes/NotHere\t\n' >>"$T_ROOT/cache/locations.tsv"
	printf 'gonestore\t2026-08-20-155805\t1755698285\tzz9999\t-\t1\t2\t3\t-\tok\tData\n' | t_cache_add
	: >"$(t_calls)"
	_out=$( ( cmd_rm zz9999 ) 2>&1 )
	t_match "it says it cannot verify" "$_out" "cannot verify"
	t_eq "it does not claim the snapshot is already deleted" \
		"$(printf '%s\n' "$_out" | count_match 'already deleted')" "0"
	t_eq "and nothing was run" "$(count_match 'tmutil delete' < "$(t_calls)")" "0"
	grep -v '^gonestore' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/l.tmp" && mv "$T_ROOT/l.tmp" "$T_ROOT/cache/locations.tsv"
	cache_read_checked "$_cf" 2>/dev/null | grep -v '^gonestore' | cache_write_checked "$_cf"
}

## REGRESSION: snap_mount and image_attach are called inside $(...) to capture
## the path they return. Their progress lines went to stdout, so under -V the
## captured "path" was the echo plus the path -- every mountpoint my-tm handled
## was corrupted, and only in verbose mode.
t_test_progress_goes_to_stderr() {
	printf '\nProgress never contaminates a captured value\n'
	_old="$VRB"; VRB=1
	_v=$( { run true one two; printf 'THEVALUE\n'; } 2>/dev/null )
	t_eq "run's echo stays out of the value" "$_v" "THEVALUE"
	_v=$( { why "an explanation"; printf 'THEVALUE\n'; } 2>/dev/null )
	t_eq "why stays out of the value" "$_v" "THEVALUE"
	_v=$( { msg "a milestone"; printf 'THEVALUE\n'; } 2>/dev/null )
	t_eq "msg stays out of the value" "$_v" "THEVALUE"
	## and they are still visible on stderr
	_e=$( { run true marker; } 2>&1 >/dev/null )
	t_match "but they are still shown" "$_e" "marker"
	VRB="$_old"
}

## Usage sampling is driven by backup EVENTS, and the trend it feeds must not
## extrapolate from a series too short to mean anything.
t_test_usage_trend() {
	printf '\nStore growth and capacity\n'
	_f="$(cache_write_dir)/usage.trendtest.tsv"
	need_dir "$(dirname "$_f")"

	## a single sample says nothing
	printf '1000000\t1000\t5000\t10\t2026-08-01-000000\n' >"$_f"
	t_eq "one sample yields no trend" \
		"$(usage_trend trendtest >/dev/null 2>&1 && echo yes || echo no)" "no"

	## two samples an hour apart is still too short to extrapolate from
	printf '1003600\t2000\t4000\t11\t2026-08-01-010000\n' >>"$_f"
	t_eq "too short a span yields no trend" \
		"$(usage_trend trendtest >/dev/null 2>&1 && echo yes || echo no)" "no"

	## ten days, growing 100 bytes/day, 1000 free -> 10 days left
	## (written in one go: redirecting INTO a file you are also reading
	## truncates it before the read happens)
	{
		printf '1000000\t1000\t5000\t10\t2026-08-01-000000\n'
		printf '1864000\t2000\t1000\t20\t2026-08-10-000000\n'
	} >"$_f"
	_tr=$(usage_trend trendtest)
	t_eq "growth per day"  "$(printf '%s' "$_tr" | cut -f1)" "100"
	t_eq "free space"      "$(printf '%s' "$_tr" | cut -f2)" "1000"
	t_eq "days remaining"  "$(printf '%s' "$_tr" | cut -f3)" "10"

	## a store that thins as fast as it grows must not claim a doomsday
	printf '1000000\t5000\t1000\t10\t2026-08-01-000000\n1864000\t4000\t2000\t9\t2026-08-10-000000\n' >"$_f"
	_tr=$(usage_trend trendtest)
	t_eq "shrinking gives no forecast" "$(printf '%s' "$_tr" | cut -f3)" "-1"
	rm -f "$_f"
}

## REGRESSION: snapshots get thinned and purged, but the index went on claiming
## to cover them. Their deltas cannot merely be deleted either: a delta records
## changes against the PREVIOUS walk, so dropping one from the middle makes
## every later snapshot inherit the version before it.
t_test_version_store_pruning() {
	printf '\nPruning snapshots that no longer exist\n'
	_d=$(vs_dir store)
	need_dir "$_d"
	_cov=$(index_covered_file store)
	need_dir "$(dirname "$_cov")"

	## the fixture store really has these two; the third is invented
	_live=$(snap_names store | LC_ALL=C sort)
	_a=$(printf '%s\n' "$_live" | head -n 1)
	_b=$(printf '%s\n' "$_live" | tail -n 1)
	_gone=2020-01-01-000000
	printf '%s\n%s\n%s\n' "$_a" "$_gone" "$_b" >"$_cov"

	## the purged snapshot changed two files; the next one changed one of them
	printf '/keep/only-in-old\t11\t111\n/both/changed\t22\t222\n' >"$_d/d.$_gone.tsv"
	printf '/both/changed\t99\t999\n' >"$_d/d.$_b.tsv"

	vs_prune store >/dev/null 2>&1

	t_eq "the purged snapshot is no longer claimed as covered" \
		"$(count_match "$_gone" < "$_cov")" "0"
	t_eq "the ones that exist still are" "$(count_lines < "$_cov")" "2"
	t_eq "its delta file is gone" \
		"$([ -f "$_d/d.$_gone.tsv" ] && echo left || echo gone)" "gone"
	## the squash: what only the old delta knew must survive in the next one...
	t_eq "a row only the purged delta had is carried forward" \
		"$(awk -F'\t' '$1 == "/keep/only-in-old" {print $2}' "$_d/d.$_b.tsv")" "11"
	## ...and where both knew a path, the LATER one must win
	t_eq "the later version wins for a path both changed" \
		"$(awk -F'\t' '$1 == "/both/changed" {print $2}' "$_d/d.$_b.tsv")" "99"
	t_eq "and it is not duplicated" \
		"$(count_match '/both/changed' < "$_d/d.$_b.tsv")" "1"
	rm -rf "$_d" "$_cov"
}

## REGRESSION: the health table documented a Full Disk Access check that did
## not exist. Without it, tmutil delete and verifychecksums fail one by one
## with their own errors instead of one pointer at the cause.
t_test_full_disk_access() {
	printf '\nFull Disk Access\n'
	_saved="$FDA_PROBE"

	_ok="$T_ROOT/fda_ok"; printf 'x\n' >"$_ok"
	FDA_PROBE="$_ok"
	t_true has_full_disk_access

	## TCC denies the read, so the probe must READ, not merely stat
	_no="$T_ROOT/fda_denied"; printf 'x\n' >"$_no"; chmod 000 "$_no"
	FDA_PROBE="$_no"
	t_eq "an unreadable probe is detected" \
		"$(has_full_disk_access && echo granted || echo denied)" "denied"
	t_match "and --health says so with a pointer" "$(cmd_health 2>&1)" "Full Disk Access"
	t_match "naming where to grant it" "$(cmd_health 2>&1)" "System Settings"

	## a probe that is not there at all must not raise a false alarm
	FDA_PROBE="$T_ROOT/does-not-exist"
	t_true has_full_disk_access

	chmod 644 "$_no" 2>/dev/null
	FDA_PROBE="$_saved"
}

## A sparsebundle records the UUID of the Mac it backs up. That makes "is this
## my own backup history?" a fact rather than a guess -- which is what lets
## my-tm pick up its own bundles automatically while leaving other machines'
## backups alone.
## A sparsebundle belongs to the machine that STORES it. Adversarial: detection
## picked up /Volumes/*/*.sparsebundle wherever it sat, so horse.sparsebundle on
## ada became a location here -- and every health run pulled it over SMB, 1060 s
## measured. On a share it must not be detected, and --add must refuse it and
## name the ssh form instead.
t_test_network_bundles() {
	printf '\nA sparsebundle on a share belongs to its host\n'
	_nb_mt="$MOUNT_TABLE_FILE"; _nb_vd="$VOLUMES_DIR"; _nb_uu="$MAC_UUID"
	MAC_UUID="AAAA1111-2222-3333-4444-555566667777"
	VOLUMES_DIR="$T_ROOT/vols2"
	mkdir -p "$VOLUMES_DIR/timeMachine" "$VOLUMES_DIR/usbdisk"
	t_make_bundle "$VOLUMES_DIR/timeMachine/horse.sparsebundle" "$MAC_UUID" "Mac16,5"
	t_make_bundle "$VOLUMES_DIR/usbdisk/horse.sparsebundle" "$MAC_UUID" "Mac16,5"
	MOUNT_TABLE_FILE="$T_ROOT/nb.table"
	printf '//me@ada/tm on %s (smbfs, nodev, nosuid)\n' "$VOLUMES_DIR/timeMachine" >"$MOUNT_TABLE_FILE"
	printf '/dev/disk9s2 on %s (apfs, local, journaled)\n' "$VOLUMES_DIR/usbdisk" >>"$MOUNT_TABLE_FILE"
	rm -f "$(cache_write_dir)/images.autodetect"

	_nb_det=$(autodetect_images)
	t_eq "the bundle on the share is not detected" \
		"$(printf '%s\n' "$_nb_det" | count_match 'timeMachine/horse.sparsebundle')" "0"
	t_eq "the one on the local disk still is" \
		"$(printf '%s\n' "$_nb_det" | count_match 'usbdisk/horse.sparsebundle')" "1"

	_nb_err=$( ( cmd_add "$VOLUMES_DIR/timeMachine/horse.sparsebundle" fromada ) 2>&1 >/dev/null )
	t_match "--add refuses it" "$_nb_err" "on a network share"
	t_match "names the host it is stored on" "$_nb_err" "(ada)"
	t_match "and shows the ssh form" "$_nb_err" "add ada:"
	t_eq "and registered nothing" \
		"$(locations_registered | count_match 'fromada')" "0"

	t_eq "the host behind the share is read from the mount table" \
		"$(network_mount_host "$VOLUMES_DIR/timeMachine")" "ada"

	rm -f "$(cache_write_dir)/images.autodetect"
	rm -rf "$VOLUMES_DIR"
	MOUNT_TABLE_FILE="$_nb_mt"; VOLUMES_DIR="$_nb_vd"; MAC_UUID="$_nb_uu"
	return 0
}

t_test_bundle_ownership() {
	printf '\nSparsebundles: whose backups are these\n'
	_saved="$MAC_UUID"
	MAC_UUID="AAAA1111-2222-3333-4444-555566667777"

	_share="$T_ROOT/share"; mkdir -p "$_share"
	t_make_bundle "$_share/mine.sparsebundle" "$MAC_UUID" "Mac16,5"
	t_make_bundle "$_share/theirs.sparsebundle" "BBBB9999-8888-7777-6666-555544443333" "Mac14,2"
	mkdir -p "$_share/notabundle.sparsebundle"   # no MachineID.plist at all

	t_eq "my own bundle is recognised" \
		"$(bundle_is_mine "$_share/mine.sparsebundle" && echo mine || echo other)" "mine"
	t_eq "another Mac's is not" \
		"$(bundle_is_mine "$_share/theirs.sparsebundle" && echo mine || echo other)" "other"
	t_eq "and neither is something without a MachineID" \
		"$(bundle_is_mine "$_share/notabundle.sparsebundle" && echo mine || echo other)" "other"
	t_eq "the host UUID is read back" \
		"$(bundle_host_uuid "$_share/theirs.sparsebundle")" "BBBB9999-8888-7777-6666-555544443333"

	## what --add shows before asking, without attaching anything
	_show=$(bundle_show "$_share/mine.sparsebundle" 2>&1)
	t_match "the summary says whose it is" "$_show" "THIS Mac"
	t_match "and names the model" "$_show" "Mac16,5"
	_show=$(bundle_show "$_share/theirs.sparsebundle" 2>&1)
	t_match "a foreign one is marked as such" "$_show" "another Mac"

	MAC_UUID="$_saved"
}

## --add pointed at a directory full of bundles asks about each in turn.
t_test_add_picker() {
	printf '\n--add on a directory of bundles\n'
	_saved="$MAC_UUID"
	MAC_UUID="AAAA1111-2222-3333-4444-555566667777"
	_share="$T_ROOT/share2"; mkdir -p "$_share"
	t_make_bundle "$_share/one.sparsebundle" "$MAC_UUID" "Mac16,5"
	t_make_bundle "$_share/two.sparsebundle" "BBBB9999-8888-7777-6666-555544443333" "Mac14,2"
	_lf=$(locations_file)
	_before=$(cat "$_lf" 2>/dev/null)

	## no terminal: it must not guess, it must name them
	_out=$( ( cmd_add "$_share" ) </dev/null 2>&1 )
	t_match "with nothing to answer with, it lists them instead of choosing" "$_out" "add one by name"
	t_eq "and registers nothing" "$(cat "$_lf" 2>/dev/null)" "$_before"

	## skip the first, add the second, then quit
	_out=$( printf 's\na\n' | ( cmd_add "$_share" ) 2>&1 )
	t_match "it walks through each bundle" "$_out" "\[1/2\]"
	t_match "and the second one too" "$_out" "\[2/2\]"
	t_eq "the skipped bundle was not registered" \
		"$(count_match 'one.sparsebundle' < "$_lf")" "0"
	t_eq "the chosen one was" "$(count_match 'two.sparsebundle' < "$_lf")" "1"

	## quitting stops immediately
	_before=$(cat "$_lf" 2>/dev/null)
	_out=$( printf 'q\n' | ( cmd_add "$_share" ) 2>&1 )
	t_eq "quit registers nothing more" "$(cat "$_lf" 2>/dev/null)" "$_before"

	MAC_UUID="$_saved"
}

## a minimal but real sparsebundle: the two plists my-tm reads
t_make_bundle() {
	_b="$1"; _host="$2"; _model="$3"
	mkdir -p "$_b/bands"
	cat >"$_b/Info.plist" <<_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>band-size</key><integer>268435456</integer>
	<key>diskimage-bundle-type</key><string>com.apple.diskimage.sparsebundle</string>
	<key>size</key><integer>11399877943296</integer>
	<key>uuid</key><string>d3da6a2f-7bd7-4db1-bd52-295f50474ff5</string>
</dict></plist>
_EOF
	cat >"$_b/com.apple.TimeMachine.MachineID.plist" <<_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.backupd.HostUUID</key><string>$_host</string>
	<key>com.apple.backupd.ModelID</key><string>$_model</string>
	<key>VerificationState</key><integer>1</integer>
</dict></plist>
_EOF
	return 0
}

## REGRESSION: an image attached by a run that was killed had no record, and
## the sweep only releases what it has a record of -- so it would have stayed
## attached indefinitely.
t_test_image_orphan_adoption() {
	printf '\nAn untracked attach is adopted, not abandoned\n'
	_saved="$MAC_UUID"; MAC_UUID="AAAA1111-2222-3333-4444-555566667777"
	_share="$T_ROOT/share3"; mkdir -p "$_share"
	t_make_bundle "$_share/orphan.sparsebundle" "$MAC_UUID" "Mac16,5"
	printf 'orphanloc\t%s/orphan.sparsebundle\t\n' "$_share" >>"$T_ROOT/cache/locations.tsv"

	## pretend hdiutil reports it as attached -- as a real plist, because that
	## is what image_mountpoint parses
	{
		printf '#!/bin/sh\n'
		printf 'printf "hdiutil %%s\\n" "$*" >>"%s"\n' "$(t_calls)"
		# shellcheck disable=SC2016  # writing a script: $1 is the STUB's argument
		printf 'if [ "$1" = "info" ]; then cat <<XEOF\n'
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<plist version="1.0"><dict><key>images</key><array><dict>\n'
		printf '<key>image-path</key><string>%s/orphan.sparsebundle</string>\n' "$_share"
		printf '<key>system-entities</key><array><dict>\n'
		printf '<key>mount-point</key><string>/Volumes/Orphan</string>\n'
		printf '</dict></array></dict></array></dict></plist>\n'
		printf 'XEOF\n'
		printf 'fi\n'
		printf 'exit 0\n'
	} >"$(t_stub_dir)/hdiutil"
	chmod 0755 "$(t_stub_dir)/hdiutil"

	_f=$(mounts_file); : >"$_f"
	t_eq "nothing is tracked to begin with" "$(mounts_read_all | count_lines)" "0"
	images_adopt_orphans >/dev/null 2>&1
	t_eq "the untracked attach is now tracked" \
		"$(mounts_read_all | count_match 'image')" "1"
	_ttl=$(mounts_read_all | awk -F'\t' '$7 ~ /image/ {print $5}')
	t_eq "with the image grace period" "$_ttl" "$IMAGE_GRACE"

	## and adopting twice must not duplicate it
	images_adopt_orphans >/dev/null 2>&1
	t_eq "adopting again changes nothing" "$(mounts_read_all | count_match 'image')" "1"

	rm -f "$(t_stub_dir)/hdiutil"
	: >"$_f"
	grep -v '^orphanloc' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/l3.tmp" &&
		mv "$T_ROOT/l3.tmp" "$T_ROOT/cache/locations.tsv"
	MAC_UUID="$_saved"
}

## REGRESSION: pruning wrote its scratch files INSIDE the version-store
## directory. A location indexed before the version store existed has coverage
## but no such directory, so the very first thing --index did was fail with a
## shell error and prune nothing.
t_test_prune_without_version_store() {
	printf '\nPruning a location that has no version store yet\n'
	_cov=$(index_covered_file store)
	need_dir "$(dirname "$_cov")"
	_d=$(vs_dir store)
	rm -rf "$_d"          # coverage exists, version store does not
	_live=$(snap_names store | LC_ALL=C sort)
	{ printf '%s\n' "$_live"; printf '2020-01-01-000000\n'; } >"$_cov"

	_err=$( ( vs_prune store ) 2>&1 >/dev/null )
	t_eq "it does not fail" "$(printf '%s' "$_err" | count_match 'No such file')" "0"
	t_eq "and still prunes what is gone" "$(count_match '2020-01-01' < "$_cov")" "0"
	t_eq "keeping what exists" "$(count_lines < "$_cov")" "$(printf '%s\n' "$_live" | count_lines)"
	rm -f "$_cov"
}

## REGRESSION: a CHANGED file was recorded as changed and removed at once,
## because removals were computed by comparing whole lines: the old line is
## gone, so every changed path looked deleted. An absent row sorts before a
## real one, so the phantom won -- my-tm reported a backup as not holding a
## file it plainly held. Verified against a real store: 2.26M such rows.
t_test_delta_removals_by_path() {
	printf '\nDeltas: changed is not removed\n'
	_d=$(vs_dir store); rm -rf "$_d"; need_dir "$_d"

	## walk 1: two files. walk 2: one changed, one deleted, one new.
	_w1=$(mktemp "$T_ROOT/w1.XXXXXX"); _w2=$(mktemp "$T_ROOT/w2.XXXXXX")
	printf '/a/changed\t100\t1000\n/a/deleted\t200\t2000\n' >"$_w1"
	printf '/a/changed\t999\t9999\n/a/new\t300\t3000\n' >"$_w2"

	vs_record_snapshot store 2026-01-01-000000 "$_w1" >/dev/null 2>&1
	vs_record_snapshot store 2026-01-02-000000 "$_w2" >/dev/null 2>&1
	_dl="$_d/d.2026-01-02-000000.tsv"

	t_eq "the changed file is recorded with its new size" \
		"$(awk -F'\t' '$1 == "/a/changed" {print $2}' "$_dl")" "999"
	t_eq "and NOT also as removed" \
		"$(awk -F'\t' '$1 == "/a/changed" && $2 == "-"' "$_dl" | count_lines)" "0"
	t_eq "the genuinely deleted file IS marked absent" \
		"$(awk -F'\t' '$1 == "/a/deleted" && $2 == "-"' "$_dl" | count_lines)" "1"
	t_eq "the new file is recorded" \
		"$(awk -F'\t' '$1 == "/a/new" {print $2}' "$_dl")" "300"

	## and what a lookup reconstructs must say the changed file is THERE
	_v=$(vs_versions_for store /a/changed)
	t_eq "the reconstruction reports it present" \
		"$(printf '%s\n' "$_v" | awk -F'\t' '$1 == "2026-01-02-000000" {print $2}')" "999"
	t_eq "and the deleted one absent" \
		"$(vs_versions_for store /a/deleted | awk -F'\t' '$1 == "2026-01-02-000000" {print $2}')" "-"

	## the repair mends a store already written the wrong way
	printf '/a/changed\t-\t-\n' >>"$_dl"
	rm -f "$_d/.repaired.$VS_REPAIR"
	vs_repair_deltas store
	t_eq "a phantom removal is repaired away" \
		"$(awk -F'\t' '$1 == "/a/changed" && $2 == "-"' "$_dl" | count_lines)" "0"
	t_eq "while the real row survives" \
		"$(awk -F'\t' '$1 == "/a/changed" && $2 == "999"' "$_dl" | count_lines)" "1"
	t_eq "and a genuine removal is left alone" \
		"$(awk -F'\t' '$1 == "/a/deleted" && $2 == "-"' "$_dl" | count_lines)" "1"
	rm -rf "$_d" "$_w1" "$_w2"
}

## REGRESSION: presence was decided by the INODE field, but the version store
## holds path, size and mtime and has no inode -- so every snapshot the index
## answered was reported "absent" no matter what it held, which made a
## 25-hour index worse than useless: confidently wrong.
t_test_presence_by_size_not_inode() {
	printf '\nPresence is decided by size, not inode\n'
	_w="$T_ROOT/pres"
	## rows as cmd_lookup builds them: ts, epoch, id, inode, size, mtime
	{
		printf '2026-08-03-000000\t300\tc3\t-\t205797\t1787660725\n'
		printf '2026-08-02-000000\t200\tb2\t-\t-\t-\n'
		printf '2026-08-01-000000\t100\ta1\t99\t7466\t1748518711\n'
	} >"$_w"
	_out=$(while IFS="$(printf '\t')" read -r _ts _ep _id _i _s _m; do
		if [ "${_s:--}" = "-" ]; then printf '%s absent\n' "$_id"
		else printf '%s present\n' "$_id"; fi
	done <"$_w")
	t_match "an index row with no inode is still PRESENT" "$_out" "c3 present"
	t_match "a row with no size is absent" "$_out" "b2 absent"
	t_match "a live-read row is present too" "$_out" "a1 present"
	t_eq "nothing is called absent merely for lacking an inode" \
		"$(printf '%s\n' "$_out" | count_match 'absent')" "1"
	rm -f "$_w"
}

## A <ts>.previous directory is normal housekeeping -- the working copy Time
## Machine keeps of the last completed backup -- so it must not be reported as
## a state. Only in-progress and interrupted backups are conditions.
t_test_previous_is_not_a_state() {
	printf '\nA .previous working copy is not a condition\n'
	mkdir -p "$T_ROOT/store/2026-08-26-231818.previous"
	_st=$(snap_states store)
	t_eq "a .previous directory is not reported" \
		"$(printf '%s\n' "$_st" | count_match 'previous')" "0"
	t_match "while an interrupted backup still is" "$_st" "interrupted"
	t_match "and one in progress too" "$_st" "inprogress"
	rmdir "$T_ROOT/store/2026-08-26-231818.previous"
}

## REGRESSION: a mangled comment left a bare word in the --version arm, which
## the shell tried to run. The output still looked right, so nothing caught it.
## The post-backup disk action.  Adversarial first: the failure that matters
## is not "eject did not run", it is my-tm running the WRONG action while
## reporting the right one -- ejecting a disk whose policy says unmount, or
## touching a disk the flag file says to leave alone.  Every case asserts the
## diskutil call that reached the stub, never what my-tm said it did.
## REGRESSION: the search was keyed on $SITE_CONF_DIR, whose site value lives
## INSIDE the config file -- so /LINKS/default, the primary location, was never
## looked at and a config sitting right there was silently ignored.
## A sparsebundle on a share takes minutes to attach and hdiutil says nothing
## while it does, so my-tm now reports elapsed time. The danger in adding ANY
## output here is the bug the stderr rule exists for: image_attach is called
## inside $(...) for the path it prints, so a progress line on stdout becomes
## part of the mountpoint. Both halves are asserted -- that it speaks, and
## that speaking does not corrupt the value.
## REGRESSION: lsof enumerates EVERY mount, so one unresponsive filesystem
## anywhere wedges it in an uninterruptible wait that no signal can clear --
## observed live, where even `lsof /tmp` never returned. The sweep runs from a
## daemon every MAINT_INTERVAL seconds, so an unbounded wait there stops the
## daemon for good. Adversarial first: the test is the lsof that NEVER answers.
## REGRESSION: --install built the /tm tree, which reads every store. On a
## fresh install nothing is cached, so it attached a sparsebundle over a share
## and sat for minutes on work the maintenance job does on its first run.
## cmd_install writes /etc/synthetic.conf and LaunchDaemons, so it cannot run
## here; this reads its body from the script instead.
## REGRESSION: launchd starts a daemon with no HOME, and under set -u the first
## "$HOME" in the defaults killed the script before it did anything -- every
## job --install wrote exited 1 at once. Adversarial: run the WHOLE script in
## that environment, not a unit of it, since the crash is at load time.
## REGRESSION: the sparsebundle list was built in /tmp and moved into the
## cache, keeping mktemp's 0600 -- unreadable to the group like the rest.
t_test_autodetect_mode() {
	printf '\nThe sparsebundle list follows its directory\n'
	_am_save="$MAC_UUID"; MAC_UUID="00000000-0000-0000-0000-000000000000"
	_am_f="$(cache_write_dir)/images.autodetect"
	rm -f "$_am_f"
	chmod 0750 "$(cache_write_dir)" 2>/dev/null
	autodetect_images >/dev/null 2>&1
	t_eq "it is written, even when empty" "$([ -f "$_am_f" ] && echo yes)" "yes"
	t_eq "and group-readable like its directory" \
		"$(stat -f '%Sp' "$_am_f")" "-rw-r-----"
	MAC_UUID="$_am_save"
}

## REGRESSION: an unreadable shared cache was reported as "no integrity header",
## sending anyone who looked after a malformed file that was not malformed.
t_test_cache_unreadable() {
	printf '\nA cache that cannot be read says so\n'
	if is_root; then
		t_skip "an unreadable cache" "root reads every file"
		return 0
	fi
	_cu_f="$T_ROOT/unreadable.cache"
	printf '%s x\nrow\n' "$CACHE_MAGIC" >"$_cu_f"
	chmod 0000 "$_cu_f"
	_cu_err=$( (DBG=1; cache_read_checked "$_cu_f") 2>&1 >/dev/null )
	chmod 0600 "$_cu_f"
	t_match "the real cause is reported" "$_cu_err" "cannot read"
	t_eq "not a malformed file" \
		"$(printf '%s\n' "$_cu_err" | count_match 'no integrity header')" "0"
	rm -f "$_cu_f"
}

## REGRESSION: --install copied the config it found in the site directory into
## SITE_CONF_DIR as a second copy that would drift, then warned that a plain run
## would not find a config it had just found. It copies only when a plain run
## finds none, and never overwrites a different file.
t_test_install_config() {
	printf '\n--install and the config it was run with\n'
	_ic_root="$T_ROOT/icfg"; rm -rf "$_ic_root"
	mkdir -p "$_ic_root/site" "$_ic_root/write" "$_ic_root/home" "$_ic_root/src"
	_ic_s="$_ic_root/src/my-tm.local.conf"
	printf 'CACHE_TTL=1\n' >"$_ic_s"
	## scratch search directories only: the real site directory on the machine
	## running the suite must take no part. Saved and restored explicitly, so
	## nothing leaks into the tests that run after this one.
	_ic_run() {
		_ic_v1="$CONFIG_SITE_DIR"; _ic_v2="$SITE_CONF_DIR_SEARCH"
		_ic_v3="$SITE_CONF_DIR_FROM_ENV"; _ic_v4="$HOME"
		_ic_v5="${MY_TM_CONFIG:-}"; _ic_v6="$CONFIG_FILE"; _ic_v7="$SITE_CONF_DIR"
		CONFIG_SITE_DIR="$_ic_root/site"; SITE_CONF_DIR_SEARCH="$_ic_root/nowhere"
		SITE_CONF_DIR_FROM_ENV=0; HOME="$_ic_root/home"
		MY_TM_CONFIG=''; CONFIG_FILE="$_ic_s"; SITE_CONF_DIR="$_ic_root/write"
		install_config "$_ic_s" >"$_ic_root/out" 2>&1
		CONFIG_SITE_DIR="$_ic_v1"; SITE_CONF_DIR_SEARCH="$_ic_v2"
		SITE_CONF_DIR_FROM_ENV="$_ic_v3"; HOME="$_ic_v4"
		MY_TM_CONFIG="$_ic_v5"; CONFIG_FILE="$_ic_v6"; SITE_CONF_DIR="$_ic_v7"
		cat "$_ic_root/out"
	}

	cp "$_ic_s" "$_ic_root/site/my-tm.conf"
	_ic_out=$(_ic_run)
	t_eq "found on the search path: no second copy is made" \
		"$([ -f "$_ic_root/write/my-tm.conf" ] && echo copied || echo none)" "none"
	t_eq "and nothing is flagged" "$(printf '%s\n' "$_ic_out" | count_match '!!!')" "0"

	printf 'CACHE_TTL=2\n' >"$_ic_root/site/my-tm.conf"
	_ic_out=$(_ic_run)
	t_eq "a different one on the search path: still no copy" \
		"$([ -f "$_ic_root/write/my-tm.conf" ] && echo copied || echo none)" "none"
	t_eq "the two are offered for merging" \
		"$(printf '%s\n' "$_ic_out" | count_match "vimdiff $_ic_s $_ic_root/site/my-tm.conf")" "1"
	rm -f "$_ic_root/site/my-tm.conf"

	_ic_out=$(_ic_run)
	t_eq "none on the search path: the config is copied" \
		"$(cat "$_ic_root/write/my-tm.conf" 2>/dev/null)" "CACHE_TTL=1"
	t_eq "and a plain run not looking there is said" \
		"$(printf '%s\n' "$_ic_out" | count_match 'will not look at')" "1"

	printf 'CACHE_TTL=9\n' >"$_ic_root/write/my-tm.conf"
	_ic_out=$(_ic_run)
	t_eq "an existing, different copy is never overwritten" \
		"$(cat "$_ic_root/write/my-tm.conf")" "CACHE_TTL=9"
	t_eq "it is offered for merging instead" \
		"$(printf '%s\n' "$_ic_out" | count_match "vimdiff $_ic_s $_ic_root/write/my-tm.conf")" "1"
	rm -rf "$_ic_root"
}

## The daemons' logs follow LOG_DIR. cmd_install needs root, so its body is read.
## REGRESSION: the job plists captured stderr only, so everything a daemon
## printed on stdout was discarded -- the whole --health report included.
## What counts as a network volume. Adversarial: a mount point that is a
## string-prefix of another must not claim it, and a name with a space in it
## must still be matched whole.
## The Full Disk Access launcher. Adversarial where it counts: its arguments
## must arrive intact (one per line, so "a b" cannot silently split); with no
## arguments it must run NOTHING; and a quote in the my-tm path -- pasted into a
## compiler define -- must be refused, not compiled.
## --install and the launcher. Adversarial: the plan must name what the jobs
## will actually run; the plists must switch their program; and a launcher built
## for a DIFFERENT my-tm must count as stale, or an install after moving my-tm
## would keep a launcher that runs the old path.
## Guidance on the job access setting. Adversarial: a hint must come only where
## the setting changed what the jobs could do -- never for a location off the
## network, never for one the jobs can read, and never as a failure.
t_test_job_guidance() {
	printf '\nGuidance on the job access setting\n'
	_jg_tf="$MOUNT_TABLE_FILE"; _jg_a="$JOBS_RUN_WITH_FULL_DISK_ACCESS"
	_jg_mnt="$T_ROOT/jgnet"; mkdir -p "$_jg_mnt/tmdisk"
	MOUNT_TABLE_FILE="$T_ROOT/jg.table"
	printf '//me@ada/tm on %s (smbfs, nodev, nosuid)\n' "$_jg_mnt" >"$MOUNT_TABLE_FILE"
	printf 'jgnet\t%s/tmdisk\t\n' "$_jg_mnt" >>"$T_ROOT/cache/locations.tsv"

	for _jg_c in 0 1; do
		JOBS_RUN_WITH_FULL_DISK_ACCESS=$_jg_c
		printf '%s:%s:%s\n' "$_jg_c" \
			"$( ( jobs_blind_on jgnet ) && echo blind || echo -)" \
			"$( ( jobs_blind_on store ) && echo blind || echo -)"
	done >"$T_ROOT/jg.reasons"
	t_eq "blind without the access, seeing with it -- and never either for a local location" \
		"$(tr '\n' '|' <"$T_ROOT/jg.reasons")" "0:blind:-|1:-:-|"

	HEALTH_RC=0
	health_say hint "x" >/dev/null
	t_eq "a health hint leaves the exit code alone" "$HEALTH_RC" "0"

	JOBS_RUN_WITH_FULL_DISK_ACCESS=0
	_jg_st=$(cmd_status 2>/dev/null)
	t_eq "--status names the location the jobs cannot see into" \
		"$(printf '%s\n' "$_jg_st" | count_match 'jgnet is on a network volume the jobs cannot see into')" "1"
	t_eq "and nothing else" "$(printf '%s\n' "$_jg_st" | count_match 'on a network volume the jobs')" "1"
	JOBS_RUN_WITH_FULL_DISK_ACCESS=1
	t_eq "with the access granted, --status says nothing about it" \
		"$(cmd_status 2>/dev/null | count_match 'on a network volume the jobs')" "0"

	## the setting is gone, and so is everything it gated: a config that still
	## sets it is stopped rather than silently ignored
	## every other retired name is unset first: err EXITS, so one that this
	## machine's own config still sets would refuse before this one is reached
	# shellcheck disable=SC2034  # config_refuse_old_names reads it through eval
	t_eq "a config still setting JOBS_ACCESS_NETWORK_VOLUMES is refused" \
		"$( ( unset THIN_POLICY_TO_KEEP THIN_POLICY_PER_LOCATION POST_BACKUP \
		            POST_BACKUP_PER_LOCATION HEALTH_MAX_AGE_H AUTODETECT_LOCAL_TM_BACKUPS
		      JOBS_ACCESS_NETWORK_VOLUMES=1; config_refuse_old_names ) 2>&1 |
		    count_match 'JOBS_ACCESS_NETWORK_VOLUMES is no longer read')" "1"
	## anchored on the DEFINITIONS, so this line's own pattern cannot match
	t_eq "and the gate it drove is gone with it" \
		"$(grep -cE '^(jobs_skip_reason|job_skips_location|slow_attaches_today)\(\) \{$|^SLOW_ATTACH_S=' "$T_MYTM")" "0"
	## the refusal reads the name through eval, so what must be zero is any
	## EXPANSION of it -- pattern in two pieces so this line cannot match itself
	_jg_v='\$\{?'"JOBS_ACCESS_NETWORK_VOLUMES"
	t_eq "and nothing reads it any more" "$(grep -cE "$_jg_v" "$T_MYTM")" "0"

	rm -f "$T_ROOT/jg.reasons" "$MOUNT_TABLE_FILE"
	grep -v '^jgnet	' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/cache/l.jg" &&
		mv "$T_ROOT/cache/l.jg" "$T_ROOT/cache/locations.tsv"
	rm -rf "$_jg_mnt"
	MOUNT_TABLE_FILE="$_jg_tf"; JOBS_RUN_WITH_FULL_DISK_ACCESS="$_jg_a"
}

t_test_install_launcher() {
	printf '\n--install and the Full Disk Access launcher\n'
	_il_a="$JOBS_RUN_WITH_FULL_DISK_ACCESS"
	_il_l="$JOBS_LAUNCHER"; JOBS_LAUNCHER="/usr/local/sbin/my-tm-launcher"
	JOBS_RUN_WITH_FULL_DISK_ACCESS=0
	t_eq "without the access, the plan says so" \
		"$(install_access_plan 2>&1 | count_match 'JOBS_RUN_WITH_FULL_DISK_ACCESS=0 -- the jobs run my-tm directly')" "1"
	t_match "and -V says what the jobs will not be able to do" \
		"$( ( VRB=1; install_access_plan ) 2>&1 )" "cannot read a store on a network volume"
	JOBS_RUN_WITH_FULL_DISK_ACCESS=1
	t_match "with access on, the plan names the launcher" \
		"$(install_access_plan 2>&1)" "run through /usr/local/sbin/my-tm-launcher"
	t_eq "and then says nothing about what it cannot do" \
		"$(install_access_plan 2>&1 | count_match 'cannot')" "0"

	_il_bin="${MY_TM_BIN:-}"; _il_prog="${JOB_PROGRAM:-}"; _il_log="${LOG_DIR_ROOT:-}"
	MY_TM_BIN="/usr/local/sbin/my-tm"; LOG_DIR_ROOT="$T_ROOT/logs"
	JOB_PROGRAM="/usr/local/sbin/my-tm-launcher"
	job_plist test.launcher.job 120s --maintenance >"$T_ROOT/lj.plist"
	t_eq "the job plist runs the launcher, my-tm's arguments after it" \
		"$(plutil -extract ProgramArguments.0 raw -o - "$T_ROOT/lj.plist") $(plutil -extract ProgramArguments.1 raw -o - "$T_ROOT/lj.plist")" \
		"/usr/local/sbin/my-tm-launcher --maintenance"
	JOB_PROGRAM=""
	job_plist test.launcher.job 120s --maintenance >"$T_ROOT/lj.plist"
	t_eq "without it, my-tm itself" \
		"$(plutil -extract ProgramArguments.0 raw -o - "$T_ROOT/lj.plist")" "/usr/local/sbin/my-tm"
	rm -f "$T_ROOT/lj.plist"

	_il_body=$(sed -n '/^cmd_install() {$/,/^}$/p' "$T_MYTM")
	# shellcheck disable=SC2016  # the literal source text is matched, not a variable
	t_eq "--install refuses a launcher directory others can write" \
		"$(printf '%s\n' "$_il_body" | count_match 'path_is_user_writable "$(dirname "$JOBS_LAUNCHER")"')" "1"
	# shellcheck disable=SC2016  # the literal source text is matched, not a variable
	t_eq "--uninstall removes the launcher" \
		"$(sed -n '/^cmd_uninstall() {$/,/^}$/p' "$T_MYTM" | count_match 'rm -f "$JOBS_LAUNCHER"')" "1"
	t_match "the default config leaves the jobs without it" "$(cmd_create_config)" "JOBS_RUN_WITH_FULL_DISK_ACCESS=0"

	if command -v clang >/dev/null 2>&1 && command -v codesign >/dev/null 2>&1; then
		_il_d="$T_ROOT/il"; mkdir -p "$_il_d"
		printf '#!/bin/dash\nexit 0\n' >"$_il_d/my-tm"; chmod 755 "$_il_d/my-tm"
		launcher_build "$_il_d/my-tm" "$_il_d/launcher" >/dev/null 2>&1
		t_eq "a launcher built for this my-tm is current" \
			"$(launcher_is_current "$_il_d/launcher" "$_il_d/my-tm" && echo current || echo stale)" "current"
		t_eq "for a different my-tm it is stale" \
			"$(launcher_is_current "$_il_d/launcher" "$_il_d/elsewhere/my-tm" && echo current || echo stale)" "stale"
		t_eq "and a missing one is stale" \
			"$(launcher_is_current "$_il_d/none" "$_il_d/my-tm" && echo current || echo stale)" "stale"
		rm -rf "$_il_d"
	else
		t_skip "launcher staleness" "needs clang and codesign"
	fi

	MY_TM_BIN="$_il_bin"; JOB_PROGRAM="$_il_prog"; LOG_DIR_ROOT="$_il_log"
	JOBS_RUN_WITH_FULL_DISK_ACCESS="$_il_a"; JOBS_LAUNCHER="$_il_l"
}

t_test_launcher() {
	printf '\nThe Full Disk Access launcher\n'
	_ln_c="$(dirname "$T_MYTM")/my-tm-launcher.c"
	if [ -f "$_ln_c" ]; then
		t_eq "the source carried inside my-tm is my-tm-launcher.c, byte for byte" \
			"$(launcher_source_hash)" "$(md5_file "$_ln_c")"
	else
		t_skip "embedded launcher source matches my-tm-launcher.c" "not in a checkout"
	fi
	if ! command -v clang >/dev/null 2>&1 || ! command -v codesign >/dev/null 2>&1; then
		t_skip "building the launcher" "needs clang and codesign"
		return 0
	fi
	_ln_d="$T_ROOT/launcher"; mkdir -p "$_ln_d"
	# shellcheck disable=SC2016  # writing a script: $@ belongs to the stub
	printf '#!/bin/dash\nprintf "%%s\\n" "$@" >"%s/ran.args"\n' "$_ln_d" >"$_ln_d/fake-my-tm"
	chmod 755 "$_ln_d/fake-my-tm"
	_ln_b="$_ln_d/my-tm-launcher"

	launcher_build "$_ln_d/fake-my-tm" "$_ln_b" >/dev/null 2>&1
	t_eq "it builds" "$([ -x "$_ln_b" ] && echo built)" "built"

	"$_ln_b" >"$_ln_d/o" 2>"$_ln_d/e"; _ln_rc=$?
	t_eq "with no arguments it runs nothing, prints no output, exits 64" \
		"$_ln_rc $(wc -c <"$_ln_d/o" | tr -d ' ') $([ -f "$_ln_d/ran.args" ] && echo ran || echo idle)" "64 0 idle"
	t_match "and explains itself" "$(cat "$_ln_d/e")" "usage: my-tm-launcher"
	## each check starts clean, so it fails for its own reason only
	rm -f "$_ln_d/ran.args"
	t_eq "--help explains, exits 0, runs nothing" \
		"$("$_ln_b" --help >/dev/null 2>&1; echo $?) $([ -f "$_ln_d/ran.args" ] && echo ran || echo idle)" "0 idle"
	t_eq "--version names the program and THIS source" \
		"$("$_ln_b" --version)" "my-tm-launcher (runs $_ln_d/fake-my-tm, source $(launcher_source_hash))"

	"$_ln_b" --maintenance "a b" >/dev/null 2>&1
	t_eq "anything else runs the fixed program, arguments intact" \
		"$(tr '\n' '|' <"$_ln_d/ran.args" 2>/dev/null)" "--maintenance|a b|"
	rm -f "$_ln_d/ran.args"
	"$_ln_b" --help extra >/dev/null 2>&1
	t_eq "--help with more arguments is passed through" \
		"$(tr '\n' '|' <"$_ln_d/ran.args" 2>/dev/null)" "--help|extra|"
	t_match "it is ad-hoc signed as my-tm-launcher" "$(codesign -dv "$_ln_b" 2>&1)" "Identifier=my-tm-launcher"

	## a payload that still COMPILES: C joins adjacent string literals, so
	## '.../a" "b' would build cleanly and quietly run '.../ab' instead
	launcher_build "$_ln_d/a\" \"b" "$_ln_d/evil" >/dev/null 2>&1
	t_eq "a my-tm path containing a quote is refused, nothing written" \
		"$([ -e "$_ln_d/evil" ] && echo written || echo refused)" "refused"
	rm -rf "$_ln_d"
}

t_test_network_volume_of() {
	printf '\nWhat counts as a network volume\n'
	_ng_save="$MOUNT_TABLE_FILE"
	_ng_mnt="$T_ROOT/netmnt"; mkdir -p "$_ng_mnt/horse.sparsebundle" "$T_ROOT/netmntX"
	: >"$_ng_mnt/horse.sparsebundle/Info.plist"
	MOUNT_TABLE_FILE="$T_ROOT/mount.table"
	{
		printf '//me@ada/timeMachine on %s (smbfs, nodev, nosuid, mounted by me)\n' "$_ng_mnt"
		printf '/dev/disk5s2 on /Volumes/TimeMachine.Horse (apfs, local, nodev, journaled)\n'
		printf '/dev/disk7s1 on /Volumes/Backups of macado (apfs, local, nodev)\n'
		printf 'ada:/export on /Volumes/nfs share (nfs, nodev)\n'
	} >"$MOUNT_TABLE_FILE"

	t_eq "an SMB share is a network volume" \
		"$(path_on_network_volume "$_ng_mnt/horse.sparsebundle" && echo yes || echo no)" "yes"
	t_eq "an NFS mount with a space in its name too" \
		"$(path_on_network_volume "/Volumes/nfs share/a" && echo yes || echo no)" "yes"
	t_eq "a local APFS volume is not" \
		"$(path_on_network_volume /Volumes/TimeMachine.Horse && echo yes || echo no)" "no"
	t_eq "a sibling whose name merely starts the same is not" \
		"$(path_on_network_volume "$T_ROOT/netmntX/a" && echo yes || echo no)" "no"

	## nothing about a network volume stops a job from REACHING a location any
	## more -- the expensive case, a sparsebundle on a share, is refused at --add
	printf 'netloc\t%s/horse.sparsebundle\t\n' "$_ng_mnt" >>"$T_ROOT/cache/locations.tsv"
	## the retired setting is named on purpose: a config that still says 0 must
	## not be able to stop a job, and saying nothing here would assert nothing
	## on a machine whose own config sets it to 1
	_ng_bg="$BACKGROUND_JOB"; BACKGROUND_JOB=1
	# shellcheck disable=SC2034  # deliberately dead: nothing reads it any more
	t_eq "a job reaches a location on a share like any other" \
		"$( ( JOBS_ACCESS_NETWORK_VOLUMES=0; loc_reachable netloc ) && echo reached || echo skipped)" "reached"
	BACKGROUND_JOB="$_ng_bg"

	grep -v '^netloc	' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/cache/l.ng" &&
		mv "$T_ROOT/cache/l.ng" "$T_ROOT/cache/locations.tsv"
	rm -rf "$_ng_mnt" "$T_ROOT/netmntX" "$MOUNT_TABLE_FILE"
	MOUNT_TABLE_FILE="$_ng_save"
}

t_test_job_plist_streams() {
	printf '\nDaemon plists capture both output streams\n'
	_jt_bin="${MY_TM_BIN:-}"; _jt_log="${LOG_DIR_ROOT:-}"
	MY_TM_BIN="/usr/local/sbin/my-tm"; LOG_DIR_ROOT="$T_ROOT/logs"
	_jt_f="$T_ROOT/job.plist"
	job_plist test.my-tm.job 86400s --health >"$_jt_f"
	t_eq "the plist lints" "$(plutil -lint "$_jt_f" >/dev/null 2>&1 && echo ok)" "ok"
	t_eq "stdout is captured, as <label>.log" \
		"$(plutil -extract StandardOutPath raw -o - "$_jt_f" 2>/dev/null)" "$T_ROOT/logs/test.my-tm.job.log"
	t_eq "stderr is captured, as <label>.err" \
		"$(plutil -extract StandardErrorPath raw -o - "$_jt_f" 2>/dev/null)" "$T_ROOT/logs/test.my-tm.job.err"
	t_eq "the job runs the installed binary with its arguments" \
		"$(plutil -extract ProgramArguments.1 raw -o - "$_jt_f" 2>/dev/null)" "--health"
	rm -f "$_jt_f"
	MY_TM_BIN="$_jt_bin"; LOG_DIR_ROOT="$_jt_log"
}

t_test_install_logs() {
	printf '\nDaemon logs follow LOG_DIR\n'
	_il=$(sed -n '/^cmd_install() {$/,/^}$/p' "$T_MYTM")
	# shellcheck disable=SC2016  # the literal source text is matched, not a variable
	t_eq "the daemons log where the config says" \
		"$(printf '%s\n' "$_il" | count_match 'LOG_DIR_ROOT="$LOG_DIR"')" "1"
	t_eq "and nowhere hard-coded" \
		"$(printf '%s\n' "$_il" | count_match '/var/log/my-tm')" "0"
}

t_test_runs_without_home() {
	printf '\nA daemon environment without HOME\n'
	_nh_err="$T_ROOT/nohome.err"
	env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$T_MYTM" --version >/dev/null 2>"$_nh_err"
	_nh_rc=$?
	t_eq "the script runs with no HOME at all" "$_nh_rc" "0"
	t_eq "and nothing is reported unbound" \
		"$(count_match 'unbound variable' < "$_nh_err")" "0"
	rm -f "$_nh_err"
}

t_test_install_builds_no_tree() {
	printf '\n--install leaves the tree to the maintenance job\n'
	_ib=$(sed -n '/^cmd_install() {$/,/^}$/p' "$T_MYTM")
	t_eq "the function body was found" \
		"$([ -n "$_ib" ] && echo found)" "found"
	t_eq "it does not build the tree" \
		"$(printf '%s\n' "$_ib" | grep -v '^[[:space:]]*#' | count_match 'tm_refresh')" "0"
	t_eq "it still writes the /tm README" \
		"$(printf '%s\n' "$_ib" | grep -v '^[[:space:]]*#' | count_match 'tm_write_readme')" "1"

	## /tm/README has ONE writer, --install. That holds only because its text
	## names $FIRMLINK: were it built from tm_root, it would name $MOUNT_ROOT
	## until the reboot that creates the firmlink, and need rewriting after.
	_rb=$(sed -n '/^tm_refresh() {$/,/^}$/p' "$T_MYTM")
	t_eq "--refresh does not rewrite the README" \
		"$(printf '%s\n' "$_rb" | grep -v '^[[:space:]]*#' | count_match 'tm_write_readme')" "0"
	## Adversarial: a firmlink that does NOT exist yet -- the state --install
	## writes in. A real /tm on the machine running the suite would let a
	## tm_root-based README pass too, and prove nothing.
	_fl_save="$FIRMLINK"; FIRMLINK="$T_ROOT/firmlink-not-created-yet"
	need_dir "$MOUNT_ROOT"
	tm_write_readme
	t_eq "the README names the firmlink before it exists" \
		"$(count_match "$FIRMLINK/<location>/<snapshot>" < "$MOUNT_ROOT/README")" "1"
	t_eq "and never the mount root" \
		"$(count_match "$MOUNT_ROOT/<location>" < "$MOUNT_ROOT/README")" "0"
	FIRMLINK="$_fl_save"
	## fixed-string matches: the text looked for is the SOURCE, with its '$'
	# shellcheck disable=SC2016  # the literal source text is matched, not a variable
	t_eq "the plan says who builds the tree" \
		"$(printf '%s\n' "$_ib" | count_match 'tree:       built by $MAINT_JOB on its first run, not here')" "1"
	# shellcheck disable=SC2016  # the literal source text is matched, not a variable
	t_eq "and the user is told how to build it now" \
		"$(printf '%s\n' "$_ib" | count_match 'to build it now: $US --refresh')" "1"
}

t_test_lsof_never_answers() {
	printf '\nA wedged lsof must not stop the sweep\n'
	_lt_save="$LSOF_TIMEOUT"; LSOF_TIMEOUT=2
	_lt_stub="$(t_stub_dir)/lsof"
	_lt_in="$T_ROOT/mnt-a
$T_ROOT/mnt-b"

	## an lsof that hangs far longer than the bound
	printf '#!/bin/sh\nsleep 30\n' >"$_lt_stub"
	chmod 0755 "$_lt_stub"

	_lt_t0=$(now_epoch)
	_lt_out=$(printf '%s\n' "$_lt_in" | busy_mounts 2>"$T_ROOT/busy.err")
	_lt_el=$(( $(now_epoch) - _lt_t0 ))

	t_eq "it gives up instead of waiting for ever" \
		"$([ "$_lt_el" -le 8 ] && echo bounded || echo "waited ${_lt_el}s")" "bounded"
	## failing SAFE is the whole point: a mount that might be in use is left
	## alone, never released on a guess
	t_eq "and calls every candidate busy, so nothing is released" \
		"$(printf '%s\n' "$_lt_out" | count_lines)" "2"
	t_match "the reason is stated, not swallowed" \
		"$(cat "$T_ROOT/busy.err")" "did not answer"

	## and a healthy lsof still gets its real answer through
	{
		printf '#!/bin/sh\n'
		printf 'echo "COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME"\n'
		printf 'echo "vim 1 me 3r REG 1,2 10 20 %s/mnt-a"\n' "$T_ROOT"
	} >"$_lt_stub"
	chmod 0755 "$_lt_stub"
	_lt_ok=$(printf '%s\n' "$_lt_in" | busy_mounts 2>/dev/null)
	t_eq "a healthy lsof still reports only the busy one" \
		"$_lt_ok" "$T_ROOT/mnt-a"

	rm -f "$_lt_stub" "$T_ROOT/busy.err"
	LSOF_TIMEOUT="$_lt_save"
}

t_test_attach_progress() {
	printf '\nA slow attach reports elapsed time, without corrupting the path\n'
	_ap_img="$T_ROOT/slow.sparsebundle"
	mkdir -p "$_ap_img"
	_ap_stub="$(t_stub_dir)/hdiutil"

	## a stub that takes long enough to trip the 6s threshold, then answers
	## like the real thing
	{
		printf '#!/bin/sh\n'
		# shellcheck disable=SC2016  # writing a script: $1 is the STUB's argument
		printf 'if [ "$1" = "info" ]; then exit 0; fi\n'
		printf 'sleep 9\n'
		printf '%s\n' 'cat <<XEOF'
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<plist version="1.0"><dict><key>system-entities</key><array><dict>\n'
		printf '<key>mount-point</key><string>/Volumes/SlowOne</string>\n'
		printf '</dict></array></dict></plist>\n'
		printf 'XEOF\n'
		printf 'exit 0\n'
	} >"$_ap_stub"
	chmod 0755 "$_ap_stub"

	_ap_err="$T_ROOT/attach.err"
	_ap_val=$(image_attach "$_ap_img" 2>"$_ap_err")

	t_eq "the captured value is the mountpoint and nothing else" \
		"$_ap_val" "/Volumes/SlowOne"
	t_match "the wait is announced once it is slow" \
		"$(cat "$_ap_err")" "this can take minutes"
	t_match "and the finish reports how long it took" \
		"$(cat "$_ap_err")" "attached slow.sparsebundle after"
	t_eq "every progress line went to stderr" \
		"$(printf '%s' "$_ap_val" | count_match 'attaching')" "0"

	## a fast attach says nothing at all -- no noise for a local image
	{
		printf '#!/bin/sh\n'
		# shellcheck disable=SC2016  # writing a script: $1 is the STUB's argument
		printf 'if [ "$1" = "info" ]; then exit 0; fi\n'
		printf '%s\n' 'cat <<XEOF'
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<plist version="1.0"><dict><key>system-entities</key><array><dict>\n'
		printf '<key>mount-point</key><string>/Volumes/FastOne</string>\n'
		printf '</dict></array></dict></plist>\n'
		printf 'XEOF\n'
		printf 'exit 0\n'
	} >"$_ap_stub"
	chmod 0755 "$_ap_stub"

	_ap_img2="$T_ROOT/fast.sparsebundle"; mkdir -p "$_ap_img2"
	_ap_val2=$(image_attach "$_ap_img2" 2>"$T_ROOT/attach2.err")
	t_eq "a fast attach still yields the path" "$_ap_val2" "/Volumes/FastOne"
	t_eq "and says nothing about waiting" \
		"$(count_match 'attaching' < "$T_ROOT/attach2.err")" "0"

	rm -f "$_ap_stub" "$_ap_err" "$T_ROOT/attach2.err"
	rm -rf "$_ap_img" "$_ap_img2"
}

t_test_config_search_order() {
	printf '\nConfig search order\n'
	_cso_save="$SITE_CONF_DIR_FROM_ENV"

	SITE_CONF_DIR_FROM_ENV=0
	t_eq "the primary location is searched FIRST" \
		"$(config_search_dirs | sed -n '1p')" "/LINKS/default"
	t_eq "and it is spelled out, not derived from a config value" \
		"$(config_search_dirs | count_match '$')" "0"

	## the escape hatch keeps its rank: an env var is an explicit override,
	## the same class as $MY_TM_CONFIG and --config
	## Simulated the way a real run gets it: the ENVIRONMENT's value, frozen
	## before any config loads. Adversarial: SITE_CONF_DIR itself still holds
	## whatever the loaded config set, so a search that used it would fail here.
	_se_v="$SITE_CONF_DIR_SEARCH"; SITE_CONF_DIR_SEARCH="$T_ROOT/from-env"
	SITE_CONF_DIR_FROM_ENV=1
	t_eq "SITE_CONF_DIR from the environment still wins" \
		"$(config_search_dirs | sed -n '1p')" "$T_ROOT/from-env"
	t_eq "with the primary location right behind it" \
		"$(config_search_dirs | sed -n '2p')" "/LINKS/default"
	SITE_CONF_DIR_FROM_ENV=0; SITE_CONF_DIR_SEARCH="$_se_v"

	## the paths the user is TOLD about are the paths that were searched --
	## naming one hand-picked location is what sent people to the wrong file
	t_eq "every searched dir yields a path (the site one yields both spellings)" \
		"$(config_search_paths | count_lines)" \
		"$(( $(config_search_dirs | count_lines) + 1 ))"
	t_eq "the site location is searched under its .conf name" \
		"$(config_search_paths | count_match '/LINKS/default/my-tm.conf')" "1"
	t_eq "and under the bare name the farm also uses" \
		"$(config_search_paths | grep -cxF '/LINKS/default/my-tm')" "1"
	t_match "the primary one is offered first" \
		"$(config_search_paths | sed -n '1p')" "/LINKS/default/my-tm.conf"
	t_match "and \$HOME renders as a dotfile" \
		"$(config_search_paths)" "$HOME/.my-tm.conf"

	## REGRESSION: the list offered the bare /LINKS/default/my-tm, but the
	## loader walked its own directory list and only ever tried my-tm.conf.
	## Adversarial: the bare name is the ONLY config there is.
	_cf_v1="$CONFIG_SITE_DIR"; _cf_v2="$HOME"
	_cf_v3="$SITE_CONF_DIR_SEARCH"; _cf_v4="$SITE_CONF_DIR_FROM_ENV"
	_cf_d="$T_ROOT/site-bare"; mkdir -p "$_cf_d" "$T_ROOT/home-bare"
	printf 'ID_LEN=6\n' >"$_cf_d/my-tm"
	CONFIG_SITE_DIR="$_cf_d"; HOME="$T_ROOT/home-bare"
	SITE_CONF_DIR_SEARCH="$T_ROOT/nowhere-bare"; SITE_CONF_DIR_FROM_ENV=0
	_cf_found=$(config_search_first | tail -n 1)
	CONFIG_SITE_DIR="$_cf_v1"; HOME="$_cf_v2"
	SITE_CONF_DIR_SEARCH="$_cf_v3"; SITE_CONF_DIR_FROM_ENV="$_cf_v4"
	t_eq "a config under the bare name is actually loaded" "$_cf_found" "$_cf_d/my-tm"
	rm -rf "$_cf_d" "$T_ROOT/home-bare"

	## What a user with no config is TOLD to do. Ordered by how often each
	## place is the right answer -- site, then system, then user -- which is
	## deliberately NOT the search order, so it is never described as one.
	t_eq "the site location is offered first" \
		"$(config_offer_paths | sed -n '1p')" "/LINKS/default/my-tm.conf"
	t_eq "then the system one" \
		"$(config_offer_paths | sed -n '2p')" "/etc/my-tm.conf"
	t_eq "then the user's" \
		"$(config_offer_paths | sed -n '3p')" "$HOME/.my-tm.conf"

	## REGRESSION-GUARD: the offer must never name a file my-tm would not
	## read. Every offered path has to be in the real search list -- so a
	## later edit to the search cannot leave the message pointing at a
	## location that is no longer consulted.
	_cso_orphans=0
	config_offer_paths | while IFS= read -r _cso_p; do
		config_search_paths | grep -qxF "$_cso_p" || _cso_orphans=1
		[ "$_cso_orphans" = "1" ] && printf 'ORPHAN %s\n' "$_cso_p"
	done >"$T_ROOT/offer.check"
	t_eq "every offered path is one that is actually searched" \
		"$(count_lines < "$T_ROOT/offer.check")" "0"
	rm -f "$T_ROOT/offer.check"

	SITE_CONF_DIR_FROM_ENV="$_cso_save"
}

## What happens to the disk when the backup was NOT ours. Adversarial: on horse
## `my-tm --backup start` met "a backup was already running" and ejected the disk
## anyway, cutting Time Machine's run off. And the lookup for the volume's
## location must CONSUME locations_all: an early exit closed the pipe and the
## producer took a SIGPIPE ("write error: Broken pipe").
## Resolving the destination when it is NOT mounted. Adversarial: on horse the
## disk was unmounted when --backup start ran, tmutil printed no "Mount Point",
## backup_volume resolved to nothing, and POST_BACKUP then did nothing at all --
## silently, because that line was only shown under -V.
## Reporting what Time Machine actually did. Adversarial: on horse
## `tmutil startbackup --block` exited 0, my-tm printed "backup finished", and
## Time Machine had recorded RESULT 704 and written no snapshot -- the run left
## .inprogress leftovers that its structure check rejects.
## my-tm's own tree must stay out of the backups. Adversarial: on horse
## backupd walked /var/lib/mine/my-tm/mount while the maintenance job rewrote it
## underneath, and nothing had ever excluded it -- the mount root can also hold a
## MOUNTED snapshot, which is the whole backup copied back into the backup.
t_test_cache_excluded() {
	printf '\nmy-tm'"'"'s own tree is excluded from Time Machine\n'
	rm -f "$T_ROOT/tm.excluded"
	_ce=$(cmd_health store 2>&1)
	t_eq "health warns while the cache dir is included" \
		"$(printf '%s\n' "$_ce" | count_match 'is NOT excluded from Time Machine')" "1"

	printf '%s\n' "$CACHE_DIR" >"$T_ROOT/tm.excluded"
	_ce=$(cmd_health store 2>&1)
	t_eq "and says nothing once it is excluded" \
		"$(printf '%s\n' "$_ce" | count_match 'is NOT excluded from Time Machine')" "0"
	rm -f "$T_ROOT/tm.excluded"

	## --install: named in the plan, and done in the run. The suite never runs a
	## real --install (it writes LaunchDaemons), so the call itself is checked
	## over the source.
	## t_setup clears CONFIG_SOURCED (loc_param re-reads it), and --install
	## refuses without a config -- give it one for this call only
	: >"$T_ROOT/ce.conf"
	# shellcheck disable=SC2030  # local to the subshell on purpose: it must not leak
	_ce_plan=$( ( is_root() { return 0; }; CONFIG_SOURCED=" $T_ROOT/ce.conf"; cmd_install ) 2>&1 )
	rm -f "$T_ROOT/ce.conf"
	t_match "the install plan names the exclusion" "$_ce_plan" "exclude:"
	if [ -r "$T_MYTM" ]; then
		t_eq "and --install runs tmutil addexclusion" \
			"$(awk '/^cmd_install\(\) \{/, /^\}/ { if (/tmutil addexclusion -p "\$CACHE_DIR"/) n++ } END { print n + 0 }' "$T_MYTM")" "1"
		t_eq "while --uninstall removes it again" \
			"$(awk '/^cmd_uninstall\(\) \{/, /^\}/ { if (/tmutil removeexclusion -p "\$CACHE_DIR"/) n++ } END { print n + 0 }' "$T_MYTM")" "1"
	else
		t_skip "--install excludes the cache dir" "not a readable checkout"
	fi
	return 0
}

# shellcheck disable=SC2031  # its own subshells set these on purpose
t_test_backup_result() {
	printf '\nThe recorded Time Machine result decides\n'
	_tr_save="$TM_PREFS_PLIST"; _tr_v="$BACKUP_VOLUME"; _tr_p="$POST_BACKUP_DEFAULT"
	_tr_plist="$T_ROOT/tm.plist"
	t_tm_plist() {
		{
			printf '<?xml version="1.0" encoding="UTF-8"?>\n'
			printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
			printf '<plist version="1.0"><dict><key>Destinations</key><array>\n'
			printf '<dict><key>DestinationID</key><string>OTHER-ID</string><key>RESULT</key><integer>0</integer></dict>\n'
			printf '<dict><key>DestinationID</key><string>11111111-2222-3333-4444-555555555555</string><key>RESULT</key><integer>%s</integer></dict>\n' "$1"
			printf '</array></dict></plist>\n'
		} >"$_tr_plist"
	}
	TM_PREFS_PLIST="$_tr_plist"

	t_tm_plist 704
	t_eq "the result is read for the matching destination, not the first one" \
		"$(tm_result_for 11111111-2222-3333-4444-555555555555)" "704"
	t_eq "and for the other one" "$(tm_result_for OTHER-ID)" "0"
	if tm_result_for NO-SUCH-ID >/dev/null 2>&1; then
		t_bad "an unknown destination must not resolve" ""
	else
		t_ok "an unknown destination does not resolve"
	fi
	t_eq "the stub's destination id is found by volume name" \
		"$(backup_destination_id store)" "11111111-2222-3333-4444-555555555555"

	## a run tmutil calls success, which Time Machine recorded as a failure
	# shellcheck disable=SC2030  # the settings are meant to stay in the subshell
	( is_root() { return 0; }
	  LOCKFILE="$T_ROOT/tr.lock"; BACKUP_VOLUME="store"; unset BACKUP_VOLUME_RESOLVED
	  POST_BACKUP_DEFAULT="none"; NOTIFY_BEGIN=0; NOTIFY_END=0
	  cmd_backup start ) >"$T_ROOT/tr.out" 2>&1
	_tr_o=$(cat "$T_ROOT/tr.out")
	t_match "a recorded failure is reported as one" "$_tr_o" "recorded a FAILURE"
	t_match "with both raw values beside it" "$_tr_o" "rc 0, Time Machine RESULT 704"
	t_eq "and never as finished" "$(printf '%s\n' "$_tr_o" | count_match 'backup finished')" "0"

	## the same run, recorded as a success
	t_tm_plist 0
	( is_root() { return 0; }
	  LOCKFILE="$T_ROOT/tr.lock"; BACKUP_VOLUME="store"; unset BACKUP_VOLUME_RESOLVED
	  POST_BACKUP_DEFAULT="none"; NOTIFY_BEGIN=0; NOTIFY_END=0
	  cmd_backup start ) >"$T_ROOT/tr.out" 2>&1
	_tr_o=$(cat "$T_ROOT/tr.out")
	t_match "RESULT 0 is a finished backup" "$_tr_o" "backup finished"
	t_match "and says so with the raw values" "$_tr_o" "rc 0, Time Machine RESULT 0"

	## leftovers are named, since they are what the store is refused for
	_tr_vd="$VOLUMES_DIR"; VOLUMES_DIR="$T_ROOT/vols"
	mkdir -p "$VOLUMES_DIR/store/2026-09-16-010719.inprogress"
	t_eq "an interrupted leftover is named" \
		"$(backup_leftovers_hint store 2>&1 | count_match 'interrupted leftover')" "1"
	rmdir "$VOLUMES_DIR/store/2026-09-16-010719.inprogress"
	t_eq "and a clean store says nothing" \
		"$(backup_leftovers_hint store 2>&1 | count_match 'interrupted leftover')" "0"
	VOLUMES_DIR="$_tr_vd"

	rm -f "$T_ROOT/tr.lock" "$T_ROOT/tr.out" "$_tr_plist"
	TM_PREFS_PLIST="$_tr_save"; BACKUP_VOLUME="$_tr_v"; POST_BACKUP_DEFAULT="$_tr_p"
	unset BACKUP_VOLUME_RESOLVED
	return 0
}

# shellcheck disable=SC2031  # a neighbouring test sets these inside its own subshell
t_test_backup_volume_unmounted() {
	printf '\nThe backup destination resolves while unmounted\n'
	_bu_v="$BACKUP_VOLUME"; _bu_p="$POST_BACKUP_DEFAULT"
	_bu_stub="$(t_stub_dir)/tmutil"; cp -p "$_bu_stub" "$T_ROOT/tmutil.bu"

	## one destination, no Mount Point line: exactly horse's case
	# shellcheck disable=SC2016  # writing a script: its $1 and $@ are the stub's own
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" = "destinationinfo" ]; then\n'
		printf '\tprintf "====\\nName          : TimeMachine.Horse\\nKind          : Local\\nID            : 1111\\n"\n'
		printf '\texit 0\n'
		printf 'fi\n'
		printf 'exec "%s" "$@"\n' "$T_ROOT/tmutil.bu"
	} >"$_bu_stub"
	chmod 0755 "$_bu_stub"
	BACKUP_VOLUME=""; unset BACKUP_VOLUME_RESOLVED
	t_eq "an unmounted destination resolves by its name" "$(backup_volume)" "TimeMachine.Horse"

	## and POST_BACKUP then acts on it
	: >"$(t_calls)"
	POST_BACKUP_DEFAULT="eject"; unset BACKUP_VOLUME_RESOLVED
	do_post_backup >/dev/null 2>&1
	t_eq "so POST_BACKUP acts on it" \
		"$(count_match 'diskutil eject /Volumes/TimeMachine.Horse' < "$(t_calls)")" "1"

	## no destination at all: say so, do not fall silent
	# shellcheck disable=SC2016  # same
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" = "destinationinfo" ]; then printf "No destinations configured.\\n"; exit 0; fi\n'
		printf 'exec "%s" "$@"\n' "$T_ROOT/tmutil.bu"
	} >"$_bu_stub"
	chmod 0755 "$_bu_stub"
	unset BACKUP_VOLUME_RESOLVED
	_bu_err=$( do_post_backup 2>&1 >/dev/null )
	t_match "with no destination at all it says so" "$_bu_err" "POST_BACKUP did nothing"

	mv -f "$T_ROOT/tmutil.bu" "$_bu_stub"
	BACKUP_VOLUME="$_bu_v"; POST_BACKUP_DEFAULT="$_bu_p"; unset BACKUP_VOLUME_RESOLVED
	return 0
}

# shellcheck disable=SC2031  # its own subshell sets these on purpose; cmd_backup's EXIT trap needs one
t_test_backup_already_running() {
	printf '\nA backup already running is left alone\n'
	_br_v="$BACKUP_VOLUME"; _br_p="$POST_BACKUP_DEFAULT"
	_br_stub="$(t_stub_dir)/tmutil"; cp -p "$_br_stub" "$T_ROOT/tmutil.br"
	# shellcheck disable=SC2016  # writing a script: its $1 and $@ are the stub's own
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" = "startbackup" ]; then printf "tmutil: Backup already in progress.\\n" >&2; exit 3; fi\n'
		printf 'exec "%s" "$@"\n' "$T_ROOT/tmutil.br"
	} >"$_br_stub"
	chmod 0755 "$_br_stub"
	: >"$(t_calls)"
	# shellcheck disable=SC2030  # the settings are meant to stay in the subshell
	( is_root() { return 0; }
	  LOCKFILE="$T_ROOT/br.lock"; BACKUP_VOLUME="store"; unset BACKUP_VOLUME_RESOLVED
	  POST_BACKUP_DEFAULT="eject"; NOTIFY_BEGIN=0; NOTIFY_END=0
	  cmd_backup start ) >"$T_ROOT/br.out" 2>&1
	t_eq "a backup already running is not ejected" \
		"$(count_match 'diskutil eject' < "$(t_calls)")" "0"
	t_eq "and not unmounted either" \
		"$(count_match 'diskutil unmountDisk' < "$(t_calls)")" "0"
	t_match "and my-tm says why" "$(cat "$T_ROOT/br.out")" "does not end a backup my-tm did not start"
	mv -f "$T_ROOT/tmutil.br" "$_br_stub"

	## No reader of locations_all may end its awk early: loc_line says why
	## ("awk must CONSUME the whole pipe here"), and on horse an early exit
	## made the producer take a SIGPIPE -- "printf: write error: Broken pipe"
	## during --backup. Reproducing that needs the real timing, so this is a
	## check of the SOURCE, not of a run.
	if [ -r "$T_MYTM" ]; then
		t_eq "no reader of locations_all ends its awk early" \
			"$(awk '/locations_all \| awk/, /\)|;/ { if (/exit/) n++ } END { print n + 0 }' "$T_MYTM")" "0"
	else
		t_skip "no reader of locations_all ends its awk early" "not a readable checkout"
	fi

	rm -f "$T_ROOT/br.lock" "$T_ROOT/br.out"
	BACKUP_VOLUME="$_br_v"; POST_BACKUP_DEFAULT="$_br_p"; unset BACKUP_VOLUME_RESOLVED
	return 0
}

# shellcheck disable=SC2031  # another test changes these settings only inside its own subshell
t_test_post_backup() {
	printf '\nPost-backup disk action\n'
	_pb_save_v="$BACKUP_VOLUME"; _pb_save_p="$POST_BACKUP_DEFAULT"
	_pb_save_l="$CONFIG_SOURCED"; _pb_save_f="$NO_EJECT_FLAGFILE"
	NO_EJECT_FLAGFILE="$T_ROOT/no-eject"
	CONFIG_SOURCED=""
	BACKUP_VOLUME="TestVol"

	## Where the log ends now, so each case reads only the calls IT made --
	## a count of matching lines is NOT a line offset, and using one as the
	## other made the "does not eject" case re-read the eject case above it.
	_pb_n() { count_lines < "$(t_calls)"; }

	POST_BACKUP_DEFAULT="eject"; unset BACKUP_VOLUME_RESOLVED
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_match "POST_BACKUP=eject ejects" "$_new" "diskutil eject /Volumes/TestVol"

	POST_BACKUP_DEFAULT="unmount"; unset BACKUP_VOLUME_RESOLVED
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_match "POST_BACKUP=unmount unmounts" "$_new" "diskutil unmountDisk /Volumes/TestVol"
	t_eq "and does NOT eject" "$(printf '%s\n' "$_new" | count_match 'eject')" "0"

	POST_BACKUP_DEFAULT="none"; unset BACKUP_VOLUME_RESOLVED
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_eq "POST_BACKUP=none touches the disk with nothing" \
		"$(printf '%s\n' "$_new" | count_match 'diskutil')" "0"

	POST_BACKUP_DEFAULT="eject"; unset BACKUP_VOLUME_RESOLVED
	: >"$NO_EJECT_FLAGFILE"
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_eq "the flag file suppresses the policy entirely" \
		"$(printf '%s\n' "$_new" | count_match 'diskutil')" "0"
	rm -f "$NO_EJECT_FLAGFILE"

	POST_BACKUP_DEFAULT="eject"
	# shellcheck disable=SC2016  # writing a config file: $LOCATION is its own
	printf 'set_location_parameters() {\n\tcase "$LOCATION" in\n\t\tstore) POST_BACKUP="unmount" ;;\n\t\tother) POST_BACKUP="none" ;;\n\tesac\n}\n' >"$T_ROOT/pb-params.conf"
	CONFIG_SOURCED=" $T_ROOT/pb-params.conf"
	t_eq "a per-location value beats POST_BACKUP_DEFAULT" \
		"$(post_backup_policy store)" "unmount"
	t_eq "and a location not named falls back to it" \
		"$(post_backup_policy nosuch)" "eject"
	## the backup itself must find the location behind its volume, or no
	## per-location value would ever reach the one command it exists for
	BACKUP_VOLUME="store"; unset BACKUP_VOLUME_RESOLVED
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_match "the backup volume's own POST_BACKUP applies after a backup" "$_new" "diskutil unmountDisk /Volumes/store"
	BACKUP_VOLUME="TestVol"; unset BACKUP_VOLUME_RESOLVED
	CONFIG_SOURCED=""; rm -f "$T_ROOT/pb-params.conf"

	_bad=$( ( POST_BACKUP_DEFAULT="sleep"; post_backup_policy store ) 2>&1 >/dev/null )
	t_match "an unknown value is refused, not silently defaulted" "$_bad" "none, unmount or eject"

	## REGRESSION: BACKUP_VOLUME="" used to mean "do nothing", while
	## tmutil startbackup wrote to its destination regardless -- my-tm backed
	## up to a disk it refused to name, mount or release.
	BACKUP_VOLUME=""; unset BACKUP_VOLUME_RESOLVED
	t_eq "an empty BACKUP_VOLUME resolves from tmutil" "$(backup_volume)" "store"
	POST_BACKUP_DEFAULT="eject"; unset BACKUP_VOLUME_RESOLVED
	_b=$(_pb_n); do_post_backup >/dev/null 2>&1
	_new=$(sed -n "$(( _b + 1 )),\$p" "$(t_calls)")
	t_match "and the action reaches that volume" "$_new" "diskutil eject /Volumes/store"

	## A disk my-tm just put to sleep must not be woken by a daemon two
	## minutes later -- that is what defeated the whole feature before.
	POST_BACKUP_DEFAULT="eject"; unset BACKUP_VOLUME_RESOLVED
	if loc_is_quiet store; then t_ok "a location with a post-backup action is quiet"
	else t_bad "store should be quiet under POST_BACKUP=eject" ""; fi
	POST_BACKUP_DEFAULT="none"; unset BACKUP_VOLUME_RESOLVED
	if loc_is_quiet store; then t_bad "POST_BACKUP=none must not make it quiet" ""
	else t_ok "POST_BACKUP=none leaves it an ordinary location"; fi

	## ...and the rule has to hold where it is USED, not only where it is
	## decided: loc_open is what every daemon reaches the disk through.
	_pb_sv="$TRANSIENT_VOLUMES"; TRANSIENT_VOLUMES="$T_ROOT/pb.volumes"
	rm -f "$TRANSIENT_VOLUMES"
	BACKUP_VOLUME="UnmountedStore"; POST_BACKUP_DEFAULT="eject"
	unset BACKUP_VOLUME_RESOLVED
	printf 'quietstore\t/Volumes/UnmountedStore\t\n' >>"$T_ROOT/cache/locations.tsv"

	BACKGROUND_JOB=1
	: >"$(t_calls)"
	loc_open quietstore >/dev/null 2>&1
	t_eq "a daemon does not mount a quiet location" \
		"$(count_match 'diskutil mount' < "$(t_calls)")" "0"

	BACKGROUND_JOB=0
	: >"$(t_calls)"
	loc_open quietstore >/dev/null 2>&1
	t_eq "but an interactive command still does -- somebody asked" \
		"$(count_match 'diskutil mount UnmountedStore' < "$(t_calls)")" "1"
	cleanup_volumes >/dev/null 2>&1

	grep -v '^quietstore	' "$T_ROOT/cache/locations.tsv" >"$T_ROOT/cache/l.pb" &&
		mv "$T_ROOT/cache/l.pb" "$T_ROOT/cache/locations.tsv"
	rm -f "$TRANSIENT_VOLUMES"; TRANSIENT_VOLUMES="$_pb_sv"

	BACKUP_VOLUME="$_pb_save_v"; POST_BACKUP_DEFAULT="$_pb_save_p"
	CONFIG_SOURCED="$_pb_save_l"; NO_EJECT_FLAGFILE="$_pb_save_f"
	unset BACKUP_VOLUME_RESOLVED
}

t_test_version_output() {
	printf '\n--version\n'
	_err=$( "$T_MYTM" --version 2>&1 >/dev/null )
	t_eq "it prints no errors" "$_err" ""
	_out=$( "$T_MYTM" --version 2>/dev/null )
	t_match "the version number is there" "$_out" "[0-9]\.[0-9]"
	t_match "and the file it ran from" "$_out" "my-tm"
	t_eq "the path is clean" "$(printf '%s' "$_out" | count_match '/./')" "0"
	t_eq "abs_path normalises a dot component" \
		"$(cd /tmp && abs_path ./x/y)" "/tmp/x/y"
}

run_tests() {
	T_WITH_SNAPSHOTS=0
	for _a in "$@"; do
		[ "$_a" = "--with-snapshots" ] && T_WITH_SNAPSHOTS=1
	done
	if is_root; then
		printf ' !!! do not run the tests as root -- they must pass unprivileged.\n' >&2
		exit 1
	fi
	printf '%s %s -- self test\n' "$US" "$MY_TM_VERSION"
	t_setup

	t_test_ids
	t_test_handles
	t_test_ttl
	t_test_format
	t_test_manifest
	t_test_states
	t_test_previous_is_not_a_state
	t_test_thin
	t_test_config
	t_test_location_parameters
	t_test_locations
	t_test_handle_characters
	t_test_one_shared_location_list
	t_test_ladder
	t_test_mount_records
	t_test_version_store
	t_test_atomic
	t_test_plists
	t_test_rm_dryrun
	t_test_help
	t_test_paths
	t_test_version_output
	t_test_post_backup
	t_test_backup_already_running
	t_test_backup_volume_unmounted
	t_test_backup_result
	t_test_cache_excluded
	t_test_config_search_order
	t_test_attach_progress
	t_test_lsof_never_answers
	t_test_install_builds_no_tree
	t_test_runs_without_home
	t_test_autodetect_mode
	t_test_cache_unreadable
	t_test_install_config
	t_test_install_logs
	t_test_job_plist_streams
	t_test_network_volume_of
	t_test_launcher
	t_test_install_launcher
	t_test_job_guidance
	t_test_detection_dedup
	t_test_ejected_destination
	t_test_auto_mount_destinations
	t_test_verify_reports
	t_test_locate_toolchain
	t_test_indexer_exemption_expires
	t_test_lookup_collapse
	t_test_progress_goes_to_stderr
	t_test_usage_trend
	t_test_version_store_pruning
	t_test_prune_without_version_store
	t_test_delta_removals_by_path
	t_test_presence_by_size_not_inode
	t_test_full_disk_access
	t_test_bundle_ownership
	t_test_network_bundles
	t_test_add_picker
	t_test_image_orphan_adoption
	t_test_snapshot_set_is_validated
	t_test_no_exclusive_size_claims
	t_test_site_conf_dir_from_env
	t_test_detached_store_still_answers
	t_test_rm_needs_the_store
	t_test_volume_paths
	t_test_mount_root_fallback
	t_test_version_store_generation
	t_test_local_list_never_cached
	t_test_maintenance_keeps_other_tables
	t_test_commands_keep_other_tables
	t_test_local_snapshots

	t_teardown
	printf '\n%s passed, %s failed, %s skipped\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
	[ "$T_FAIL" -eq 0 ] || return 1
	return 0
}

#############################################################################
main "$@"

