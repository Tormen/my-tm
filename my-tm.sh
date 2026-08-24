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

US="${0##*/}"
MY_TM_VERSION="0.9"

#############################################################################
## DEFAULTS -- all neutral.  Site values belong in the config file, never here.
#############################################################################

AUTODETECT_LOCAL_TM_BACKUPS=1
DEFAULT_CMD="--status"
TM_GROUP=""
CACHE_DIR="/var/lib/my-tm"
CACHE_MODE=0750
CACHE_DIR_USER="$HOME/Library/Caches/my-tm"
LOG_DIR="$HOME/Library/Logs/my-tm"
FIRMLINK="/tm"
MOUNT_ROOT="/var/lib/my-tm/mount"
SITE_CONF_DIR="/usr/local/etc"
NOTIFY_MOUNT_WARN=1
CACHE_TTL=3600
INDEX_BASELINES="newest oldest"
INDEX_INC_MAX=16
INDEX_REMOTE_COPY=1
ID_LEN=6
THIN_POLICY_TO_KEEP="24h:hourly 7d:daily 4w:weekly 2y:monthly"
THIN_POLICY_PER_LOCATION=""
HEALTH_INTERVAL="1d"
HEALTH_JOB="local.my-tm.health-check"
HEALTH_LOCATIONS="LOCAL"
HEALTH_VERIFY=""
HEALTH_WATCH_PATHS=""
HEALTH_MAX_AGE_H=48
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
NOTIFY_CMD=""
NO_EJECT_FLAGFILE="/var/lib/my-tm/no-eject"
LOCKFILE="/var/lib/my-tm/backup.lock"
NOTIFY_BEGIN=0
NOTIFY_END=1
EJECT_RETRIES=10
EJECT_WAIT=5

## how long a mount made on the way into a command lives if the command dies
## without cleaning up.  Not user-tunable: it is a leak-reaper, not a policy.
TRANSIENT_TTL=900

## how many snapshots --lookup holds mounted at once.  Bounded on purpose: each
## mount pins its snapshot against thinning, and releasing one is not free.
LOOKUP_CHUNK=16

#############################################################################
## RUNTIME STATE (never in the config)
#############################################################################

VRB=0; DBG=0; DEEPDBG=0; DBG_PATH=""
JSON=0; OPT_ALL=0; LIMIT=""; FORCE=0; SRC=""
CONFIG_FILE=""; CONFIG_SOURCED=""
EXIT_RC=0

## Mountpoints to release when this run ends.  A FILE, not a variable: every
## caller reaches transient_snapshot through $(...), which is a subshell, and a
## variable set there dies with it -- leaving the snapshot mounted, which is
## exactly what blocks Time Machine's thinning.
TRANSIENT_LIST="${TMPDIR:-/tmp}/.my-tm.transient.$$"

#############################################################################
## OUTPUT
##   >>>  major step        >>   medium        >    minor detail
##   ~~~  debug             ~    fine debug (-DD)
#############################################################################

msg()   { printf ' >>> %s\n' "$*"; }
med()   { printf '  >> %s\n' "$*"; }
minor() { printf '    > %s\n' "$*"; }
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
	[ "$VRB" = "1" ] && printf ' >>> %s\n' "$*"
	"$@"
}

## same, but for a command whose output is captured: caller does the exec.
run_echo() {
	[ "$VRB" = "1" ] && printf ' >>> %s\n' "$*"
	return 0
}

## a `    > ` explanation belonging to the command echoed just above
why() {
	[ "$VRB" = "1" ] || return 0
	printf '    > %s\n' "$*"
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
#   $MY_TM_CONFIG · --config <FILE> · $SITE_CONF_DIR/my-tm.conf
#   · ~/.my-tm.conf · /etc/my-tm.conf · /usr/local/etc/my-tm.conf
# When both a shared and a host-specific file sit at the site location, the
# host-specific one is my-tm.conf and the shared one is my-tm.conf.GLOBAL;
# my-tm sources .GLOBAL first, then my-tm.conf on top.

# Locations live in $CACHE_DIR/locations.tsv, maintained by --add / --forget --
# not in this file.
AUTODETECT_LOCAL_TM_BACKUPS=1   # also pick up destinations tmutil reports
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
ID_LEN=6
# --- retention ---
THIN_POLICY_TO_KEEP="24h:hourly 7d:daily 4w:weekly 2y:monthly"
THIN_POLICY_PER_LOCATION=""
# --- health ---
HEALTH_INTERVAL="1d"            # "" / 0 / false -> no daemon installed
HEALTH_JOB="local.my-tm.health-check"
HEALTH_LOCATIONS="LOCAL"        # ON-THIS-DISK | LOCAL | ALL | handles | paths
HEALTH_VERIFY=""                # "" = off; else a list of paths, one per line
HEALTH_WATCH_PATHS=""           # paths that MUST be covered by a backup
HEALTH_MAX_AGE_H=48; HEALTH_MIN_FREE_PCT=10
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
# --- backup control ---
BACKUP_VOLUME=""                # "" = TM's own destination
NOTIFY_CMD=""                   # optional external notifier; empty = osascript
NO_EJECT_FLAGFILE="/var/lib/my-tm/no-eject"
LOCKFILE="/var/lib/my-tm/backup.lock"
NOTIFY_BEGIN=0; NOTIFY_END=1
EJECT_RETRIES=10; EJECT_WAIT=5
_CFG_EOF
}

