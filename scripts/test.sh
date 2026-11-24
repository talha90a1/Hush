#!/bin/bash
# Runs the tests. None of them need a monitor.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

clang -O2 -framework CoreFoundation -framework CoreAudio tests/forwarding_test.c -o build/forwarding_test
build/forwarding_test

swiftc -parse-as-library App/Sources/DisplayPairing.swift App/Sources/MCCS.swift tests/pairing_test.swift -o build/pairing_test
build/pairing_test

swiftc -parse-as-library App/Sources/VolumeCurve.swift App/Sources/NightSchedule.swift App/Sources/Solar.swift tests/schedule_test.swift -o build/schedule_test
build/schedule_test
