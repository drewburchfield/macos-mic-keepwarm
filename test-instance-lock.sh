#!/bin/bash
# Standalone Swift tests: only Command Line Tools required, no mic permission.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc -parse-as-library \
    "$SCRIPT_DIR/Sources/MicWarm/InstanceLock.swift" \
    "$SCRIPT_DIR/Tests/InstanceLockTests.swift" \
    -o "$TEST_BUILD_DIR/instance-lock-tests"
"$TEST_BUILD_DIR/instance-lock-tests"
