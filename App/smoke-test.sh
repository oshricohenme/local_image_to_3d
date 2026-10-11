#!/bin/sh
# Launch smoke test (spec §14): runs the built app on a throwaway working directory and passes once
# the sidebar is on screen. Nothing is written outside the temp folder: the workdir and the setup flag
# come in on the command line (UserDefaults reads them without saving), and CFFIXED_USER_HOME sends
# AppKit's own preference writes (window and split-view frames) to the temp folder.
# Usage: App/smoke-test.sh path/to/Lift.app
set -eu
app="$1"
tmp="$(mktemp -d)"
mkdir -p "$tmp/home"
CFFIXED_USER_HOME="$tmp/home" "$app/Contents/MacOS/Lift" -LiftSmokeTest YES -workdir "$tmp/workdir" -setupDone YES \
    -ApplePersistenceIgnoreState YES > "$tmp/smoke.log" 2>&1 &
pid=$!
n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 90 ]; do sleep 1; n=$((n + 1)); done
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "FAIL: Lift was still running after 90 s"; cat "$tmp/smoke.log"; exit 1
fi
wait "$pid" || { echo "FAIL: Lift exited with $?"; cat "$tmp/smoke.log"; exit 1; }
if grep -q "LIFT_SMOKE sidebar: Generate, Queue, History, Models, Settings" "$tmp/smoke.log"; then
    echo "PASS: $(grep LIFT_SMOKE "$tmp/smoke.log")"
    echo "temp folder: $tmp"
else
    echo "FAIL: no sidebar line"; cat "$tmp/smoke.log"; exit 1
fi
