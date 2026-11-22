#!/bin/sh
# Root worker, launched by the bridge's RunAtLoad / KeepAlive.SuccessfulExit=false job.
# This file is DATA until explicitly launched on a device. No host/device auto-discovery.
# All absolute paths are in the jailbreak root view. No source/eval, preferences, DBs,
# user-supplied executable, synthetic ACK, or retry that can replenish a send budget.
# Packaging supplies payload.sha256 and postload.sha256: each exactly four
# lowercase SHA256/name lines, never a wildcard for unaudited loader transforms.
# The bridge creates the mobile-owned 0700 session, identity and focus directories and
# current-session.plist plus canonical start-unix/deadline-unix files. Native gates
# bind that pointer, UUID, boot and expiry themselves; worker entry never renews expiry.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/basebin
export PATH
unset ENV BASH_ENV CDPATH
umask 077

[ "$#" -eq 1 ] || exit 64
uuid=$1
case "$uuid" in ????????-????-????-????-????????????) ;; *) exit 64;; esac
case "$uuid" in *[!0-9A-Fa-f-]*) exit 64;; esac
[ "$(/usr/bin/id -u)" = 0 ] || exit 77

base='/var/mobile/Library/Application Support/WatchFix/SleepSync'
session="$base/Sessions/$uuid"
runtime=/Applications/WatchFix.app/SleepSyncRuntime
target=/usr/lib/TweakInject
work="$session/worker-entered"
hello=WatchFix_HelloReadOnlyObserver
focus=WatchFix_FocusConfigCompatibility
started=0 deadline=0 ack=false sends=0 clean=false
failure=failed cancelled=false recovering=false

# Procursus GNU stat: do not follow a final symlink; reject links/owner/mode.
# The bridge must serialize sessions. The inode pin catches replaced session roots;
# shell checks are defense in depth, not a substitute for trusted native root bridging.
plain() { [ ! -L "$1" ] && [ -f "$1" ] && [ "$(/usr/bin/stat -c %h "$1")" = 1 ]; }
rootfile() { plain "$1" && [ "$(/usr/bin/stat -c %u "$1")" = 0 ]; }
directory() { [ ! -L "$1" ] && [ -d "$1" ]; }
secure_rootdir() {
    directory "$1" || return 1
    [ "$(/usr/bin/stat -c %u "$1")" = 0 ] || return 1
    mode=$(/usr/bin/stat -c %a "$1") || return 1
    case "$mode" in 700|755|750|555) ;; *) return 1;; esac
}
mobile_dir() {
    directory "$1" && [ "$(/usr/bin/stat -c %u:%a "$1")" = 501:700 ]
}
session_tree() {
    # /var itself may be the platform's normal /private/var alias.
    for p in /var/mobile /var/mobile/Library '/var/mobile/Library/Application Support' \
        '/var/mobile/Library/Application Support/WatchFix' "$base" "$base/Sessions"; do
        directory "$p" || return 1
    done
    mobile_dir "$session" && mobile_dir "$session/identity" && mobile_dir "$session/focus" || return 1
    [ "$(/usr/bin/stat -c %d:%i "$session")" = "$session_inode" ]
}
safe_session() { session_tree && secure_rootdir "$work"; }
safe_target() {
    for p in /usr /usr/lib "$target"; do secure_rootdir "$p" || return 1; done
}
safe_runtime() {
    for p in /Applications /Applications/WatchFix.app "$runtime"; do
        secure_rootdir "$p" || return 1
    done
}
hash() {
    rootfile "$1" || return 1
    result=$(/usr/bin/sha256sum "$1") || return 1
    result=${result%% *}
    [ "${#result}" -eq 64 ] || return 1
    case "$result" in *[!0-9a-f]*) return 1;; esac
    printf '%s\n' "$result"
}
original_hash() {
    case "$1" in
        "$hello.dylib") printf '%s\n' d68e8f6d975229167566fc0a8b81d5068d11ea30a63b1b989ffeced2db17a2cf;;
        "$hello.plist") printf '%s\n' 7a0735ef9b15554e41a7ec835567795bbf18c4f5716551ddd1a837ab5856b790;;
        "$focus.dylib") printf '%s\n' 1f4fb3cff36e2293607c3ae686e9ada3cb492d7fab43372132e631a05e3b8b4a;;
        "$focus.plist") printf '%s\n' 10d0ed6e2671c0be7ac4dedda4ba4aa890a5103581208ec383dfd1d9b2c8346a;;
        *) return 1;;
    esac
}
manifest_hash() {
    # Do not source a shell hash file or let sha256sum -c interpret filenames.
    rootfile "$1" || return 1
    [ "$(/usr/bin/stat -c %s "$1")" -le 1024 ] || return 1
    seen=' ' found='' count=0
    while IFS=' ' read -r digest name extra || [ -n "$digest$name$extra" ]; do
        [ -z "$extra" ] && [ "${#digest}" -eq 64 ] || return 1
        case "$digest" in *[!0-9a-f]*) return 1;; esac
        case "$name" in "$hello.dylib"|"$hello.plist"|"$focus.dylib"|"$focus.plist") ;; *) return 1;; esac
        case "$seen" in *" $name "*) return 1;; esac
        seen="$seen$name " count=$((count + 1))
        [ "$name" != "$2" ] || found=$digest
    done < "$1"
    [ "$count" -eq 4 ] && [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}
