#!/bin/bash
#
# Tests for plugins/agentic-dev-team/scripts/adt.sh, run against the fake
# commands in tests/shims/ — no real device, emulator or driver is touched.
#
# Run with the system shell, so macOS checks the script under bash 3.2:
#   /bin/bash tests/adt.test.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/plugins/agentic-dev-team/scripts/adt.sh"
SHIMS="$ROOT/tests/shims"

PASS=0
FAIL=0
FAILED=""

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED
  - $1"
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
}

# expect <description> <expected exit code> <actual exit code>
expect_code() {
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected exit $2, got $3"; fi
}

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$2], got [$3]"; fi
}

expect_true() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else not_ok "$desc" "condition failed: $*"; fi
}

# ---------- a fresh sandbox per test group ----------

SANDBOX=""

setup() {
  [ -n "$SANDBOX" ] && teardown
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/adt-test.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export FAKE_ADT_STATE="$SANDBOX/state"
  export ADT_HOME="$SANDBOX/adt-home"
  export ANDROID_HOME="$SANDBOX/sdk"
  export CLAUDE_CONFIG_DIR="$SANDBOX/claude-config"
  # Tests may run inside Codex: keep its session and rules out of them.
  export CODEX_HOME="$SANDBOX/codex-home"
  unset CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED
  # Keep the developer's own git config and global ignores out of the tests.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$SANDBOX/xdg"
  unset ANDROID_SDK_ROOT ADT_AVD ADT_DEVICE_MODE ADT_HEADLESS ANDROID_SERIAL ADT_MEM_TOTAL_MB ADT_MEM_AVAILABLE_MB
  # One emulator per run unless a test asks for two.
  export ADT_PARALLEL=1
  export ADT_BOOT_TIMEOUT_S=6
  export ADT_PORT_FIRST=15554
  export ADT_PORT_LAST=15560
  mkdir -p "$FAKE_ADT_STATE/dev" "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/emulator"
  ln -s "$SHIMS/adb" "$ANDROID_HOME/platform-tools/adb"
  ln -s "$SHIMS/emulator" "$ANDROID_HOME/emulator/emulator"
  export PATH="$ANDROID_HOME/platform-tools:$BASE_PATH"
  printf 'Pixel_A\nPixel_B\n' > "$FAKE_ADT_STATE/avds"
  export ANDROID_AVD_HOME="$SANDBOX/avd"
  mkdir -p "$ANDROID_AVD_HOME"
  mkdir -p "$SANDBOX/proj1" "$SANDBOX/proj2"
  git -C "$SANDBOX/proj1" init -q
  git -C "$SANDBOX/proj2" init -q
}

teardown() {
  [ -n "$SANDBOX" ] || return 0
  # Stop any fake emulator still waiting on its device file.
  rm -rf "${FAKE_ADT_STATE:?}/dev"
  sleep 0.5
  rm -rf "$SANDBOX"
  SANDBOX=""
}

# adt <dir> <args...> — runs the script from a project directory.
adt() {
  local dir="$1"; shift
  (cd "$dir" && /bin/bash "$SCRIPT" "$@")
}

lease_file() { cat "$ADT_HOME/leases/$1/$2" 2>/dev/null; }
device_state() { cat "$FAKE_ADT_STATE/dev/$1" 2>/dev/null; }
boots() { local n; n="$(grep -c -- '-read-only' "$FAKE_ADT_STATE/emulator.calls" 2>/dev/null)"; echo "${n:-0}"; }

# A device that is online and not started by adt.sh, e.g. your own emulator.
attach() {
  echo device > "$FAKE_ADT_STATE/dev/$1"
  [ -n "${2:-}" ] && echo "$2" > "$FAKE_ADT_STATE/avd.$1"
}

BASE_PATH="$PATH"
trap 'teardown' EXIT

echo "adt.sh tests ($(/bin/bash --version | head -n 1))"

# ---------- usage ----------

echo "usage"
setup
adt "$SANDBOX/proj1" >/dev/null 2>&1;                       expect_code "no subcommand is a usage error" 2 $?
adt "$SANDBOX/proj1" bogus >/dev/null 2>&1;                 expect_code "unknown subcommand is a usage error" 2 $?
adt "$SANDBOX/proj1" device-acquire >/dev/null 2>&1;        expect_code "device-acquire without --slug is a usage error" 2 $?
adt "$SANDBOX/proj1" install --slug a >/dev/null 2>&1;      expect_code "install without a command is a usage error" 2 $?
adt "$SANDBOX/proj1" device-release >/dev/null 2>&1;        expect_code "device-release without --slug or --serial is a usage error" 2 $?

# ---------- acquire ----------

echo "device-acquire"
setup
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null)";  rc=$?
expect_code "boots an emulator" 0 $rc
serial_a="$(printf '%s\n' "$out" | tail -n 1)"
expect_eq "prints the serial on the last line" "emulator-15554" "$serial_a"
expect_eq "the device is online after the command returns" "device" "$(device_state "$serial_a")"
expect_eq "the lease records the project" "$SANDBOX/proj1" "$(lease_file "$serial_a" project)"
expect_eq "the lease records the slug" "a" "$(lease_file "$serial_a" slug)"
expect_eq "the lease records that adt.sh started it" "yes" "$(lease_file "$serial_a" started)"
expect_true "it boots read-only and headless" grep -q -- '-avd Pixel_A -read-only -no-audio -no-boot-anim -port 15554 -no-window' "$FAKE_ADT_STATE/emulator.calls"
expect_true "it turns animations off" grep -q 'shell settings put global animator_duration_scale 0' "$FAKE_ADT_STATE/adb.calls"
expect_true "it keeps the screen on while the run waits" grep -q "adb -s $serial_a shell settings put system screen_off_timeout 2147483647" "$FAKE_ADT_STATE/adb.calls"
expect_true "and dismisses the keyguard" grep -q "adb -s $serial_a shell wm dismiss-keyguard" "$FAKE_ADT_STATE/adb.calls"
expect_true "and hides error dialogs, which could cover the app" grep -q "adb -s $serial_a shell settings put global hide_error_dialogs 1" "$FAKE_ADT_STATE/adb.calls"

out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "acquiring again for the same project and slug reuses the device" "$serial_a" "$out"
expect_eq "and boots nothing new" "1" "$(boots)"

out="$(adt "$SANDBOX/proj1" device-acquire --slug b 2>/dev/null | tail -n 1)"
expect_eq "another slug gets another device" "emulator-15556" "$out"
out="$(adt "$SANDBOX/proj2" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "the same slug in another project gets another device" "emulator-15558" "$out"

echo "device-acquire, concurrently"
setup
adt "$SANDBOX/proj1" device-acquire --slug a > "$SANDBOX/a.out" 2>/dev/null &
pid_a=$!
adt "$SANDBOX/proj1" device-acquire --slug b > "$SANDBOX/b.out" 2>/dev/null &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?
expect_eq "both acquires succeed" "0 0" "$rc_a $rc_b"
sa="$(tail -n 1 "$SANDBOX/a.out")"; sb="$(tail -n 1 "$SANDBOX/b.out")"
expect_true "they print different serials ($sa, $sb)" [ -n "$sa" -a "$sa" != "$sb" ]

echo "device-acquire, concurrently, where mkdir is not atomic"
# The fake mkdir lets every caller at once create the same directory, as the
# uutils mkdir before 0.11 (Ubuntu 26.04's) can.
setup
mkdir -p "$SANDBOX/bin"
ln -s "$SHIMS/mkdir" "$SANDBOX/bin/mkdir"
pids=""
for s in a a b; do
  (cd "$SANDBOX/proj1" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" device-acquire --slug "$s") \
    >> "$SANDBOX/$s.out" 2>/dev/null &
  pids="$pids $!"
done
rcs=""
for pid in $pids; do wait "$pid"; rcs="${rcs:+$rcs }$?"; done
expect_eq "all three acquires succeed" "0 0 0" "$rcs"
sa="$(sort -u "$SANDBOX/a.out")"; sb="$(cat "$SANDBOX/b.out")"
expect_eq "two acquires for one slug print one serial" "1" "$(printf '%s\n' "$sa" | grep -c .)"
expect_true "another slug gets another serial ($sa, $sb)" [ -n "$sb" -a "$sb" != "$sa" ]
expect_eq "and only two devices boot" "2" "$(boots)"

echo "choosing the AVD"
setup
attach emulator-5554 Pixel_A
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "an AVD open in normal mode is skipped" "Pixel_B" "$(lease_file "$out" avd)"
expect_eq "your own emulator is left alone" "device" "$(device_state emulator-5554)"

setup
attach emulator-5554 Pixel_A
attach emulator-5556 Pixel_B
err="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>&1 >/dev/null)"; rc=$?
expect_code "with every AVD open in normal mode, nothing is taken: exit 10" 10 $rc
expect_eq "  (your emulators get no lease)" "" "$(lease_file emulator-5554 slug)$(lease_file emulator-5556 slug)"
expect_true "  (and the script says how to opt in)" grep -q 'every AVD is open in normal mode.*ADT_DEVICE_MODE=reuse' <<EOF
$err
EOF
export ADT_DEVICE_MODE=reuse
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "with ADT_DEVICE_MODE=reuse, an attached device is taken" "a" "$(lease_file "$out" slug)"
expect_eq "it is recorded as not started by adt.sh" "no" "$(lease_file "$out" started)"
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_eq "releasing it does not stop it" "device" "$(device_state "$out")"
unset ADT_DEVICE_MODE

setup
echo busy > "$FAKE_ADT_STATE/mode.Pixel_A"
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "an AVD the emulator refuses as already running is skipped" "Pixel_B" "$(lease_file "$out" avd)"

setup
export ADT_AVD=Pixel_B
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "ADT_AVD picks the AVD" "Pixel_B" "$(lease_file "$out" avd)"
export ADT_AVD=Nope
adt "$SANDBOX/proj1" device-acquire --slug b >/dev/null 2>&1
expect_code "an unknown ADT_AVD is refused" 10 $?
export ADT_AVD=Pixel_A
attach emulator-5554 Pixel_A
adt "$SANDBOX/proj1" device-acquire --slug c >/dev/null 2>&1
expect_code "an ADT_AVD open in normal mode is refused" 10 $?
unset ADT_AVD

setup
: > "$FAKE_ADT_STATE/avds"
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "no AVD and no device: exit 10" 10 $?
attach R58M123
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "no AVD but a phone attached: the phone is not used without ADT_DEVICE_MODE=reuse" 10 $?
expect_eq "  (it gets no lease)" "" "$(lease_file R58M123 slug)"

echo "reuse mode"
setup
export ADT_DEVICE_MODE=reuse
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "reuse with nothing attached: exit 10" 10 $?
attach R58M123
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "reuse takes the attached device" "R58M123" "$out"
expect_eq "and boots nothing" "0" "$(boots)"
expect_eq "and changes none of its settings" "0" "$(grep -c 'R58M123 shell settings\|R58M123 shell wm' "$FAKE_ADT_STATE/adb.calls")"
unset ADT_DEVICE_MODE

echo "boot failures"
setup
echo fail > "$FAKE_ADT_STATE/mode.Pixel_A"
export ADT_AVD=Pixel_A
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "an emulator that will not start: exit 11" 11 $?
expect_eq "it was tried twice, on different ports" "2" "$(boots)"
expect_true "the retry used a later port" grep -q -- '-port 15556' "$FAKE_ADT_STATE/emulator.calls"
expect_eq "no lease is left behind" "" "$(ls "$ADT_HOME/leases" 2>/dev/null)"
expect_true "the log is kept" [ -f "$ADT_HOME/last-failed-boot.log" ]

setup
echo hang > "$FAKE_ADT_STATE/mode.Pixel_A"
export ADT_AVD=Pixel_A ADT_BOOT_TIMEOUT_S=3
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "an emulator that never finishes booting: exit 11" 11 $?
expect_eq "and it is stopped" "" "$(ls "$FAKE_ADT_STATE/dev")"
unset ADT_AVD
export ADT_BOOT_TIMEOUT_S=6

echo "ports"
setup
perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 15555, Listen => 1, ReuseAddr => 1) or die; sleep 30' &
listener=$!
sleep 1
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
kill $listener 2>/dev/null
wait $listener 2>/dev/null
expect_eq "a port whose adb port (port+1) is taken is skipped" "emulator-15556" "$out"

