#!/bin/sh
# Fixed root launcher. No caller-supplied executable, label, path, TTL or shell.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/basebin
export PATH
unset ENV BASH_ENV CDPATH
test "$(id -u)" = 0
test "$#" = 2
operation=$1
identifier=$2
case "$operation" in start|recover) ;; *) exit 64;; esac
case "$identifier" in ????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$identifier" in *[!0-9A-F-]*) exit 64;; esac
base='/var/mobile/Library/Application Support/WatchFix/SleepSync'
session="$base/Sessions/$identifier"
runtime=/Applications/WatchFix.app/SleepSyncRuntime
jobs=/Library/LaunchDaemons
for path in /Applications /Applications/WatchFix.app "$runtime" /Library "$jobs"; do
 test -d "$path" && test ! -L "$path"
 test "$(stat -c %u "$path")" = 0
 directory_mode=$(stat -c %a "$path")
 if [ "$path" = /Library ] && [ "$directory_mode" = 775 ]; then
  : # Existing shared ancestor; the root-only LaunchDaemons child is checked below.
 else
  case "$directory_mode" in 755|700|750|555) ;; *) exit 78;; esac
 fi
done
test -f "$runtime/SleepSyncCoordinator.sh" && test ! -L "$runtime/SleepSyncCoordinator.sh"
test "$(stat -c %u:%h "$runtime/SleepSyncCoordinator.sh")" = 0:1
for path in "$base" "$base/Sessions" "$session" "$session/focus" "$session/identity"; do
 test -d "$path" && test ! -L "$path"
 test "$(stat -c %u:%a "$path")" = 501:700
done
label="cn.fkj233.watchfix.sleepsync.$identifier"
job="$jobs/$label.plist"
if [ "$operation" = recover ]; then
 test ! -L "$session/recovery-requested"
 if [ ! -e "$session/recovery-requested" ]; then
  (umask 077; set -C; : > "$session/recovery-requested")
 fi
 if launchctl print "system/$label" >/dev/null 2>&1; then
  # Do not kill a live worker. Its cancellation guard initiates cleanup.
  if [ ! -e "$session/cancel-requested" ]; then (umask 077; set -C; : > "$session/cancel-requested"); fi
  launchctl kickstart "system/$label"
  exit 0
 fi
fi
# The root-consumed plist is generated in a ROOT-owned directory, never copied
# from the mobile session's request or allowed to override ProgramArguments.
if [ -e "$job" ] || [ -L "$job" ]; then
 test -f "$job" && test ! -L "$job" && test "$(stat -c %u:%h "$job")" = 0:1 || exit 78
else
 temporary="$jobs/.$label.new"
 test ! -e "$temporary" && test ! -L "$temporary"
 (umask 022; set -C; cat > "$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>$runtime/SleepSyncCoordinator.sh</string><string>$identifier</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>3</integer>
</dict></plist>
EOF
 )
 chmod 644 "$temporary"
 mv "$temporary" "$job"
fi
launchctl bootstrap system "$job"