payload_hash() { manifest_hash "$runtime/payload.sha256" "$1"; }
postload_hash() { manifest_hash "$runtime/postload.sha256" "$1"; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
# Absence is an explicit, root-owned journal entry, never inferred during recovery.
was_absent() { secure_rootdir "$work/backup" && secure_rootdir "$work/backup/$1.absent"; }
baseline_matches() {
    if was_absent "$1"; then
        absent "$target/$1"
    elif ! marked backups-verified && ! marked identity-dirty && ! marked focus-dirty &&
         absent "$target/${1%.*}.dylib" && absent "$target/${1%.*}.plist"; then
        # Cancel/expiry or validation failure before installing anything.
        return 0
    else
        [ "$(hash "$target/$1")" = "$(original_hash "$1")" ]
    fi
}
mark() { safe_session && /bin/mkdir "$work/$1"; }
marked() { directory "$work/$1"; }
now() {
    time_value=$(/usr/bin/date +%s) || return 1
    case "$time_value" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$time_value"
}
session_number() {
    # Bridge-owned decimal bytes, optionally followed by ONE LF. No whitespace,
    # signs, leading zeroes, shell arithmetic expressions, links or loose modes.
    plain "$1" || return 1
    number_metadata=$(/usr/bin/stat -c %u:%a "$1") || return 1
    case "$number_metadata" in 0:600|501:600) ;; *) return 1;; esac
    number_size=$(/usr/bin/stat -c %s "$1") || return 1
    case "$number_size" in ''|*[!0-9]*) return 1;; esac
    [ "$number_size" -gt 0 ] && [ "$number_size" -le 16 ] || return 1
    number_value=''
    IFS= read -r number_value < "$1"
    number_read=$?
    case "$number_value" in ''|0*|*[!0-9]*) return 1;; esac
    # Check the byte count as well as read's line/EOF result: trailing extra lines
    # and embedded NULs must not turn into an apparently canonical shell value.
    if [ "$number_read" -eq 0 ]; then
        [ "$number_size" -eq "$((${#number_value} + 1))" ] || return 1
    else
        [ "$number_read" -eq 1 ] && [ "$number_size" -eq "${#number_value}" ] || return 1
    fi
    printf '%s\n' "$number_value"
}
session_times() {
    # Snapshot each bridge value once, even on re-entry. Never use now()+420.
    bridge_start=$(session_number "$session/start-unix") || return 1
    bridge_deadline=$(session_number "$session/deadline-unix") || return 1
    [ "$bridge_deadline" -gt "$bridge_start" ] || return 1
    [ "$((bridge_deadline - bridge_start))" -le 420 ] || return 1
    started=$bridge_start deadline=$bridge_deadline
}
write_status() {
    safe_session || return 1
    if [ -e "$session/status.plist" ] || [ -L "$session/status.plist" ]; then
        plain "$session/status.plist" || return 1
        status_owner=$(/usr/bin/stat -c %u "$session/status.plist") || return 1
        case "$status_owner" in 0|501) ;; *) return 1;; esac
    fi
    if [ -e "$work/status.staged.plist" ] || [ -L "$work/status.staged.plist" ]; then
        rootfile "$work/status.staged.plist" || return 1
    fi
    # Values are fixed tokens, canonical numeric fields, and a validated UUID only.
    /bin/cat > "$work/status.staged.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>schema</key><integer>1</integer>
