#!/usr/bin/env bash
#
# adt.sh — devices and flow runs for the agentic-dev-team pipeline.
#
# Usage:
#   adt.sh preflight      --driver auto-mobile|maestro
#   adt.sh device-acquire --slug <slug> [--background]
#   adt.sh install        --slug <slug> -- <install command...>   (prints BUILD_INSTALLED)
#   adt.sh run            --slug <slug> --driver auto-mobile|maestro
#                         [--area <area>:<tiers>]... [--exclude <id>]...
#                         [--only <id>]...
#   adt.sh suite          --driver auto-mobile|maestro [--serial <serial>]
#                         [--area <area>:<tiers>]... [--all] [--exclude <id>]...
#                         [--out <dir>]
#   adt.sh select         --driver auto-mobile|maestro
#                         [--area <area>:<tiers>]... [--exclude <id>]...
#   adt.sh check          --slug <slug> --name <name> [--device] -- <command...>
#   adt.sh promote        --slug <slug> [--remove <id>]...
#   adt.sh state          --slug <slug> start <command> | set <key> <value>
#                         | get <key> | bump <key> --max <n> | show
#   adt.sh device-release --slug <slug> | --serial <serial>
#   adt.sh device-list
#   adt.sh allow          [--remove] [--project <dir>]
#
# preflight checks the machine before a run starts. The only thing it changes
# is to start auto-mobile's background service when it is not running, which
# the run needs anyway, so a service that cannot start is found at once.
#
# Every build command leases one device for its whole run. device-acquire
# boots a headless, read-only emulator (or reuses this run's existing lease)
# and prints its serial on the last line; with --background it returns at once
# and boots the device while other work runs, and a later device-acquire for
# the same slug waits for it. When there is memory for it, the run also gets a
# second emulator, booted in the background, that only run uses.
#
# install runs the project's install command on the run's device only. On an
# emulator it started, it clears app caches first, and if the install still
# runs out of space it restarts the emulator as a fresh copy of its AVD, on
# the same serial, and tries once more.
#
# run executes the run's flow files, plus the regression suite flows it
# selects, with no model in the loop, splitting them between the run's two
# emulators when it has two, and writes run-results.md. It reads Android's
# crash log after each flow, so a crash or ANR of the app fails the flow.
# With --only, it re-runs just the named flows of this run and updates their
# rows. check runs one of the plan's Section 0 checks (today, the device
# tests on the run's device) and records it in checks.md for the Tester. promote keeps this run's passing flows in e2e/flows/, and only when
# the Tester's test-results.md says READY TO MERGE. state is the run's
# ledger: the phase, paths and budgets a build command records as it goes, so
# a run can be resumed and a spent budget is refused (exit 17). suite replays
# e2e/flows/ on a device it is given, with no lease (for CI), and writes a
# JUnit report beside run-results.md. device-release
# stops the run's devices when it ends. allow adds the pipeline's permission
# rules to the project's .claude/settings.local.json (or, with --remove, takes
# them out again).
#
# The regression suite is e2e/flows/<area>/<name>.yaml in the project. A run
# replays every P0 flow, plus the tiers each --area names (for example
# --area checkout:p1,p2), minus any --exclude, minus suite flows this run
# re-specifies (same id as one of its own flows).
#
# A lease belongs to a project directory and a slug together, so two worktrees
# or two apps never share a device. The project directory is the nearest one,
# from the current directory up to the git top level, that holds
# pipeline_artifacts/; or else the git top level.
#
# Environment:
#   ADT_AVD              AVD to boot (default: the first one not open in normal mode)
#   ADT_DEVICE_MODE      "reuse" = use an attached device, boot nothing
#   ADT_HEADLESS         "0" = show the emulator window (default: headless)
#   ADT_BOOT_TIMEOUT_S   seconds to wait for boot (default 240)
#   ADT_HOME             where leases live (default ~/.adt)
#   ADT_PORT_FIRST/LAST  console port range (default 5554-5584; for tests)
#   ADT_FLOW_TIMEOUT_S   longest one flow may run before it fails (default 300)
#   ADT_P0_BUDGET_S      warn when the P0 flows take longer than this (default 180)
#   ADT_PARALLEL         most emulators one run may use: 2 (the default) boots
#                        a second one when there is memory for it; 1 never does
#   ADT_MEM_TOTAL_MB/ADT_MEM_AVAILABLE_MB  memory to assume (for tests)
#   ADT_SECOND_BOOT_WAIT_S  how long run waits for a second emulator still
#                        booting before it stops it (default 90; for tests)
#   ADT_AUTOMOBILE       auto-mobile command (default: bunx @kaeawc/auto-mobile@0.0.84)
#   ADT_MAESTRO          Maestro command (default: maestro)
#
# Exit codes:
#   0 success, 1 a flow or a check failed (run, check), 2 usage, 10 no
#   device, 11 the emulator did not start or boot, 12 install failed, 13 a
#   device could not be stopped, 14 the driver's command was not found, 15 no
#   live device is leased for this run, 16 preflight found a problem, 17 a
#   budget is spent (state bump)
#
# Runs under bash 3.2 (the macOS system shell): no associative arrays, no
# mapfile, no ${var,,}.

set -u

ADT_HOME="${ADT_HOME:-$HOME/.adt}"
LEASE_ROOT="$ADT_HOME/leases"
BOOT_TIMEOUT="${ADT_BOOT_TIMEOUT_S:-240}"
# auto-mobile hides some tools the pipeline needs. Its background service
# enables a list of them when it starts, from this variable, and every client
# then sees that list. So any auto-mobile call made here, which may be the one
# that starts the service, carries the same list as the MCP registration.
export AUTOMOBILE_ENABLED_TOOLS="${AUTOMOBILE_ENABLED_TOOLS:-rotate,displayConfig,setAppPermissions,setDeviceState,getDeviceState,openLink,executePlan}"

# Emulator console ports are even, from 5554 to 5584; adb uses the port above.
PORT_FIRST="${ADT_PORT_FIRST:-5554}"
PORT_LAST="${ADT_PORT_LAST:-5584}"

# ---------- output ----------

say() { printf '%s\n' "$*" >&2; }

die() {
  local code="$1"; shift
  say "adt: $*"
  exit "$code"
}

