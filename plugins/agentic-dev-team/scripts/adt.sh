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
#   adt.sh select         --driver auto-mobile|maestro
#                         [--area <area>:<tiers>]... [--exclude <id>]...
#   adt.sh promote        --slug <slug> [--remove <id>]...
#   adt.sh device-release --slug <slug> | --serial <serial>
#   adt.sh device-list
#   adt.sh allow          [--remove] [--project <dir>]
#
# preflight checks the machine before a run starts. The only thing it changes
# is to start auto-mobile's background service when it is not running, which
# the run needs anyway, so a service that cannot start is found at once.
# Every build command leases one device for its whole run: device-acquire boots
# a headless, read-only emulator (or reuses this run's existing lease) and
# prints its serial on the last line; install runs the project's install
# command on that device only; run executes the run's flow files, plus the
# regression suite flows it selects, with no model in the loop and writes
# run-results.md; promote keeps this run's passing flows in e2e/flows/;
# device-release stops the device when the run ends. With --background,
# device-acquire returns at once and boots the device while other work runs;
# a later device-acquire for the same slug waits for it. run reads Android's
# crash log after each flow, so a crash or ANR of the app fails the flow.
# allow adds the pipeline's permission rules to the project's
# .claude/settings.local.json (or, with --remove, takes them out again).
#
# The regression suite is e2e/flows/<area>/<name>.yaml in the project. A run
# replays every P0 flow, plus the tiers each --area names (for example
# --area checkout:p1,p2), minus any --exclude, minus suite flows this run
# re-specifies (same id as one of its own flows).
#
# A lease belongs to a project directory (the git top level) and a slug
# together, so two worktrees or two apps never share a device.
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
#   ADT_AUTOMOBILE       auto-mobile command (default: bunx @kaeawc/auto-mobile@0.0.84)
#   ADT_MAESTRO          Maestro command (default: maestro)
#
# Exit codes:
#   0 success, 1 a flow failed (run), 2 usage, 10 no device, 11 the emulator
#   did not start or boot, 12 install failed, 13 a device could not be
#   stopped, 14 the driver's command was not found, 15 no live device is
#   leased for this run, 16 preflight found a problem
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