<key>sessionID</key><string>$uuid</string>
<key>phase</key><string>$1</string>
<key>messageCode</key><string>$2</string>
<key>startedAt</key><integer>$started</integer>
<key>deadline</key><integer>$deadline</integer>
<key>deadlineUnix</key><integer>$deadline</integer>
<key>ackMatched</key><$ack/>
<key>cleanupVerified</key><$clean/>
<key>backendAvailable</key><true/>
<key>addedSendCount</key><integer>$sends</integer>
<key>sends</key><integer>$sends</integer>
<key>userVerified</key><false/>
</dict></plist>
EOF
    [ "$?" -eq 0 ] && /usr/bin/chmod 644 "$work/status.staged.plist" &&
        /bin/mv -f "$work/status.staged.plist" "$session/status.plist"
}
restart() {
    # Reserve before invoking launchctl. An unresolved reservation is NEVER retried.
    # Separate restoration slots make recovery possible without replaying activation.
    marked "$1-done" && return 0
    mark "$1-reserved" || return 1
    case "$1" in
        identity-baseline|identity-candidate)
            previous_identity_pid=$(pid_for identityservicesd) || return 1;;
        focus-active)
            previous_focus_pid=$(pid_for donotdisturbd) || return 1;;
    esac
    launchctl kickstart -k "system/$2" || return 1
    mark "$1-done"
}
atomic_payload() {
    safe_session && safe_target || return 1
    rootfile "$1" || return 1
    dest="$target/$2" tmp="$target/.WatchFix-SleepSync-$2"
    if ! absent "$dest"; then
        rootfile "$dest" || return 1
    else
        marked backups-verified && was_absent "$2" || return 1
    fi
    # A stale staging file is not authority to overwrite arbitrary bytes.
    if [ -e "$tmp" ] || [ -L "$tmp" ]; then
        [ "$(hash "$tmp")" = "$3" ] || return 1
    fi
    /bin/cp "$1" "$tmp" && /usr/bin/chmod "$4" "$tmp" || return 1
    [ "$(hash "$tmp")" = "$3" ] || return 1
    /bin/mv -f "$tmp" "$dest" && [ "$(hash "$dest")" = "$3" ]
}
install_pair() {
    mark "$1-dirty" || return 1
    for ext in dylib plist; do
        name="$2.$ext" permissions=644
        [ "$ext" != dylib ] || permissions=755
        expected=$(payload_hash "$name") || return 1
        atomic_payload "$runtime/$name" "$name" "$expected" "$permissions" || return 1
    done
}
restore_pair() {
    # Only an exact packaged post-load digest can authorize transformed bytes;
    # unreviewed RootHide transforms and external changes remain fail-closed.
    for check_ext in dylib plist; do
        check_name="$1.$check_ext"
        if was_absent "$check_name" && absent "$target/$check_name"; then continue; fi
        check_current=$(hash "$target/$check_name") || return 1
        check_original=$(original_hash "$check_name") || return 1
        check_payload=$(payload_hash "$check_name") || return 1
        check_postload=$(postload_hash "$check_name") || return 1
        [ "$check_current" = "$check_original" ] || [ "$check_current" = "$check_payload" ] ||
            [ "$check_current" = "$check_postload" ] || return 1
    done
    for ext in dylib plist; do
        name="$1.$ext" permissions=644
        if was_absent "$name"; then
            # Quarantine only known session bytes; never delete an unknown file.
            # The complete pair was checked above before either file is moved.
            if ! absent "$target/$name"; then
                absent "$work/$name.retired" || return 1
                /bin/mv "$target/$name" "$work/$name.retired" || return 1
            fi
            continue
        fi
        [ "$ext" != dylib ] || permissions=755
        expected=$(original_hash "$name") || return 1
        [ "$(hash "$work/backup/$name")" = "$expected" ] || return 1
        atomic_payload "$work/backup/$name" "$name" "$expected" "$permissions" || return 1
    done
}
pid_for() {
    # Exact executable basename, unique PID, never pgrep a substring or scan all logs.
    ps_snapshot=$(/rootfs/bin/ps -axo pid=,comm=) || return 1
    chosen=''
    while read -r number executable remainder; do
        [ "${executable##*/}" = "$1" ] || continue
        case "$number" in ''|0|*[!0-9]*) return 1;; esac
        [ -z "$chosen" ] || return 1
        chosen=$number
    done <<EOF