usage() {
  sed -n '3,/^# Runs under bash/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# ---------- small helpers ----------

now() { date +%s; }

# Modification time of a path, in epoch seconds (BSD and GNU stat differ).
mtime() {
  # GNU first: on Linux, `stat -f` reports on the file system, not the file.
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || now
}

# The project: the nearest directory from here up to the git top level that
# holds pipeline_artifacts/, which the agents write beside AGENTS.md, or else
# the git top level. So an app in a subfolder of its repository works, and so
# does a command run from a subfolder of the app.
project_dir() {
  local here top dir
  here="$(pwd -P)"
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf '%s\n' "$here"; return 0; }
  top="$(cd "$top" && pwd -P)"
  dir="$here"
  while :; do
    if [ -d "$dir/pipeline_artifacts" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    case "$dir" in "$top"/*) dir="$(dirname "$dir")" ;; *) break ;; esac
  done
  printf '%s\n' "$top"
}

# True when something accepts a TCP connection on 127.0.0.1:<port>.
port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------- tools ----------

ADB=""
EMULATOR=""

find_adb() {
  [ -n "$ADB" ] && return 0
  if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
    return 0
  fi
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$sdk" ] && [ -x "$sdk/platform-tools/adb" ]; then
      ADB="$sdk/platform-tools/adb"
      return 0
    fi
  done
  die 10 "adb not found. Install the Android SDK platform tools, or set ANDROID_HOME."
}

# The SDK is found from ANDROID_HOME, ANDROID_SDK_ROOT, the adb on PATH, then
# the platform default. A candidate counts only if it has emulator/emulator.
find_emulator() {
  [ -n "$EMULATOR" ] && return 0
  find_adb
  local from_adb sdk
  from_adb="$(cd "$(dirname "$ADB")/.." 2>/dev/null && pwd -P)"
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$from_adb" \
             "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$sdk" ] && [ -x "$sdk/emulator/emulator" ]; then
      EMULATOR="$sdk/emulator/emulator"
      return 0
    fi
  done
  return 1
}

# "<serial> <state>" for every device adb knows about.
adb_devices() {
  "$ADB" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1, $2 }'
}

serial_listed() {
  adb_devices | awk -v s="$1" '$1 == s { found = 1 } END { exit !found }'
}

console_port() {
  case "$1" in
    emulator-*) printf '%s\n' "${1#emulator-}" ;;
    *) printf '\n' ;;
  esac
}

# ---------- leases ----------
# A lease is the directory $LEASE_ROOT/<serial>/. mkdir is the atomic claim;
# its files (project, slug, created, started, avd, pid) are written right after.

lease_path() { printf '%s/%s\n' "$LEASE_ROOT" "$1"; }

lease_get() {
  local f
  f="$(lease_path "$1")/$2"
  [ -f "$f" ] && cat "$f"
}

lease_set() {
  printf '%s\n' "$3" > "$(lease_path "$1")/$2"
}

lease_serials() {
  [ -d "$LEASE_ROOT" ] || return 0
  local d
  for d in "$LEASE_ROOT"/*; do
    [ -d "$d" ] && basename "$d"
  done
}

lease_created() {
  local c
  c="$(lease_get "$1" created)"
  if [ -z "$c" ]; then
    c="$(mtime "$(lease_path "$1")")"
  fi
  printf '%s\n' "$c"
}

# Live: adb lists the serial, or the emulator's console port answers.
lease_live() {
  local port
  serial_listed "$1" && return 0
  port="$(console_port "$1")"
  [ -n "$port" ] && port_open "$port" && return 0
  return 1
}

# Stale: not live, and older than the boot timeout, so a claim whose emulator
# is still booting is never taken.
remove_stale_leases() {
  local serial age
  for serial in $(lease_serials); do
    lease_live "$serial" && continue
    age=$(( $(now) - $(lease_created "$serial") ))
    if [ "$age" -gt "$BOOT_TIMEOUT" ]; then
      rm -rf "$(lease_path "$serial")"
      say "adt: removed stale lease $serial"
    fi
  done
}

# Prints the serial of this project's lease for <slug>, if any.
find_lease() {
  local project="$1" slug="$2" serial
  for serial in $(lease_serials); do
    if [ "$(lease_get "$serial" project)" = "$project" ] && \
       [ "$(lease_get "$serial" slug)" = "$slug" ]; then
      printf '%s\n' "$serial"
      return 0
    fi
  done
  return 1
}

claim() {
  local serial="$1" project="$2" slug="$3" started="$4"
  mkdir -p "$LEASE_ROOT"
  mkdir "$(lease_path "$serial")" 2>/dev/null || return 1
  lease_set "$serial" project "$project"
  lease_set "$serial" slug "$slug"
  lease_set "$serial" created "$(now)"
  lease_set "$serial" started "$started"
  return 0
}

# ---------- one acquire at a time per run ----------
# device-acquire holds a lock per project and slug, so a background acquire
# started early and the test phase's own acquire never boot two devices.

LOCK_DIR=""

lock_key() {
  printf '%s|%s' "$1" "$2" | cksum | awk '{ print $1 }'
}

release_lock() {
  [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
  LOCK_DIR=""
}

take_lock() {
  local lock holder waited=0 limit
  lock="$LEASE_ROOT/.lock-$(lock_key "$1" "$2")"
  limit=$(( BOOT_TIMEOUT * 2 + 120 ))
  mkdir -p "$LEASE_ROOT"
  while ! mkdir "$lock" 2>/dev/null; do
    holder="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    if [ -z "$holder" ] && [ $(( $(now) - $(mtime "$lock") )) -gt 30 ]; then
      rm -rf "$lock"
      continue
    fi
    [ "$waited" -ge "$limit" ] && return 1
    [ "$waited" -eq 0 ] && say "adt: waiting for the device that is already booting for '$2'"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$lock/pid"
  LOCK_DIR="$lock"
  trap release_lock EXIT
  return 0
}

# ---------- emulators ----------

list_avds() {
  "$EMULATOR" -list-avds 2>/dev/null | tr -d '\r' | awk 'NF == 1'
}

is_avd_name() {
  list_avds | grep -Fxq "$1"
}

# AVDs open in normal mode: reported by a running emulator that has no lease.
avds_in_normal_mode() {
  local serial state name
  adb_devices | while read -r serial state; do
    case "$serial" in emulator-*) ;; *) continue ;; esac
    [ -d "$(lease_path "$serial")" ] && continue
    "$ADB" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | while read -r name; do
      [ -n "$name" ] && is_avd_name "$name" && printf '%s\n' "$name"
    done
  done | sort -u
}

# Prints the first usable AVD not in the skip list (newline-separated).
choose_avd() {
  local skip="$1" busy avd
  busy="$(avds_in_normal_mode)"
  if [ -n "${ADT_AVD:-}" ]; then
    is_avd_name "$ADT_AVD" || \
      die 10 "ADT_AVD=$ADT_AVD is not an AVD on this machine. Known AVDs: $(list_avds | tr '\n' ' ')"
    printf '%s\n' "$busy" | grep -Fxq "$ADT_AVD" && \
      die 10 "ADT_AVD=$ADT_AVD is open in normal mode, and a read-only copy cannot start beside it. Close it, or unset ADT_AVD."
    printf '%s\n' "$ADT_AVD"
    return 0
  fi
  for avd in $(list_avds); do
    printf '%s\n' "$busy" | grep -Fxq "$avd" && continue
    printf '%s\n' "$skip" | grep -Fxq "$avd" && continue
    printf '%s\n' "$avd"
    return 0
  done
  return 1
}

# Claims the first free even port pair after <after>; prints the serial.
claim_port() {
  local project="$1" slug="$2" after="$3" port serial
  port=$PORT_FIRST
  while [ "$port" -le "$PORT_LAST" ]; do
    serial="emulator-$port"
    if [ "$port" -gt "$after" ] && ! serial_listed "$serial" && \
       ! port_open "$port" && ! port_open $((port + 1)) && \
       claim "$serial" "$project" "$slug" yes; then
      printf '%s\n' "$serial"
      return 0
    fi
    port=$((port + 2))
  done
  return 1
}

# Starts the emulator detached from the calling shell, so it outlives it.
start_detached() {
  local log="$1"; shift
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" > "$log" 2>&1 < /dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@" > "$log" 2>&1 < /dev/null &
  else
    nohup "$@" > "$log" 2>&1 < /dev/null &
  fi
  printf '%s\n' "$!"
}

boot_completed() {
  [ "$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ')" = "1" ]
}

# Waits for a leased device to finish booting. Fails if it never does, or
# disappears while waiting.
wait_for_boot() {
  local serial="$1" waited=0
  while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    boot_completed "$serial" && return 0
    lease_live "$serial" || return 1
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# True while the device is still around: listed by adb, or its console answers.
device_present() {
  local port
  serial_listed "$1" && return 0
  port="$(console_port "$1")"
  [ -n "$port" ] && port_open "$port"
}

# Stops a device the script started: emu kill, up to 10 s for it to go, then
# the recorded pid. Succeeds only if the device is really gone.
stop_emulator() {
  local serial="$1" pid i
  pid="$(lease_get "$serial" pid)"
  "$ADB" -s "$serial" emu kill > /dev/null 2>&1
  i=0
  while [ "$i" -lt 10 ] && device_present "$serial"; do
    sleep 1
    i=$((i + 1))
  done
  if device_present "$serial" && [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    i=0
    while [ "$i" -lt 5 ] && device_present "$serial"; do
      sleep 1
      i=$((i + 1))
    done
  fi
  ! device_present "$serial"
}

# Starts <avd> as <serial>, read-only, and waits for it to boot; returns 1 if
# it never does. Never add -wipe-data here: even with -read-only, it erases the
# AVD's own data files.
launch_emulator() {
  local serial="$1" avd="$2" port log pid waited=0
  port="$(console_port "$serial")"
  log="$(lease_path "$serial")/emulator.log"
  set -- -avd "$avd" -read-only -no-audio -no-boot-anim -port "$port"
  [ "${ADT_HEADLESS:-1}" = "0" ] || set -- "$@" -no-window
  say "adt: booting $avd as $serial (read-only, log: $log)"
  pid="$(start_detached "$log" "$EMULATOR" "$@")"
  lease_set "$serial" pid "$pid"

  while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    if boot_completed "$serial"; then
      "$ADB" -s "$serial" shell settings put global window_animation_scale 0 > /dev/null 2>&1
      "$ADB" -s "$serial" shell settings put global transition_animation_scale 0 > /dev/null 2>&1
      "$ADB" -s "$serial" shell settings put global animator_duration_scale 0 > /dev/null 2>&1
      # The device may wait idle while the Coder works: keep its screen on and
      # unlocked, so the first flow does not meet a dark or locked screen. A
      # read-only copy forgets these settings when it stops.
      "$ADB" -s "$serial" shell settings put system screen_off_timeout 2147483647 > /dev/null 2>&1
      "$ADB" -s "$serial" shell wm dismiss-keyguard > /dev/null 2>&1
      # A freshly booted emulator under load can raise "System UI isn't
      # responding" over the app, and every launch then times out. Crashes are
      # read from Android's log, not from dialogs, so hiding them loses nothing.
      "$ADB" -s "$serial" shell settings put global hide_error_dialogs 1 > /dev/null 2>&1
      "$ADB" -s "$serial" shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# Boots <avd> on a freshly claimed port above <after>. Prints the serial it
# tried, and returns 0 on success, 3 when the AVD is open in normal mode
# elsewhere, or 1 for any other failure (its lease is removed).
boot_avd() {
  local project="$1" slug="$2" avd="$3" after="$4" serial lease log
  serial="$(claim_port "$project" "$slug" "$after")" || {
    say "adt: no free emulator port between $PORT_FIRST and $PORT_LAST"
    return 1
  }
  printf '%s\n' "$serial"
  lease="$(lease_path "$serial")"
  log="$lease/emulator.log"
  lease_set "$serial" avd "$avd"
  launch_emulator "$serial" "$avd" && return 0

  stop_emulator "$serial" > /dev/null 2>&1
  local busy=1
  if grep -qi 'another emulator instance is running\|already running\|multiple emulators' "$log" 2>/dev/null; then
    busy=3
  fi
  say "adt: $avd did not boot as $serial; log follows:"
  tail -n 20 "$log" >&2 2>/dev/null
  cp "$log" "$ADT_HOME/last-failed-boot.log" 2>/dev/null
  rm -rf "$lease"
  return "$busy"
}

# ---------- room to install ----------
# A device the script started is a throwaway read-only copy of an AVD, so it
# may be cleaned and restarted freely. One left running while the Coder works
# fills up as Google Play updates its apps.

# Clears every app's cache: a few hundred MB on a Play image, in a second.
clear_caches() {
  "$ADB" -s "$1" shell pm trim-caches 999G > /dev/null 2>&1
}

# Free space on the device's /data, in MB.
free_mb() {
  "$ADB" -s "$1" shell df -k /data 2>/dev/null | tr -d '\r' | awk 'NR == 2 { printf "%d", $4 / 1024 }'
}

out_of_space() {
  grep -Eqi 'INSUFFICIENT_STORAGE|not enough space|No space left' "$1"
}

# Stops a device the script started and starts a fresh copy of its AVD on the
# same serial, so nothing else in the run has to change.
restart_fresh() {
  local serial="$1" avd
  avd="$(lease_get "$serial" avd)"
  [ -n "$avd" ] && find_emulator || return 1
  stop_emulator "$serial" > /dev/null 2>&1 || return 1
  launch_emulator "$serial" "$avd"
}

# Takes the first online device with no lease, without changing its settings.
acquire_attached() {
  local project="$1" slug="$2" reason="$3" serial state
  while read -r serial state; do
    [ "$state" = "device" ] || continue
    [ -d "$(lease_path "$serial")" ] && continue
    if claim "$serial" "$project" "$slug" no; then
      say "adt: using attached device $serial ($reason); it will not be stopped"
      printf '%s\n' "$serial"
      return 0
    fi
  done <<EOF
$(adb_devices)
EOF
  return 1
}

# ---------- flows ----------
# Rows are tab-separated, and bash's read merges consecutive tabs, so an empty
# field is always written as "-" and turned back into blank on output.
# A flow is one test case as a YAML file in the driver's own format. Its
# header comments carry what the pipeline needs to know about it:
#   # adt:driver: auto-mobile | maestro
#   # adt:priority: p0 | p1 | p2 | none
# Its id is its path under the flows directory, without ".yaml".

FLOW_TIMEOUT="${ADT_FLOW_TIMEOUT_S:-300}"

flow_header() {
  sed -n "s/^# adt:$2:[[:space:]]*//p" "$1" | head -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# A flow's tier, from its priority header: its first word, in lowercase, so
# "P1" and "p1 — the main path" both read as p1.
flow_tier() {
  flow_header "$1" priority | tr 'A-Z' 'a-z' | sed 's/^[^a-z0-9]*//; s/[^a-z0-9].*$//'
}

# An --area value as "<area>:<tiers>", the tiers in lowercase and separated by
# single commas, so "checkout:P1, P2" and "checkout:p1 p2" mean checkout:p1,p2.
area_spec() {
  local area="${1%%:*}" tiers=""
  case "$1" in *:*) tiers="${1#*:}" ;; esac
  tiers="$(printf '%s' "$tiers" | tr 'A-Z' 'a-z' | tr -s ' \t;,' ',' | sed 's/^,//; s/,$//')"
  printf '%s:%s\n' "$area" "$tiers"
}

# Table-safe one-line text: no pipes, no newlines, at most 300 characters.
cell() {
  tr '\n\r|' '  /' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-300
}

# Stops a process and the processes it started (bunx, for one, runs the
# real CLI as a child), so a timed-out flow cannot keep driving the device.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}

# Runs a command for at most <limit> seconds; returns 124 on timeout. A
# watcher process does the timing, so a command that finishes early returns
# at once rather than at the next poll.
run_bounded() {
  local limit="$1" pid watcher rc marker
  shift
  marker="$(mktemp "${TMPDIR:-/tmp}/adt-timeout.XXXXXX")" && rm -f "$marker"
  "$@" &
  pid=$!
  ( sleep "$limit"; : > "$marker"; kill_tree "$pid"; sleep 1; kill -9 "$pid" 2>/dev/null ) \
    > /dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  rc=$?
  kill_tree "$watcher"
  wait "$watcher" 2>/dev/null
  if [ -f "$marker" ]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

# ---------- crashes ----------
# After each flow, Android's crash and system logs are read for the window the
# flow ran in. A crash or ANR of the flow's app fails the flow, even when every
# check in it passed. The app id comes from the flow itself: Maestro's appId
# header, or the first launchApp step's appId.

flow_app_id() {
  sed -n 's/^[[:space:]-]*appId:[[:space:]]*//p' "$1" | head -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

# The device's clock, in the form logcat -T takes.
device_time() {
  "$ADB" -s "$1" shell "date '+%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r'
}

# Prints a one-line description of a crash or ANR of <app> on <serial> since
# <device time>, and succeeds, if there was one.
app_crash_since() {
  local serial="$1" app="$2" since="$3" log re exc
  [ -n "$app" ] && [ -n "$since" ] || return 1
  log="$("$ADB" -s "$serial" logcat -d -b crash,system -T "$since" 2>/dev/null)"
  re="$(printf '%s' "$app" | sed 's/[.]/[.]/g')"
  if printf '%s\n' "$log" | grep -Eq "AndroidRuntime: Process: ${re}(:[^,]*)?, PID"; then
    exc="$(printf '%s\n' "$log" | awk -v re="AndroidRuntime: Process: ${re}(:[^,]*)?, PID" '
      $0 ~ re { if ((getline nxt) > 0) { sub(/^.*AndroidRuntime: /, "", nxt); print nxt }; exit }')"
    printf 'app crashed: %s\n' "${exc:-FATAL EXCEPTION}" | cell
    return 0
  fi
  if printf '%s\n' "$log" | grep -Eq ">>> ${re}(:[^ ]*)? <<<"; then
    printf 'app crashed in native code\n'
    return 0
  fi
  if printf '%s\n' "$log" | grep -Eq "ANR in ${re}([ :]|$)"; then
    printf 'app not responding (ANR)\n'
    return 0
  fi
  return 1
}

# Copies the crash log for the window into <log>, for the Tester and the Coder.
save_crash_log() {
  {
    printf '\n--- Android crash log since %s ---\n' "$3"
    "$ADB" -s "$1" logcat -d -b crash -T "$3" 2>/dev/null
  } >> "$2"
}

# ---------- test secrets ----------
# A flow never holds a credential. It names a test secret as ${NAME}, and the
# value comes from .agentic-dev-team/secrets.env (NAME=value lines), which
# must be git-ignored and untracked. auto-mobile gets the flow with the values
# filled in; Maestro gets them as -e NAME=value. Every log the run keeps is
# scrubbed of the values. No agent reads the file.

SECRETS_FILE=""

# Finds and checks the project's secrets file and sets SECRETS_FILE (empty
# when there is none). Stops when the file could reach git, or is malformed.
load_secrets() {
  local project="$1" f bad
  f="$project/.agentic-dev-team/secrets.env"
  SECRETS_FILE=""
  [ -f "$f" ] || return 0
  if git -C "$project" rev-parse --git-dir > /dev/null 2>&1; then
    if git -C "$project" ls-files --error-unmatch "$f" > /dev/null 2>&1; then
      die 2 "$f is tracked by git. Remove it from git (git rm --cached), then change every secret in it."
    fi
    git -C "$project" check-ignore -q "$f" 2>/dev/null || \
      die 2 "$f is not git-ignored, so a commit could publish it. Keep .agentic-dev-team/.gitignore, or ignore the file in .gitignore."
  fi
  bad="$(tr -d '\r' < "$f" | awk '!/^[[:space:]]*(#|$)/ && !/^[A-Z][A-Z0-9_]*=/ { print NR; exit }')"
  [ -z "$bad" ] || die 2 "line $bad of $f is not NAME=value (NAME in capitals, digits and '_')."
  SECRETS_FILE="$f"
}

# The value of secret <name>.
secret_value() {
  tr -d '\r' < "$SECRETS_FILE" | awk -v n="$1" 'index($0, n "=") == 1 { v = substr($0, length(n) + 2) } END { printf "%s", v }'
}

# The names of the secrets a flow uses: every ${NAME} in it.
flow_secret_names() {
  # MAESTRO_* are Maestro's own variables, not secrets.
  grep -o '[$][{][A-Z][A-Z0-9_]*[}]' "$1" 2>/dev/null | sed 's/^[$][{]//; s/[}]$//' | \
    grep -v '^MAESTRO_' | LC_ALL=C sort -u
}

# Prints the first secret a flow uses that secrets.env does not set, if any.
missing_secret() {
  local n
  for n in $(flow_secret_names "$1"); do
    [ -n "$SECRETS_FILE" ] && tr -d '\r' < "$SECRETS_FILE" | grep -q "^$n=" && continue
    printf '%s\n' "$n"
    return 0
  done
  return 1
}

# The secrets as awk arrays name[1..n] and val[1..n], loaded in BEGIN from
# the file in the variable sf. (Not "NR == FNR": with a file that defines no
# secret, that test would also match the lines of the file being processed.)
SECRETS_AWK='BEGIN {
  while ((getline l < sf) > 0) {
    sub(/\r$/, "", l)
    if (l ~ /^[A-Z][A-Z0-9_]*=/) { i = index(l, "="); name[++n] = substr(l, 1, i - 1); val[n] = substr(l, i + 1) }
  }
  close(sf)
}'

# The flow's text, with each ${NAME} of a secret replaced by its value.
flow_with_secrets() {
  if [ -z "$SECRETS_FILE" ]; then
    cat "$1"
    return
  fi
  awk -v sf="$SECRETS_FILE" "$SECRETS_AWK"'
    {
      line = $0
      for (k = 1; k <= n; k++) {
        tok = "${" name[k] "}"; out = ""
        while ((p = index(line, tok)) > 0) { out = out substr(line, 1, p - 1) val[k]; line = substr(line, p + length(tok)) }
        line = out line
      }
      print line
    }' "$1"
}

# Replaces every secret value in the given files with ***.
scrub_secrets() {
  [ -n "$SECRETS_FILE" ] || return 0
  local f tmp
  for f in "$@"; do
    [ -f "$f" ] || continue
    tmp="$f.scrub.$$"
    awk -v sf="$SECRETS_FILE" "$SECRETS_AWK"'
      {
        line = $0
        for (k = 1; k <= n; k++) {
          if (val[k] == "") continue
          out = ""
          while ((p = index(line, val[k])) > 0) { out = out substr(line, 1, p - 1) "***"; line = substr(line, p + length(val[k])) }
          line = out line
        }
        print line
      }' "$f" > "$tmp" && mv -f "$tmp" "$f"
  done
}

# Scrubs every text file under <dir> (screenshots and videos are left as they
# are: a password field shows dots).
scrub_dir() {
  [ -n "$SECRETS_FILE" ] && [ -d "$1" ] || return 0
  local f
  find "$1" -type f ! -name '*.png' ! -name '*.jpg' ! -name '*.jpeg' ! -name '*.webp' ! -name '*.mp4' ! -name '*.gif' | \
    while IFS= read -r f; do scrub_secrets "$f"; done
}

# auto-mobile: one --cli executePlan call per flow. Sets FLOW_RESULT (PASS or
# FAIL), FLOW_STEP (the failing step and its error) and FLOW_SECONDS.
run_automobile_flow() {
  local flow="$1" log="$2" serial="$3" start rc since crash
  set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  since="$(device_time "$serial")"
  start="$(now)"
  run_bounded "$FLOW_TIMEOUT" "$@" --cli executePlan --platform android \
    --deviceId "$serial" --planContent "$(flow_with_secrets "$flow")" > "$log.out" 2> "$log"
  rc=$?
  scrub_secrets "$log" "$log.out"
  FLOW_SECONDS=$(( $(now) - start ))
  FLOW_STEP=""
  # A result over 64 KB is written to a file, and stdout only points at it.
  # Keep the full result with this run's logs, where it will not expire.
  local artifact
  artifact="$(grep -q '"artifact"' "$log.out" 2>/dev/null && \
    sed -n 's/^[[:space:]]*"path":[[:space:]]*"\([^"]*\)".*/\1/p' "$log.out" | head -n 1)"
  if [ -n "$artifact" ] && [ -f "$artifact" ]; then
    cp "$artifact" "$log.out"
    scrub_secrets "$log.out"
  fi
  if crash="$(app_crash_since "$serial" "$(flow_app_id "$flow")" "$since")"; then
    save_crash_log "$serial" "$log" "$since"
    FLOW_RESULT=FAIL
    FLOW_STEP="$crash"
    return 1
  fi
  if [ "$rc" -eq 0 ] && grep -q '\\"success\\":true\|"success": *true' "$log.out"; then
    FLOW_RESULT=PASS
    return 0
  fi
  FLOW_RESULT=FAIL
  if [ "$rc" -eq 124 ]; then
    FLOW_STEP="timed out after ${FLOW_TIMEOUT}s"
  else
    local where error
    where="$(sed -n 's/^Failed at step //p' "$log" | head -n 1)"
    error="$(sed -n 's/^Step error: //p' "$log" | head -n 1)"
    if [ -n "$where" ]; then
      FLOW_STEP="$(printf 'step %s (%s): %s' "${where%%:*}" "${where#*: }" "$error" | cell)"
    else
      FLOW_STEP="$(grep -v '^[[:space:]]*at \|sourcemap' "$log" | grep . | tail -n 1 | cell)"
      [ -n "$FLOW_STEP" ] || FLOW_STEP="auto-mobile exited with code $rc and no error; see the log"
    fi
  fi
  return 1
}

# Maestro: one `maestro test` call for a list of flows. Prints one line per
# flow: <file> TAB <PASS|FAIL> TAB <seconds> TAB <failure message>.
run_maestro_flows() {
  local serial="$1" out="$2" count n f
  local -a envs
  shift 2
  count=$#
  envs=()
  if [ -n "$SECRETS_FILE" ]; then
    for n in $(for f in "$@"; do flow_secret_names "$f"; done | LC_ALL=C sort -u); do
      envs+=(-e "$n=$(secret_value "$n")")
    done
  fi
  set -- ${ADT_MAESTRO:-maestro} --device "$serial" test ${envs[@]+"${envs[@]}"} --format junit \
    --output "$out/junit.xml" --test-output-dir "$out/artifacts" "$@"
  run_bounded $(( FLOW_TIMEOUT * count )) "$@" > "$out/maestro.log" 2>&1
  # Not "$out" as a whole: the caller is writing results.tsv there now.
  scrub_secrets "$out/maestro.log" "$out/junit.xml"
  scrub_dir "$out/artifacts"
  [ -f "$out/junit.xml" ] || return 0
  tr '\n\r' '  ' < "$out/junit.xml" | awk '
    function unxml(v) {
      gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v); gsub(/&lt;/, "<", v)
      gsub(/&gt;/, ">", v); gsub(/&#10;/, " ", v); gsub(/&amp;/, "\\&", v)
      return v
    }
    function attr(rec, name,    re) {
      re = name "=\"[^\"]*\""
      if (match(rec, re)) return unxml(substr(rec, RSTART + length(name) + 2, RLENGTH - length(name) - 3))
      return ""
    }
    {
      n = split($0, parts, "<testcase ")
      for (i = 2; i <= n; i++) {
        rec = parts[i]
        msg = ""
        result = "PASS"
        if (index(rec, "<failure") > 0) {
          result = "FAIL"
          msg = rec
          sub(/^.*<failure[^>]*>/, "", msg)
          sub(/<\/failure>.*$/, "", msg)
          if (msg == "" && match(rec, /<failure message="[^"]*"/)) msg = attr(rec, "message")
          msg = unxml(msg)
        }
        t = attr(rec, "time")
        if (t == "") t = 0
        printf "%s\t%s\t%d\t%s\n", attr(rec, "file"), result, t + 0.5, msg
      }
    }'
}

# ---------- the regression suite ----------

tier_rank() {
  case "$1" in p0) echo 0 ;; p1) echo 1 ;; p2) echo 2 ;; *) echo 9 ;; esac
}

# select_suite <project> <driver> <areas> <excludes> <feature ids> [all]
# Areas, excludes and feature ids are newline-separated lists; areas are
# "<area>:<tiers>". With all=yes, every p0, p1 and p2 flow is selected.
# Prints "<tier> TAB <id> TAB <path>" per selected flow, P0 first; reports
# flows written for the other driver on stderr.
select_suite() {
  local project="$1" driver="$2" areas="$3" excludes="$4" feature_ids="$5" all="${6:-no}"
  local suite="$project/e2e/flows" flow rel id area tier header spec tiers
  [ -d "$suite" ] || return 0
  find "$suite" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
    rel="${flow#"$suite"/}"
    id="${rel%.yaml}"
    case "$id" in */*) area="${id%%/*}" ;; *) area="" ;; esac
    tier="$(flow_tier "$flow")"
    printf '%s\n' "$excludes" | grep -Fxq "$id" && continue
    printf '%s\n' "$feature_ids" | grep -Fxq "$id" && continue
    header="$(flow_header "$flow" driver)"
    if [ -n "$header" ] && [ "$header" != "$driver" ]; then
      say "adt: skipped suite flow $id: written for $header"
      continue
    fi
    if [ "$all" = yes ]; then
      case "$tier" in p0|p1|p2) ;; *) continue ;; esac
    elif [ "$tier" != p0 ]; then
      [ -n "$area" ] || continue
      tiers=""
      for spec in $areas; do
        [ "${spec%%:*}" = "$area" ] && tiers="$tiers,${spec#*:}"
      done
      case ",$tiers," in *",$tier,"*) ;; *) continue ;; esac
    fi
    printf '%s\t%s\t%s\t%s\n' "$(tier_rank "$tier")" "$tier" "$id" "$flow"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k3,3 | cut -f2-
}

feature_ids() {
  local dir="$1" flow
  [ -d "$dir" ] || return 0
  find "$dir" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
    flow="${flow#"$dir"/}"
    printf '%s\n' "${flow%.yaml}"
  done
}

# ---------- a second device ----------
# When there is memory to spare, a run boots a second emulator beside its own,
# so the flow run can split its flows between the two. It is the script's
# alone: agents only ever use the run's DEVICE. Its lease's slug is "<slug>~2".

PARALLEL="${ADT_PARALLEL:-2}"

second_slug() { printf '%s~2\n' "$1"; }

# Memory in MB: all of it, and how much a new process could have.
mem_total_mb() {
  if [ -n "${ADT_MEM_TOTAL_MB:-}" ]; then echo "$ADT_MEM_TOTAL_MB"
  elif [ -r /proc/meminfo ]; then awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
  else sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d\n", $1 / 1048576 }'
  fi
}
mem_available_mb() {
  if [ -n "${ADT_MEM_AVAILABLE_MB:-}" ]; then echo "$ADT_MEM_AVAILABLE_MB"
  elif [ -r /proc/meminfo ]; then awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
  else
    vm_stat 2>/dev/null | awk '/page size of/ { ps = $8 }
      /^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); n += $NF }
      END { if (ps) printf "%d\n", n * ps / 1048576 }'
  fi
}

# MB one more emulator of <avd> takes: its RAM three times over, and a GB more.
# A read-only copy of a 2 GB AVD takes about 6.4 GB.
emulator_need_mb() {
  local ini path ram
  ini="${ANDROID_AVD_HOME:-$HOME/.android/avd}/$1.ini"
  path="$(sed -n 's/^path=//p' "$ini" 2>/dev/null | tr -d '\r' | head -n 1)"
  ram="$(sed -n 's/^hw.ramSize=//p' "$path/config.ini" 2>/dev/null | tr -d '\r' | head -n 1)"
  case "$ram" in *[Gg]) ram=$(( ${ram%?} * 1024 )) ;; *[Mm]) ram="${ram%?}" ;; esac
  case "$ram" in ''|*[!0-9]*) ram=2048 ;; esac
  echo $(( ram * 3 + 1024 ))
}

# Succeeds when one more emulator of <avd> still leaves a quarter of the
# memory, and at least 8 GB, free. Otherwise prints why not.
can_afford_emulator() {
  local need avail total reserve
  need="$(emulator_need_mb "$1")"
  avail="$(mem_available_mb)"
  total="$(mem_total_mb)"
  case "$avail" in ''|*[!0-9]*) echo "free memory could not be read"; return 1 ;; esac
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  reserve=$(( total / 4 ))
  [ "$reserve" -lt 8192 ] && reserve=8192
  if [ "$avail" -lt $(( need + reserve )) ]; then
    echo "a second emulator needs about $(( need / 1024 )) GB, and $(( avail / 1024 )) GB is free"
    return 1
  fi
}

# Once a run's own emulator is up, boots its second one in the background
# when there is memory for it. Only beside an emulator the script started.
start_second_device() {
  local project="$1" slug="$2" serial="$3" why log avd
  [ "$PARALLEL" -ge 2 ] 2>/dev/null || return 0
  case "$slug" in *~2) return 0 ;; esac
  [ "$(lease_get "$serial" started)" = yes ] || return 0
  [ -z "$(find_lease "$project" "$(second_slug "$slug")")" ] || return 0
  avd="$(lease_get "$serial" avd)"
  if ! why="$(can_afford_emulator "$avd")"; then
    say "adt: flows will run on one emulator: $why"
    return 0
  fi
  log="$ADT_HOME/acquire-$(lock_key "$project" "$(second_slug "$slug")").log"
  ( export ADT_AVD="$avd"
    start_detached "$log" /bin/bash "$(script_path)" device-acquire --slug "$(second_slug "$slug")" > /dev/null )
  say "adt: booting a second emulator in the background, so flows can run on two (log: $log)"
}

cancel_marker() {
  printf '%s/.cancel-%s\n' "$LEASE_ROOT" "$(lock_key "$1" "$2")"
}

# Stops the run's second emulator while it is still booting, so its boot does
# not retry elsewhere. auto-mobile polls a booting emulator hard enough to stall
# its boot, and while it does, it cannot see the run's other emulator either,
# so a run never drives a device while one of its emulators is booting.
cancel_second() {
  local project="$1" slug="$2" serial
  serial="$(find_lease "$project" "$(second_slug "$slug")")"
  [ -n "$serial" ] || return 0
  : > "$(cancel_marker "$project" "$(second_slug "$slug")")"
  stop_emulator "$serial" > /dev/null 2>&1
  rm -rf "$(lease_path "$serial")"
}

# ---------- subcommands ----------

cmd_device_acquire() {
  local slug="" background=0 project serial avd rc skip="" after=0 retried=0 log
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --background) background=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  find_adb
  project="$(project_dir)"

  if [ "$background" = 1 ]; then
    local child lock waited=0
    mkdir -p "$ADT_HOME"
    log="$ADT_HOME/acquire-$(lock_key "$project" "$slug").log"
    child="$(start_detached "$log" /bin/bash "${BASH_SOURCE[0]}" device-acquire --slug "$slug")"
    # Return once the boot holds this run's lock (a few milliseconds), so a
    # device-release that follows at once waits for the boot, not misses it.
    lock="$LEASE_ROOT/.lock-$(lock_key "$project" "$slug")"
    while [ "$waited" -lt 50 ] && kill -0 "$child" 2>/dev/null && \
          [ "$(cat "$lock/pid" 2>/dev/null)" != "$child" ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    say "adt: booting a device for '$slug' in the background (log: $log)"
    say "adt: 'device-acquire --slug $slug' waits for it and prints its serial"
    return 0
  fi

  take_lock "$project" "$slug" || \
    die 11 "another device-acquire for '$slug' did not finish within $(( BOOT_TIMEOUT * 2 + 120 ))s."
  # A boot can be cancelled (see cancel_second); a marker left from before
  # this acquire took the lock is stale.
  local cancel
  cancel="$(cancel_marker "$project" "$slug")"
  rm -f "$cancel"
  remove_stale_leases
  serial="$(find_lease "$project" "$slug")"
  if [ -n "$serial" ] && lease_live "$serial"; then
    if wait_for_boot "$serial"; then
      say "adt: reusing this run's device $serial"
      start_second_device "$project" "$slug" "$serial"
      printf '%s\n' "$serial"
      return 0
    fi
    say "adt: $serial never finished booting; replacing it"
    [ "$(lease_get "$serial" started)" = yes ] && stop_emulator "$serial" > /dev/null 2>&1
  fi
  [ -n "$serial" ] && rm -rf "$(lease_path "$serial")"

  if [ "${ADT_DEVICE_MODE:-}" = "reuse" ]; then
    acquire_attached "$project" "$slug" "ADT_DEVICE_MODE=reuse" && return 0
    die 10 "ADT_DEVICE_MODE=reuse, but no attached device is online and free."
  fi

  # An attached device is the developer's own: flows clear the app's data on
  # the device they run on. So it is used only when they ask for it.
  if ! find_emulator; then
    die 10 "the Android emulator is not installed. Install it from Android Studio's SDK Manager, or set ADT_DEVICE_MODE=reuse to test on an attached device (flows clear the app's data on it)."
  fi

  if [ -n "${ADT_AVD:-}" ]; then
    avd="$(choose_avd "")" || exit $?
  fi

  while :; do
    if ! avd="$(choose_avd "$skip")"; then
      if [ -z "$(list_avds)" ]; then
        die 10 "no AVD exists. Create one in Android Studio's Device Manager, or set ADT_DEVICE_MODE=reuse to test on an attached device (flows clear the app's data on it)."
      fi
      die 10 "every AVD is open in normal mode, and a read-only copy cannot start beside it. Close one, create another AVD, or set ADT_DEVICE_MODE=reuse to test on an attached device (flows clear the app's data on it)."
    fi
    serial="$(boot_avd "$project" "$slug" "$avd" "$after")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      start_second_device "$project" "$slug" "$serial"
      printf '%s\n' "$serial"
      return 0
    fi
    if [ -f "$cancel" ]; then
      rm -f "$cancel"
      die 11 "the boot of a device for '$slug' was cancelled."
    fi
    if [ "$rc" -eq 3 ] && [ -z "${ADT_AVD:-}" ]; then
      say "adt: $avd is open in normal mode; trying the next AVD"
      skip="$(printf '%s\n%s\n' "$skip" "$avd")"
      continue
    fi
    if [ "$retried" -eq 0 ] && [ -n "$serial" ]; then
      retried=1
      after="$(console_port "$serial")"
      say "adt: retrying once on the next free ports"
      continue
    fi
    die 11 "the emulator did not start or boot. Log: $ADT_HOME/last-failed-boot.log"
  done
}

# Runs the install command once, on <serial> only. Its output goes to stderr
# and to <out>, so the only thing on stdout is the BUILD_INSTALLED timestamp.
install_once() {
  local serial="$1" out="$2"
  shift 2
  say "adt: installing on $serial: $*"
  ANDROID_SERIAL="$serial" "$@" 2>&1 | tee "$out" >&2
  return "${PIPESTATUS[0]}"
}

cmd_install() {
  local slug="" project serial own out rc avd stamp
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ $# -gt 0 ] || usage
  find_adb
  project="$(project_dir)"
  serial="$(find_lease "$project" "$slug")"
  [ -n "$serial" ] && lease_live "$serial" || \
    die 15 "no live device is leased for slug '$slug' in $project. Run device-acquire first."
  own=no
  [ "$(lease_get "$serial" started)" = yes ] && own=yes
  avd="$(lease_get "$serial" avd)"
  out="$(mktemp "${TMPDIR:-/tmp}/adt-install.XXXXXX")"

  [ "$own" = yes ] && clear_caches "$serial"
  install_once "$serial" "$out" "$@"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$own" = yes ] && out_of_space "$out"; then
    say "adt: $serial ran out of space; restarting it as a fresh copy of $avd and installing again"
    take_lock "$project" "$slug" || { rm -f "$out"; die 12 "$serial ran out of space, and another command holds this run's device."; }
    if ! restart_fresh "$serial"; then
      rm -f "$out"
      die 11 "$serial ran out of space and did not restart. Log: $(lease_path "$serial")/emulator.log"
    fi
    clear_caches "$serial"
    install_once "$serial" "$out" "$@"
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if out_of_space "$out" && [ "$own" = yes ]; then
      rm -f "$out"
      die 12 "not enough space to install on $serial, even on a fresh copy of $avd with its caches cleared ($(free_mb "$serial") MB free). That AVD itself is nearly full. Give it more room in Android Studio's Device Manager: Edit, then Internal storage (16 GB, say), then Wipe Data on that AVD. Or set ADT_AVD to an AVD with more room."
    elif out_of_space "$out"; then
      rm -f "$out"
      die 12 "not enough space to install on $serial ($(free_mb "$serial") MB free). Free some space on it, then run the command again."
    fi
    rm -f "$out"
    die 12 "the install command failed on $serial."
  fi
  rm -f "$out"
  # Recorded so the flow run can put the same build on the run's second device.
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\0' "$@" > "$(lease_path "$serial")/install-cmd"
  lease_set "$serial" installed "$stamp"
  printf '%s\n' "$stamp"
}

# ---------- running flows on one or two devices ----------

# Prints the first line of <queue> and removes it; fails when it is empty.
# Workers share the queue, so a mkdir lock guards it. A worker that takes a
# flow touches <marker>, if it names one, before the lock is released.
queue_pop() {
  local queue="$1" marker="${2:-}" line
  while ! mkdir "$queue.lock" 2>/dev/null; do sleep 0.1; done
  line="$(head -n 1 "$queue" 2>/dev/null)"
  if [ -n "$line" ]; then
    tail -n +2 "$queue" > "$queue.tmp" && mv "$queue.tmp" "$queue"
    [ -n "$marker" ] && : > "$marker"
  fi
  rmdir "$queue.lock"
  [ -n "$line" ] && printf '%s\n' "$line"
}

# Gets <serial> ready for flows: closes any system dialog left on screen and,
# under auto-mobile, binds to the device. auto-mobile installs a helper app on
# a device the first time it drives it, and remembers that per serial for as
# long as its background service runs. A fresh emulator on a serial it has
# seen before lacks the helper, and auto-mobile then refuses to set it up
# again, so every flow would fail. Binding makes it check, and set it up again.
prepare_device() {
  local serial="$1"
  "$ADB" -s "$serial" shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1
  if [ "$driver" = auto-mobile ]; then
    run_bounded 120 ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84} --cli getAndroid --deviceId "$serial" \
      > "$logs/bind-$serial.log" 2>&1 < /dev/null || \
      say "adt: auto-mobile could not bind to $serial; see $logs/bind-$serial.log"
  fi
}

# Gets the run's second device ready: waits for its boot, installs the build
# the first device has, with the command install recorded, and prepares it.
# Prints why not, and fails, if any step does.
prepare_second() {
  local first="$1" second="$2" stamp a
  local -a cmd
  wait_for_boot "$second" || { echo "it did not finish booting"; return 1; }
  stamp="$(lease_get "$first" installed)"
  [ -n "$stamp" ] || { echo "the build was not installed through adt.sh install"; return 1; }
  if [ "$(lease_get "$second" installed)" != "$stamp" ]; then
    [ -s "$(lease_path "$first")/install-cmd" ] || { echo "no install command was recorded"; return 1; }
    cmd=()
    while IFS= read -r -d '' a; do cmd+=("$a"); done < "$(lease_path "$first")/install-cmd"
    clear_caches "$second"
    if ! ANDROID_SERIAL="$second" "${cmd[@]}" > "$logs/install-$second.log" 2>&1 < /dev/null; then
      echo "installing the build on it failed; see $logs/install-$second.log"
      return 1
    fi
    lease_set "$second" installed "$stamp"
  fi
  prepare_device "$second" > /dev/null 2>&1
}

# Runs flows from <queue> on <serial> under auto-mobile until the queue is
# empty, adding each one's row to <rows>.
automobile_worker() {
  local serial="$1" queue="$2" rows="$3" attempt="$4" marker="${5:-}" line kind id flow log
  while line="$(queue_pop "$queue" "$marker")"; do
    IFS="$(printf '\t')" read -r kind id flow <<EOF
$line
EOF
    log="$logs/$kind-$(printf '%s' "$id" | tr '/' '_').attempt$attempt.log"
    run_automobile_flow "$flow" "$log" "$serial" < /dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$flow" "$FLOW_RESULT" "${FLOW_STEP:--}" "$FLOW_SECONDS" \
      "${log#"$rel_base"/}" >> "$rows"
  done
}

# Runs the flows listed in <todo> in one Maestro call on <serial>, adding each
# one's row to <rows>. One call runs them all, so a crash of the app cannot be
# pinned on one flow: it gets its own failing row, <crash id>.
maestro_batch() {
  local serial="$1" todo="$2" rows="$3" out="$4" crash_id="$5" kind id flow since app crash line result secs step
  local -a files
  [ -s "$todo" ] || return 0
  mkdir -p "$out"
  files=()
  while IFS="$(printf '\t')" read -r kind id flow; do files+=("$flow"); done < "$todo"
  since="$(device_time "$serial")"
  run_maestro_flows "$serial" "$out" "${files[@]}" > "$out/results.tsv"
  for app in $(for flow in "${files[@]}"; do flow_app_id "$flow"; done | LC_ALL=C sort -u); do
    if crash="$(app_crash_since "$serial" "$app" "$since")"; then
      save_crash_log "$serial" "$out/maestro.log" "$since"
      printf '%s\t%s\t%s\tFAIL\t%s\t0\t%s\n' "$crash_id" "check" "-" "$crash ($app, during the Maestro run)" \
        "${out#"$rel_base"/}/maestro.log" >> "$logs/.rows"
    fi
  done
  while IFS="$(printf '\t')" read -r kind id flow; do
    line="$(awk -F'\t' -v f="$flow" '$1 == f || (length($1) > 0 && substr(f, length(f) - length($1) + 1) == $1) { print; exit }' "$out/results.tsv")"
    if [ -n "$line" ]; then
      result="$(printf '%s' "$line" | cut -f2)"
      secs="$(printf '%s' "$line" | cut -f3)"
      step="$(printf '%s' "$line" | cut -f4- | cell)"
    else
      result=FAIL; secs=0
      step="no result in Maestro's report; see its log"
    fi
    [ "$result" = PASS ] && step=""
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$flow" "$result" "${step:--}" "${secs:-0}" \
      "${out#"$rel_base"/}/maestro.log" >> "$rows"
  done < "$todo"
}

# Runs one attempt's flows (<todo>) on the run's device and, when it is ready
# to help, the second device; adds their rows to <rows>. The second device
# joins once it has booted, has the build and is prepared, so it never holds
# the run up: if the first device runs out of flows before it joins, it is
# left out of this run.
run_attempt() {
  local todo="$1" rows="$2" attempt="$3" w2 why
  # A worker stopped while it held the queue's lock leaves it behind.
  rm -rf "$logs/.queue.lock"
  if [ -z "$second" ]; then
    if [ "$driver" = auto-mobile ]; then
      cp "$todo" "$logs/.queue"
      automobile_worker "$serial" "$logs/.queue" "$rows" "$attempt"
    else
      maestro_batch "$serial" "$todo" "$rows" "$logs/maestro.attempt$attempt" "${recheck}crash-check-$attempt"
    fi
    return 0
  fi
  rm -f "$logs/.second-took" "$logs/.second-why"
  rm -rf "$logs/.claim-b"
  if [ "$driver" = auto-mobile ]; then
    cp "$todo" "$logs/.queue"
    (
      if [ "$second_ready" = yes ] || why="$(prepare_second "$serial" "$second")"; then
        automobile_worker "$second" "$logs/.queue" "$rows" "$attempt" "$logs/.second-took"
      else
        printf '%s\n' "$why" > "$logs/.second-why"
      fi
    ) &
    w2=$!
    automobile_worker "$serial" "$logs/.queue" "$rows" "$attempt"
    # The queue is empty. A second device that never took a flow is still
    # getting ready: stop it rather than wait for it.
    [ -f "$logs/.second-took" ] || kill_tree "$w2"
    wait "$w2" 2>/dev/null
    rm -rf "$logs/.queue.lock"
  else
    # Maestro runs a list of flows per call: half for each device. The second
    # half goes to the second device once it is ready, or back to the first.
    awk 'NR % 2 == 1' "$todo" > "$logs/.todo-a"
    awk 'NR % 2 == 0' "$todo" > "$logs/.todo-b"
    (
      if [ "$second_ready" = yes ] || why="$(prepare_second "$serial" "$second")"; then
        mkdir "$logs/.claim-b" 2>/dev/null && : > "$logs/.second-took" && \
          maestro_batch "$second" "$logs/.todo-b" "$rows" "$logs/maestro.attempt$attempt-2" "${recheck}crash-check-$attempt-2"
      else
        printf '%s\n' "$why" > "$logs/.second-why"
      fi
    ) &
    w2=$!
    maestro_batch "$serial" "$logs/.todo-a" "$rows" "$logs/maestro.attempt$attempt" "${recheck}crash-check-$attempt"
    if mkdir "$logs/.claim-b" 2>/dev/null; then
      kill_tree "$w2"
      wait "$w2" 2>/dev/null
      maestro_batch "$serial" "$logs/.todo-b" "$rows" "$logs/maestro.attempt$attempt-b" "${recheck}crash-check-$attempt-b"
    else
      wait "$w2" 2>/dev/null
    fi
  fi
  if [ -f "$logs/.second-took" ]; then
    second_ready=yes
    second_used=yes
  else
    [ -f "$logs/.second-why" ] && say "adt: the second emulator $second was left out: $(cat "$logs/.second-why")"
    second=""
  fi
}

cmd_run() {
  local slug="" driver="" project serial flows_dir results logs flow id rel only="" recheck=""
  local total=0 passed=0 failed=0 flaky=0 skipped=0 seconds=0 areas="" excludes="" started_at
  local second="" second_ready=no second_used=no rel_base suite_serial="" suite_out="" all_tiers=no
  started_at="$(now)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --driver) driver="${2:-}"; shift 2 ;;
      # Set by cmd_suite only: the device, the results folder, every tier.
      --suite-serial) suite_serial="${2:-}"; shift 2 ;;
      --suite-out) suite_out="${2:-}"; shift 2 ;;
      --all) all_tiers=yes; shift ;;
      --area) areas="$areas
$(area_spec "${2:-}")"; shift 2 ;;
      # A tier on its own, as in "--area checkout:p1 p2", belongs to that area.
      [pP][0-2]) [ -n "$areas" ] || usage; areas="$areas,$(printf '%s' "$1" | tr 'P' 'p')"; shift ;;
      --exclude) excludes="$excludes
${2:-}"; shift 2 ;;
      --only) only="$only
${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  find_adb
  project="$(project_dir)"
  if [ -n "$suite_serial" ]; then
    serial="$suite_serial"
  else
    serial="$(find_lease "$project" "$slug")"
    [ -n "$serial" ] && lease_live "$serial" || \
      die 15 "no live device is leased for slug '$slug' in $project. Run device-acquire first."
  fi

  if [ "$driver" = auto-mobile ]; then
    set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  else
    set -- ${ADT_MAESTRO:-maestro}
  fi
  command -v "$1" > /dev/null 2>&1 || die 14 "the $driver command '$1' was not found. See HOW_IT_WORKS, 'Setting up device testing'."

  load_secrets "$project"
  if [ -n "$suite_out" ]; then
    rel_base="$suite_out"
    flows_dir="$suite_out/.no-feature-flows"
  else
    rel_base="$project/pipeline_artifacts/$slug"
    flows_dir="$rel_base/flows"
  fi
  results="$rel_base/run-results.md"
  logs="$rel_base/run-logs"
  local list="$logs/.flows"
  if [ -n "$only" ]; then
    # Re-run only the named flows of this run, and update their rows in the
    # results of the last full run.
    [ -f "$logs/rows.tsv" ] || die 2 "no earlier flow run to update in $logs: run without --only first."
    for id in $(printf '%s\n' "$only" | awk 'NF'); do
      [ -f "$flows_dir/$id.yaml" ] || die 2 "no flow $id in $flows_dir."
    done
    recheck="recheck-"
    rm -f "$logs"/.flows "$logs"/.runnable "$logs"/.todo "$logs"/.queue "$logs"/.attempt1 "$logs"/.attempt2 "$logs"/.rows
    : > "$list"
    for id in $(printf '%s\n' "$only" | awk 'NF' | LC_ALL=C sort -u); do
      printf 'feature\t%s\t%s\n' "$flows_dir" "$flows_dir/$id.yaml" >> "$list"
    done
  else
    rm -rf "$logs"
    mkdir -p "$logs"
    # The flows to run: every *.yaml under this run's flows directory, then the
    # regression suite flows this run selects.
    : > "$list"
    if [ -d "$flows_dir" ]; then
      find "$flows_dir" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
        printf 'feature\t%s\t%s\n' "$flows_dir" "$flow"
      done >> "$list"
    fi
    select_suite "$project" "$driver" "$areas" "$excludes" "$(feature_ids "$flows_dir")" "$all_tiers" | \
      while IFS="$(printf '\t')" read -r _ _ flow; do
        printf 'regression\t%s\t%s\n' "$project/e2e/flows" "$flow"
      done >> "$list"
  fi

  # Driver mismatch: a flow written for the other driver is skipped, not run.
  local runnable="$logs/.runnable"
  : > "$runnable"
  local kind base header tier secret
  while IFS="$(printf '\t')" read -r kind base flow; do
    rel="${flow#"$base"/}"
    id="${rel%.yaml}"
    header="$(flow_header "$flow" driver)"
    if [ -n "$header" ] && [ "$header" != "$driver" ]; then
      tier="$(flow_tier "$flow")"
      printf '%s\t%s\t%s\tSKIPPED\twritten for %s\t0\t-\n' "$id" "$kind" "${tier:--}" "$header" >> "$logs/.rows"
      continue
    fi
    if secret="$(missing_secret "$flow")"; then
      tier="$(flow_tier "$flow")"
      printf '%s\t%s\t%s\tFAIL\tneeds the test secret %s, which .agentic-dev-team/secrets.env does not set\t0\t-\n' \
        "$id" "$kind" "${tier:--}" "$secret" >> "$logs/.rows"
      continue
    fi
    printf '%s\t%s\t%s\n' "$kind" "$id" "$flow" >> "$runnable"
  done < "$list"

  # The run's second device, when it has one and there is more than one flow.
  # No device is driven while one of the run's emulators is still booting:
  # a second one gets a little longer, then is stopped.
  [ -n "$suite_serial" ] || second="$(find_lease "$project" "$(second_slug "$slug")")"
  if [ -n "$second" ] && ! boot_completed "$second"; then
    local waited=0
    while [ "$waited" -lt "${ADT_SECOND_BOOT_WAIT_S:-90}" ] && lease_live "$second" && ! boot_completed "$second"; do
      sleep 2
      waited=$((waited + 2))
    done
    if ! boot_completed "$second"; then
      say "adt: the second emulator $second has not finished booting; stopping it, so flows run on one"
      cancel_second "$project" "$slug"
      second=""
    fi
  fi
  [ "$(wc -l < "$runnable" | tr -d ' ')" -ge 2 ] || second=""
  say "adt: running $(wc -l < "$runnable" | tr -d ' ') flow(s) on $serial${second:+ and $second} with $driver"
  [ -s "$runnable" ] && prepare_device "$serial"

  # Pass 1, then one retry for each flow that failed. A crash is never
  # retried: it is a real defect even if it does not happen every time.
  local attempt
  for attempt in 1 2; do
    : > "$logs/.attempt$attempt"
    [ -s "$runnable" ] || break
    if [ "$attempt" = 1 ]; then
      cp "$runnable" "$logs/.todo"
    else
      awk -F'\t' '$4 == "FAIL" && $5 !~ /^app (crashed|not responding)/ { print $2 "\t" $1 "\t" $3 }' \
        "$logs/.attempt1" > "$logs/.todo"
      [ -s "$logs/.todo" ] || break
      say "adt: retrying $(wc -l < "$logs/.todo" | tr -d ' ') failed flow(s) once"
    fi
    run_attempt "$logs/.todo" "$logs/.attempt$attempt" "$attempt"
  done

  # Merge the attempts: a flow that failed and then passed is FLAKY. A retry
  # that crashed the app names that crash, which outranks the first failure.
  local retry retry_result r_step r_secs r_log result step secs log
  while IFS="$(printf '\t')" read -r id kind flow result step secs log; do
    if [ "$result" = FAIL ] && [ -f "$logs/.attempt2" ]; then
      retry="$(awk -F'\t' -v i="$id" -v k="$kind" '$1 == i && $2 == k { print; exit }' "$logs/.attempt2")"
      if [ -n "$retry" ]; then
        retry_result="$(printf '%s\n' "$retry" | cut -f4)"
        r_step="$(printf '%s\n' "$retry" | cut -f5)"
        r_secs="$(printf '%s\n' "$retry" | cut -f6)"
        r_log="$(printf '%s\n' "$retry" | cut -f7)"
        if [ "$retry_result" = PASS ]; then
          result=FLAKY
        else
          case "$r_step" in "app crashed"*|"app not responding"*) step="$r_step"; log="$r_log" ;; esac
        fi
        secs=$(( secs + ${r_secs:-0} ))
      fi
    fi
    tier="$(flow_tier "$flow")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "${tier:--}" "$result" "$step" "$secs" "$log" >> "$logs/.rows"
  done < "$logs/.attempt1"
  touch "$logs/.rows"

  # The rows of record: this run's, or, for --only, the last run's with the
  # re-run flows' rows replaced.
  if [ -n "$only" ]; then
    awk -F'\t' 'NR == FNR { new[$1 FS $2] = $0; order[++n] = $1 FS $2; next }
      { k = $1 FS $2; if (k in new) { print new[k]; done[k] = 1 } else print }
      END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print new[order[i]] }' \
      "$logs/.rows" "$logs/rows.tsv" > "$logs/rows.tsv.new" && mv "$logs/rows.tsv.new" "$logs/rows.tsv"
  else
    cp "$logs/.rows" "$logs/rows.tsv"
  fi

  scrub_dir "$logs"

  # Write run-results.md.
  local devices="Device: $serial"
  [ "$second_used" = yes ] && devices="Devices: $serial and $(find_lease "$project" "$(second_slug "$slug")")"
  {
    printf '# Flow run: %s\n\n' "$slug"
    printf 'Driver: %s · %s · Finished: %s\n\n' "$driver" "$devices" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'A FAIL failed twice. FLAKY failed once, then passed on its retry. SKIPPED was written for the other driver and did not run.\n'
    printf 'After each flow, Android'"'"'s crash log is read: a crash or ANR of the app fails the flow, with no retry.\n\n'
    printf '| Flow | Kind | Tier | Result | Failing step | Seconds | Log |\n'
    printf '|---|---|---|---|---|---|---|\n'
    while IFS="$(printf '\t')" read -r id kind tier result step secs log; do
      [ "$tier" = "-" ] && tier="—"
      [ "$step" = "-" ] && step=""
      [ "$log" = "-" ] && log=""
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$kind" "$tier" "$result" "$step" "$secs" "$log"
    done < "$logs/rows.tsv"
  } > "$results"

  total="$(wc -l < "$logs/rows.tsv" | tr -d ' ')"
  passed="$(awk -F'\t' '$4 == "PASS"' "$logs/rows.tsv" | wc -l | tr -d ' ')"
  failed="$(awk -F'\t' '$4 == "FAIL"' "$logs/rows.tsv" | wc -l | tr -d ' ')"
  flaky="$(awk -F'\t' '$4 == "FLAKY"' "$logs/rows.tsv" | wc -l | tr -d ' ')"
  skipped="$(awk -F'\t' '$4 == "SKIPPED"' "$logs/rows.tsv" | wc -l | tr -d ' ')"
  seconds="$(awk -F'\t' '{ s += $6 } END { print s + 0 }' "$logs/rows.tsv")"
  printf '\nTotals: %s flow(s) — %s passed, %s failed, %s flaky, %s skipped — %s seconds.\n' \
    "$total" "$passed" "$failed" "$flaky" "$skipped" "$seconds" >> "$results"
  printf 'Run time: %s seconds, start to finish%s.\n' "$(( $(now) - started_at ))" \
    "$([ "$second_used" = yes ] && echo ', on two emulators')" >> "$results"
  local p0_count p0_seconds
  p0_count="$(awk -F'\t' '$3 == "p0"' "$logs/rows.tsv" | wc -l | tr -d ' ')"
  p0_seconds="$(awk -F'\t' '$3 == "p0" { s += $6 } END { print s + 0 }' "$logs/rows.tsv")"
  if [ "$p0_count" -gt 0 ]; then
    printf 'P0 flows: %s seconds.\n' "$p0_seconds" >> "$results"
    if [ "$p0_seconds" -gt "${ADT_P0_BUDGET_S:-180}" ]; then
      printf 'Warning: the P0 flows took more than %s seconds. Every run replays all of them, so consider moving some to P1.\n' \
        "${ADT_P0_BUDGET_S:-180}" >> "$results"
    fi
  fi
  rm -f "$logs"/.flows "$logs"/.runnable "$logs"/.todo "$logs"/.todo-a "$logs"/.todo-b "$logs"/.queue \
    "$logs"/.attempt1 "$logs"/.attempt2 "$logs"/.rows "$logs"/.second-took "$logs"/.second-why
  rm -rf "$logs/.claim-b"

  say "adt: $total flow(s): $passed passed, $failed failed, $flaky flaky, $skipped skipped. Results: $results"
  [ "$failed" -eq 0 ]
}

# ---------- the suite on its own (CI) ----------
# suite replays e2e/flows/ on a device it is given, with no lease and no
# pipeline run: in CI, or on a developer's machine before a release. It
# writes run-results.md, its logs and junit.xml into --out, and exits 1 when
# a flow failed.

# One JUnit <testcase> per row of <rows.tsv>, for CI systems to show.
write_junit() {
  local rows="$1" out="$2"
  awk -F'\t' '
    function esc(v) { gsub(/&/, "\\&amp;", v); gsub(/</, "\\&lt;", v); gsub(/>/, "\\&gt;", v); gsub(/"/, "\\&quot;", v); return v }
    { n++; id[n] = $1; kind[n] = $2; res[n] = $4; step[n] = ($5 == "-" ? "" : $5); secs[n] = $6
      if ($4 == "FAIL") f++; if ($4 == "SKIPPED") sk++; t += $6 }
    END {
      printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      printf "<testsuites>\n  <testsuite name=\"e2e-flows\" tests=\"%d\" failures=\"%d\" skipped=\"%d\" time=\"%d\">\n", n, f, sk, t
      for (i = 1; i <= n; i++) {
        printf "    <testcase classname=\"%s\" name=\"%s\" time=\"%d\"", esc(kind[i]), esc(id[i]), secs[i]
        if (res[i] == "FAIL") printf ">\n      <failure message=\"%s\"/>\n    </testcase>\n", esc(step[i])
        else if (res[i] == "SKIPPED") printf ">\n      <skipped message=\"%s\"/>\n    </testcase>\n", esc(step[i])
        else if (res[i] == "FLAKY") printf ">\n      <system-out>FLAKY: failed once, then passed on its retry</system-out>\n    </testcase>\n"
        else printf "/>\n"
      }
      printf "  </testsuite>\n</testsuites>\n"
    }' "$rows" > "$out"
}

cmd_suite() {
  local driver="" serial="${ANDROID_SERIAL:-}" out="" project rc online
  local -a pass
  pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) driver="${2:-}"; shift 2 ;;
      --serial) serial="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --area|--exclude) pass+=("$1" "${2:-}"); shift 2 ;;
      [pP][0-2]) pass+=("$1"); shift ;;
      --all) pass+=(--all); shift ;;
      *) usage ;;
    esac
  done
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  find_adb
  project="$(project_dir)"
  [ -d "$project/e2e/flows" ] || die 2 "no regression suite in $project/e2e/flows."
  if [ -z "$serial" ]; then
    online="$(adb_devices | awk '$2 == "device" { print $1 }')"
    case "$(printf '%s\n' "$online" | awk 'NF' | wc -l | tr -d ' ')" in
      0) die 10 "no device is online. Start an emulator, or pass --serial." ;;
      1) serial="$online" ;;
      *) die 10 "more than one device is online ($(printf '%s ' $online)). Pass --serial." ;;
    esac
  fi
  [ "$(adb_devices | awk -v s="$serial" '$1 == s { print $2 }')" = device ] || \
    die 10 "device $serial is not online."
  [ -n "$out" ] || out="$project/pipeline_artifacts/suite"
  mkdir -p "$out"
  out="$(cd "$out" && pwd -P)"
  case "$out" in "$project"/pipeline_artifacts|"$project"/pipeline_artifacts/*)
    [ -f "$project/pipeline_artifacts/.gitignore" ] || printf '*\n' > "$project/pipeline_artifacts/.gitignore" ;;
  esac
  cmd_run --slug suite --driver "$driver" --suite-serial "$serial" --suite-out "$out" ${pass[@]+"${pass[@]}"}
  rc=$?
  [ -f "$out/run-logs/rows.tsv" ] && write_junit "$out/run-logs/rows.tsv" "$out/junit.xml"
  return "$rc"
}

cmd_select() {
  local driver="" areas="" excludes="" project
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) driver="${2:-}"; shift 2 ;;
      --area) areas="$areas
$(area_spec "${2:-}")"; shift 2 ;;
      [pP][0-2]) [ -n "$areas" ] || usage; areas="$areas,$(printf '%s' "$1" | tr 'P' 'p')"; shift ;;
      --exclude) excludes="$excludes
${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  project="$(project_dir)"
  select_suite "$project" "$driver" "$areas" "$excludes" "" | cut -f3
}

# ---------- checks ----------
# A check is one of the plan's Section 0 commands that the test phase runs
# beside the flows: today, the device tests (instrumented tests, on the run's
# device, with --device). Its output goes to
# pipeline_artifacts/<slug>/checks/<name>.log, and its row to checks.md,
# which the Tester reads. A failed check is the Tester's to report, so it
# exits 1, like a failed flow.

cmd_check() {
  local slug="" name="" on_device=0 project serial dir log table rc start secs status row tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      --device) on_device=1; shift ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$name" ] && [ $# -gt 0 ] || usage
  case "$name" in *[!a-z0-9-]*) die 2 "a check name is lowercase letters, digits and '-': $name" ;; esac
  project="$(project_dir)"
  dir="$project/pipeline_artifacts/$slug"
  mkdir -p "$dir/checks"
  log="$dir/checks/$name.log"
  table="$dir/checks.md"
  if [ "$on_device" = 1 ]; then
    find_adb
    serial="$(find_lease "$project" "$slug")"
    [ -n "$serial" ] && lease_live "$serial" || \
      die 15 "no live device is leased for slug '$slug' in $project. Run device-acquire first."
  fi
  start="$(now)"
  if [ "$on_device" = 1 ]; then
    say "adt: running check $name on $serial: $*"
    ANDROID_SERIAL="$serial" "$@" > "$log" 2>&1 < /dev/null
    rc=$?
  else
    say "adt: running check $name: $*"
    "$@" > "$log" 2>&1 < /dev/null
    rc=$?
  fi
  secs=$(( $(now) - start ))
  if [ "$rc" -eq 0 ]; then status=PASS; else status=FAIL; fi
  row="$(printf '| %s | %s | %s | %s | checks/%s.log | %s |' "$name" "$status" "$rc" "$secs" "$name" "$(printf '%s ' "$@" | cell)")"
  tmp="$table.tmp.$$"
  {
    printf '# Checks: %s\n\n' "$slug"
    printf 'Section 0 commands run beside the flows. A FAIL is a blocking finding for the Tester to report.\n\n'
    printf '| Check | Result | Exit | Seconds | Log | Command |\n'
    printf '|---|---|---|---|---|---|\n'
    [ -f "$table" ] && grep '^| ' "$table" | grep -v '^| Check |' | awk -v n="$name" -F'|' '{ c = $2; gsub(/^ +| +$/, "", c) } c != n'
    printf '%s\n' "$row"
  } > "$tmp" && mv -f "$tmp" "$table"
  say "adt: check $name: $status (exit $rc). Log: $log"
  printf 'CHECK name=%s status=%s exit=%s log=%s\n' "$name" "$status" "$rc" "$log"
  [ "$rc" -eq 0 ]
}

# ---------- the run ledger ----------
# pipeline_artifacts/.ledger/<slug> holds what a build command must not
# forget: its command, phase, paths and budgets, one "key=value" per line.
# The orchestrator writes it at each phase and before each re-run, so a run
# whose session died, or whose context was compacted, continues from the file
# rather than from memory, and a spent budget is refused here. It lives
# outside pipeline_artifacts/<slug>/, which a review round's tree guard
# hashes.

ledger_file() { printf '%s/pipeline_artifacts/.ledger/%s\n' "$1" "$2"; }

ledger_get() { # <file> <key>
  [ -f "$1" ] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); found = 1 }
    END { if (found) print v; exit !found }' "$1"
}

ledger_put() { # <file> <key> <value>
  local tmp="$1.tmp.$$"
  {
    [ -f "$1" ] && awk -v k="$2" 'index($0, k "=") != 1' "$1"
    printf '%s=%s\n' "$2" "$3"
  } > "$tmp" && mv -f "$tmp" "$1"
}

cmd_state() {
  local slug="" project file action key value max cur next nl
  nl='
'
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done
  [ -n "$slug" ] && [ $# -gt 0 ] || usage
  case "$slug" in .*|*[!A-Za-z0-9._~-]*) die 2 "a slug is letters, digits, '.', '_', '~' and '-' only: $slug" ;; esac
  action="$1"; shift
  project="$(project_dir)"
  file="$(ledger_file "$project" "$slug")"
  case "$action" in
    set|bump|get)
      key="${1:-}"
      case "$key" in ''|[!a-z]*|*[!a-z0-9_]*) die 2 "a ledger key is lowercase letters, digits and '_': '$key'" ;; esac
      ;;
  esac
  case "$action" in
    start)
      # A new run of this slug: a fresh ledger, so no count of an earlier run
      # carries over. A resume never runs this.
      [ $# -eq 1 ] || usage
      case "$1" in ''|*[!a-z-]*) die 2 "start takes the command's name, such as build-auto: '$1'" ;; esac
      mkdir -p "$(dirname "$file")"
      [ -f "$project/pipeline_artifacts/.gitignore" ] || printf '*\n' > "$project/pipeline_artifacts/.gitignore"
      [ -f "$file" ] && mv -f "$file" "$file.previous"
      printf 'command=%s\nstarted=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$file"
      ;;
    set)
      [ $# -eq 2 ] || usage
      value="$2"
      case "$value" in *"$nl"*) die 2 "a ledger value is one line." ;; esac
      mkdir -p "$(dirname "$file")"
      [ -f "$project/pipeline_artifacts/.gitignore" ] || printf '*\n' > "$project/pipeline_artifacts/.gitignore"
      ledger_put "$file" "$key" "$value"
      ;;
    get)
      [ $# -eq 1 ] || usage
      ledger_get "$file" "$key" || { say "adt: the ledger for '$slug' has no $key"; return 1; }
      ;;
    bump)
      [ $# -eq 3 ] && [ "$2" = --max ] || usage
      max="$3"
      case "$max" in ''|*[!0-9]*) die 2 "--max takes a whole number: $max" ;; esac
      cur="$(ledger_get "$file" "$key" 2>/dev/null)"
      case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
      next=$((cur + 1))
      if [ "$next" -gt "$max" ]; then
        say "adt: budget spent: $key is already $cur, the most this run allows ($max). STOP the run and report it."
        printf '%s\n' "$cur"
        exit 17
      fi
      mkdir -p "$(dirname "$file")"
      [ -f "$project/pipeline_artifacts/.gitignore" ] || printf '*\n' > "$project/pipeline_artifacts/.gitignore"
      ledger_put "$file" "$key" "$next"
      printf '%s\n' "$next"
      ;;
    show)
      [ $# -eq 0 ] || usage
      [ -f "$file" ] || die 2 "no ledger for '$slug' in $project: there is no run to resume."
      cat "$file"
      ;;
    *) usage ;;
  esac
}

# The verdict of a test-results.md: the first non-empty line under its
# "## Verdict" heading, without markdown emphasis.
tester_verdict() {
  awk '
    /^##[[:space:]]+Verdict[[:space:]]*$/ { inv = 1; next }
    inv && /^#/ { exit }
    inv && NF { gsub(/[*_`]/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$1" 2>/dev/null
}

# Succeeds when <test-results.md> gives READY TO MERGE and is not older than
# <run-results.md>; otherwise says why, and fails. promote checks this itself,
# so a suite never keeps the flows of a run that was not ready.
check_ready_to_merge() {
  local tests="$1" flows="$2" verdict
  if [ ! -f "$tests" ]; then
    say "adt: no $tests: the Tester has not given a verdict, so nothing is promoted."
    return 1
  fi
  verdict="$(tester_verdict "$tests")"
  case "$verdict" in
    *"NEEDS FIXES"*|*BLOCKED*|"")
      say "adt: the Tester's verdict is '${verdict:-missing}', not READY TO MERGE, so nothing is promoted."
      return 1 ;;
    "READY TO MERGE"*) ;;
    *)
      say "adt: the Tester's verdict is '$verdict', not READY TO MERGE, so nothing is promoted."
      return 1 ;;
  esac
  if [ -n "$flows" ] && [ "$flows" -nt "$tests" ]; then
    say "adt: the flows ran again after the Tester's verdict, so that verdict does not cover them. Nothing is promoted."
    return 1
  fi
}

# Keeps this run's passing flows in the suite. A flow is kept when its last
# result was PASS (not FLAKY) and its tier is p0, p1 or p2. A suite flow with
# the same id as one of this run's flows is replaced by it if it is kept, and
# removed otherwise; each --remove id is removed unless it was just replaced.
cmd_promote() {
  local slug="" removes="" project results flows_dir suite id kind tier result
  local src dest added=0 replaced=0 removed=0 kept=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --remove) removes="$removes
${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  project="$(project_dir)"
  results="$project/pipeline_artifacts/$slug/run-results.md"
  flows_dir="$project/pipeline_artifacts/$slug/flows"
  suite="$project/e2e/flows"
  [ -f "$results" ] || die 2 "no $results: run the flows before promoting them."
  check_ready_to_merge "$project/pipeline_artifacts/$slug/test-results.md" "$results" || exit 2

  while IFS="$(printf '\t')" read -r id kind tier result; do
    [ "$kind" = feature ] || continue
    src="$flows_dir/$id.yaml"
    dest="$suite/$id.yaml"
    [ -f "$src" ] || continue
    case "$tier" in p0|p1|p2) ;; *) tier="" ;; esac
    if [ "$result" = PASS ] && [ -n "$tier" ]; then
      mkdir -p "$(dirname "$dest")"
      if [ -f "$dest" ]; then
        replaced=$((replaced + 1)); printf 'replaced: %s\n' "$id"
      else
        added=$((added + 1)); printf 'added: %s\n' "$id"
      fi
      cp "$src" "$dest"
      kept="$kept
$id"
    elif [ -f "$dest" ]; then
      removes="$removes
$id"
    fi
  done <<EOF
$(awk -F'|' 'NR > 2 && /^\| / {
    for (i = 2; i <= 5; i++) { gsub(/^ +| +$/, "", $i) }
    print $2 "\t" $3 "\t" $4 "\t" $5
  }' "$results")
EOF

  for id in $(printf '%s\n' "$removes" | awk 'NF' | LC_ALL=C sort -u); do
    printf '%s\n' "$kept" | grep -Fxq "$id" && continue
    dest="$suite/$id.yaml"
    if [ -f "$dest" ]; then
      rm -f "$dest"
      prune_empty_dirs_under "$(dirname "$dest")" "$suite"
      removed=$((removed + 1)); printf 'removed: %s\n' "$id"
    fi
  done
  say "adt: suite: $added added, $replaced replaced, $removed removed"
}

# Removes now-empty directories from <dir> up to, but not including, <stop>.
prune_empty_dirs_under() {
  local d="$1" stop="$2"
  while [ "$d" != "$stop" ] && [ "$d" != "/" ]; do
    rmdir "$d" 2>/dev/null || break
    d="$(dirname "$d")"
  done
}

# ---------- preflight ----------

PF_FAILS=0
PF_WARNS=0
pf_ok()   { printf 'ok    %s\n' "$*"; }
pf_warn() { printf 'warn  %s\n' "$*"; PF_WARNS=$((PF_WARNS + 1)); }
pf_fail() { printf 'FAIL  %s\n' "$*"; PF_FAILS=$((PF_FAILS + 1)); }

# Online devices with no lease, one serial per line.
free_attached() {
  local serial state
  adb_devices | while read -r serial state; do
    [ "$state" = device ] && [ ! -d "$(lease_path "$serial")" ] && printf '%s\n' "$serial"
  done
}

# Whether this machine has the memory for a run's second emulator of <avd>.
preflight_parallel() {
  local why
  if ! [ "$PARALLEL" -ge 2 ] 2>/dev/null; then
    pf_ok "flows run on one emulator (ADT_PARALLEL=$PARALLEL)"
  elif why="$(can_afford_emulator "$1")"; then
    pf_ok "flows can run on two emulators: there is memory for a second one"
  else
    pf_ok "flows will run on one emulator: $why"
  fi
}

preflight_devices() {
  local attached avds busy avd usable=""
  attached="$(free_attached | head -n 1)"
  if [ "${ADT_DEVICE_MODE:-}" = reuse ]; then
    if [ -n "$attached" ]; then
      pf_ok "device: $attached (ADT_DEVICE_MODE=reuse)"
    else
      pf_fail "ADT_DEVICE_MODE=reuse, but no attached device is online and free. Connect one, or unset ADT_DEVICE_MODE."
    fi
    return
  fi
  if ! find_emulator; then
    pf_fail "the Android emulator is not installed. Install it from Android Studio's SDK Manager, or set ADT_DEVICE_MODE=reuse to test on an attached device${attached:+ such as $attached} (flows clear the app's data on it)."
    return
  fi
  pf_ok "emulator: $EMULATOR"
  avds="$(list_avds)"
  busy="$(avds_in_normal_mode)"
  if [ -n "${ADT_AVD:-}" ]; then
    if ! printf '%s\n' "$avds" | grep -Fxq "$ADT_AVD"; then
      pf_fail "ADT_AVD=$ADT_AVD is not an AVD on this machine. Known AVDs: $(printf '%s ' $avds)"
    elif printf '%s\n' "$busy" | grep -Fxq "$ADT_AVD"; then
      pf_fail "ADT_AVD=$ADT_AVD is open in normal mode, so a read-only copy cannot start. Close it, or set ADT_AVD to another AVD."
    else
      pf_ok "AVD: $ADT_AVD (from ADT_AVD)"
      preflight_parallel "$ADT_AVD"
    fi
    return
  fi
  for avd in $avds; do
    if ! printf '%s\n' "$busy" | grep -Fxq "$avd"; then
      usable="$avd"
      break
    fi
  done
  if [ -n "$usable" ]; then
    pf_ok "AVD: $usable (the first one not open in normal mode)"
    preflight_parallel "$usable"
    pf_warn "ADT_AVD is not set, so runs may boot different AVDs and pay auto-mobile's first-time setup again. See HOW_IT_WORKS, 'Setting up device testing'."
  elif [ -z "$avds" ]; then
    pf_fail "no AVD exists. Create one in Android Studio's Device Manager, or set ADT_DEVICE_MODE=reuse to test on an attached device${attached:+ such as $attached} (flows clear the app's data on it)."
  else
    pf_fail "every AVD is open in normal mode, so no read-only copy can start. Close one, create another AVD, or set ADT_DEVICE_MODE=reuse to test on an attached device${attached:+ such as $attached} (flows clear the app's data on it)."
  fi
}

preflight_automobile() {
  local status version pinned old
  set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  if ! command -v "$1" > /dev/null 2>&1; then
    if [ "$1" = bunx ]; then
      pf_fail "bunx not found: auto-mobile runs through Bun. Install it from https://bun.sh."
    else
      pf_fail "the auto-mobile command '$1' was not found."
    fi
    return
  fi
  pinned="$(printf '%s\n' "$*" | sed -n 's/.*@kaeawc\/auto-mobile@\([0-9][0-9.]*\).*/\1/p')"
  status="$(run_bounded 60 "$@" --daemon status 2>&1 < /dev/null)"
  version="$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*Version:[[:space:]]*//p' | head -n 1)"
  if printf '%s\n' "$status" | grep -q 'Daemon is running'; then
    if [ -n "$pinned" ] && [ -n "$version" ] && [ "$version" != "$pinned" ]; then
      pf_fail "auto-mobile's background service runs $version, but the pipeline uses $pinned. Register auto-mobile at $pinned (HOW_IT_WORKS, 'Setting up device testing'), then run: $* --daemon restart"
    else
      pf_ok "auto-mobile: background service running${version:+ version $version}"
    fi
  elif printf '%s\n' "$status" | grep -q 'Daemon is not running'; then
    old="$(ps -Ao pid=,args= 2>/dev/null | grep -E 'auto-mobile.*--daemon-mode' | grep -v grep | awk '{ print $1 }' | head -n 1)"
    if [ -n "$old" ]; then
      pf_fail "an auto-mobile background service this version cannot use is running (PID $old), probably an older version. Every flow would time out. Stop it with: kill $old"
      return
    fi
    # Start it now, with the pipeline's tool list, so a service that cannot
    # start is found here rather than at the first flow.
    status="$(run_bounded 120 "$@" --daemon start 2>&1 < /dev/null)"
    if printf '%s\n' "$status" | grep -q 'Daemon started successfully'; then
      pf_ok "auto-mobile: started its background service"
    else
      local why
      why="$(printf '%s\n' "$status" | grep -E 'Fatal error|Error:' | grep -v sourcemap | head -n 1 | cell)"
      if printf '%s\n' "$status" | grep -q 'Database'; then
        pf_fail "auto-mobile's background service cannot start: its database could not be upgraded ($why). Move it aside and let auto-mobile create a fresh one: mv ~/.auto-mobile/auto-mobile.db ~/.auto-mobile/auto-mobile.db.bak"
      else
        pf_fail "auto-mobile's background service cannot start: ${why:-see its log in ~/.auto-mobile/logs/}"
      fi
    fi
  else
    pf_warn "could not check auto-mobile's background service: $(printf '%s\n' "$status" | grep -v sourcemap | tail -n 1 | cell)"
  fi
}

version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

preflight_maestro() {
  local version
  set -- ${ADT_MAESTRO:-maestro}
  if ! command -v "$1" > /dev/null 2>&1; then
    pf_fail "the Maestro CLI ('$1') was not found. Install it: https://docs.maestro.dev"
    return
  fi
  if ! command -v java > /dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
    pf_fail "Java was not found, and Maestro needs Java 17 or later."
  fi
  version="$(run_bounded 60 "$@" --version 2>/dev/null < /dev/null | grep -Eo '[0-9]+[.][0-9]+[.][0-9]+' | tail -n 1)"
  if [ -z "$version" ]; then
    pf_warn "could not read Maestro's version; the pipeline needs 2.11.0 or later."
  elif version_at_least "$version" 2.11.0; then
    pf_ok "maestro: $version"
  else
    pf_fail "Maestro $version is too old; the pipeline needs 2.11.0 or later. Upgrade with: maestro update"
  fi
}

# This script's own path, with symlinks resolved, for commands a person runs.
script_path() {
  printf '%s/%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" "$(basename "${BASH_SOURCE[0]}")"
}

# Claude Code only: are the pipeline's own commands pre-approved anywhere it
# reads permission rules from? It reads the project's rules from the directory
# it runs in, which is where the build commands run this. If not, say how to
# approve them once.
preflight_permissions() {
  local here file
  here="$(pwd -P)"
  for file in "$here/.claude/settings.local.json" "$here/.claude/settings.json" \
              "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    [ -f "$file" ] && grep -q 'mcp__auto-mobile__\*\|mcp__auto-mobile"' "$file" && \
      grep -q 'adt[.]sh' "$file" && return 0
  done
  pf_warn "in Claude Code, the pipeline's own commands are not pre-approved, so a run may stop to ask. Approve them once with: bash $(script_path) allow --project $here"
}

# Devices leased hours ago and still running were most likely left by a
# session that died. Say how to stop each one; another run may still be using
# a younger one, so those are left alone.
preflight_leftovers() {
  local serial age
  for serial in $(lease_serials); do
    lease_live "$serial" || continue
    age=$(( $(now) - $(lease_created "$serial") ))
    [ "$age" -gt 10800 ] || continue
    pf_warn "$serial has been running for $(( age / 3600 ))h for '$(lease_get "$serial" slug)' in $(lease_get "$serial" project). If no run is using it, stop it with: bash $(script_path) device-release --serial $serial"
  done
}

cmd_preflight() {
  local driver=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) driver="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  if (find_adb) > /dev/null 2>&1; then
    find_adb
    pf_ok "adb: $ADB"
    preflight_devices
    preflight_leftovers
  else
    pf_fail "adb not found. Install the Android SDK platform tools, or set ANDROID_HOME."
  fi
  if [ "$driver" = auto-mobile ]; then
    preflight_automobile
  else
    preflight_maestro
  fi
  preflight_permissions
  printf '\npreflight: %s problem(s), %s warning(s)\n' "$PF_FAILS" "$PF_WARNS"
  [ "$PF_FAILS" -eq 0 ] || exit 16
}

# ---------- allow ----------
# Adds the pipeline's own permission rules to the project's
# .claude/settings.local.json — the script, and the test drivers' MCP tools —
# so Claude Code does not stop to ask mid-run. Only a person runs this
# (install.sh does it for you); an agent never grants itself permissions.

ALLOW_RULES_FIXED='Bash(bash .claude/adt/scripts/adt.sh *)
mcp__auto-mobile__*
mcp__maestro__*'

cmd_allow() {
  local mode=add project="" settings state self rules py
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove) mode=remove; shift ;;
      --project) project="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  # Claude Code reads the project's rules from the directory it runs in.
  [ -n "$project" ] || project="."
  project="$(cd "$project" 2>/dev/null && pwd -P)" || die 2 "no such project directory."
  settings="$project/.claude/settings.local.json"
  state="$ADT_HOME/allowed/$(printf '%s' "$project" | cksum | awk '{ print $1 }')"
  rules="$ALLOW_RULES_FIXED"
  # A plugin install runs the script by its absolute path, so allow that too.
  self="$(script_path)"
  case "$self" in
    "$project"/*) ;;
    *) case "$self" in */.claude/plugins/*) rules="$rules
Bash(bash $self *)" ;; esac ;;
  esac

  if command -v python3 > /dev/null 2>&1 && python3 -c 'import json' > /dev/null 2>&1; then
    py=python3
  else
    say "adt: python3 is not available, so the rules were not written. Add these to"
    say "     the permissions.allow list in $settings yourself:"
    printf '%s\n' "$rules" | sed 's/^/       /' >&2
    return 0
  fi
  mkdir -p "$(dirname "$state")"
  ADT_ALLOW_RULES="$rules" "$py" - "$settings" "$state" "$mode" <<'PY'
import json, os, sys
settings, state, mode = sys.argv[1], sys.argv[2], sys.argv[3]
rules = [r for r in os.environ["ADT_ALLOW_RULES"].splitlines() if r.strip()]
data = {}
if os.path.exists(settings):
    with open(settings) as f:
        text = f.read()
    if text.strip():
        try:
            data = json.loads(text)
        except ValueError:
            sys.stderr.write("adt: %s is not valid JSON; leaving it alone.\n" % settings)
            sys.exit(0)
if not isinstance(data, dict):
    sys.stderr.write("adt: %s is not a JSON object; leaving it alone.\n" % settings)
    sys.exit(0)
changed = False
added = []
if os.path.exists(state):
    with open(state) as f:
        added = [l for l in f.read().splitlines() if l.strip()]
perms = data.get("permissions")
if perms is None:
    perms = {}
allow = perms.get("allow") or []
if mode == "add":
    for rule in rules:
        if rule not in allow:
            allow.append(rule)
            added.append(rule)
            changed = True
            sys.stderr.write("adt: allowed %s\n" % rule)
    if added:
        with open(state, "w") as f:
            f.write("\n".join(sorted(set(added))) + "\n")
else:
    for rule in added:
        if rule in allow:
            allow.remove(rule)
            changed = True
            sys.stderr.write("adt: removed %s\n" % rule)
    if os.path.exists(state):
        os.remove(state)
if not changed:
    sys.exit(0)
if allow:
    perms["allow"] = allow
else:
    perms.pop("allow", None)
if perms:
    data["permissions"] = perms
else:
    data.pop("permissions", None)
if not data and mode == "remove":
    if os.path.exists(settings):
        os.remove(settings)
    sys.exit(0)
os.makedirs(os.path.dirname(settings), exist_ok=True)
tmp = settings + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, settings)
PY
  # Keep a file this script created out of git, without touching .gitignore.
  if [ "$mode" = add ] && [ -f "$settings" ] && git -C "$project" rev-parse --git-dir > /dev/null 2>&1 && \
     ! git -C "$project" check-ignore -q "$settings" 2>/dev/null && \
     ! git -C "$project" ls-files --error-unmatch "$settings" > /dev/null 2>&1; then
    (
      cd "$project" || exit 0
      exclude="$(git rev-parse --git-path info/exclude)"
      # The pattern is relative to the repository's top level, so an app in a
      # subfolder of its repository names that subfolder.
      prefix="$(git rev-parse --show-prefix)"
      mkdir -p "$(dirname "$exclude")"
      printf '/%s.claude/settings.local.json\n' "$prefix" >> "$exclude"
    )
  fi
}

# Stops the device leased for <project> and <slug> (or <serial>, when given),
# and drops its lease. An acquire still booting that device holds the run's
# lock, so this waits for it: the device it boots is the one released, not one
# left running. Returns 13 if the device would not stop.
release_one() {
  local project="$1" slug="$2" serial="${3:-}" quiet="${4:-}"
  if [ -n "$project" ] && [ -n "$slug" ]; then
    if ! take_lock "$project" "$slug"; then
      say "adt: a device-acquire for '$slug' is still running after $(( BOOT_TIMEOUT * 2 + 120 ))s; nothing was released. Run device-release again once it ends."
      return 13
    fi
  fi
  if [ -z "$serial" ]; then
    serial="$(find_lease "$project" "$slug")"
    if [ -z "$serial" ]; then
      [ -n "$quiet" ] || say "adt: no device is leased for slug '$slug'; nothing to release"
      release_lock
      return 0
    fi
  elif [ ! -d "$(lease_path "$serial")" ]; then
    say "adt: no lease for $serial; nothing to release"
    release_lock
    return 0
  fi
  if [ "$(lease_get "$serial" started)" = "yes" ] && device_present "$serial"; then
    if ! stop_emulator "$serial"; then
      say "adt: $serial would not stop; its lease is kept. Stop it by hand, then run: adt.sh device-release --serial $serial"
      release_lock
      return 13
    fi
    say "adt: stopped $serial"
  fi
  rm -rf "$(lease_path "$serial")"
  say "adt: released $serial"
  release_lock
  return 0
}

cmd_device_release() {
  local slug="" serial="" project rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --serial) serial="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || [ -n "$serial" ] || usage
  find_adb
  if [ -n "$slug" ]; then
    project="$(project_dir)"
    release_one "$project" "$slug" || rc=$?
    # The run's second emulator, if it has one, goes with it.
    case "$slug" in
      *~2) ;;
      *) release_one "$project" "$(second_slug "$slug")" "" quiet || rc=$? ;;
    esac
  elif [ -d "$(lease_path "$serial")" ]; then
    release_one "$(lease_get "$serial" project)" "$(lease_get "$serial" slug)" "$serial" || rc=$?
  else
    say "adt: no lease for $serial; nothing to release"
  fi
  return "$rc"
}

cmd_device_list() {
  local serial live age
  find_adb
  for serial in $(lease_serials); do
    if lease_live "$serial"; then live=live; else live=gone; fi
    age=$(( $(now) - $(lease_created "$serial") ))
    printf '%s\t%s\t%s\t%ss\t%s\n' "$serial" "$(lease_get "$serial" project)" \
      "$(lease_get "$serial" slug)" "$age" "$live"
  done
}

# ---------- main ----------

[ $# -gt 0 ] || usage
command="$1"; shift
case "$command" in
  device-acquire) cmd_device_acquire "$@" ;;
  install)        cmd_install "$@" ;;
  preflight)      cmd_preflight "$@" ;;
  allow)          cmd_allow "$@" ;;
  run)            cmd_run "$@" ;;
  select)         cmd_select "$@" ;;
  suite)          cmd_suite "$@" ;;
  promote)        cmd_promote "$@" ;;
  check)          cmd_check "$@" ;;
  state)          cmd_state "$@" ;;
  device-release) cmd_device_release "$@" ;;
  device-list)    cmd_device_list ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
