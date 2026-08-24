#!/bin/sh

# 004 == highest used errCode

US="${0##*/}";   # get filename without path

DBG=1;
PFX="$$| "
DBG_PREFIX="$PFX"
LOG="/var/log/mine/root/${US%.*}.log"
BGN_NFY="1" # Display Notification when started
END_NFY="1" # Display Notification when finished

LOCKFILE='/var/lib/root/my-timemachine.lock'
NO_EJECT_FLAGFILE='/var/lib/my-backup.no-eject'
#BACKUP_VOLUME="bkp-nvme"
BACKUP_VOLUME="" #"timeMachine"

PREV_BACKUPRUNTIME_FILE="/var/tmp/mine.net.PREV_TMBACKUPRUNTIME"    # gets set/written/updated by /LINKS/sbin/my-timemachine.sh on SUCCESSFUL BACKUP


cleanup() { local rc=$?;
  [ $CLEANUP_DONE ] && return;
  #[ $DBG ] && echo && echo "$$| CLEANUP! ($rc) [$*]" \
  #         || exec 2>/dev/null # don't show errors if NOT in DBG mode
  rm -f "$LOCKFILE"
  CLEANUP_DONE=1
  exit $rc; # return does not suffice
}


usage() {
  echo "usage: $0 start|stop [--set-no-eject] [--set-eject]

IF THIS STILL BUGS NOW WITH THE LOCKFILE ... then maybe try: using 'on-mount' of LaunchDaemon and remove trigger via '/LINKS/sbin/my-network-change_macos.sh'
# SEE:
https://www.reddit.com/r/apple/comments/19gqyd/is_there_anyway_to_automatically_have_a_time/
# -->
# https://web.archive.org/web/20160409130936/http://somethinginteractive.com/blog/2013/07/24/time-machine-auto-mountunmount-drive-os-x/

  --set-no-eject)  Creates '$NO_EJECT_FLAGFILE'. When present, no auto-eject will be done!
  --set-eject)     Removes '$NO_EJECT_FLAGFILE', to assure EJECT happens.

This script allows to control the backup tool TimeMachine, using '/usr/bin/tmutil'
backing up onto BACKUP_VOLUME '$BACKUP_VOLUME'.

Sript uses the environment variables DBG, DBG_PREFIX and LOG !";
  exit 0
}

err() { local errCode="$1"; [ -z "$2" ] && local msg="Please fix." || local msg="$2"; [ -z "$3" ] && local exitCode=1 || local exitCode="$3";
  local outp="${PFX}ERROR $errCode [$exitCode]: $msg"
  printf "\n$outp\n" 1>&2

  exit $exitCode;
}



# REDIRECT STDOUT AND STDERR TO LOGFILE !
redirect_to_log() {
  [ -z "$LOG" ] && return;
  [ $DBG ] && echo "${DBG_PREFIX}> Redirectring stdout+stderr now to LOG '$LOG'!"
#less \"$LOG\""
  touch "$LOG" || { rc=$?; m="ERROR: FAILED [$rc] accessing log '$LOG'."; logger -t mine "#$US: $m"; err 004 "$m"; }
  exec 1>>"$LOG"
  exec 2>&1
}