$ps_snapshot
EOF
    [ -n "$chosen" ] || return 1
    printf '%s\n' "$chosen"
}
read_log() {
    # One session/PID only; cap both bytes and lines before shell pattern matching.
    # An overlong/unsafe log is unknown evidence, never proof of a stale constructor.
    plain "$1" || return 1
    log_owner=$(/usr/bin/stat -c %u "$1") || return 1
    case "$log_owner" in 0|501) ;; *) return 1;; esac
    log_size=$(/usr/bin/stat -c %s "$1") || return 1
    case "$log_size" in ''|*[!0-9]*) return 1;; esac
    [ "$log_size" -le 32768 ] || return 1
    /usr/bin/head -c 32768 "$1" | /usr/bin/head -n 256
}
poll_guard() {
    safe_session || return 1
    if [ -e "$session/cancel-requested" ] || [ -L "$session/cancel-requested" ]; then
        plain "$session/cancel-requested" || return 1
        cancelled=true
        return 1
    fi
    wall=$(now) || return 1
    [ "$wall" -lt "$deadline" ] || { failure=deadlineExceeded; return 1; }
}
wait_identity() {
    # kickstart returning does not guarantee the replacement PID is visible yet.
    # Pin the first replacement; never follow another crash/restart for evidence.
    identity_pid=''
    until_time=$(( $(now) + 60 )) || return 1
    ticks=0
    while [ "$ticks" -lt 60 ]; do
        poll_guard || return 1
        observed_identity_pid=$(pid_for identityservicesd) || observed_identity_pid=''
        if [ -z "$identity_pid" ]; then
            if [ -n "$observed_identity_pid" ] && [ "$observed_identity_pid" != "$previous_identity_pid" ]; then
                identity_pid=$observed_identity_pid
            fi
        elif [ "$observed_identity_pid" != "$identity_pid" ]; then return 1
        fi
        contents=''
        if [ -n "$identity_pid" ]; then
            identity_log="$session/identity/run-$identity_pid.log"
            contents=$(read_log "$identity_log") || contents=''
        fi
        case "$contents" in *"$1"*) return 0;; esac
        [ "$(now)" -lt "$until_time" ] || return 1
        /bin/sleep 1 || return 1
        ticks=$((ticks + 1))
    done
    return 1
}
wait_focus_ready() {
    # A new PID alone is not permission to ask the user to save. Require this
    # exact process's startup lease AND completed hooks, within the original TTL.
    ready_until=$(( $(now) + 30 )) || return 1
    ready_ticks=0
    while [ "$ready_ticks" -lt 30 ]; do
        poll_guard || return 1
        [ "$(now)" -lt "$policy_deadline" ] || return 1
        [ "$(pid_for donotdisturbd)" = "$focus_pid" ] || return 1
        ready_log=$(read_log "$session/focus/run-$focus_pid.log") || ready_log=''
        ready_claim=false
        while IFS= read -r ready_line; do
            case "$ready_line" in
                *"SLEEPMODULE1 startup session claimed=YES pid=$focus_pid "*) ready_claim=true;;
            esac
        done <<EOF