## echo every config file to source, in order (base first, override last)
config_candidates() {
	if [ -n "${MY_TM_CONFIG:-}" ]; then
		printf '%s\n' "$MY_TM_CONFIG"
		return 0
	fi
	if [ -n "$CONFIG_FILE" ]; then
		printf '%s\n' "$CONFIG_FILE"
		return 0
	fi
	for _d in "$SITE_CONF_DIR" "$HOME" /etc /usr/local/etc; do
		case "$_d" in
			"$HOME") _f="$_d/.my-tm.conf" ;;
			*)       _f="$_d/my-tm.conf" ;;
		esac
		if [ -f "$_f" ]; then
			[ -f "$_f.GLOBAL" ] && printf '%s\n' "$_f.GLOBAL"
			printf '%s\n' "$_f"
			return 0
		fi
	done
	return 1
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
atomic_write() {
	_f="$1"
	_d=$(dirname "$_f")
	need_dir "$_d" || return 1
	_t=$(mktemp "$_d/.my-tm.XXXXXX") || return 1
	cat >"$_t" || { rm -f "$_t"; return 1; }
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
		if (i == 1)      printf "%d\n", b;
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

locations_file() { printf '%s/locations.tsv\n' "$(cache_write_dir)"; }

## every registered location, shared file first, then this user's own
locations_registered() {
	for _d in $(cache_read_dirs); do
		[ -f "$_d/locations.tsv" ] || continue
		grep -v '^[[:space:]]*#' "$_d/locations.tsv" 2>/dev/null | grep -v '^[[:space:]]*$'
	done
	return 0
}

## tmutil's own destinations -> handle <TAB> mountpoint <TAB> "" <TAB> uuid
destinations_scan() {
	tmutil destinationinfo 2>/dev/null | awk '
		/^Name +:/        { sub(/^[^:]*: */, ""); name = $0 }
		/^Kind +:/        { sub(/^[^:]*: */, ""); kind = $0 }
		/^Mount Point +:/ { sub(/^[^:]*: */, ""); mp   = $0 }
		/^ID +:/          { sub(/^[^:]*: */, ""); id   = $0;
		                    if (mp != "") printf "%s\t%s\t%s\t%s\n", name, mp, id, kind;
		                    name = ""; kind = ""; mp = ""; id = "" }
	'
}

## all locations: registered + (optionally) autodetected + the `local` pseudo
## emits: handle <TAB> target <TAB> installdir
locations_all() {
	_seen=""
	_reg=$(locations_registered)
	if [ -n "$_reg" ]; then
		while IFS= read -r _l; do
			[ -n "$_l" ] || continue
			_h=$(printf '%s' "$_l" | awk -F'\t' '{print $1}')
			[ -n "$_h" ] || continue
			_seen="$_seen $_h"
			printf '%s\n' "$_l"
		done <<_EOF
$_reg
_EOF
	fi
	if [ "$AUTODETECT_LOCAL_TM_BACKUPS" = "1" ]; then
		_dst=$(destinations_scan)
		if [ -n "$_dst" ]; then
			while IFS="$(printf '\t')" read -r _name _mp _id _kind; do
				[ -n "${_mp:-}" ] || continue
				_h=$(slug "$_name")
				case " $_seen " in *" $_h "*) continue ;; esac
				## a handle that could read as an ID is unusable (rung 1 wins)
				is_id_word "$_h" && _h="${_h}-tm"
				_seen="$_seen $_h"
				printf '%s\t%s\t\n' "$_h" "$_mp"
			done <<_EOF
$_dst
_EOF
		fi
	fi
	case " $_seen " in
		*" local "*) : ;;
		*) printf 'local\tlocal\t\n' ;;
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

## the volume whose APFS snapshots this location holds
loc_volume() {
	_t=$(loc_target "$1")
	case "$_t" in
		local) printf '/System/Volumes/Data\n' ;;
		*)     printf '%s\n' "$_t" ;;
	esac
}