echo "stale leases"
setup
mkdir -p "$ADT_HOME/leases/emulator-15554" "$ADT_HOME/leases/emulator-15556"
echo "$SANDBOX/proj1" > "$ADT_HOME/leases/emulator-15554/project"
echo old > "$ADT_HOME/leases/emulator-15554/slug"
echo $(( $(date +%s) - 1000 )) > "$ADT_HOME/leases/emulator-15554/created"
echo "$SANDBOX/proj1" > "$ADT_HOME/leases/emulator-15556/project"
echo booting > "$ADT_HOME/leases/emulator-15556/slug"
date +%s > "$ADT_HOME/leases/emulator-15556/created"
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "an old lease with no device is removed, so its port is free again" "emulator-15554" "$out"
expect_eq "and the new lease replaced it" "a" "$(lease_file emulator-15554 slug)"
expect_eq "a young lease (still booting) is kept, so its port is not taken" "booting" "$(lease_file emulator-15556 slug)"

# ---------- install ----------

echo "install"
setup
adt "$SANDBOX/proj1" install --slug a -- true >/dev/null 2>&1
expect_code "install with no lease: exit 15" 15 $?
serial="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
out="$(adt "$SANDBOX/proj1" install --slug a -- sh -c 'echo "gradle output"; echo "$ANDROID_SERIAL" > "$FAKE_ADT_STATE/installed-on"' 2>/dev/null)"
rc=$?
expect_code "install runs the command" 0 $rc
expect_eq "with ANDROID_SERIAL set to the leased device" "$serial" "$(cat "$FAKE_ADT_STATE/installed-on")"
expect_true "and prints only a UTC timestamp on stdout ($out)" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<EOF
$out
EOF
adt "$SANDBOX/proj1" install --slug a -- false >/dev/null 2>&1
expect_code "a failing install command: exit 12" 12 $?
expect_eq "  (and it is not retried)" "1" "$(boots)"
expect_true "an emulator it started has its caches cleared before each install" grep -q "adb -s $serial shell pm trim-caches 999G" "$FAKE_ADT_STATE/adb.calls"