$ready_log
EOF
        if [ "$ready_claim" = true ]; then
            case "$ready_log" in *'PASS policy-only hooks installed; enabled=YES controlUpgrade=NO'*) return 0;; esac
        fi
        [ "$(now)" -lt "$ready_until" ] || return 1
        /bin/sleep 1 || return 1
        ready_ticks=$((ready_ticks + 1))
    done
    return 1
}
revoke() {
    safe_session || return 1
    if [ -e "$1" ] || [ -L "$1" ]; then
        plain "$1" || return 1
        revoke_owner=$(/usr/bin/stat -c %u "$1") || return 1
        case "$revoke_owner" in 0|501) ;; *) return 1;; esac
        [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
        /bin/mv "$1" "$2" || return 1
    fi
}
cleanup() {
    safe_session && safe_target || return 1
    # Native gates observe closed immediately, including cached policy contexts.
    if [ -e "$session/closed" ] || [ -L "$session/closed" ]; then
        rootfile "$session/closed" || return 1
    else
        printf '%s\n' "$uuid" > "$work/closed.staged" || return 1
        /bin/mv "$work/closed.staged" "$session/closed" || return 1
    fi
    write_status restoring restoring || return 1
    cleanup_ok=true
    revoke "$session/focus/policy-grant.plist" "$work/policy-grant.revoked.plist" || cleanup_ok=false
    revoke "$session/identity-enabled" "$work/identity-enabled.revoked" || cleanup_ok=false
    if marked identity-dirty; then
        if marked identity-candidate-reserved && ! marked identity-original-reserved; then
            # Best-effort neutral observation, then always attempt original recovery.
            # This does not wait on cancellation, which must not block restoration.
            if restart identity-neutral com.apple.identityservicesd; then
                neutral_pid=$(pid_for identityservicesd) || neutral_pid=''
                neutral_ticks=0
                while [ -n "$neutral_pid" ] && [ "$neutral_ticks" -lt 7 ]; do
                    contents=$(read_log "$session/identity/run-$neutral_pid.log") || contents=''
                    case "$contents" in *'event=neutral-result seq=1 depth=1 count=1 route=2 detail=7 returned=1'*)
                        marked neutral-observed || mark neutral-observed || cleanup_ok=false
                        break;;
                    esac
                    /bin/sleep 1 || break
                    neutral_ticks=$((neutral_ticks + 1))
                done
            fi
        fi
        if restore_pair "$hello"; then
            restart identity-original com.apple.identityservicesd || cleanup_ok=false
        else
            cleanup_ok=false
        fi
    fi
    if marked focus-dirty; then
        if restore_pair "$focus"; then
            restart focus-original com.apple.donotdisturbd || cleanup_ok=false
        else
            cleanup_ok=false
        fi
    fi
    for name in "$hello.dylib" "$hello.plist" "$focus.dylib" "$focus.plist"; do
        baseline_matches "$name" || cleanup_ok=false
    done
    [ "$cleanup_ok" = true ] || return 1
    clean=true
}
retire_job() {
    # Stop future boot-time launches without killing the running cleanup worker.
    # launchd may retain an idle registration; no active grant remains after close.
    job="/Library/LaunchDaemons/cn.fkj233.watchfix.sleepsync.$uuid.plist"
    absent "$job" && return 0
    secure_rootdir /Library/LaunchDaemons && rootfile "$job" || return 1
    if ! absent "$work/launchd-job.retired.plist"; then
        [ "$(hash "$job")" = "$(hash "$work/launchd-job.retired.plist")" ] || return 1
    fi
    /bin/mv -f "$job" "$work/launchd-job.retired.plist"
}
finish() {
    trap '' HUP INT TERM
    if cleanup && retire_job; then
        if [ "$recovering" = true ]; then
            write_status failed failed || :
        elif [ "$cancelled" = true ]; then
            write_status cancelled cancelled || :
        elif [ "$ack" = true ]; then
            write_status finished protocolConfirmed || :
        else
            write_status failed "$failure" || :
        fi
    else
        clean=false
        write_status recoveryRequired recoveryRequired || :
    fi
    # A hard crash gets one launchd recovery run; a known failure is terminal and
    # visible, not a KeepAlive crash loop. The bridge can offer explicit recovery.
    exit 0
}