project_dir() {
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
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

# Boots <avd> on a freshly claimed port above <after>. Prints the serial it
# tried, and returns 0 on success, 3 when the AVD is open in normal mode
# elsewhere, or 1 for any other failure (its lease is removed).
boot_avd() {
  local project="$1" slug="$2" avd="$3" after="$4" serial port lease log pid waited
  serial="$(claim_port "$project" "$slug" "$after")" || {
    say "adt: no free emulator port between $PORT_FIRST and $PORT_LAST"
    return 1
  }
  printf '%s\n' "$serial"
  port="$(console_port "$serial")"
  lease="$(lease_path "$serial")"
  log="$lease/emulator.log"
  lease_set "$serial" avd "$avd"

  set -- -avd "$avd" -read-only -no-audio -no-boot-anim -port "$port"
  [ "${ADT_HEADLESS:-1}" = "0" ] || set -- "$@" -no-window
  say "adt: booting $avd as $serial (read-only, log: $log)"
  pid="$(start_detached "$log" "$EMULATOR" "$@")"
  lease_set "$serial" pid "$pid"

  waited=0
  while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    if boot_completed "$serial"; then
      "$ADB" -s "$serial" shell settings put global window_animation_scale 0 > /dev/null 2>&1
      "$ADB" -s "$serial" shell settings put global transition_animation_scale 0 > /dev/null 2>&1
      "$ADB" -s "$serial" shell settings put global animator_duration_scale 0 > /dev/null 2>&1
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

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

# auto-mobile: one --cli executePlan call per flow. Sets FLOW_RESULT (PASS or
# FAIL), FLOW_STEP (the failing step and its error) and FLOW_SECONDS.
run_automobile_flow() {
  local flow="$1" log="$2" serial="$3" start rc since crash
  set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  since="$(device_time "$serial")"
  start="$(now)"
  run_bounded "$FLOW_TIMEOUT" "$@" --cli executePlan --platform android \
    --deviceId "$serial" --planContent "$(cat "$flow")" > "$log.out" 2> "$log"
  rc=$?
  FLOW_SECONDS=$(( $(now) - start ))
  FLOW_STEP=""
  # A result over 64 KB is written to a file, and stdout only points at it.
  # Keep the full result with this run's logs, where it will not expire.
  local artifact
  artifact="$(grep -q '"artifact"' "$log.out" 2>/dev/null && \
    sed -n 's/^[[:space:]]*"path":[[:space:]]*"\([^"]*\)".*/\1/p' "$log.out" | head -n 1)"
  if [ -n "$artifact" ] && [ -f "$artifact" ]; then
    cp "$artifact" "$log.out"
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
  local serial="$1" out="$2" count
  shift 2
  count=$#
  set -- ${ADT_MAESTRO:-maestro} --device "$serial" test --format junit \
    --output "$out/junit.xml" --test-output-dir "$out/artifacts" "$@"
  run_bounded $(( FLOW_TIMEOUT * count )) "$@" > "$out/maestro.log" 2>&1
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

# select_suite <project> <driver> <areas> <excludes> <feature ids>
# The last three are newline-separated lists; areas are "<area>:<tiers>".
# Prints "<tier> TAB <id> TAB <path>" per selected flow, P0 first; reports
# flows written for the other driver on stderr.
select_suite() {
  local project="$1" driver="$2" areas="$3" excludes="$4" feature_ids="$5"
  local suite="$project/e2e/flows" flow rel id area tier header spec tiers
  [ -d "$suite" ] || return 0
  find "$suite" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
    rel="${flow#$suite/}"
    id="${rel%.yaml}"
    case "$id" in */*) area="${id%%/*}" ;; *) area="" ;; esac
    tier="$(flow_header "$flow" priority | tr 'A-Z' 'a-z')"
    printf '%s\n' "$excludes" | grep -Fxq "$id" && continue
    printf '%s\n' "$feature_ids" | grep -Fxq "$id" && continue
    header="$(flow_header "$flow" driver)"
    if [ -n "$header" ] && [ "$header" != "$driver" ]; then
      say "adt: skipped suite flow $id: written for $header"
      continue
    fi
    if [ "$tier" != p0 ]; then
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
    flow="${flow#$dir/}"
    printf '%s\n' "${flow%.yaml}"
  done
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
    mkdir -p "$ADT_HOME"
    log="$ADT_HOME/acquire-$(lock_key "$project" "$slug").log"
    start_detached "$log" /bin/bash "${BASH_SOURCE[0]}" device-acquire --slug "$slug" > /dev/null
    say "adt: booting a device for '$slug' in the background (log: $log)"
    say "adt: 'device-acquire --slug $slug' waits for it and prints its serial"
    return 0
  fi

  take_lock "$project" "$slug" || \
    die 11 "another device-acquire for '$slug' did not finish within $(( BOOT_TIMEOUT * 2 + 120 ))s."
  remove_stale_leases
  serial="$(find_lease "$project" "$slug")"
  if [ -n "$serial" ] && lease_live "$serial"; then
    if wait_for_boot "$serial"; then
      say "adt: reusing this run's device $serial"
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

  if ! find_emulator; then
    acquire_attached "$project" "$slug" "the Android emulator is not installed" && return 0
    die 10 "the Android emulator is not installed and no device is attached."
  fi

  if [ -n "${ADT_AVD:-}" ]; then
    avd="$(choose_avd "")" || exit $?
  fi

  while :; do
    if ! avd="$(choose_avd "$skip")"; then
      if [ -z "$(list_avds)" ]; then
        acquire_attached "$project" "$slug" "no AVD exists" && return 0
        die 10 "no AVD exists and no device is attached. Create one in Android Studio's Device Manager."
      fi
      acquire_attached "$project" "$slug" "every AVD is open in normal mode" && return 0
      die 10 "every AVD is open in normal mode and no other device is attached. Close one, or set ADT_AVD."
    fi
    serial="$(boot_avd "$project" "$slug" "$avd" "$after")"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$serial"
      return 0
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

cmd_install() {
  local slug="" project serial
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
    die 10 "no live device is leased for slug '$slug' in $project. Run device-acquire first."
  say "adt: installing on $serial: $*"
  # The install command's own output goes to stderr, so the only thing on
  # stdout is the BUILD_INSTALLED timestamp.
  if ! ANDROID_SERIAL="$serial" "$@" >&2; then
    die 12 "the install command failed on $serial."
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

cmd_run() {
  local slug="" driver="" project serial flows_dir results logs flow id rel
  local total=0 passed=0 failed=0 flaky=0 skipped=0 seconds=0 areas="" excludes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --driver) driver="${2:-}"; shift 2 ;;
      --area) areas="$areas
${2:-}"; shift 2 ;;
      --exclude) excludes="$excludes
${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  find_adb
  project="$(project_dir)"
  serial="$(find_lease "$project" "$slug")"
  [ -n "$serial" ] && lease_live "$serial" || \
    die 15 "no live device is leased for slug '$slug' in $project. Run device-acquire first."

  if [ "$driver" = auto-mobile ]; then
    set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  else
    set -- ${ADT_MAESTRO:-maestro}
  fi
  command -v "$1" > /dev/null 2>&1 || die 14 "the $driver command '$1' was not found. See the README's 'Choosing a test driver'."

  flows_dir="$project/pipeline_artifacts/$slug/flows"
  results="$project/pipeline_artifacts/$slug/run-results.md"
  logs="$project/pipeline_artifacts/$slug/run-logs"
  rm -rf "$logs"
  mkdir -p "$logs"

  # The flows to run: every *.yaml under this run's flows directory, then the
  # regression suite flows this run selects.
  local list="$logs/.flows" suite_tier suite_id
  : > "$list"
  if [ -d "$flows_dir" ]; then
    find "$flows_dir" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
      printf 'feature\t%s\t%s\n' "$flows_dir" "$flow"
    done >> "$list"
  fi
  select_suite "$project" "$driver" "$areas" "$excludes" "$(feature_ids "$flows_dir")" | \
    while IFS="$(printf '\t')" read -r suite_tier suite_id flow; do
      printf 'regression\t%s\t%s\n' "$project/e2e/flows" "$flow"
    done >> "$list"

  # Driver mismatch: a flow written for the other driver is skipped, not run.
  local runnable="$logs/.runnable"
  : > "$runnable"
  local kind base header tier
  while IFS="$(printf '\t')" read -r kind base flow; do
    rel="${flow#$base/}"
    id="${rel%.yaml}"
    header="$(flow_header "$flow" driver)"
    if [ -n "$header" ] && [ "$header" != "$driver" ]; then
      tier="$(flow_header "$flow" priority)"
      printf '%s\t%s\t%s\tSKIPPED\twritten for %s\t0\t-\n' "$id" "$kind" "${tier:--}" "$header" >> "$logs/.rows"
      continue
    fi
    printf '%s\t%s\t%s\n' "$kind" "$id" "$flow" >> "$runnable"
  done < "$list"

  say "adt: running $(wc -l < "$runnable" | tr -d ' ') flow(s) on $serial with $driver"

  # Pass 1, then one retry for each flow that failed. A crash is never
  # retried: it is a real defect even if it does not happen every time.
  local attempt result step secs log m_out line file since crash app
  local files
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

    if [ "$driver" = auto-mobile ]; then
      while IFS="$(printf '\t')" read -r kind id flow; do
        log="$logs/$kind-$(printf '%s' "$id" | tr '/' '_').attempt$attempt.log"
        run_automobile_flow "$flow" "$log" "$serial" < /dev/null
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$flow" "$FLOW_RESULT" "${FLOW_STEP:--}" "$FLOW_SECONDS" \
          "${log#$project/pipeline_artifacts/$slug/}" >> "$logs/.attempt$attempt"
      done < "$logs/.todo"
    else
      m_out="$logs/maestro.attempt$attempt"
      mkdir -p "$m_out"
      files=()
      while IFS="$(printf '\t')" read -r kind id flow; do
        files+=("$flow")
      done < "$logs/.todo"
      since="$(device_time "$serial")"
      run_maestro_flows "$serial" "$m_out" "${files[@]}" > "$m_out/results.tsv"
      # Maestro runs every flow in one call, so a crash cannot be pinned on one
      # flow: it becomes its own failing row.
      for app in $(for flow in "${files[@]}"; do flow_app_id "$flow"; done | LC_ALL=C sort -u); do
        if crash="$(app_crash_since "$serial" "$app" "$since")"; then
          save_crash_log "$serial" "$m_out/maestro.log" "$since"
          printf '%s\t%s\t%s\tFAIL\t%s\t0\t%s\n' "crash-check-$attempt" "check" "-" "$crash ($app, during the Maestro run)" \
            "${m_out#$project/pipeline_artifacts/$slug/}/maestro.log" >> "$logs/.rows"
        fi
      done
      while IFS="$(printf '\t')" read -r kind id flow; do
        line="$(awk -F'\t' -v f="$flow" '$1 == f || (length($1) > 0 && substr(f, length(f) - length($1) + 1) == $1) { print; exit }' "$m_out/results.tsv")"
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
          "${m_out#$project/pipeline_artifacts/$slug/}/maestro.log" >> "$logs/.attempt$attempt"
      done < "$logs/.todo"
    fi
  done

  # Merge the attempts: a flow that failed and then passed is FLAKY.
  local retry_result r_step r_secs r_log
  while IFS="$(printf '\t')" read -r id kind flow result step secs log; do
    if [ "$result" = FAIL ] && [ -f "$logs/.attempt2" ]; then
      retry_result="$(awk -F'\t' -v i="$id" -v k="$kind" '$1 == i && $2 == k { print $4; exit }' "$logs/.attempt2")"
      if [ "$retry_result" = PASS ]; then
        result=FLAKY
      fi
      r_secs="$(awk -F'\t' -v i="$id" -v k="$kind" '$1 == i && $2 == k { print $6; exit }' "$logs/.attempt2")"
      secs=$(( secs + ${r_secs:-0} ))
    fi
    tier="$(flow_header "$flow" priority)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "${tier:--}" "$result" "$step" "$secs" "$log" >> "$logs/.rows"
  done < "$logs/.attempt1"

  # Write run-results.md.
  {
    printf '# Flow run: %s\n\n' "$slug"
    printf 'Driver: %s · Device: %s · Finished: %s\n\n' "$driver" "$serial" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'A FAIL failed twice. FLAKY failed once, then passed on its retry. SKIPPED was written for the other driver and did not run.\n'
    printf 'After each flow, Android'"'"'s crash log is read: a crash or ANR of the app fails the flow, with no retry.\n\n'
    printf '| Flow | Kind | Tier | Result | Failing step | Seconds | Log |\n'
    printf '|---|---|---|---|---|---|---|\n'
    if [ -f "$logs/.rows" ]; then
      while IFS="$(printf '\t')" read -r id kind tier result step secs log; do
        [ "$tier" = "-" ] && tier="—"
        [ "$step" = "-" ] && step=""
        [ "$log" = "-" ] && log=""
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$kind" "$tier" "$result" "$step" "$secs" "$log"
      done < "$logs/.rows"
    fi
  } > "$results"

  if [ -f "$logs/.rows" ]; then
    total="$(wc -l < "$logs/.rows" | tr -d ' ')"
    passed="$(awk -F'\t' '$4 == "PASS"' "$logs/.rows" | wc -l | tr -d ' ')"
    failed="$(awk -F'\t' '$4 == "FAIL"' "$logs/.rows" | wc -l | tr -d ' ')"
    flaky="$(awk -F'\t' '$4 == "FLAKY"' "$logs/.rows" | wc -l | tr -d ' ')"
    skipped="$(awk -F'\t' '$4 == "SKIPPED"' "$logs/.rows" | wc -l | tr -d ' ')"
    seconds="$(awk -F'\t' '{ s += $6 } END { print s + 0 }' "$logs/.rows")"
  fi
  printf '\nTotals: %s flow(s) — %s passed, %s failed, %s flaky, %s skipped — %s seconds.\n' \
    "$total" "$passed" "$failed" "$flaky" "$skipped" "$seconds" >> "$results"
  local p0_count=0 p0_seconds=0
  if [ -f "$logs/.rows" ]; then
    p0_count="$(awk -F'\t' '$3 == "p0"' "$logs/.rows" | wc -l | tr -d ' ')"
    p0_seconds="$(awk -F'\t' '$3 == "p0" { s += $6 } END { print s + 0 }' "$logs/.rows")"
  fi
  if [ "$p0_count" -gt 0 ]; then
    printf 'P0 flows: %s seconds.\n' "$p0_seconds" >> "$results"
    if [ "$p0_seconds" -gt "${ADT_P0_BUDGET_S:-180}" ]; then
      printf 'Warning: the P0 flows took more than %s seconds. Every run replays all of them, so consider moving some to P1.\n' \
        "${ADT_P0_BUDGET_S:-180}" >> "$results"
    fi
  fi
  rm -f "$logs"/.flows "$logs"/.runnable "$logs"/.todo "$logs"/.attempt1 "$logs"/.attempt2 "$logs"/.rows

  say "adt: $total flow(s): $passed passed, $failed failed, $flaky flaky, $skipped skipped. Results: $results"
  [ "$failed" -eq 0 ]
}

cmd_select() {
  local driver="" areas="" excludes="" project
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) driver="${2:-}"; shift 2 ;;
      --area) areas="$areas
${2:-}"; shift 2 ;;
      --exclude) excludes="$excludes
${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$driver" in auto-mobile|maestro) ;; *) usage ;; esac
  project="$(project_dir)"
  select_suite "$project" "$driver" "$areas" "$excludes" "" | cut -f3
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
    if [ -n "$attached" ]; then
      pf_warn "the Android emulator is not installed, so the run will test on the attached device $attached."
    else
      pf_fail "the Android emulator is not installed and no device is attached. Install the emulator from Android Studio's SDK Manager."
    fi
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
    pf_warn "ADT_AVD is not set, so runs may boot different AVDs and pay auto-mobile's first-time setup again. See the README's 'One-time setup'."
  elif [ -n "$attached" ]; then
    pf_warn "every AVD is open in normal mode, so the run will test on $attached instead of an emulator of its own. Close one, or create another AVD."
  elif [ -z "$avds" ]; then
    pf_fail "no AVD exists and no device is attached. Create one in Android Studio's Device Manager."
  else
    pf_fail "every AVD is open in normal mode and no other device is attached. Close one, or create another AVD."
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
      pf_fail "auto-mobile's background service runs $version, but the pipeline uses $pinned. Register auto-mobile at $pinned (README, 'Choosing a test driver'), then run: $* --daemon restart"
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

# Claude Code only: are the pipeline's own commands pre-approved anywhere it
# reads permission rules from? If not, say how to do it once.
preflight_permissions() {
  local project file self
  project="$(project_dir)"
  for file in "$project/.claude/settings.local.json" "$project/.claude/settings.json" \
              "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    [ -f "$file" ] && grep -q 'mcp__auto-mobile__\*\|mcp__auto-mobile"' "$file" && \
      grep -q 'adt[.]sh' "$file" && return 0
  done
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  pf_warn "in Claude Code, the pipeline's own commands are not pre-approved, so a run may stop to ask. Approve them once with: bash $self allow"
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
  [ -n "$project" ] || project="$(project_dir)"
  project="$(cd "$project" 2>/dev/null && pwd -P)" || die 2 "no such project directory."
  settings="$project/.claude/settings.local.json"
  state="$ADT_HOME/allowed/$(printf '%s' "$project" | cksum | awk '{ print $1 }')"
  rules="$ALLOW_RULES_FIXED"
  # A plugin install runs the script by its absolute path, so allow that too.
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
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
      mkdir -p "$(dirname "$exclude")"
      printf '/.claude/settings.local.json\n' >> "$exclude"
    )
  fi
}

cmd_device_release() {
  local slug="" serial="" project
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
    serial="$(find_lease "$project" "$slug")"
    if [ -z "$serial" ]; then
      say "adt: no device is leased for slug '$slug'; nothing to release"
      return 0
    fi
  elif [ ! -d "$(lease_path "$serial")" ]; then
    say "adt: no lease for $serial; nothing to release"
    return 0
  fi

  if [ "$(lease_get "$serial" started)" = "yes" ] && device_present "$serial"; then
    if ! stop_emulator "$serial"; then
      die 13 "$serial would not stop; its lease is kept. Stop it by hand, then run: adt.sh device-release --serial $serial"
    fi
    say "adt: stopped $serial"
  fi
  rm -rf "$(lease_path "$serial")"
  say "adt: released $serial"
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
  promote)        cmd_promote "$@" ;;
  device-release) cmd_device_release "$@" ;;
  device-list)    cmd_device_list ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
