#!/usr/bin/env bash
# Builds and runs tests/CoreTests.swift against app/Core.swift.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/build"
swiftc -swift-version 5 -parse-as-library -o "$HERE/build/core-tests" \
    "$HERE/app/Core.swift" "$HERE/tests/CoreTests.swift"
"$HERE/build/core-tests"