# No writable operation precedes validation of the mobile session and payload roots.
mobile_dir "$session" && mobile_dir "$session/identity" && mobile_dir "$session/focus" || exit 78
session_inode=$(/usr/bin/stat -c %d:%i "$session") || exit 78
session_tree && safe_target && safe_runtime || exit 78
if /bin/mkdir "$work" 2>/dev/null; then
    safe_session || exit 78
else
    # Existing marker means crash/re-entry, including half-written startup state.
    recovering=true
    safe_session || exit 78
    marked sent-observed && sends=1
    marked ack-matched && ack=true
fi
trap finish HUP INT TERM

# The trusted launcher can request recovery before the first worker ever entered.
# Creating the exclusive marker must not accidentally turn that request into Start.
if [ -e "$session/recovery-requested" ] || [ -L "$session/recovery-requested" ]; then
    recovering=true
    rootfile "$session/recovery-requested" || exit 78
fi
# Invalid timing is never activation permission. Recovery is cleanup-only even
# with missing/corrupt times; zero explicitly denotes unknown recovery timing.
if ! session_times; then
    started=0 deadline=0
    finish
fi
[ "$recovering" != true ] || finish

prepare() {
    write_status preparing preparing || return 1
    # Each legacy pair is either wholly absent or the exact audited baseline.
    # Missing one half is not a clean installation and must not be guessed away.
    for stem in "$hello" "$focus"; do
        if absent "$target/$stem.dylib" && absent "$target/$stem.plist"; then continue; fi
        for ext in dylib plist; do
            [ "$(hash "$target/$stem.$ext")" = "$(original_hash "$stem.$ext")" ] || return 1
        done
    done
    # Validate ALL payload bytes before even backing up or installing.
    for name in "$hello.dylib" "$hello.plist" "$focus.dylib" "$focus.plist"; do
        expected=$(payload_hash "$name") || return 1
        expected_postload=$(postload_hash "$name") || return 1
        [ "$(hash "$runtime/$name")" = "$expected" ] || return 1
    done
    mark backup || return 1
    for name in "$hello.dylib" "$hello.plist" "$focus.dylib" "$focus.plist"; do
        if absent "$target/$name"; then
            mark "backup/$name.absent" || return 1
            continue
        fi
        /bin/cp "$target/$name" "$work/backup/$name" || return 1
        [ "$(hash "$work/backup/$name")" = "$(original_hash "$name")" ] || return 1
    done
    mark backups-verified || return 1
    # Explicitly require no inherited module authorization, independent of old prefs.
    for p in "$session/identity-enabled" "$session/focus/policy-grant.plist"; do
        [ ! -e "$p" ] && [ ! -L "$p" ] || return 1
    done
}
run_session() {
    poll_guard || return 1
    prepare || return 1
    poll_guard || return 1
    write_status identity identity || return 1
    install_pair identity "$hello" || return 1
    restart identity-baseline com.apple.identityservicesd || return 1
    wait_identity 'event=neutral-result seq=1 depth=1 count=1 route=2 detail=7 returned=1' || return 1
    safe_session || return 1
    printf '%s\n' "$uuid" > "$work/identity-enabled.staged" || return 1
    /usr/bin/chmod 600 "$work/identity-enabled.staged" || return 1
    # Root-owned marker; native gate tests existence, never a mobile-only UID check.
    /bin/mv "$work/identity-enabled.staged" "$session/identity-enabled" || return 1
    restart identity-candidate com.apple.identityservicesd || return 1
    wait_identity 'event=identity-result seq=1 depth=1 count=1 route=2 detail=15 returned=1' || return 1
    poll_guard || return 1
    boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid) || return 1
    case "$boot" in ????????-????-????-????-????????????) ;; *) return 1;; esac
    case "$boot" in *[!0-9A-Fa-f-]*) return 1;; esac
    issued=$(now) || return 1
    policy_deadline=$((issued + 180))
    [ "$policy_deadline" -le "$deadline" ] || policy_deadline=$deadline
    safe_session || return 1
    /bin/cat > "$work/policy-grant.staged.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>schema</key><string>sleep-module1-policy-v1</string>
