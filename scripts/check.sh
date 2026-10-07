#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
# Some Command Line Tools releases ship the new SwiftUI SDK without its macro
# plugin. Use the installed 26.5 SDK for the macOS-only shared-view compile.
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    args+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
    plugin=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
    if [[ -f "$plugin" ]]; then args+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
fi
swift test "${args[@]}"
plutil -lint App/Info.plist Inkstone.xcodeproj/project.pbxproj