# fills_up <n> — writes $SANDBOX/fills-up, an install command that runs out of
# space its first <n> times, then installs.
fills_up() {
  echo "$1" > "$FAKE_ADT_STATE/full"
  cat > "$SANDBOX/fills-up" <<'EOF'
#!/bin/sh
n=$(cat "$FAKE_ADT_STATE/full" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then
  echo $((n - 1)) > "$FAKE_ADT_STATE/full"
  echo "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
  exit 1
fi
echo "$ANDROID_SERIAL" > "$FAKE_ADT_STATE/installed-on"
EOF
  chmod +x "$SANDBOX/fills-up"
}
echo "install, out of space"
fills_up 1
out="$(adt "$SANDBOX/proj1" install --slug a -- "$SANDBOX/fills-up" 2>"$SANDBOX/err")"
rc=$?
expect_code "an emulator that runs out of space is restarted fresh, and the install succeeds" 0 $rc
expect_true "  (it says so)" grep -q "ran out of space; restarting it as a fresh copy of Pixel_A" "$SANDBOX/err"
expect_eq "  (on the same serial, so the run's DEVICE still holds)" "$serial" "$(cat "$FAKE_ADT_STATE/installed-on")"
expect_eq "  (one more boot, on the same port)" "2" "$(grep -c -- '-port 15554' "$FAKE_ADT_STATE/emulator.calls")"
expect_eq "  (the lease is kept)" "a" "$(lease_file "$serial" slug)"
expect_true "  (and it prints BUILD_INSTALLED)" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' <<EOF
$out
EOF
fills_up 2
echo 120000 > "$FAKE_ADT_STATE/free.$serial"
adt "$SANDBOX/proj1" install --slug a -- "$SANDBOX/fills-up" >/dev/null 2>"$SANDBOX/err"
expect_code "still out of space on a fresh copy: exit 12" 12 $?
expect_true "  (naming the AVD, its free space and the fix)" grep -q "fresh copy of Pixel_A with its caches cleared (117 MB free).*Internal storage" "$SANDBOX/err"
expect_eq "  (it restarted once, not again and again)" "3" "$(grep -c -- '-port 15554' "$FAKE_ADT_STATE/emulator.calls")"
rm -f "$FAKE_ADT_STATE/free.$serial"

setup
export ADT_DEVICE_MODE=reuse
attach R58M123
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
fills_up 1
adt "$SANDBOX/proj1" install --slug a -- "$SANDBOX/fills-up" >/dev/null 2>"$SANDBOX/err"
expect_code "a device you attached that is out of space: exit 12" 12 $?
expect_true "  (asking you to free space on it)" grep -q "Free some space on it" "$SANDBOX/err"
expect_eq "  (it is never cleaned or restarted)" "0 0" "$(grep -c 'R58M123 shell pm' "$FAKE_ADT_STATE/adb.calls") $(boots)"
unset ADT_DEVICE_MODE

# ---------- release and list ----------

echo "device-release and device-list"
setup
sa="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
sb="$(adt "$SANDBOX/proj1" device-acquire --slug b 2>/dev/null | tail -n 1)"
list="$(adt "$SANDBOX/proj1" device-list 2>/dev/null)"
expect_eq "device-list shows one line per lease" "2" "$(printf '%s\n' "$list" | grep -c live)"
expect_true "with serial, project and slug" grep -q "^$sa	$SANDBOX/proj1	a	" <<EOF
$list
EOF
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_code "release stops this run's emulator" 0 $?
expect_eq "it is gone" "" "$(device_state "$sa")"
expect_eq "the other run's emulator keeps running" "device" "$(device_state "$sb")"
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_code "releasing again is harmless" 0 $?
adt "$SANDBOX/proj2" device-release --slug b >/dev/null 2>&1
expect_eq "--slug only touches this project's lease" "device" "$(device_state "$sb")"
adt "$SANDBOX/proj2" device-release --serial "$sb" >/dev/null 2>&1
expect_eq "--serial releases a lease from any project" "" "$(device_state "$sb")"
expect_eq "no leases are left" "" "$(adt "$SANDBOX/proj1" device-list 2>/dev/null)"

setup
sa="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
touch "$FAKE_ADT_STATE/stubborn.$sa"
pid="$(lease_file "$sa" pid)"
echo "999999" > "$ADT_HOME/leases/$sa/pid"
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_code "a device that will not stop: exit 13" 13 $?
expect_eq "and its lease is kept" "a" "$(lease_file "$sa" slug)"
rm -f "$FAKE_ADT_STATE/stubborn.$sa"
kill "$pid" 2>/dev/null

echo "device-release during a background boot"
setup
adt "$SANDBOX/proj1" device-acquire --slug a --background >/dev/null 2>&1
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_code "a release right after a background acquire succeeds" 0 $?
sleep 2
expect_eq "it waited for the boot, then stopped that device" "" "$(ls "$FAKE_ADT_STATE/dev")"
expect_eq "no lease is left" "" "$(ls "$ADT_HOME/leases" 2>/dev/null)"
expect_eq "and nothing else was booted" "1" "$(boots)"

# ---------- run ----------

# flow <project> <slug> <file under flows/> <driver> [fake outcome]
flow() {
  local f="$1/pipeline_artifacts/$2/flows/$3"
  mkdir -p "$(dirname "$f")"
  {
    echo "# adt:driver: $4"
    [ -n "${5:-}" ] && echo "# fake: $5"
    echo "name: $(basename "$3" .yaml)"
    echo "appId: com.example.app"
    echo "steps:"
    echo "  - tool: launchApp"
  } > "$f"
}
row() { grep "^| $3 |" "$1/pipeline_artifacts/$2/run-results.md"; }
# row_has <description> <project> <slug> <flow id> <text the row must contain>
row_has() {
  if row "$2" "$3" "$4" | grep -qF -- "$5"; then ok "$1"; else not_ok "$1" "row: $(row "$2" "$3" "$4")"; fi
}

echo "run"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "run with no leased device: exit 15" 15 $?
serial="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
adt "$SANDBOX/proj1" run --slug a --driver espresso >/dev/null 2>&1
expect_code "an unknown driver is a usage error" 2 $?
ADT_AUTOMOBILE=/nonexistent/auto-mobile adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "a driver command that is not installed: exit 14" 14 $?

adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "no flows: nothing fails" 0 $?
expect_true "and the results say so" grep -q "Totals: 0 flow(s)" "$SANDBOX/proj1/pipeline_artifacts/a/run-results.md"

echo "run, auto-mobile"
flow "$SANDBOX/proj1" a 01-pass.yaml auto-mobile
flow "$SANDBOX/proj1" a 02-fail.yaml auto-mobile fail
flow "$SANDBOX/proj1" a 03-flaky.yaml auto-mobile flaky
flow "$SANDBOX/proj1" a 04-maestro.yaml maestro
adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "a flow that fails twice fails the run" 1 $?
row_has "a passing flow is PASS" "$SANDBOX/proj1" a 01-pass "| feature | — | PASS |"
row_has "a failing flow is FAIL, with its step and error" "$SANDBOX/proj1" a 02-fail "| FAIL | step 2 (observe): observe waitFor timed out after 4000ms |"
row_has "a flow that passes on its retry is FLAKY" "$SANDBOX/proj1" a 03-flaky "| FLAKY |"
row_has "a flow for the other driver is SKIPPED" "$SANDBOX/proj1" a 04-maestro "| SKIPPED | written for maestro |"
expect_eq "each flow ran on the leased device, and only failures were retried" \
  "executePlan device=$serial name=01-pass
executePlan device=$serial name=02-fail
executePlan device=$serial name=03-flaky
executePlan device=$serial name=02-fail
executePlan device=$serial name=03-flaky" "$(cat "$FAKE_ADT_STATE/automobile.calls")"
expect_eq "before the flows, it binds auto-mobile to the device, so a fresh emulator gets its helper" "getAndroid device=$serial" "$(tail -n 1 "$FAKE_ADT_STATE/automobile.binds")"
expect_true "every row links its log" [ -f "$SANDBOX/proj1/pipeline_artifacts/a/run-logs/feature-02-fail.attempt1.log" ]
row_has "  (named in the row)" "$SANDBOX/proj1" a 02-fail "| run-logs/feature-02-fail.attempt1.log |"
expect_true "the totals line counts each result" grep -q "Totals: 4 flow(s) — 1 passed, 1 failed, 1 flaky, 1 skipped" "$SANDBOX/proj1/pipeline_artifacts/a/run-results.md"

rm "$SANDBOX/proj1/pipeline_artifacts/a/flows/02-fail.yaml"
adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "with no failing flow, the run passes" 0 $?
expect_eq "and run-results.md is rewritten, not appended" "0" "$(grep -c '^| 02-fail' "$SANDBOX/proj1/pipeline_artifacts/a/run-results.md")"

flow "$SANDBOX/proj1" a 06-big.yaml auto-mobile big
flow "$SANDBOX/proj1" a 07-quiet.yaml auto-mobile quiet-fail
adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
row_has "a passing flow whose result was too big to print is PASS" "$SANDBOX/proj1" a 06-big "| PASS |"
expect_true "  (its full result is kept with the run's logs)" grep -q '"success":true' "$SANDBOX/proj1/pipeline_artifacts/a/run-logs/feature-06-big.attempt1.log.out"
row_has "a failure with no error message still says why" "$SANDBOX/proj1" a 07-quiet "| FAIL | auto-mobile exited with code 3 and no error; see the log |"
rm -f "$SANDBOX/proj1/pipeline_artifacts/a/flows/06-big.yaml" "$SANDBOX/proj1/pipeline_artifacts/a/flows/07-quiet.yaml"

flow "$SANDBOX/proj1" a 05-hang.yaml auto-mobile hang
ADT_FLOW_TIMEOUT_S=2 adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "a flow that hangs fails the run" 1 $?
row_has "with a timeout as its failing step" "$SANDBOX/proj1" a 05-hang "| FAIL | timed out after 2s |"

echo "run --only"
serial_o="$(adt "$SANDBOX/proj1" device-acquire --slug o 2>/dev/null | tail -n 1)"
flow "$SANDBOX/proj1" o items/a.yaml auto-mobile
flow "$SANDBOX/proj1" o items/b.yaml auto-mobile fail
adt "$SANDBOX/proj1" run --slug o --driver auto-mobile --only items/b >/dev/null 2>&1
expect_code "--only before any full run is refused" 2 $?
adt "$SANDBOX/proj1" run --slug o --driver auto-mobile >/dev/null 2>&1
expect_code "a full run with a failing flow fails" 1 $?
flow "$SANDBOX/proj1" o items/b.yaml auto-mobile
: > "$FAKE_ADT_STATE/automobile.calls"
adt "$SANDBOX/proj1" run --slug o --driver auto-mobile --only items/b >/dev/null 2>&1
expect_code "--only re-runs the named flow, and the run now passes" 0 $?
expect_eq "  (only that flow ran)" "executePlan device=$serial_o name=b" "$(cat "$FAKE_ADT_STATE/automobile.calls")"
row_has "  (its row is updated)" "$SANDBOX/proj1" o items/b "| feature | — | PASS |"
row_has "  (the other flow's row is kept)" "$SANDBOX/proj1" o items/a "| feature | — | PASS |"
expect_true "  (and the totals count both)" grep -q "Totals: 2 flow(s) — 2 passed, 0 failed" "$SANDBOX/proj1/pipeline_artifacts/o/run-results.md"
adt "$SANDBOX/proj1" run --slug o --driver auto-mobile --only items/nope >/dev/null 2>&1
expect_code "--only with a flow that does not exist is refused" 2 $?

echo "run, Maestro"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
mkdir -p "$SANDBOX/my project"
git -C "$SANDBOX/my project" init -q
serial="$(adt "$SANDBOX/my project" device-acquire --slug m 2>/dev/null | tail -n 1)"
flow "$SANDBOX/my project" m 01-pass.yaml maestro
flow "$SANDBOX/my project" m 02-fail.yaml maestro fail
flow "$SANDBOX/my project" m 03-flaky.yaml maestro flaky
flow "$SANDBOX/my project" m 04-automobile.yaml auto-mobile
adt "$SANDBOX/my project" run --slug m --driver maestro >/dev/null 2>&1
expect_code "a Maestro flow that fails twice fails the run" 1 $?
expect_eq "one maestro call for all flows, one for the retries, on the leased device" \
  "test device=$serial flows=3
test device=$serial flows=2" "$(cat "$FAKE_ADT_STATE/maestro.calls")"
row_has "PASS, with its time from the report (a path with a space)" "$SANDBOX/my project" m 01-pass "| PASS |  | 2 |"
row_has "FAIL, with the report's failure message, unescaped" "$SANDBOX/my project" m 02-fail '| FAIL | Assertion is false: id: "order_confirmation_title" is visible & enabled |'
row_has "FLAKY when it passes on the retry" "$SANDBOX/my project" m 03-flaky "| FLAKY |"
row_has "an auto-mobile flow is SKIPPED in a Maestro run" "$SANDBOX/my project" m 04-automobile "| SKIPPED | written for auto-mobile |"
unset ADT_AUTOMOBILE ADT_MAESTRO

echo "test secrets"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
git -C "$SANDBOX/proj1" config user.email t@example.com
git -C "$SANDBOX/proj1" config user.name t
serial="$(adt "$SANDBOX/proj1" device-acquire --slug s 2>/dev/null | tail -n 1)"
mkdir -p "$SANDBOX/proj1/.agentic-dev-team"
printf '*\n' > "$SANDBOX/proj1/.agentic-dev-team/.gitignore"
printf '# test account\nTEST_EMAIL=qa@example.com\nTEST_PASSWORD=s3cr3t-Pa$$\n' > "$SANDBOX/proj1/.agentic-dev-team/secrets.env"
f="$SANDBOX/proj1/pipeline_artifacts/s/flows/auth/sign-in.yaml"
mkdir -p "$(dirname "$f")"
printf '# adt:driver: auto-mobile\n# adt:priority: p0\n# fake: echo-plan\nname: sign-in\nsteps:\n  - tool: launchApp\n    appId: com.example.app\n  - tool: sendKeys\n    text: "${TEST_EMAIL}"\n  - tool: sendKeys\n    text: "${TEST_PASSWORD}"\n' > "$f"
adt "$SANDBOX/proj1" run --slug s --driver auto-mobile >/dev/null 2>&1
expect_code "a flow that uses declared secrets runs" 0 $?
expect_true "auto-mobile gets the values in place of the names" grep -qF 'text: "s3cr3t-Pa$$"' "$FAKE_ADT_STATE/plan.sign-in"
expect_true "  (both of them)" grep -qF 'text: "qa@example.com"' "$FAKE_ADT_STATE/plan.sign-in"
expect_true "the flow file keeps the names, never the values" grep -qF '${TEST_PASSWORD}' "$f"
expect_eq "no log of the run holds a value" "" "$(grep -rlF 's3cr3t-Pa$$' "$SANDBOX/proj1/pipeline_artifacts/s" 2>/dev/null)"
expect_true "  (they hold *** instead)" grep -rqF 'text: "***"' "$SANDBOX/proj1/pipeline_artifacts/s/run-logs"
printf '# adt:driver: auto-mobile\nname: other\nsteps:\n  - tool: sendKeys\n    text: "${TEST_PIN}"\n' > "$SANDBOX/proj1/pipeline_artifacts/s/flows/auth/pin.yaml"
adt "$SANDBOX/proj1" run --slug s --driver auto-mobile >/dev/null 2>&1
expect_code "a flow that uses a secret the file does not set fails the run" 1 $?
row_has "  (its row names the missing secret)" "$SANDBOX/proj1" s auth/pin "| FAIL | needs the test secret TEST_PIN, which .agentic-dev-team/secrets.env does not set |"
expect_eq "  (and it never reaches the device)" "0" "$(grep -c 'name=other' "$FAKE_ADT_STATE/automobile.calls")"
rm -f "$SANDBOX/proj1/pipeline_artifacts/s/flows/auth/pin.yaml"

printf '# adt:driver: maestro\n# fake: echo-env\nappId: com.example.app\n---\n- inputText: ${TEST_PASSWORD}\n- takeScreenshot: ${MAESTRO_FILENAME}\n' > "$SANDBOX/proj1/pipeline_artifacts/s/flows/auth/sign-in.yaml"
adt "$SANDBOX/proj1" run --slug s --driver maestro >/dev/null 2>&1
expect_code "under Maestro, a flow with a secret runs" 0 $?
expect_eq "Maestro gets only the secrets the flows use, as -e (not its own MAESTRO_ variables)" "TEST_PASSWORD=s3cr3t-Pa\$\$" "$(cat "$FAKE_ADT_STATE/maestro.env")"
expect_eq "  (and no log keeps the value)" "" "$(grep -rlF 's3cr3t-Pa$$' "$SANDBOX/proj1/pipeline_artifacts/s" 2>/dev/null)"

printf 'not a setting\n' > "$SANDBOX/proj1/.agentic-dev-team/secrets.env"
adt "$SANDBOX/proj1" run --slug s --driver maestro >/dev/null 2>&1
expect_code "a malformed secrets file stops the run" 2 $?
printf 'TEST_PASSWORD=x1\n' > "$SANDBOX/proj1/.agentic-dev-team/secrets.env"
rm "$SANDBOX/proj1/.agentic-dev-team/.gitignore"
err="$(adt "$SANDBOX/proj1" run --slug s --driver maestro 2>&1 >/dev/null)"; rc=$?
expect_code "a secrets file git does not ignore stops the run" 2 $rc
expect_true "  (and says why)" grep -q 'is not git-ignored' <<EOF
$err
EOF
git -C "$SANDBOX/proj1" add -f .agentic-dev-team/secrets.env
adt "$SANDBOX/proj1" run --slug s --driver maestro >/dev/null 2>&1
expect_code "a tracked secrets file stops the run" 2 $?
git -C "$SANDBOX/proj1" rm -q --cached .agentic-dev-team/secrets.env
rm -f "$SANDBOX/proj1/.agentic-dev-team/secrets.env"
printf '# adt:driver: maestro\nappId: com.example.app\n---\n- launchApp\n' > "$SANDBOX/proj1/pipeline_artifacts/s/flows/auth/sign-in.yaml"
adt "$SANDBOX/proj1" run --slug s --driver maestro >/dev/null 2>&1
expect_code "with no secrets file, flows without secrets run as before" 0 $?
expect_eq "  (and Maestro gets no -e)" "" "$(cat "$FAKE_ADT_STATE/maestro.env")"
unset ADT_AUTOMOBILE ADT_MAESTRO

echo "where the project is"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile"
mkdir -p "$SANDBOX/proj1/android/app"
flow "$SANDBOX/proj1/android" s items/sub.yaml auto-mobile
serial="$(adt "$SANDBOX/proj1/android" device-acquire --slug s 2>/dev/null | tail -n 1)"
expect_eq "an app in a subfolder of its repository owns its lease" "$SANDBOX/proj1/android" "$(lease_file "$serial" project)"
adt "$SANDBOX/proj1/android/app" run --slug s --driver auto-mobile >/dev/null 2>&1
expect_code "run from a folder below the app finds that lease" 0 $?
row_has "and runs the app's own flows" "$SANDBOX/proj1/android" s items/sub "| PASS |"
expect_eq "nothing is written at the repository's top level" "android" "$(ls "$SANDBOX/proj1")"
mkdir -p "$SANDBOX/my [old] app"
git -C "$SANDBOX/my [old] app" init -q
flow "$SANDBOX/my [old] app" g items/brk.yaml auto-mobile
adt "$SANDBOX/my [old] app" device-acquire --slug g >/dev/null 2>&1
adt "$SANDBOX/my [old] app" run --slug g --driver auto-mobile >/dev/null 2>&1
row_has "a project path with [ ] still gives ids relative to the flows folder" "$SANDBOX/my [old] app" g items/brk "| PASS |"
unset ADT_AUTOMOBILE

# ---------- the regression suite ----------

# suite <project> <id> <driver> <tier> [fake outcome] — a flow in e2e/flows/
suite() {
  local f="$1/e2e/flows/$2.yaml"
  mkdir -p "$(dirname "$f")"
  {
    echo "# adt:driver: $3"
    echo "# adt:priority: $4"
    [ -n "${5:-}" ] && echo "# fake: $5"
    echo "name: $(basename "$2")"
    echo "steps:"
    echo "  - tool: launchApp"
  } > "$f"
}
# tiered <project> <slug> <id> <driver> <tier> [fake outcome] — a flow of this run
tiered() {
  flow "$1" "$2" "$3.yaml" "$4" "${6:-}"
  local f="$1/pipeline_artifacts/$2/flows/$3.yaml"
  { echo "# adt:priority: $5"; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
}
# verdict <project> <slug> <verdict line> — the Tester's test-results.md
verdict() {
  mkdir -p "$1/pipeline_artifacts/$2"
  printf '# Test Results: x\n\n## Summary\nVerified 1 of 1 plan cases; 0 not verified.\n\n## Verdict\n%s\n\n## Recommendations for Coder\n- None\n' "$3" \
    > "$1/pipeline_artifacts/$2/test-results.md"
}
selected() { (cd "$1" && shift && /bin/bash "$SCRIPT" select "$@" 2>/dev/null) | sed "s#^$SANDBOX/proj1/e2e/flows/##"; }

echo "select"
setup
expect_eq "with no suite, nothing is selected" "" "$(selected "$SANDBOX/proj1" --driver auto-mobile)"
suite "$SANDBOX/proj1" app/launch auto-mobile p0
suite "$SANDBOX/proj1" cart/add-item auto-mobile p1
suite "$SANDBOX/proj1" cart/empty-cart auto-mobile p2
suite "$SANDBOX/proj1" checkout/pay auto-mobile p1
suite "$SANDBOX/proj1" checkout/offline auto-mobile p2
suite "$SANDBOX/proj1" checkout/maestro-only maestro p0
expect_eq "P0 only by default" "app/launch.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile)"
expect_eq "an area adds the tiers it names, P0 first" "app/launch.yaml
checkout/pay.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area checkout:p1)"
expect_eq "several areas and tiers" "app/launch.yaml
cart/add-item.yaml
checkout/pay.yaml
checkout/offline.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area checkout:p1,p2 --area cart:p1)"
expect_eq "--exclude drops a flow, even a P0" "checkout/pay.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area checkout:p1 --exclude app/launch)"
expect_eq "a flow for the other driver is never selected" "checkout/maestro-only.yaml" "$(selected "$SANDBOX/proj1" --driver maestro)"
suite "$SANDBOX/proj1" profile/edit auto-mobile "P1 — the main path"
expect_eq "a priority is read in any case, without its reason" "app/launch.yaml
profile/edit.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area profile:p1)"
expect_eq "an --area tier in capitals selects too" "app/launch.yaml
profile/edit.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area profile:P1)"
expect_eq "so do tiers written 'p2 p1'" "app/launch.yaml
profile/edit.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area 'profile:p2 p1')"
expect_eq "and a tier passed as its own word" "app/launch.yaml
profile/edit.yaml" "$(selected "$SANDBOX/proj1" --driver auto-mobile --area profile:p2 p1)"
rm -rf "$SANDBOX/proj1/e2e/flows/profile"

