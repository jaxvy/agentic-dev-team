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

# ---------- run ----------

# flow <project> <slug> <file under flows/> <driver> [fake outcome]
flow() {
  local f="$1/pipeline_artifacts/$2/flows/$3"
  mkdir -p "$(dirname "$f")"
  {
    echo "# adt:driver: $4"
    [ -n "${5:-}" ] && echo "# fake: $5"
    echo "name: $(basename "$3" .yaml)"
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
expect_true "every row links its log" [ -f "$SANDBOX/proj1/pipeline_artifacts/a/run-logs/feature-02-fail.attempt1.log" ]
row_has "  (named in the row)" "$SANDBOX/proj1" a 02-fail "| run-logs/feature-02-fail.attempt1.log |"
expect_true "the totals line counts each result" grep -q "Totals: 4 flow(s) — 1 passed, 1 failed, 1 flaky, 1 skipped" "$SANDBOX/proj1/pipeline_artifacts/a/run-results.md"

rm "$SANDBOX/proj1/pipeline_artifacts/a/flows/02-fail.yaml"
adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "with no failing flow, the run passes" 0 $?
expect_eq "and run-results.md is rewritten, not appended" "0" "$(grep -c '^| 02-fail' "$SANDBOX/proj1/pipeline_artifacts/a/run-results.md")"

flow "$SANDBOX/proj1" a 05-hang.yaml auto-mobile hang
ADT_FLOW_TIMEOUT_S=2 adt "$SANDBOX/proj1" run --slug a --driver auto-mobile >/dev/null 2>&1
expect_code "a flow that hangs fails the run" 1 $?
row_has "with a timeout as its failing step" "$SANDBOX/proj1" a 05-hang "| FAIL | timed out after 2s |"

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
row_has "FAIL, with the report's failure message" "$SANDBOX/my project" m 02-fail "| FAIL | Assertion is false: id: order_confirmation_title is visible |"
row_has "FLAKY when it passes on the retry" "$SANDBOX/my project" m 03-flaky "| FLAKY |"
row_has "an auto-mobile flow is SKIPPED in a Maestro run" "$SANDBOX/my project" m 04-automobile "| SKIPPED | written for auto-mobile |"
unset ADT_AUTOMOBILE ADT_MAESTRO

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

echo "promote"
tiered "$SANDBOX/proj1" f checkout/no-tier auto-mobile none
tiered "$SANDBOX/proj1" f checkout/flaky auto-mobile p1 flaky
tiered "$SANDBOX/proj1" f cart/add-item auto-mobile p1 fail
rm -f "$SANDBOX/proj1/e2e/flows/cart/broken.yaml"
adt "$SANDBOX/proj1" run --slug f --driver auto-mobile --area checkout:p1,p2 --area cart:p1 >/dev/null 2>&1
out="$(adt "$SANDBOX/proj1" promote --slug f --remove checkout/offline --remove cart/empty-cart 2>/dev/null)"
expect_code "promote succeeds" 0 $?
expect_true "a new passing flow with a tier is added" [ -f "$SANDBOX/proj1/e2e/flows/checkout/receipt.yaml" ]
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

# ---------- summary ----------

teardown
echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed:%s\n' "$FAILED"
  exit 1
fi
