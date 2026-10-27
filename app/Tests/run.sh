#!/bin/bash
set -e
cd "$(dirname "$0")"
BIN="${TMPDIR:-/tmp}/statemachine-tests"
swiftc ../Sources/AppConfig.swift ../Sources/StateMachine.swift ../Sources/RuleLogic.swift ../Sources/ConnLogic.swift ../Sources/RouteVerdict.swift ../Sources/NetParse.swift ../Sources/Watchdog.swift ../Sources/LeakLogic.swift ../Sources/History.swift ../Sources/ServerLogic.swift ../Sources/ExitLogic.swift ../Sources/QRCode.swift StateMachineTests.swift RoutingTests.swift ReliabilityTests.swift ServerTests.swift ExitTests.swift -o "$BIN" -parse-as-library -swift-version 5 -target arm64-apple-macos13 -lsqlite3
"$BIN"
rm -f "$BIN"