echo "run with the suite"
export ADT_AUTOMOBILE="$SHIMS/auto-mobile"
serial="$(adt "$SANDBOX/proj1" device-acquire --slug f 2>/dev/null | tail -n 1)"
suite "$SANDBOX/proj1" cart/broken auto-mobile p1 fail
tiered "$SANDBOX/proj1" f checkout/pay auto-mobile p1
tiered "$SANDBOX/proj1" f checkout/receipt auto-mobile p2
adt "$SANDBOX/proj1" run --slug f --driver auto-mobile --area checkout:p1,p2 --area cart:p1 >/dev/null 2>&1
expect_code "a failing suite flow fails the run" 1 $?
row_has "the feature's own flows run, with their tier" "$SANDBOX/proj1" f checkout/receipt "| feature | p2 | PASS |"
row_has "a P0 suite flow is replayed" "$SANDBOX/proj1" f app/launch "| regression | p0 | PASS |"
row_has "a selected P1 suite flow is replayed" "$SANDBOX/proj1" f cart/add-item "| regression | p1 | PASS |"
row_has "a broken suite flow is FAIL" "$SANDBOX/proj1" f cart/broken "| regression | p1 | FAIL |"
expect_eq "a suite flow this run re-specifies is not replayed; its new version runs instead" "1" \
  "$(grep -c '^| checkout/pay |' "$SANDBOX/proj1/pipeline_artifacts/f/run-results.md")"
row_has "  (the row is the feature's)" "$SANDBOX/proj1" f checkout/pay "| feature | p1 | PASS |"
expect_eq "unselected tiers are not replayed" "0" "$(grep -c '^| cart/empty-cart |' "$SANDBOX/proj1/pipeline_artifacts/f/run-results.md")"
expect_true "the P0 time is reported" grep -q '^P0 flows: [0-9]* seconds.$' "$SANDBOX/proj1/pipeline_artifacts/f/run-results.md"
ADT_P0_BUDGET_S=-1 adt "$SANDBOX/proj1" run --slug f --driver auto-mobile >/dev/null 2>&1
expect_true "with a warning once it passes the budget" grep -q '^Warning: the P0 flows took more than -1 seconds' "$SANDBOX/proj1/pipeline_artifacts/f/run-results.md"