## device node of a mounted volume (disk5s2)
vol_device() {
	_plist=$(mktemp /tmp/my-tm.disk.XXXXXX) || return 1
	if diskutil info -plist "$1" >"$_plist" 2>/dev/null; then
		plutil -extract DeviceIdentifier raw -o - "$_plist" 2>/dev/null
	fi
	rm -f "$_plist"
	return 0
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
	[ -d "$_t" ] || return 0
	_dev=$(vol_device "$_t")
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
	[ -d "$_t" ] || return 0
	for _e in "$_t"/*.inprogress "$_t"/*.interrupted "$_t"/*.previous; do
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

	if [ "$(loc_target "$_h")" = "local" ]; then
		: >"$_tmpd/manifest"
	else
		manifest_parse "$(loc_target "$_h")" >"$_tmpd/manifest" 2>/dev/null || : >"$_tmpd/manifest"
	fi
	snap_states "$_h" >"$_tmpd/states" 2>/dev/null || : >"$_tmpd/states"
	unique_cache_dump "$_h" >"$_tmpd/unique" 2>/dev/null || : >"$_tmpd/unique"

	awk -F'\t' -v loc="$_h" '
		FILENAME ~ /manifest$/ { mf[$1] = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; next }
		FILENAME ~ /states$/   { st[$1] = $2; next }
		FILENAME ~ /unique$/   { uq[$1] = $2; next }
		FILENAME ~ /snaps$/ {
			ep = $1; ts = $2;
			files = "-"; added = "-"; total = "-"; vol = "-"; xid = "-";
			if (ep in mf) { split(mf[ep], m, "\t");
				files = m[1]; added = m[2]; total = m[3]; vol = m[4]; xid = m[5] }
			state = (ts in st) ? st[ts] : "ok";
			uniq  = (ts in uq) ? uq[ts] : "-";
			## every field carries a placeholder, never an empty string: tab is
			## an IFS *whitespace* character, so two adjacent tabs would count
			## as ONE delimiter and shift every later column left.
			printf "%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			       loc, ts, ep, xid, files, added, total, uniq, state, vol;
		}
	' "$_tmpd/manifest" "$_tmpd/states" "$_tmpd/unique" "$_tmpd/snaps" |
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
	_cf=$(snapshots_cache_file)
	_fresh=0
	if [ -f "$_cf" ]; then
		_age=$(( $(now_epoch) - $(stat -f '%m' "$_cf" 2>/dev/null || echo 0) ))
		[ "$_age" -lt "$CACHE_TTL" ] && _fresh=1
	fi
	if [ "$_fresh" = "1" ]; then
		_cached=$(awk -F'\t' -v l="$_h" '$1 == l' "$_cf" 2>/dev/null)
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
	[ -f "$_cf" ] && _old=$(awk -F'\t' -v l="$_h" '$1 != l' "$_cf" 2>/dev/null)
	{
		[ -n "$_old" ] && printf '%s\n' "$_old"
		printf '%s\n' "$_rows"
	} | atomic_write "$_cf" 2>/dev/null || dbg "snapshots cache not writable: $_cf"
	return 0
}

## every location's rows
snapshots_all() {
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_reachable "$_h" || continue
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

mnt_private_root() { printf '%s/.mnt\n' "$MOUNT_ROOT"; }
mnt_point_for()    { printf '%s/.mnt/%s/%s\n' "$MOUNT_ROOT" "$1" "$2"; }

## where the volume actually sits inside a mounted snapshot
mnt_volume_path() {
	_loc="$1"; _ts="$2"; _vol="$3"
	_m=$(mnt_point_for "$_loc" "$_ts")
	if [ "$(loc_target "$_loc")" = "local" ]; then
		printf '%s/%s\n' "$_m" "$_vol"
	else
		printf '%s/%s.backup/%s\n' "$_m" "$_ts" "$_vol"
	fi
}

mount_table_has() {
	mount | awk -v p="$1" 'index($0, " on " p " (") > 0 { f = 1 } END { exit(f ? 0 : 1) }'
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

	if mount_table_has "$_mp"; then
		dbg "already mounted: $_mp"
		mount_record_add "$_id" "$_loc" "$_mp" "$_ttl" "$_flags"
		printf '%s\n' "$_mp"
		return 0
	fi
	need_dir "$_mp" || { warn "cannot create mountpoint: $_mp"; return 1; }
	if run mount_apfs -s "$_apfs" "$_vol_src" "$_mp" >/dev/null 2>&1; then
		why "read-only snapshot mount; no root needed, and it pins the snapshot until released"
		mount_record_add "$_id" "$_loc" "$_mp" "$_ttl" "$_flags"
		printf '%s\n' "$_mp"
		return 0
	fi
	warn "mount failed: $_apfs on $_vol_src"
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
		run umount -f "$_mp" >/dev/null 2>&1 || return 1
	else
		run umount "$_mp" >/dev/null 2>&1 || return 1
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

trap 'cleanup_transient' EXIT
trap 'cleanup_transient; exit 130' INT
trap 'cleanup_transient; exit 143' TERM

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
	if [ -s "$_bl" ]; then
		tr '\n' '\0' <"$_bl" | xargs -0 lsof -n -P -- 2>/dev/null |
			awk 'NR > 1 {print $NF}' | sort -u
	fi
	rm -f "$_bl"
	return 0
}

tm_backup_running() {
	tmutil status 2>/dev/null | grep -q 'Running = 1'
}

## free percent of a mounted volume
vol_free_pct() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { if ($2 > 0) printf "%d\n", ($4 * 100) / $2; else print 100 }'
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
		if ! mount_table_is_snapshot "$_mp"; then
			dbg "sweep: stale record dropped ($_mp)"
			mount_record_drop "$_mp"
			continue
		fi
		case "${_flags:-}" in
			*indexer*)
				dbg "sweep: indexer mount exempt ($_mp)"
				continue
				;;
		esac
		_age=$(( _now - ${_made:-0} ))
		_expired=0
		[ "$_age" -ge "${_ttl:-0}" ] && _expired=1
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
		_target=$(mnt_volume_path "$_l" "$_ts" "$_vol")
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
		loc_reachable "$_h" || continue
		dbg "refreshing tree for $_h"
		tm_refresh_loc "$_h"
	done <<_EOF
$_locs
_EOF
	tm_write_readme
	return 0
}

tm_write_readme() {
	[ -d "$MOUNT_ROOT" ] || return 0
	_r=$(tm_root)
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

vs_file() { printf '%s/index/versions.tsv\n' "$(cache_write_dir)"; }

vs_lookup() {
	_loc="$1"; _ts="$2"; _p="$3"
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
	_f=$(vs_file)
	need_dir "$(dirname "$_f")" || return 1
	_new=$(mktemp /tmp/my-tm.vs.XXXXXX) || return 1
	awk -F'\t' -v l="$_loc" '{printf "%s\t%s\t%s\t%s\t%s\t%s\n", l, $1, $2, $3, $4, $5}' >"$_new"
	{
		[ -f "$_f" ] && cat "$_f"
		cat "$_new"
	} | sort -u | atomic_write "$_f" 2>/dev/null || dbg "version store not writable: $_f"
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

## ts <TAB> uniquesize for every indexed snapshot of a location
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
	_loc="$1"; _ts="$2"; _uniq="${3:--}"
	_f=$(index_covered_file "$_loc")
	need_dir "$(dirname "$_f")" || return 1
	_old=""
	[ -f "$_f" ] && _old=$(awk -F'\t' -v t="$_ts" '$1 != t' "$_f" 2>/dev/null)
	{
		[ -n "$_old" ] && printf '%s\n' "$_old"
		printf '%s\t%s\n' "$_ts" "$_uniq"
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

		if loc_reachable "$_h"; then
			_rows=$(snapshots_get "$_h")
			if [ -n "$_rows" ]; then
				_snaps=$(printf '%s\n' "$_rows" | count_lines)
				_first=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | head -n 1 | awk -F'\t' '{print $2}')
				_lastts=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | tail -n 1 | awk -F'\t' '{print $2}')
				_lastep=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | tail -n 1 | awk -F'\t' '{print $3}')
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
		else
			_mark="?"
		fi
		printf " %-${_w}s %-30s %6s  %-24s %5s%1s  %s\n" \
			"$_h" "$(printf '%s' "$_dest" | cut -c1-30)" \
			"$_snaps" "$_span" "$_last" "$_mark" "$_space"
	done <<_EOF
$_locs
_EOF

	## footer: what the caches cost, and whether the index is behind
	_csize="-"
	_cf=$(snapshots_cache_file)
	[ -f "$_cf" ] && _csize=$(human_bytes "$(wc -c <"$_cf" | tr -d ' ')")
	_isize="-"
	[ -d "$(index_dir)" ] &&
		_isize=$(human_bytes "$(find "$(index_dir)" -type f -exec wc -c {} + 2>/dev/null |
			awk 'END {print $1 + 0}')")
	_note="cache $_csize · index $_isize"
	_first_loc=$(printf '%s\n' "$_locs" | awk -F'\t' '$2 != "local" && !f {print $1; f = 1}')
	if [ -n "$_first_loc" ]; then
		_cov=$(index_covered_count "$_first_loc")
		_tot=$(snapshots_get "$_first_loc" | count_lines)
		[ "$_tot" -gt 0 ] && _note="$_note ($_cov/$_tot snaps, $US --index $_first_loc)"
	fi
	note "$_note"
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
		loc_reachable "$_h" || continue
		_rows=$(snapshots_get "$_h")
		[ -n "$_rows" ] || continue
		printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3nr |
		while IFS="$(printf '\t')" read -r _l _ts _ep _id _xid _f _a _t2 _u _st _vol; do
			[ -n "${_ts:-}" ] || continue
			[ "$_first" = "1" ] && _first=0 || printf ',\n'
			printf '  {"location": "%s", "snapshot": "%s", "id": "%s", "epoch": %s,' \
				"$(json_escape "$_l")" "$_ts" "$_id" "${_ep:-0}"
			printf ' "files": "%s", "added": "%s", "total": "%s", "unique": "%s",' \
				"${_f:--}" "${_a:--}" "${_t2:--}" "${_u:--}"
			printf ' "state": "%s", "volume": "%s"}' "${_st:-ok}" "$(json_escape "${_vol:--}")"
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
		loc_reachable "$_h" || continue
		_rows=$(snapshots_get "$_h")
		[ -n "$_rows" ] || continue
		[ -z "$_only" ] && printf '\n%s:\n' "$_h"

		_max="${LIMIT:-20}"
		[ "$OPT_ALL" = "1" ] && _max=0
		_total=$(printf '%s\n' "$_rows" | count_lines)
		## the MEDIAN, not the mean: a handful of huge backups (a VM image, a
		## restored archive) drag a mean up until every ordinary night reads
		## 0.0x and a real spike no longer stands out.
		_avg=$(added_median "$_rows")

		printf ' %-8s %-20s %5s %6s %6s %6s %6s %7s  %s\n' \
			ID SNAPSHOT AGE FILES ADDED DRIFT TOTAL UNIQUE VOL
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
				printf ' %-8s %-20s %5s %6s %6s %6s %6s %7s  %s%s\n' \
					"$_id" "$(ts_display "$_ts")" "$_age" \
					"$(human_count "$_files")" "$(human_bytes "$_added")" "$_drift" \
					"$(human_bytes "$_total2")" \
					"$(size_or_q "${_uniq:--}")" \
					"${_vol:--}" "$_st"
			done
		}
		if [ "$_max" -gt 0 ] && [ "$_total" -gt "$_max" ]; then
			note "$(( _total - _max )) more (--all) · ADDED median $(human_bytes "$_avg")"
		else
			note "$_total snapshots · ADDED median $(human_bytes "$_avg")"
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
	_uuid=$(vol_uuid "$_a")
	_any=0
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_reachable "$_h" || continue
		loc_is_remote "$_h" && continue
		if [ "$(loc_target "$_h")" = "local" ]; then
			[ "$_uuid" = "$(vol_uuid /System/Volumes/Data)" ] && { printf '%s\n' "$_h"; _any=1; }
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
		while IFS="$(printf '\t')" read -r _l _ts _ep _id _x _f _a _t2 _u _st _vol; do
			[ -n "${_ts:-}" ] || continue
			if _hit=$(vs_lookup "$_h" "$_ts" "$_rel"); then
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
		fi

		## collapse identical versions (inode+size+mtime), newest row per group
		printf ' %-8s %-20s %5s %6s  %s\n' ID SNAPSHOT AGE SIZE STATE
		_now=$(now_epoch)
		sort -t"$(printf '\t')" -k2,2nr "$_work/known" | awk -F'\t' -v now="$_now" \
			-v li="${_live_i:--}" -v ls="${_live_s:--}" -v lm="${_live_m:--}" '
			{
				key = $4 "|" $5 "|" $6;
				if (key == prev) next;
				prev = key;
				print $0;
			}
		' >"$_work/distinct"

		_ndist=0
		while IFS="$(printf '\t')" read -r _ts _ep _id _i _s _m; do
			[ -n "${_ts:-}" ] || continue
			_ndist=$(( _ndist + 1 ))
			if [ "${_i:--}" = "-" ]; then
				_state="absent"; _size="-"
			elif [ "$_i" = "${_live_i:-x}" ] && [ "$_s" = "${_live_s:-x}" ] && [ "$_m" = "${_live_m:-x}" ]; then
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
		if [ "${_uniq:--}" = "-" ]; then
			printf ' %-10s ? (%s --unique %s)\n' UNIQUE "$US" "$_id"
		else
			printf ' %-10s %s\n' UNIQUE "$(human_bytes "$_uniq")"
		fi
		printf ' %-10s %s\n' VOLUME "$_vol"
		printf ' %-10s %s\n' STATE "${_state:-ok}"
		printf ' %-10s %s/%s/%s/%s\n' BROWSE "$(tm_root)" "$_loc" "$_ts" "$_vol"
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
		/*) printf '%s\n' "$1" ;;
		*)  printf '%s/%s\n' "$PWD" "$1" ;;
	esac
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
			if [ -n "$_where" ]; then
				printf '%s\n' "$_got"
			else
				printf '%s/%s/%s/%s\n' "$(tm_root)" "$_h" "$_ts" "$_vol"
			fi
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
	if [ -n "$_where" ]; then
		printf '%s\n' "$_got"
	else
		printf '%s/%s/%s/%s\n' "$(tm_root)" "$_loc" "$_ts" "$_vol"
	fi
	return 0
}

cmd_umount() {
	_what="${1:-}"
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
	_targets="$*"
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
	run_echo find "$_base" -print
	find "$_base" -print 2>/dev/null | sed "s|^$_base||" | sort >"$_paths"
	_count=$(count_lines < "$_paths")
	if [ "$_count" -gt 0 ]; then
		locate.mklocatedb <"$_paths" >"$_inc" 2>/dev/null ||
			warn "$_ts: mklocatedb failed"
	fi

	## exclusive size on the same trip over the disk
	_uniq="-"
	_u=$(tmutil uniquesize "$_base" 2>/dev/null | awk '{print $1; exit}')
	case "${_u:-}" in
		[0-9]*) _uniq="$_u" ;;
	esac
	index_mark_covered "$_h" "$_ts" "$_uniq"
	msg "$(human_count "$_count") paths indexed$([ "$_uniq" != "-" ] && printf ', exclusive size %s' "$(human_bytes "$_uniq")")"
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
	_all=$(mktemp /tmp/my-tm.cons.XXXXXX) || return 1
	for _f in "$_dir/$_h.db" "$_dir/$_h".inc.*.db; do
		[ -f "$_f" ] || continue
		locate -d "$_f" '*' 2>/dev/null >>"$_all"
	done
	sort -u "$_all" | locate.mklocatedb >"$_dir/$_h.db.new" 2>/dev/null &&
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
## --unique / --verify
#############################################################################

cmd_unique() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	transient_snapshot "$_loc" "$_ts" >/dev/null || err "could not mount"
	_base=$(mnt_volume_path "$_loc" "$_ts" "$_vol")
	note "walking the snapshot -- this is the same trip over the disk --index makes"
	_u=$(run tmutil uniquesize "$_base" 2>/dev/null | awk '{print $1; exit}')
	case "${_u:-}" in
		[0-9]*) index_mark_covered "$_loc" "$_ts" "$_u"
		        printf ' %-8s %s\n' "$(printf '%s' "$_hit" | awk -F'\t' '{print $3}')" "$(size_or_q "$_u")" ;;
		*) warn "tmutil uniquesize gave nothing back (Full Disk Access?)" ;;
	esac
	return 0
}

cmd_verify() {
	_hit=$(resolve_id "$1") || snapshot_gone "$1"
	shift
	_loc=$(printf '%s' "$_hit" | awk -F'\t' '{print $1}')
	_ts=$(printf '%s' "$_hit" | awk -F'\t' '{print $2}')
	_vol=$(snapshots_get "$_loc" | awk -F'\t' -v t="$_ts" '$2 == t {print $11; exit}')
	[ "${_vol:--}" = "-" ] && _vol="Data"
	transient_snapshot "$_loc" "$_ts" >/dev/null || err "could not mount"
	_base=$(mnt_volume_path "$_loc" "$_ts" "$_vol")
	if [ "$#" -eq 0 ]; then
		note "verifying the whole snapshot is slow; a directory or one file is quick"
		run tmutil verifychecksums "$_base"
	else
		for _p in "$@"; do
			run tmutil verifychecksums "$_base$(path_in_volume "$(abs_path "$_p")")"
		done
	fi
	return 0
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
		*)    printf '    > %s\n' "$*" ;;
	esac
	return 0
}

cmd_health() {
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
		if ! loc_reachable "$_h"; then
			health_say fail "$_h: destination not reachable"
			continue
		fi
		_t=$(loc_target "$_h")
		_rows=$(snapshots_get "$_h")
		if [ -z "$_rows" ]; then
			health_say fail "$_h: no snapshots found"
			continue
		fi
		_lastep=$(printf '%s\n' "$_rows" | sort -t"$(printf '\t')" -k3,3n | tail -n 1 | awk -F'\t' '{print $3}')
		_agh=$(( (_now - _lastep) / 3600 ))
		if [ "$_agh" -gt "$HEALTH_MAX_AGE_H" ]; then
			health_say fail "$_h: newest backup is ${_agh}h old (limit ${HEALTH_MAX_AGE_H}h) -- Time Machine fails silently, this is the one to watch"
		else
			health_say ok "$_h: newest backup ${_agh}h old"
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
		health_say warn "no local APFS snapshots -- the only history that works with the backup disk detached"

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
		## the cache is an index, never the authority for a destructive call:
		## re-verify against the store before naming it for deletion.
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

	while IFS="$(printf '\t')" read -r _loc _ts _id _u; do
		if [ "$(loc_target "$_loc")" = "local" ]; then
			run tmutil deletelocalsnapshots "$_ts" || warn "$_id: delete failed"
		else
			run tmutil delete -d "$(loc_target "$_loc")" -t "$_ts" || warn "$_id: delete failed"
		fi
	done <"$_plan"
	rm -f "$_plan"
	snapshots_cache_invalidate
	return 0
}

snapshots_cache_invalidate() {
	_cf=$(snapshots_cache_file)
	[ -f "$_cf" ] && rm -f "$_cf"
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
		loc_reachable "$_h" || continue
		## CLI beats per-location beats global
		_p="$_policy"
		if [ -z "$_p" ]; then
			_p=$(printf '%s\n' "$THIN_POLICY_PER_LOCATION" |
				awk -v l="$_h" '$1 == l {$1 = ""; sub(/^ /, ""); print; exit}')
		fi
		[ -n "$_p" ] || _p="$THIN_POLICY_TO_KEEP"
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
				run tmutil delete -d "$(loc_target "$_h")" -t "$_ts" || warn "$_ts: delete failed"
			fi
		done
		snapshots_cache_invalidate
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

do_eject() {
	[ -n "$BACKUP_VOLUME" ] || return 0
	if [ -f "$NO_EJECT_FLAGFILE" ]; then
		msg "not ejecting: $NO_EJECT_FLAGFILE exists"
		return 0
	fi
	_i=1
	while [ "$_i" -le "$EJECT_RETRIES" ]; do
		sync
		if run diskutil eject "/Volumes/$BACKUP_VOLUME" >/dev/null 2>&1; then
			msg "ejected $BACKUP_VOLUME (attempt $_i)"
			return 0
		fi
		dbg "eject attempt $_i/$EJECT_RETRIES failed; waiting ${EJECT_WAIT}s"
		sleep "$EJECT_WAIT"
		_i=$(( _i + 1 ))
	done
	warn "could not eject $BACKUP_VOLUME after $EJECT_RETRIES attempts"
	return 1
}

cmd_backup() {
	_action="${1:-}"
	shift 2>/dev/null || true
	for _a in "$@"; do
		case "$_a" in
			--set-no-eject) run touch "$NO_EJECT_FLAGFILE" || err "cannot create $NO_EJECT_FLAGFILE"
			                why "while this file exists no auto-eject happens" ;;
			--set-eject)    run rm -f "$NO_EJECT_FLAGFILE"
			                why "removed, so the disk is ejected again after a backup" ;;
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
		do_eject
		return 0
	fi

	if [ -n "$BACKUP_VOLUME" ] && [ ! -d "/Volumes/$BACKUP_VOLUME" ]; then
		run diskutil mount "$BACKUP_VOLUME" || err "could not mount $BACKUP_VOLUME"
	fi
	[ "$NOTIFY_BEGIN" = "1" ] && notify "Time Machine backup starting"
	run tmutil startbackup --block
	_rc=$?
	case "$_rc" in
		0) msg "backup finished"
		   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup finished" ;;
		3) msg "a backup was already running"
		   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup already in progress" ;;
		*) warn "backup FAILED (rc=$_rc)"
		   [ "$NOTIFY_END" = "1" ] && notify "Time Machine backup FAILED ($_rc)" ;;
	esac
	do_eject
	snapshots_cache_invalidate
	return "$_rc"
}

#############################################################################
## --add / --forget / --refresh
#############################################################################

cmd_add() {
	_folder="${1:-}"; _handle="${2:-}"
	[ -n "$_folder" ] || err "--add needs a <FOLDER> (or host:/path), optionally a <HANDLE>"

	if ! is_remote_target "$_folder"; then
		_folder=$(abs_path "$_folder")
		[ -d "$_folder" ] || err "$_folder: not a directory"
	fi
	if [ -z "$_handle" ]; then
		if is_remote_target "$_folder"; then
			_handle=$(slug "$(remote_host "$_folder")")
		else
			_handle=$(slug "$(basename "$_folder")")
		fi
	fi
	is_id_word "$_handle" &&
		err "'$_handle' reads like a snapshot ID (6-8 characters, all from the ID alphabet), so my-tm could never tell them apart. Try '$_handle-tm'."
	## awk's `exit` still runs END, so END's status would win -- use a flag
	locations_registered | awk -F'\t' -v h="$_handle" '$1 == h {f = 1} END {exit(f ? 0 : 1)}' &&
		err "handle '$_handle' is already registered"

	## probe before writing anything
	if ! is_remote_target "$_folder"; then
		_vols=$(manifest_parse "$_folder" 2>/dev/null | awk -F'\t' '{print $5}' | sort -u | tr '\n' ' ')
		if [ -z "$(printf '%s' "$_vols" | tr -d ' ')" ]; then
			warn "$_folder has no readable backup_manifest.plist -- adding it anyway, but it may not be a Time Machine store"
		else
			minor "volumes: $(printf '%s' "$_vols" | sed 's/ $//')"
		fi
	fi

	_f=$(locations_file)
	need_dir "$(dirname "$_f")" || err "cannot create $(dirname "$_f")"
	if [ -f "$_f" ] && [ ! -w "$_f" ]; then
		err "$_f is root-owned: re-run with sudo."
	fi
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
	[ -w "$_f" ] || err "$_f is root-owned: re-run with sudo."
	awk -F'\t' -v h="$_handle" '$1 != h' "$_f" | atomic_write "$_f" || err "cannot write $_f"
	msg "forgot location '$_handle' -- no backup was touched"
	why "deleting snapshots is a different verb: $US --rm <ID> go"
	return 0
}

cmd_refresh() {
	_only="${1:-}"
	snapshots_cache_invalidate
	if [ -n "$_only" ]; then
		snapshots_get "$_only" >/dev/null
		tm_refresh "$_only"
	else
		snapshots_all >/dev/null
		tm_refresh
	fi
	msg "caches and $(tm_root) rebuilt"
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
write_job() {
	_label="$1"; _sched="$2"; shift 2
	_prog="$MY_TM_BIN"
	_pl="/Library/LaunchDaemons/$_label.plist"
	_args=""
	for _a in "$@"; do
		_args="$_args		<string>$_a</string>
"
	done
	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
		printf '<plist version="1.0">\n<dict>\n'
		printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$_label"
		printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>%s</string>\n%s\t</array>\n' \
			"$_prog" "$_args"
		plist_schedule "$_sched"
		printf '\t<key>StandardErrorPath</key>\n\t<string>%s/%s.err</string>\n' "$LOG_DIR_ROOT" "$_label"
		printf '</dict>\n</plist>\n'
	} >"$_pl" || return 1
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
	[ -n "$CONFIG_SOURCED" ] ||
		err "--install needs a config: job labels, directories and the group are site-specific and guessing them is worse than asking. Run: $US --create-config > /etc/my-tm.conf"

	MY_TM_BIN=$(abs_path "$0")
	LOG_DIR_ROOT="/var/log/my-tm"
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

	## a job must not run a binary anyone but root can rewrite
	if path_is_user_writable "$MY_TM_BIN"; then
		err "$MY_TM_BIN is inside a group- or world-writable tree, so a LaunchDaemon running it as root would execute whatever someone puts there. Install a root-owned copy (e.g. /usr/local/sbin/my-tm, root:wheel 0755) and run --install from that."
	fi

	[ "$_go" = "1" ] || return 0

	## 1. directories
	for _d in "$CACHE_DIR" "$MOUNT_ROOT" "$CACHE_DIR/index" "$LOG_DIR_ROOT"; do
		need_dir "$_d" || err "cannot create $_d"
	done
	run chown -R "root:$_group" "$CACHE_DIR" || warn "chown failed on $CACHE_DIR"
	run chmod "$CACHE_MODE" "$CACHE_DIR" "$MOUNT_ROOT" || warn "chmod failed"
	why "root writes, the group reads, others see nothing -- the daemons act on what is in here"

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

	## 3. tree + jobs
	tm_refresh
	write_job "$MAINT_JOB" "${MAINT_INTERVAL}s" --maintenance
	if [ -n "$HEALTH_INTERVAL" ] && [ "$HEALTH_INTERVAL" != "0" ] && [ "$HEALTH_INTERVAL" != "false" ]; then
		_hi=$(parse_interval "$HEALTH_INTERVAL") || _hi=86400
		write_job "$HEALTH_JOB" "${_hi}s" --health
	else
		minor "HEALTH_INTERVAL is empty -- no health daemon installed"
	fi
	[ -n "$BACKUP_SCHEDULE" ] && write_job "$BACKUP_JOB" "$BACKUP_SCHEDULE" --backup start

	## 4. the config, under the name the search order expects
	_src=$(printf '%s' "$CONFIG_SOURCED" | awk '{print $NF}')
	if [ -n "$_src" ] && [ -d "$SITE_CONF_DIR" ] && [ "$_src" != "$SITE_CONF_DIR/my-tm.conf" ]; then
		if [ -f "$SITE_CONF_DIR/my-tm.conf" ]; then
			minor "$SITE_CONF_DIR/my-tm.conf already exists -- left as it is"
		else
			run cp "$_src" "$SITE_CONF_DIR/my-tm.conf" &&
				minor "copied $_src -> $SITE_CONF_DIR/my-tm.conf"
		fi
	fi

	## 5. completion, for the human who ran sudo -- never root's home
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
	_loc=$(locations_all | awk -F'\t' -v h="$_h" '$2 ~ ("^" h ":") {print $1; exit}')
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
	[ "$_go" = "1" ] || return 0

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

cmd_maintenance() {
	dbg "maintenance: sweep"
	sweep
	dbg "maintenance: /tm refresh"
	_locs=$(locations_all | awk -F'\t' '{print $1}')
	while IFS= read -r _h; do
		[ -n "$_h" ] || continue
		loc_reachable "$_h" || continue
		_t=$(loc_target "$_h")
		_stamp="$(cache_write_dir)/.manifest.$_h"
		_m=0
		[ "$_t" != "local" ] && [ -f "$_t/backup_manifest.plist" ] &&
			_m=$(stat -f '%m' "$_t/backup_manifest.plist" 2>/dev/null || echo 0)
		[ "$_t" = "local" ] && _m=$(now_epoch)
		_old=0
		[ -f "$_stamp" ] && _old=$(cat "$_stamp" 2>/dev/null || echo 0)
		if [ "$_m" != "$_old" ]; then
			dbg "maintenance: $_h changed ($_old -> $_m), refreshing"
			snapshots_cache_invalidate
			snapshots_get "$_h" >/dev/null
			tm_refresh_loc "$_h"
			printf '%s\n' "$_m" >"$_stamp" 2>/dev/null || true
		fi
	done <<_EOF
$_locs
_EOF
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
    '--unique:exclusive size of a snapshot'
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
    --cp --diff --index --unique --verify --local-snapshot --health --rm --thin
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
  --unique  <ID>                 exclusive size* of one snapshot
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
  --backup  start|stop [--set-eject|--set-no-eject]
                                 run or stop a backup, then eject the disk.
                                 [daemon: run on BACKUP_SCHEDULE]

INSTALL & SET UP
  --install [<SSH-HOST>] [go] | --uninstall [<SSH-HOST>] [go]
                                 initial setup: dirs, $FIRMLINK firmlink, daemons.
                                 Without \`go\` it only prints what it would do,
                                 every host listed. Needs root + Full Disk
                                 Access locally and on each configured ssh host;
                                 <SSH-HOST> does just that one, all if omitted
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

  * exclusive size -- bytes stored ONLY in that snapshot, i.e. what deleting it
    would actually free. Everything else in a snapshot is shared with its
    neighbours, so the sizes in --ls do not add up to the disk usage.

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
		--unique)       [ "$#" -ge 1 ] || err "--unique needs an <ID>"; cmd_unique "$@" ;;
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
		--version)      printf '%s %s\n' "$US" "$MY_TM_VERSION" ;;
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
t_calls()    { printf '%s/calls.log\n' "$T_ROOT"; }

t_make_stubs() {
	_s=$(t_stub_dir)
	mkdir -p "$_s"
	cat >"$_s/tmutil" <<_EOF
#!/bin/sh
printf 'tmutil %s\n' "\$*" >>"$(t_calls)"
case "\$1" in
  destinationinfo) printf '====================================================\nName          : TestStore\nKind          : Local\nMount Point   : $T_ROOT/store\nID            : 11111111-2222-3333-4444-555555555555\n' ;;
  listlocalsnapshots) printf 'Snapshots for disk %s:\ncom.apple.TimeMachine.2026-08-23-005931.local\ncom.apple.TimeMachine.2026-08-23-020001.local\n' "\$2" ;;
  uniquesize) printf '12345678 %s\n' "\$2" ;;
  status) printf 'Backup session status:\n{\n    Running = 0;\n}\n' ;;
  isexcluded) printf '[Included]    %s\n' "\$2" ;;
  *) : ;;
esac
exit 0
_EOF
	cat >"$_s/diskutil" <<_EOF
#!/bin/sh
printf 'diskutil %s\n' "\$*" >>"$(t_calls)"
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
	AUTODETECT_LOCAL_TM_BACKUPS=0
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
	t_test_thin
	t_test_config
	t_test_locations
	t_test_ladder
	t_test_mount_records
	t_test_version_store
	t_test_atomic
	t_test_plists
	t_test_rm_dryrun
	t_test_help
	t_test_paths
	t_test_local_snapshots

	t_teardown
	printf '\n%s passed, %s failed, %s skipped\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
	[ "$T_FAIL" -eq 0 ] || return 1
	return 0
}

#############################################################################
main "$@"

