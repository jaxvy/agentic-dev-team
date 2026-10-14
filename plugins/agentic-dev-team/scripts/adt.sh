#!/usr/bin/env bash
#
# adt.sh — devices and flow runs for the agentic-dev-team pipeline.
#
# Usage:
#   adt.sh device-acquire --slug <slug>
#   adt.sh install        --slug <slug> -- <install command...>   (prints BUILD_INSTALLED)
#   adt.sh run            --slug <slug> --driver auto-mobile|maestro
#   adt.sh device-release --slug <slug> | --serial <serial>
#   adt.sh device-list
#
# Every build command leases one device for its whole run: device-acquire boots
# a headless, read-only emulator (or reuses this run's existing lease) and
# prints its serial on the last line; install runs the project's install
# command on that device only; run executes the run's flow files on it with no
# model in the loop and writes run-results.md; device-release stops the device
# when the run ends.
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
#   ADT_AUTOMOBILE       auto-mobile command (default: bunx @kaeawc/auto-mobile@0.0.84)
#   ADT_MAESTRO          Maestro command (default: maestro)
#
# Exit codes:
#   0 success, 1 a flow failed (run), 2 usage, 10 no device, 11 the emulator
#   did not start or boot, 12 install failed, 13 a device could not be
#   stopped, 14 the driver's command was not found, 15 no live device is
#   leased for this run
#
# Runs under bash 3.2 (the macOS system shell): no associative arrays, no
# mapfile, no ${var,,}.

set -u

ADT_HOME="${ADT_HOME:-$HOME/.adt}"
LEASE_ROOT="$ADT_HOME/leases"
BOOT_TIMEOUT="${ADT_BOOT_TIMEOUT_S:-240}"
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
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || now
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

serial_online() {
  adb_devices | awk -v s="$1" '$1 == s && $2 == "device" { found = 1 } END { exit !found }'
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

# Runs a command for at most <limit> seconds; returns 124 on timeout.
run_bounded() {
  local limit="$1" pid waited=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# auto-mobile: one --cli executePlan call per flow. Sets FLOW_RESULT (PASS or
# FAIL), FLOW_STEP (the failing step and its error) and FLOW_SECONDS.
run_automobile_flow() {
  local flow="$1" log="$2" serial="$3" start rc
  set -- ${ADT_AUTOMOBILE:-bunx @kaeawc/auto-mobile@0.0.84}
  start="$(now)"
  run_bounded "$FLOW_TIMEOUT" "$@" --cli executePlan --platform android \
    --deviceId "$serial" --planContent "$(cat "$flow")" > "$log.out" 2> "$log"
  rc=$?
  FLOW_SECONDS=$(( $(now) - start ))
  FLOW_STEP=""
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
      FLOW_STEP="$(grep -v '^[[:space:]]*at \|sourcemap' "$log" | tail -n 1 | cell)"
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
    function attr(rec, name,    re) {
      re = name "=\"[^\"]*\""
      if (match(rec, re)) return substr(rec, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
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
        }
        t = attr(rec, "time")
        if (t == "") t = 0
        printf "%s\t%s\t%d\t%s\n", attr(rec, "file"), result, t + 0.5, msg
      }
    }'
}

# ---------- subcommands ----------

cmd_device_acquire() {
  local slug="" project serial avd rc skip="" after=0 retried=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  find_adb
  project="$(project_dir)"

  remove_stale_leases
  serial="$(find_lease "$project" "$slug")"
  if [ -n "$serial" ] && lease_live "$serial"; then
    say "adt: reusing this run's device $serial"
    printf '%s\n' "$serial"
    return 0
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
  local rows="" total=0 passed=0 failed=0 flaky=0 skipped=0 seconds=0 first_fail=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --driver) driver="${2:-}"; shift 2 ;;
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

  # The flows to run: every *.yaml under this run's flows directory.
  local list="$logs/.flows"
  : > "$list"
  if [ -d "$flows_dir" ]; then
    find "$flows_dir" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r flow; do
      printf 'feature\t%s\t%s\n' "$flows_dir" "$flow"
    done >> "$list"
  fi

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

  # Pass 1, then one retry for each flow that failed.
  local attempt result step secs log m_out line file
  local files
  for attempt in 1 2; do
    : > "$logs/.attempt$attempt"
    [ -s "$runnable" ] || break
    if [ "$attempt" = 1 ]; then
      cp "$runnable" "$logs/.todo"
    else
      awk -F'\t' '$4 == "FAIL" { print $2 "\t" $1 "\t" $3 }' "$logs/.attempt1" > "$logs/.todo"
      [ -s "$logs/.todo" ] || break
      say "adt: retrying $(wc -l < "$logs/.todo" | tr -d ' ') failed flow(s) once"
    fi

    if [ "$driver" = auto-mobile ]; then
      while IFS="$(printf '\t')" read -r kind id flow; do
        log="$logs/$(printf '%s' "$id" | tr '/' '_').attempt$attempt.log"
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
      run_maestro_flows "$serial" "$m_out" "${files[@]}" > "$m_out/results.tsv"
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
      retry_result="$(awk -F'\t' -v i="$id" '$1 == i { print $4; exit }' "$logs/.attempt2")"
      if [ "$retry_result" = PASS ]; then
        result=FLAKY
      fi
      r_secs="$(awk -F'\t' -v i="$id" '$1 == i { print $6; exit }' "$logs/.attempt2")"
      secs=$(( secs + ${r_secs:-0} ))
    fi
    tier="$(flow_header "$flow" priority)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "${tier:--}" "$result" "$step" "$secs" "$log" >> "$logs/.rows"
  done < "$logs/.attempt1"

  # Write run-results.md.
  {
    printf '# Flow run: %s\n\n' "$slug"
    printf 'Driver: %s · Device: %s · Finished: %s\n\n' "$driver" "$serial" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'A FAIL failed twice. FLAKY failed once, then passed on its retry. SKIPPED was written for the other driver and did not run.\n\n'
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
  rm -f "$logs"/.flows "$logs"/.runnable "$logs"/.todo "$logs"/.attempt1 "$logs"/.attempt2 "$logs"/.rows

  say "adt: $total flow(s): $passed passed, $failed failed, $flaky flaky, $skipped skipped. Results: $results"
  [ "$failed" -eq 0 ]
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
  run)            cmd_run "$@" ;;
  device-release) cmd_device_release "$@" ;;
  device-list)    cmd_device_list ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