echo "suite (CI)"
attach emulator-5570 Pixel_A
attach R58M999
adt "$SANDBOX/proj2" suite --driver auto-mobile >/dev/null 2>&1
expect_code "suite with no e2e/flows: exit 2" 2 $?
ADT_AUTOMOBILE="$SHIMS/auto-mobile" adt "$SANDBOX/proj1" suite --driver auto-mobile >/dev/null 2>&1
expect_code "suite with several devices online and no --serial: exit 10" 10 $?
: > "$FAKE_ADT_STATE/automobile.calls"
ADT_AUTOMOBILE="$SHIMS/auto-mobile" adt "$SANDBOX/proj1" suite --driver auto-mobile --serial R58M999 >/dev/null 2>&1
expect_code "suite replays the P0 flows, which pass" 0 $?
out_dir="$SANDBOX/proj1/pipeline_artifacts/suite"
expect_true "  (on the device it was given, with no lease)" grep -q 'executePlan device=R58M999 name=launch' "$FAKE_ADT_STATE/automobile.calls"
expect_eq "  (it takes no lease)" "" "$(lease_file R58M999 slug)"
expect_true "  (it writes run-results.md)" grep -q '^| app/launch | regression | p0 | PASS |' "$out_dir/run-results.md"
expect_true "  (and a JUnit report)" grep -q '<testcase classname="regression" name="app/launch"' "$out_dir/junit.xml"
expect_eq "  (P0 only by default)" "0" "$(grep -c 'checkout/pay' "$out_dir/run-results.md")"
ADT_AUTOMOBILE="$SHIMS/auto-mobile" adt "$SANDBOX/proj1" suite --driver auto-mobile --serial R58M999 --all --out "$SANDBOX/suite-out" >/dev/null 2>&1
expect_code "a failing suite flow fails the suite: exit 1" 1 $?
expect_true "--all replays every tier" grep -q '^| checkout/pay | regression | p1 |' "$SANDBOX/suite-out/run-results.md"
expect_true "  (into --out)" [ -f "$SANDBOX/suite-out/junit.xml" ]
expect_true "a failing flow is a JUnit failure" grep -q '<failure message="step 2 (observe): observe waitFor timed out after 4000ms"/>' "$SANDBOX/suite-out/junit.xml"
ANDROID_SERIAL=R58M999 ADT_AUTOMOBILE="$SHIMS/auto-mobile" adt "$SANDBOX/proj1" suite --driver auto-mobile --area cart:p1 --out "$SANDBOX/suite-out2" >/dev/null 2>&1
expect_true "ANDROID_SERIAL picks the device, and --area works as in run" grep -q '^| cart/add-item | regression | p1 |' "$SANDBOX/suite-out2/run-results.md"
adt "$SANDBOX/proj1" suite --driver auto-mobile --serial nope >/dev/null 2>&1
expect_code "a --serial that is not online: exit 10" 10 $?
rm -f "$FAKE_ADT_STATE/dev/emulator-5570" "$FAKE_ADT_STATE/dev/R58M999"

echo "promote"
tiered "$SANDBOX/proj1" f checkout/no-tier auto-mobile none
tiered "$SANDBOX/proj1" f checkout/flaky auto-mobile p1 flaky
tiered "$SANDBOX/proj1" f cart/add-item auto-mobile p1 fail
tiered "$SANDBOX/proj1" f checkout/upper auto-mobile "P2 — an edge case"
rm -f "$SANDBOX/proj1/e2e/flows/cart/broken.yaml"
adt "$SANDBOX/proj1" run --slug f --driver auto-mobile --area checkout:p1,p2 --area cart:p1 >/dev/null 2>&1
adt "$SANDBOX/proj1" promote --slug f >/dev/null 2>&1
expect_code "promote with no Tester verdict is refused" 2 $?
expect_true "  (and keeps nothing)" [ ! -f "$SANDBOX/proj1/e2e/flows/checkout/receipt.yaml" ]
verdict "$SANDBOX/proj1" f "NEEDS FIXES"
adt "$SANDBOX/proj1" promote --slug f >/dev/null 2>&1
expect_code "promote after NEEDS FIXES is refused" 2 $?
verdict "$SANDBOX/proj1" f "**BLOCKED**"
adt "$SANDBOX/proj1" promote --slug f >/dev/null 2>&1
expect_code "promote after BLOCKED is refused" 2 $?
verdict "$SANDBOX/proj1" f "READY TO MERGE"
touch -t 203001010000 "$SANDBOX/proj1/pipeline_artifacts/f/run-results.md"
adt "$SANDBOX/proj1" promote --slug f >/dev/null 2>&1
expect_code "promote is refused when the flows ran after the verdict" 2 $?
verdict "$SANDBOX/proj1" f "**READY TO MERGE**"
touch -t 203001010001 "$SANDBOX/proj1/pipeline_artifacts/f/test-results.md"
out="$(adt "$SANDBOX/proj1" promote --slug f --remove checkout/offline --remove cart/empty-cart 2>/dev/null)"
expect_code "promote succeeds after READY TO MERGE" 0 $?
expect_true "a new passing flow with a tier is added" [ -f "$SANDBOX/proj1/e2e/flows/checkout/receipt.yaml" ]
row_has "a priority written 'P2 — …' reads as p2" "$SANDBOX/proj1" f checkout/upper "| feature | p2 | PASS |"
expect_true "  (and that flow is kept)" [ -f "$SANDBOX/proj1/e2e/flows/checkout/upper.yaml" ]
expect_true "a passing re-specified flow replaces the old one" grep -q '^replaced: checkout/pay$' <<EOF
$out
EOF
expect_true "  (and the file is the new version)" cmp -s "$SANDBOX/proj1/pipeline_artifacts/f/flows/checkout/pay.yaml" "$SANDBOX/proj1/e2e/flows/checkout/pay.yaml"
expect_true "a flow with tier none is not kept" [ ! -f "$SANDBOX/proj1/e2e/flows/checkout/no-tier.yaml" ]
expect_true "a FLAKY flow is not kept" [ ! -f "$SANDBOX/proj1/e2e/flows/checkout/flaky.yaml" ]
expect_true "a re-specified flow that failed removes the old one" [ ! -f "$SANDBOX/proj1/e2e/flows/cart/add-item.yaml" ]
expect_true "--remove deletes a retired flow" [ ! -f "$SANDBOX/proj1/e2e/flows/checkout/offline.yaml" ]
expect_true "and a now-empty area directory goes with its last flow" [ ! -d "$SANDBOX/proj1/e2e/flows/cart" ]
expect_true "untouched suite flows stay" [ -f "$SANDBOX/proj1/e2e/flows/app/launch.yaml" ]
out2="$(adt "$SANDBOX/proj1" promote --slug f --remove checkout/pay 2>/dev/null)"
expect_true "--remove never deletes a flow this run just replaced" [ -f "$SANDBOX/proj1/e2e/flows/checkout/pay.yaml" ]
adt "$SANDBOX/proj2" promote --slug nothing >/dev/null 2>&1
expect_code "promote with no run results is refused" 2 $?
unset ADT_AUTOMOBILE

# ---------- checks ----------

echo "check"
setup
mkdir -p "$SANDBOX/bin"
printf '#!/bin/bash\necho "serial=${ANDROID_SERIAL:-none} args=$*"\nexit ${FAKE_CHECK_EXIT:-0}\n' > "$SANDBOX/bin/fake-gradle"
chmod +x "$SANDBOX/bin/fake-gradle"
table="$SANDBOX/proj1/pipeline_artifacts/a/checks.md"
out="$(adt "$SANDBOX/proj1" check --slug a --name lint-extra -- "$SANDBOX/bin/fake-gradle" :app:lintDebug 2>/dev/null)"
expect_code "a check that passes: exit 0" 0 $?
expect_true "  (it prints one result line)" grep -q '^CHECK name=lint-extra status=PASS exit=0 log=' <<EOF
$out
EOF
expect_true "  (its output is in its log)" grep -q 'args=:app:lintDebug' "$SANDBOX/proj1/pipeline_artifacts/a/checks/lint-extra.log"
expect_true "  (without a device unless asked)" grep -q 'serial=none' "$SANDBOX/proj1/pipeline_artifacts/a/checks/lint-extra.log"
expect_true "  (and checks.md has its row)" grep -q '^| lint-extra | PASS | 0 | [0-9]* | checks/lint-extra.log | ' "$table"
adt "$SANDBOX/proj1" check --slug a --name device-tests --device -- "$SANDBOX/bin/fake-gradle" >/dev/null 2>&1
expect_code "a device check with no leased device: exit 15" 15 $?
serial="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
FAKE_CHECK_EXIT=3 adt "$SANDBOX/proj1" check --slug a --name device-tests --device -- "$SANDBOX/bin/fake-gradle" :app:connectedDebugAndroidTest >/dev/null 2>&1
expect_code "a check that fails: exit 1" 1 $?
expect_true "  (a device check runs on the leased device only)" grep -q "serial=$serial" "$SANDBOX/proj1/pipeline_artifacts/a/checks/device-tests.log"
expect_true "  (its row says FAIL, with the exit code)" grep -q '^| device-tests | FAIL | 3 |' "$table"
expect_true "  (the other check's row is kept)" grep -q '^| lint-extra | PASS |' "$table"
FAKE_CHECK_EXIT=1 adt "$SANDBOX/proj1" check --slug a --name lint-extra -- "$SANDBOX/bin/fake-gradle" >/dev/null 2>&1
expect_eq "running a check again replaces its row" "1" "$(grep -c '^| lint-extra |' "$table")"
expect_true "  (with the new result)" grep -q '^| lint-extra | FAIL | 1 |' "$table"
ADT_AUTOMOBILE="$SHIMS/auto-mobile" adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_true "a flow run does not delete the check logs" [ -f "$SANDBOX/proj1/pipeline_artifacts/a/checks/lint-extra.log" ]
adt "$SANDBOX/proj1" check --slug a --name "Bad Name" -- true >/dev/null 2>&1
expect_code "a check name with spaces is refused" 2 $?
adt "$SANDBOX/proj1" check --slug a --name x >/dev/null 2>&1
expect_code "a check with no command is a usage error" 2 $?