<key>scope</key><string>one-additive-sleep-update-no-control</string>
<key>bootUUID</key><string>$boot</string>
<key>issuedUnix</key><integer>$issued</integer>
<key>deadlineUnix</key><integer>$policy_deadline</integer>
</dict></plist>
EOF
    [ "$?" -eq 0 ] && /usr/sbin/chown mobile:mobile "$work/policy-grant.staged.plist" &&
        /usr/bin/chmod 600 "$work/policy-grant.staged.plist" || return 1
    /bin/mv "$work/policy-grant.staged.plist" "$session/focus/policy-grant.plist" || return 1
    install_pair focus "$focus" || return 1
    restart focus-active com.apple.donotdisturbd || return 1
    focus_pid='' pid_ticks=0
    while [ "$pid_ticks" -lt 10 ]; do
        poll_guard || return 1
        focus_pid=$(pid_for donotdisturbd) || focus_pid=''
        if [ -n "$focus_pid" ] && [ "$focus_pid" != "$previous_focus_pid" ]; then break; fi
        /bin/sleep 1 || return 1
        pid_ticks=$((pid_ticks + 1))
    done
    [ -n "$focus_pid" ] && [ "$focus_pid" != "$previous_focus_pid" ] || return 1
    wait_focus_ready || return 1
    write_status waitingForSave waitingForSave || return 1
    failure=noNativeSource
    ticks=0 source_at=0 ack_at=0
    while [ "$ticks" -lt 180 ]; do
        poll_guard || return 1
        wall=$(now) || return 1
        [ "$wall" -lt "$policy_deadline" ] || return 1
        [ "$(pid_for donotdisturbd)" = "$focus_pid" ] || return 1
        contents=$(read_log "$session/focus/run-$focus_pid.log") || contents=''
        if [ "$sends" -eq 0 ]; then
            case "$contents" in *'outbound event='*) failure=sourceNotEligible;; esac
        fi
        case "$contents" in *'SLEEPMODULE1 adding ONE Sleep v11 update; original native batch/completion preserved'*)
            if [ "$sends" -eq 0 ]; then
                mark sent-observed || return 1
                sends=1 source_at=$wall failure=ackNotObserved
                write_status sending sending || return 1
            fi;;
        esac
        if [ "$sends" -eq 1 ]; then
            case "$contents" in *'SLEEPMODULE1 real v11/12 ACK metadata matched; observation only, native acceptance/storage and transaction causality unverified'*)
                if [ "$ack" = false ]; then
                    mark ack-matched || return 1
                    ack=true ack_at=$wall
                    write_status acknowledged acknowledged || return 1
                fi;;
            esac
            if [ "$ack" = true ]; then
                case "$contents" in *'WATCH-SLEEP-EXPORT status='*) return 0;; esac
                # Bounded polling grace, not a fabricated return update or blind sleep.
                [ "$((wall - ack_at))" -lt 5 ] || return 0
            else
                [ "$((wall - source_at))" -lt 90 ] || return 1
            fi
        fi
        /bin/sleep 1 || return 1
        ticks=$((ticks + 1))
    done
    return 1
}

run_session || :
finish
