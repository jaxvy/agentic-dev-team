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
  unset ANDROID_SDK_ROOT ADT_AVD ADT_DEVICE_MODE ADT_HEADLESS ANDROID_SERIAL
  export ADT_BOOT_TIMEOUT_S=6
  export ADT_PORT_FIRST=15554
  export ADT_PORT_LAST=15560
  mkdir -p "$FAKE_ADT_STATE/dev" "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/emulator"
  ln -s "$SHIMS/adb" "$ANDROID_HOME/platform-tools/adb"
  ln -s "$SHIMS/emulator" "$ANDROID_HOME/emulator/emulator"
  export PATH="$ANDROID_HOME/platform-tools:$BASE_PATH"
  printf 'Pixel_A\nPixel_B\n' > "$FAKE_ADT_STATE/avds"
  mkdir -p "$SANDBOX/proj1" "$SANDBOX/proj2"
  git -C "$SANDBOX/proj1" init -q
  git -C "$SANDBOX/proj2" init -q
}

teardown() {
  [ -n "$SANDBOX" ] || return 0
  # Stop any fake emulator still waiting on its device file.
  rm -rf "$FAKE_ADT_STATE/dev"
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
boots() { grep -c -- '-read-only' "$FAKE_ADT_STATE/emulator.calls" 2>/dev/null || echo 0; }

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

echo "choosing the AVD"
setup
attach emulator-5554 Pixel_A
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "an AVD open in normal mode is skipped" "Pixel_B" "$(lease_file "$out" avd)"
expect_eq "your own emulator is left alone" "device" "$(device_state emulator-5554)"

setup
attach emulator-5554 Pixel_A
attach emulator-5556 Pixel_B
err="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>&1 >/dev/null)"
out="$(lease_file emulator-5554 slug)$(lease_file emulator-5556 slug)"
expect_eq "with every AVD open in normal mode, an attached device is taken" "a" "$out"
expect_true "and the script says why" grep -q 'every AVD is open in normal mode' <<EOF
$err
EOF
taken="$(ls "$ADT_HOME/leases")"
expect_eq "it is recorded as not started by adt.sh" "no" "$(lease_file "$taken" started)"
adt "$SANDBOX/proj1" device-release --slug a >/dev/null 2>&1
expect_eq "releasing it does not stop it" "device" "$(device_state "$taken")"

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
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "no AVD but a phone attached: the phone is used" "R58M123" "$out"

echo "reuse mode"
setup
export ADT_DEVICE_MODE=reuse
adt "$SANDBOX/proj1" device-acquire --slug a >/dev/null 2>&1
expect_code "reuse with nothing attached: exit 10" 10 $?
attach R58M123
out="$(adt "$SANDBOX/proj1" device-acquire --slug a 2>/dev/null | tail -n 1)"
expect_eq "reuse takes the attached device" "R58M123" "$out"
expect_eq "and boots nothing" "0" "$(boots)"
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
expect_code "install with no lease: exit 10" 10 $?
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

# ---------- summary ----------

teardown
echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%s\n' "$FAILED"
  exit 1
fi