# ---------- the run ledger ----------

echo "state"
setup
ledger="$SANDBOX/proj1/pipeline_artifacts/.ledger/a"
adt "$SANDBOX/proj1" state --slug a show >/dev/null 2>&1
expect_code "show with no ledger: exit 2, nothing to resume" 2 $?
adt "$SANDBOX/proj1" state --slug a set phase 2R >/dev/null 2>&1
expect_code "set records a value" 0 $?
expect_eq "  (in the ledger, outside the slug's own folder)" "phase=2R" "$(cat "$ledger")"
expect_true "  (pipeline_artifacts is kept out of git)" grep -qx '[*]' "$SANDBOX/proj1/pipeline_artifacts/.gitignore"
adt "$SANDBOX/proj1" state --slug a set plan "pipeline_artifacts/a/implementation-plan.md" >/dev/null 2>&1
adt "$SANDBOX/proj1" state --slug a set phase 3 >/dev/null 2>&1
expect_eq "set replaces a key and keeps the others" "pipeline_artifacts/a/implementation-plan.md
3" "$(adt "$SANDBOX/proj1" state --slug a get plan 2>/dev/null; adt "$SANDBOX/proj1" state --slug a get phase 2>/dev/null)"
adt "$SANDBOX/proj1" state --slug a get nope >/dev/null 2>&1
expect_code "get of a missing key fails" 1 $?
expect_eq "bump counts from 1" "1" "$(adt "$SANDBOX/proj1" state --slug a bump fix_iterations --max 2 2>/dev/null)"
expect_eq "  (and up to the budget)" "2" "$(adt "$SANDBOX/proj1" state --slug a bump fix_iterations --max 2 2>/dev/null)"
err="$(adt "$SANDBOX/proj1" state --slug a bump fix_iterations --max 2 2>&1 >/dev/null)"; rc=$?
expect_code "a bump past the budget is refused: exit 17" 17 $rc
expect_true "  (and says to stop)" grep -q 'budget spent: fix_iterations is already 2' <<EOF
$err
EOF
expect_eq "  (the count stays at the budget)" "2" "$(adt "$SANDBOX/proj1" state --slug a get fix_iterations 2>/dev/null)"
adt "$SANDBOX/proj1" state --slug a bump resumes --max 0 >/dev/null 2>&1
expect_code "a budget of 0 refuses the first bump" 17 $?
adt "$SANDBOX/proj1" state --slug ../x set phase 1 >/dev/null 2>&1
expect_code "a slug with a path in it is refused" 2 $?
adt "$SANDBOX/proj1" state --slug a set Phase 1 >/dev/null 2>&1
expect_code "a key that is not lowercase is refused" 2 $?
adt "$SANDBOX/proj1" state --slug a set note "two
lines" >/dev/null 2>&1
expect_code "a value on two lines is refused" 2 $?
expect_true "show prints the whole ledger" grep -q '^fix_iterations=2$' <<EOF
$(adt "$SANDBOX/proj1" state --slug a show 2>/dev/null)
EOF
adt "$SANDBOX/proj2" state --slug a show >/dev/null 2>&1
expect_code "a ledger belongs to its project" 2 $?
adt "$SANDBOX/proj1" state --slug a start build-auto-fast >/dev/null 2>&1
expect_code "start begins a new run's ledger" 0 $?
expect_eq "  (no count of the earlier run carries over)" "1" "$(adt "$SANDBOX/proj1" state --slug a bump fix_iterations --max 2 2>/dev/null)"
expect_eq "  (it records the command)" "build-auto-fast" "$(adt "$SANDBOX/proj1" state --slug a get command 2>/dev/null)"
expect_true "  (and keeps the earlier ledger beside it)" grep -q '^fix_iterations=2$' "$ledger.previous"
adt "$SANDBOX/proj1" state --slug a start "build auto" >/dev/null 2>&1
expect_code "start with a name that is not a command is refused" 2 $?

# ---------- crashes ----------

echo "crash detection"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
serial="$(adt "$SANDBOX/proj1" device-acquire --slug c 2>/dev/null | tail -n 1)"
flow "$SANDBOX/proj1" c 01-crash.yaml auto-mobile crash
flow "$SANDBOX/proj1" c 02-anr.yaml auto-mobile anr
flow "$SANDBOX/proj1" c 03-other-app.yaml auto-mobile other-crash
flow "$SANDBOX/proj1" c 04-clean.yaml auto-mobile
flow "$SANDBOX/proj1" c 05-fail-then-crash.yaml auto-mobile fail-then-crash
adt "$SANDBOX/proj1" run --slug c --driver auto-mobile >/dev/null 2>&1
expect_code "a crash fails the run, even though every check passed" 1 $?
row_has "a crash of the app is FAIL, with the exception" "$SANDBOX/proj1" c 01-crash "| FAIL | app crashed: java.lang.IllegalStateException: boom |"
row_has "an ANR of the app is FAIL" "$SANDBOX/proj1" c 02-anr "| FAIL | app not responding (ANR) |"
row_has "another app crashing does not fail the flow" "$SANDBOX/proj1" c 03-other-app "| PASS |"
row_has "a crash in an earlier flow does not leak into a later one" "$SANDBOX/proj1" c 04-clean "| PASS |"
row_has "a crash on the retry is reported as the crash" "$SANDBOX/proj1" c 05-fail-then-crash "| FAIL | app crashed: java.lang.IllegalStateException: boom on the retry |"
row_has "  (with the retry's log)" "$SANDBOX/proj1" c 05-fail-then-crash "| run-logs/feature-05-fail-then-crash.attempt2.log |"
expect_eq "a crash is not retried" "1" "$(grep -c 'name=01-crash' "$FAKE_ADT_STATE/automobile.calls")"
expect_true "the crash log is saved with the flow's log" grep -q 'IllegalStateException: boom' "$SANDBOX/proj1/pipeline_artifacts/c/run-logs/feature-01-crash.attempt1.log"
expect_eq "every auto-mobile call carries the pipeline's tool list" \
  "rotate,displayConfig,setAppPermissions,setDeviceState,getDeviceState,openLink,executePlan" "$(cat "$FAKE_ADT_STATE/automobile.tools")"

echo "crash detection, Maestro"
setup
export ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
serial="$(adt "$SANDBOX/proj1" device-acquire --slug m 2>/dev/null | tail -n 1)"
flow "$SANDBOX/proj1" m 01-crash.yaml maestro crash
flow "$SANDBOX/proj1" m 02-clean.yaml maestro
adt "$SANDBOX/proj1" run --slug m --driver maestro >/dev/null 2>&1
expect_code "a crash during a Maestro run fails it" 1 $?
row_has "as its own row, since one Maestro call ran every flow" "$SANDBOX/proj1" m crash-check-1 "| check | — | FAIL | app crashed: java.lang.NullPointerException: crash in a passing flow (com.example.app, during the Maestro run) |"
unset ADT_AUTOMOBILE ADT_MAESTRO

# ---------- early boot ----------

echo "device-acquire --background"
setup
start=$(date +%s)
adt "$SANDBOX/proj1" device-acquire --slug b --background >/dev/null 2>&1
expect_code "--background returns at once" 0 $?
expect_true "  (in under two seconds)" [ $(( $(date +%s) - start )) -le 2 ]
out="$(adt "$SANDBOX/proj1" device-acquire --slug b 2>/dev/null | tail -n 1)"
expect_eq "a later device-acquire waits for that device and prints it" "emulator-15554" "$out"
expect_eq "only one emulator was booted" "1" "$(boots)"
expect_eq "and it has finished booting" "device" "$(device_state "$out")"

setup
adt "$SANDBOX/proj1" device-acquire --slug b --background >/dev/null 2>&1
out="$(adt "$SANDBOX/proj1" device-acquire --slug b 2>/dev/null | tail -n 1)"
out2="$(adt "$SANDBOX/proj1" device-acquire --slug b 2>/dev/null | tail -n 1)"
expect_eq "acquiring right after a background boot, twice, still boots once" "1 $out" "$(boots) $out2"

# ---------- two emulators ----------

