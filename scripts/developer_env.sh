#!/bin/bash
# Select the installed Xcode for this process without changing xcode-select globally.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected_developer_dir" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