do_backup() {
  [ $DBG ] && echo "${DBG_PREFIX} ~~~ do_backup():";

  if [ -n "$BACKUP_VOLUME" ] && [ ! -d "/Volumes/$BACKUP_VOLUME" ]; then
    [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): (diskutil mount \"/Volumes/$BACKUP_VOLUME\")";
    diskutil mount "/Volumes/$BACKUP_VOLUME" || err 003 "(diskutil mount \"/Volumes/$BACKUP_VOLUME\") FAILED";
  fi

  [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): $(date) -- > (/usr/bin/tmutil startbackup --block)$( [ -n "$BACKUP_VOLUME" ] && echo "   <<< onto: /Volumes/$BACKUP_VOLUME")..."
  #[ $BGN_NFY ] && /LINKS/bin/my-notify -- "Starting TimeMachine backup..."
  #tmutil startbackup --auto --block; rc=$?; #    # 2>&1|sed -e "s/^/${DBG_PREFIX}[tmutil-backup] /"; rc=$?;
  /usr/bin/tmutil startbackup --block; rc=$?; #    # 2>&1|sed -e "s/^/${DBG_PREFIX}[tmutil-backup] /"; rc=$?;
  [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): $(date) -- > (/usr/bin/tmutil startbackup --block) --> rc=$rc.";
  #sync; sleep 1;

  case "$rc" in
    0)
    [ $END_NFY ] && /LINKS/bin/my-notify -- "Successful TimeMachine backup!"
    CURR_RUNTIME="$(date +%s)"
    [ $DBG ] && echo "${DBG_PREFIX}  ~ do_backup(): Successfull backup --> updating '$PREV_BACKUPRUNTIME_FILE' (with $CURR_RUNTIME)"
    echo "$CURR_RUNTIME">"$PREV_BACKUPRUNTIME_FILE"
    ;;

    3)
    [ $DBG ] && echo "${DBG_PREFIX}  ~ do_backup(): Backup already in progress."
    [ $END_NFY ] && /LINKS/bin/my-notify -- "TimeMachine backup already in progress!"
    ;;

    *)
    [ $END_NFY ] && /LINKS/bin/my-notify -- "TimeMachine backup FAILED [$rc]!"
    ;;
  esac

  if [ -z "$BACKUP_VOLUME" ]; then
    return 0
  fi

  if [ -f "$NO_EJECT_FLAGFILE" ]; then
    [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): Skipping Volume '$BACKUP_VOLUME' eject, as '$NO_EJECT_FLAGFILE' exists."
    return 0
  fi

  for ii in $(seq 10); do
    #DBG-OUTPUT XXX FIXME:
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] sleep 5"
    sleep 5;
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] sync"
    sync;
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] ls -la /Volumes/"
    ls -lad /Volumes/*
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] ls -la /dev/disk*"
    ls -la /dev/disk*
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] diskutil list"
    diskutil list
    echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] diskutil eject \"/Volumes/$BACKUP_VOLUME\""

    diskutil eject "/Volumes/$BACKUP_VOLUME"; rc=$?;
    [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): [trial #$ii/$imax] (diskutil eject \"/Volumes/$BACKUP_VOLUME\" --> rc=$rc." \
           && ls -1 /Volumes/|while read a; do echo "${DBG_PREFIX}                  --> '/Volumes/$a'|"; done

    [ $rc -eq 0 ] && break;
  done


  [ $DBG ] && echo "${DBG_PREFIX}   ~ do_backup(): Done";
  return 0
}

stop_backup() {
  [ $DBG ] && echo "${DBG_PREFIX} ~~~ stop_backup():";
  [ $DBG ] && echo "${DBG_PREFIX}   ~ stop_backup(): $(date) (/usr/bin/tmutil stopbackup)..."
  /usr/bin/tmutil stopbackup; rc=$?;
  [ $DBG ] && echo "${DBG_PREFIX}   ~ stop_backup(): $(date) (/usr/bin/tmutil stopbackup) --> rc='$rc'."

  if [ -f "$NO_EJECT_FLAGFILE" ]; then
    [ $DBG ] && echo "${DBG_PREFIX}   ~ stop_backup(): Skipping Volume '$BACKUP_VOLUME' eject, as '$NO_EJECT_FLAGFILE' exists."
    return 0
  else
    diskutil eject "/Volumes/$BACKUP_VOLUME"; rc=$?;
    [ $DBG ] && echo "${DBG_PREFIX}   ~ stop_backup(): (diskutil eject \"/Volumes/$BACKUP_VOLUME\") --> rc=$rc." \
             && ls -1 /Volumes/|while read a; do echo "${DBG_PREFIX}                  --> '/Volumes/$a'|"; done
  fi
  [ $DBG ] && echo "${DBG_PREFIX}   ~ stop_backup(): Done";
  return 0
}

#########################################################
#### MAIN:

[ "$EUID" != "0" ] && { echo "${PFX}Please run with sudo / as root."; exit 0; }

[ "$1" = "--help" ] && usage;

redirect_to_log;

if [ -e "$LOCKFILE" ]; then
 echo "${PFX}FILE '$LOCKFILE' found. Already running? -> Quitting."; exit 2;
fi

touch "$LOCKFILE" || err 000
# set up the trap for a clean exit:
for i in 0 1 2 3 4 5 6 7 8 9; do trap "cleanup \"TRAP\" $i;" $i; done;

[ $DBG ] && echo "${DBG_PREFIX}____________________________________________________________";
[ $DBG ] && echo "${DBG_PREFIX}$( date +"%Y-%m-%d_%H%M.%S") :: RUNNING [pid=$$] :: $0 ::";
[ $DBG ] && echo "${DBG_PREFIX}";

# First commandline parameter scan (to already treat --set... stuff!)
[ $# -eq 0 ] && usage
for arg in "$@"; do
  case "$arg" in
    "start"|"stop") continue;;
    "--set-no-eject") [ $DBG ] && echo "${DBG_PREFIX}   ~ touch \"$NO_EJECT_FLAGFILE\" (== NO_EJECT_FLAGFILE)"; touch "$NO_EJECT_FLAGFILE" || err 001 "touch FAILED.";;
    "--set-eject")    [ $DBG ] && echo "${DBG_PREFIX}   ~ rm -f \"$NO_EJECT_FLAGFILE\" (== NO_EJECT_FLAGFILE)"; rm -f "$NO_EJECT_FLAGFILE" || err 002 "rm FAILED.";;
    *) usage;;
  esac
done

# MAIN commandline parameter loop:
while [ $# -gt 0 ]; do
  arg="$1"; shift;
  #[ $DBG ] && "${DBG_PREFIX}   ~ MAIN cli-param loop: arg='$arg' [\$#=$#]"
  case "$arg" in
    "start") do_backup;;
    "stop")  stop_backup;;
  esac
done

[ $DBG ] && printf "${DBG_PREFIX}\n${DBG_PREFIX}$( date +"%Y-%m-%d_%H%M.%S") :: DONE --> exit 0.\n"
exit 0