# wait_lease <slug> — prints the serial of that slug's lease once its device is
# online, waiting up to ten seconds.
wait_lease() {
  local i=0 d
  while [ "$i" -lt 40 ]; do
    for d in "$ADT_HOME"/leases/*/; do
      [ -d "$d" ] || continue
      if [ "$(cat "$d/slug" 2>/dev/null)" = "$1" ] && [ "$(device_state "$(basename "$d")")" = device ]; then
        basename "$d"
        return 0
      fi
    done
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

echo "two emulators"
setup
export ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=65536 ADT_MEM_AVAILABLE_MB=60000 ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
s1="$(adt "$SANDBOX/proj1" device-acquire --slug p 2>"$SANDBOX/err" | tail -n 1)"
s2="$(wait_lease 'p~2')"
expect_true "with memory to spare, a second emulator boots in the background" [ -n "$s2" ]
expect_true "  (and the script says so)" grep -q "booting a second emulator in the background" "$SANDBOX/err"
expect_eq "  (the run's DEVICE is still the first one)" "emulator-15554" "$s1"
adt "$SANDBOX/proj1" install --slug p -- sh -c 'echo "$ANDROID_SERIAL" >> "$FAKE_ADT_STATE/installs"' >/dev/null 2>&1
expect_eq "install puts the build on the run's device only" "$s1" "$(cat "$FAKE_ADT_STATE/installs")"
for n in 1 2 3 4 5 6; do flow "$SANDBOX/proj1" p "items/f$n.yaml" auto-mobile slow; done
adt "$SANDBOX/proj1" run --slug p --driver auto-mobile >/dev/null 2>&1
expect_code "a run on two emulators passes" 0 $?
expect_eq "every flow ran once" "6" "$(grep -c 'executePlan' "$FAKE_ADT_STATE/automobile.calls")"
expect_true "  (some on the first emulator)" grep -q "device=$s1 " "$FAKE_ADT_STATE/automobile.calls"
expect_true "  (and some on the second)" grep -q "device=$s2 " "$FAKE_ADT_STATE/automobile.calls"
expect_true "  (which got the same build first)" grep -q "^$s2\$" "$FAKE_ADT_STATE/installs"
expect_true "  (and auto-mobile was bound to it)" grep -q "device=$s2\$" "$FAKE_ADT_STATE/automobile.binds"
expect_true "the results name both emulators" grep -q "Devices: $s1 and $s2" "$SANDBOX/proj1/pipeline_artifacts/p/run-results.md"
expect_true "  (and the time start to finish)" grep -q "^Run time: [0-9]* seconds, start to finish, on two emulators.\$" "$SANDBOX/proj1/pipeline_artifacts/p/run-results.md"
adt "$SANDBOX/proj1" device-release --slug p >/dev/null 2>&1
expect_eq "release stops both" "" "$(ls "$FAKE_ADT_STATE/dev")"
expect_eq "  (and drops both leases)" "" "$(ls "$ADT_HOME/leases" 2>/dev/null)"

setup
export ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=65536 ADT_MEM_AVAILABLE_MB=60000 ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
s1="$(adt "$SANDBOX/proj1" device-acquire --slug q 2>/dev/null | tail -n 1)"
s2="$(wait_lease 'q~2')"
adt "$SANDBOX/proj1" install --slug q -- sh -c 'case "$ANDROID_SERIAL" in emulator-15556) exit 1 ;; esac' >/dev/null 2>&1
for n in 1 2 3; do flow "$SANDBOX/proj1" q "items/f$n.yaml" auto-mobile slow; done
adt "$SANDBOX/proj1" run --slug q --driver auto-mobile >/dev/null 2>"$SANDBOX/err"
expect_code "a second emulator the build will not install on is left out, and the run passes" 0 $?
expect_eq "  (every flow ran on the first)" "3" "$(grep -c "device=$s1 " "$FAKE_ADT_STATE/automobile.calls")"
expect_true "  (and the script says why)" grep -q "the second emulator $s2 was left out: installing the build on it failed" "$SANDBOX/err"
adt "$SANDBOX/proj1" device-release --slug q >/dev/null 2>&1

setup
export ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=65536 ADT_MEM_AVAILABLE_MB=60000 ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_MAESTRO="$SHIMS/maestro"
s1="$(adt "$SANDBOX/proj1" device-acquire --slug m 2>/dev/null | tail -n 1)"
s2="$(wait_lease 'm~2')"
adt "$SANDBOX/proj1" install --slug m -- true >/dev/null 2>&1
for n in 1 2 3 4; do flow "$SANDBOX/proj1" m "items/f$n.yaml" maestro slow; done
adt "$SANDBOX/proj1" run --slug m --driver maestro >/dev/null 2>&1
expect_code "a Maestro run on two emulators passes" 0 $?
expect_eq "  (half the flows in one call on each)" "test device=$s1 flows=2
test device=$s2 flows=2" "$(LC_ALL=C sort "$FAKE_ADT_STATE/maestro.calls")"
adt "$SANDBOX/proj1" device-release --slug m >/dev/null 2>&1

setup
export ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=65536 ADT_MEM_AVAILABLE_MB=60000 ADT_AUTOMOBILE="$SHIMS/auto-mobile" ADT_SECOND_BOOT_WAIT_S=2
echo hang > "$FAKE_ADT_STATE/mode.port.15556"
s1="$(adt "$SANDBOX/proj1" device-acquire --slug h 2>/dev/null | tail -n 1)"
sleep 1
adt "$SANDBOX/proj1" install --slug h -- true >/dev/null 2>&1
for n in 1 2; do flow "$SANDBOX/proj1" h "items/f$n.yaml" auto-mobile; done
adt "$SANDBOX/proj1" run --slug h --driver auto-mobile >/dev/null 2>"$SANDBOX/err"
expect_code "a second emulator still booting when the flows start is stopped, and the run passes" 0 $?
expect_true "  (the script says so)" grep -q "the second emulator emulator-15556 has not finished booting; stopping it" "$SANDBOX/err"
expect_eq "  (every flow ran on the first)" "2" "$(grep -c "device=$s1 " "$FAKE_ADT_STATE/automobile.calls")"
sleep 2
expect_eq "  (and its boot is not retried elsewhere)" "2 $s1" "$(boots) $(ls "$ADT_HOME/leases")"
adt "$SANDBOX/proj1" device-release --slug h >/dev/null 2>&1
rm -f "$FAKE_ADT_STATE/mode.port.15556"
unset ADT_SECOND_BOOT_WAIT_S

setup
export ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=16384 ADT_MEM_AVAILABLE_MB=6000
adt "$SANDBOX/proj1" device-acquire --slug r >/dev/null 2>"$SANDBOX/err"
sleep 2
expect_eq "with too little memory, no second emulator boots" "1" "$(boots)"
expect_true "  (and the script says why)" grep -q "flows will run on one emulator: a second emulator needs about 7 GB, and 5 GB is free" "$SANDBOX/err"
unset ADT_MEM_TOTAL_MB ADT_MEM_AVAILABLE_MB ADT_AUTOMOBILE ADT_MAESTRO
export ADT_PARALLEL=1

# ---------- preflight ----------

# preflight <project> <driver> — runs with the fake ps on PATH.
preflight() {
  (cd "$1" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" preflight --driver "$2" 2>&1)
}

echo "preflight"
setup
mkdir -p "$SANDBOX/bin"
ln -s "$SHIMS/ps" "$SANDBOX/bin/ps"
# The pinned version is read from the command, as with the real default.
export ADT_AUTOMOBILE="$SHIMS/auto-mobile @kaeawc/auto-mobile@0.0.84" ADT_MAESTRO="$SHIMS/maestro"
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "a ready machine passes" 0 $rc
expect_true "  (it names the AVD it will boot)" grep -q '^ok    AVD: Pixel_A' <<EOF
$out
EOF
expect_true "  (and recommends setting ADT_AVD)" grep -q '^warn  ADT_AVD is not set' <<EOF
$out
EOF
expect_eq "preflight leases and boots nothing" "0 " "$(boots) $(ls "$ADT_HOME/leases" 2>/dev/null)"
expect_true "  (and says whether flows can run on two emulators)" grep -q '^ok    flows can run on two emulators' <<EOF
$(ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=65536 ADT_MEM_AVAILABLE_MB=60000 preflight "$SANDBOX/proj1" auto-mobile)
EOF
expect_true "  (or why not)" grep -q '^ok    flows will run on one emulator: a second emulator needs' <<EOF
$(ADT_PARALLEL=2 ADT_MEM_TOTAL_MB=16384 ADT_MEM_AVAILABLE_MB=6000 preflight "$SANDBOX/proj1" auto-mobile)
EOF

echo "running 0.0.80" > "$FAKE_ADT_STATE/daemon"
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "an auto-mobile service on another version fails preflight" 16 $rc
expect_true "  (and says how to fix it)" grep -q 'runs 0.0.80, but the pipeline uses' <<EOF
$out
EOF
ADT_AUTOMOBILE="$SHIMS/auto-mobile" preflight "$SANDBOX/proj1" auto-mobile > /dev/null
expect_code "  (a command with no pinned version skips the version check)" 0 $?

echo "not-running" > "$FAKE_ADT_STATE/daemon"
echo "56825 /opt/homebrew/bin/bun /tmp/auto-mobile/dist/src/index.js --daemon-mode --daemon-socket-path=x" > "$FAKE_ADT_STATE/ps"
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "a service this version cannot reach fails preflight" 16 $rc
expect_true "  (and names the PID to stop)" grep -q 'Stop it with: kill 56825' <<EOF
$out
EOF
: > "$FAKE_ADT_STATE/ps"
echo db > "$FAKE_ADT_STATE/daemon-start"
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "a service that cannot start fails preflight" 16 $rc
expect_true "  (with the way out for a broken database)" grep -q 'mv ~/.auto-mobile/auto-mobile.db ~/.auto-mobile/auto-mobile.db.bak' <<EOF
$out
EOF
echo ok > "$FAKE_ADT_STATE/daemon-start"
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "no service running yet: preflight starts it" 0 $rc
expect_true "  (and says so)" grep -q '^ok    auto-mobile: started its background service' <<EOF
$out
EOF

export ADT_AVD=Nope
preflight "$SANDBOX/proj1" auto-mobile > /dev/null
expect_code "an unknown ADT_AVD fails preflight" 16 $?
export ADT_AVD=Pixel_A
attach emulator-5554 Pixel_A
preflight "$SANDBOX/proj1" auto-mobile > /dev/null
expect_code "an ADT_AVD open in normal mode fails preflight" 16 $?
unset ADT_AVD
attach emulator-5556 Pixel_B
out="$(preflight "$SANDBOX/proj1" auto-mobile)"; rc=$?
expect_code "every AVD open, even with a device attached, fails preflight" 16 $rc
expect_true "  (naming the device, and how to opt in)" grep -q '^FAIL  every AVD is open in normal mode.*ADT_DEVICE_MODE=reuse to test on an attached device such as emulator-5554' <<EOF
$out
EOF
rm -f "$FAKE_ADT_STATE/dev/emulator-5554" "$FAKE_ADT_STATE/dev/emulator-5556"
: > "$FAKE_ADT_STATE/avds"
preflight "$SANDBOX/proj1" auto-mobile > /dev/null
expect_code "no AVD and no device fails preflight" 16 $?
printf 'Pixel_A\n' > "$FAKE_ADT_STATE/avds"

ADT_AUTOMOBILE=/nonexistent/bunx preflight "$SANDBOX/proj1" auto-mobile > /dev/null
expect_code "a missing auto-mobile command fails preflight" 16 $?
preflight "$SANDBOX/proj1" maestro > /dev/null
expect_code "Maestro 2.11.0 passes" 0 $?
echo "2.9.1" > "$FAKE_ADT_STATE/maestro.version"
preflight "$SANDBOX/proj1" maestro > /dev/null
expect_code "Maestro older than 2.11.0 fails preflight" 16 $?
ADT_MAESTRO=/nonexistent/maestro preflight "$SANDBOX/proj1" maestro > /dev/null
expect_code "a missing Maestro fails preflight" 16 $?
expect_true "with no permission rules anywhere, preflight says how to add them" grep -q "^warn  in Claude Code, the pipeline's own commands are not pre-approved" <<EOF
$(CLAUDECODE=1 preflight "$SANDBOX/proj1" maestro)
EOF
expect_true "  (for the folder it runs in)" grep -q "allow --project $SANDBOX/proj1\$" <<EOF
$(CLAUDECODE=1 preflight "$SANDBOX/proj1" maestro)
EOF
expect_true "  (but not in another tool, where the rules mean nothing)" sh -c "! grep -q 'not pre-approved' <<EOF
$(unset CLAUDECODE; preflight "$SANDBOX/proj1" maestro)
EOF"
adt "$SANDBOX/proj1" allow >/dev/null 2>&1
expect_true "after allow, that warning is gone" sh -c "! grep -q 'not pre-approved' <<EOF
$(CLAUDECODE=1 preflight "$SANDBOX/proj1" maestro)
EOF"
serial="$(adt "$SANDBOX/proj1" device-acquire --slug old 2>/dev/null | tail -n 1)"
out="$(CODEX_THREAD_ID=t1 preflight "$SANDBOX/proj2" maestro)"
expect_true "in Codex, with no Codex rule, preflight says how to add one" grep -q "^warn  in Codex, the pipeline's own commands are not pre-approved.*allow --project $SANDBOX/proj2, then start a new Codex session\$" <<EOF
$out
EOF
expect_true "  (and not the Claude Code warning)" sh -c "! grep -q 'in Claude Code' <<EOF
$out
EOF"
adt "$SANDBOX/proj2" allow >/dev/null 2>&1
expect_true "after allow, that warning is gone" sh -c "! grep -q 'not pre-approved' <<EOF
$(CODEX_THREAD_ID=t1 preflight "$SANDBOX/proj2" maestro)
EOF"
adt "$SANDBOX/proj2" allow --remove >/dev/null 2>&1
mkdir -p "$CODEX_HOME/rules"
printf 'prefix_rule(pattern = ["bash", ".claude/adt/scripts/adt.sh"], decision = "allow")\n' > "$CODEX_HOME/rules/default.rules"
expect_true "  (a rule in the user's own Codex rules counts too)" sh -c "! grep -q 'not pre-approved' <<EOF
$(CODEX_THREAD_ID=t1 preflight "$SANDBOX/proj2" maestro)
EOF"
rm -rf "$CODEX_HOME/rules"
out="$(CODEX_THREAD_ID=t1 CODEX_SANDBOX_NETWORK_DISABLED=1 preflight "$SANDBOX/proj1" maestro)"; rc=$?
expect_code "run inside Codex's sandbox, preflight fails" 16 $rc
expect_true "  (and says how to approve the script, or give Codex full access)" grep -q "^FAIL  Codex runs this script in its sandbox.*allow --project $SANDBOX/proj1, then start a new Codex session. Or give Codex full access" <<EOF
$out
EOF
CODEX_SANDBOX=seatbelt preflight "$SANDBOX/proj1" maestro > /dev/null
expect_code "  (macOS's Codex sandbox too)" 16 $?
expect_eq "a device leased minutes ago is not called a leftover" "0" "$(preflight "$SANDBOX/proj1" maestro | grep -c 'has been running for')"
echo $(( $(date +%s) - 4 * 3600 )) > "$ADT_HOME/leases/$serial/created"
expect_true "one leased hours ago is, with the command that stops it" grep -q "^warn  $serial has been running for 4h for 'old'.*device-release --serial $serial\$" <<EOF
$(preflight "$SANDBOX/proj1" maestro)
EOF
unset ADT_AUTOMOBILE ADT_MAESTRO

# ---------- allow ----------

echo "allow"
setup
settings="$SANDBOX/proj1/.claude/settings.local.json"
adt "$SANDBOX/proj1" allow >/dev/null 2>&1
expect_code "allow succeeds" 0 $?
expect_eq "it writes the three rules" '["Bash(bash .claude/adt/scripts/adt.sh *)", "mcp__auto-mobile__*", "mcp__maestro__*"]' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["permissions"]["allow"]))' "$settings")"
expect_true "and keeps the new file out of git without touching .gitignore" git -C "$SANDBOX/proj1" check-ignore -q "$settings"
expect_true "  (.gitignore was not created)" [ ! -f "$SANDBOX/proj1/.gitignore" ]
before="$(cksum < "$settings")"
adt "$SANDBOX/proj1" allow >/dev/null 2>&1
expect_eq "running it again changes nothing" "$before" "$(cksum < "$settings")"
adt "$SANDBOX/proj1" allow --remove >/dev/null 2>&1
expect_true "--remove takes them out, and deletes a file that held only them" [ ! -f "$settings" ]
mkdir -p "$SANDBOX/proj1/android"
adt "$SANDBOX/proj1/android" allow >/dev/null 2>&1
expect_true "allow writes to the folder it runs in, where Claude Code reads it" [ -f "$SANDBOX/proj1/android/.claude/settings.local.json" ]
expect_true "  (and keeps that file out of git too)" git -C "$SANDBOX/proj1" check-ignore -q "$SANDBOX/proj1/android/.claude/settings.local.json"
adt "$SANDBOX/proj1/android" allow --remove >/dev/null 2>&1

mkdir -p "$SANDBOX/proj2/.claude"
printf '{"model": "opus", "permissions": {"allow": ["Bash(npm test *)", "mcp__maestro__*"]}}\n' > "$SANDBOX/proj2/.claude/settings.local.json"
adt "$SANDBOX/proj2" allow >/dev/null 2>&1
adt "$SANDBOX/proj2" allow --remove >/dev/null 2>&1
expect_eq "--remove leaves the developer's own settings and rules, even one it would have added" \
  '{"model": "opus", "permissions": {"allow": ["Bash(npm test *)", "mcp__maestro__*"]}}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$SANDBOX/proj2/.claude/settings.local.json")"
printf 'not json' > "$SANDBOX/proj2/.claude/settings.local.json"
adt "$SANDBOX/proj2" allow >/dev/null 2>&1
expect_eq "a settings file that is not valid JSON is left alone" "not json" "$(cat "$SANDBOX/proj2/.claude/settings.local.json")"

# The Codex half: a rules file that belongs to allow as a whole.
setup
rules="$SANDBOX/proj1/.codex/rules/agentic-dev-team.rules"
adt "$SANDBOX/proj1" allow >/dev/null 2>&1
expect_eq "allow writes a Codex rule that runs adt.sh outside the sandbox" \
  'prefix_rule(pattern = ["bash", ".claude/adt/scripts/adt.sh"], decision = "allow")' "$(grep '^prefix_rule' "$rules")"
expect_true "  (marked as its own on the first line)" grep -q '^# agentic-dev-team: written by adt.sh allow' "$rules"
expect_true "  (and kept out of git without touching .gitignore)" git -C "$SANDBOX/proj1" check-ignore -q "$rules"
before="$(cksum < "$rules")"
adt "$SANDBOX/proj1" allow >/dev/null 2>&1
expect_eq "running it again changes nothing" "$before" "$(cksum < "$rules")"
adt "$SANDBOX/proj1" allow --remove >/dev/null 2>&1
expect_true "--remove deletes it, and the empty .codex/ it made" [ ! -e "$SANDBOX/proj1/.codex" ]
mkdir -p "$SANDBOX/proj2/.codex/rules"
printf 'prefix_rule(pattern = ["make"], decision = "allow")\n' > "$SANDBOX/proj2/.codex/rules/agentic-dev-team.rules"
adt "$SANDBOX/proj2" allow >/dev/null 2>&1
adt "$SANDBOX/proj2" allow --remove >/dev/null 2>&1
expect_eq "a rules file of that name that is not its own is left alone" \
  'prefix_rule(pattern = ["make"], decision = "allow")' "$(cat "$SANDBOX/proj2/.codex/rules/agentic-dev-team.rules")"
# A Codex plugin install runs its own copy of the script, by its absolute path.
cached="$CODEX_HOME/plugins/cache/adt-pipeline/agentic-dev-team/local/scripts"
mkdir -p "$cached" && cp "$SCRIPT" "$cached/adt.sh"
(cd "$SANDBOX/proj1" && /bin/bash "$cached/adt.sh" allow >/dev/null 2>&1)
expect_true "from the Codex plugin, allow also allows that path" \
  grep -qF "prefix_rule(pattern = [\"bash\", \"$cached/adt.sh\"], decision = \"allow\")" "$rules"

# --only: one tool's rules, for an install of that tool alone.
setup
settings="$SANDBOX/proj1/.claude/settings.local.json"
rules="$SANDBOX/proj1/.codex/rules/agentic-dev-team.rules"
adt "$SANDBOX/proj1" allow --only claude >/dev/null 2>&1
expect_code "allow --only claude succeeds" 0 $?
expect_true "  (it writes the Claude Code rules)" [ -f "$settings" ]
expect_true "  (and no Codex rule)" [ ! -e "$SANDBOX/proj1/.codex" ]
adt "$SANDBOX/proj1" allow --only codex >/dev/null 2>&1
expect_true "allow --only codex writes the Codex rule" [ -f "$rules" ]
adt "$SANDBOX/proj1" allow --remove --only codex >/dev/null 2>&1
expect_true "--remove --only codex deletes only the Codex rule" sh -c "[ ! -e '$rules' ] && [ -f '$settings' ]"
adt "$SANDBOX/proj2" allow --only codex >/dev/null 2>&1
expect_true "allow --only codex writes no Claude Code rules" [ ! -e "$SANDBOX/proj2/.claude" ]
adt "$SANDBOX/proj1" allow --only cursor >/dev/null 2>&1
expect_code "allow --only with another name is a usage error" 2 $?

# ---------- summary ----------

teardown
echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%s\n' "$FAILED"
  exit 1
fi
