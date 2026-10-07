#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/developer_env.sh
if ! xcrun --find simctl >/dev/null 2>&1; then
    echo "需要完整 Xcode 与已安装的 iOS Simulator runtime。" >&2
    exit 1
fi
mkdir -p .build
xcrun simctl list devices available -j > .build/simulator-devices.json
selection=$(python3 - "${1:-}" .build/simulator-devices.json <<'PY'
import json, sys
requested = sys.argv[1]
with open(sys.argv[2]) as stream:
    devices = [device for runtime, items in json.load(stream)['devices'].items()
               if '.iOS-' in runtime for device in items if device.get('isAvailable')]
if requested:
    matches = [d for d in devices if requested in (d['udid'], d['name'])]
else:
    phones = [d for d in devices if d['name'].startswith('iPhone')]
    matches = [d for d in phones if d['state'] == 'Booted'] or phones[:1]
if len(matches) != 1:
    sys.exit('请指定唯一的 iOS 模拟器名称或 UDID；用 xcrun simctl list devices available 查看。')
d = matches[0]
print(d['udid'] + '|' + d['name'] + '|' + d['state'])
PY
)
IFS='|' read -r device_id device_name device_state <<< "$selection"
echo "构建墨砚：$device_name"
if ! xcodebuild -project Inkstone.xcodeproj -scheme Inkstone \
    -destination "platform=iOS Simulator,id=$device_id" \
    -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build > .build/ios-build.log 2>&1; then
    tail -80 .build/ios-build.log
    exit 1
fi
if [[ "$device_state" != Booted ]]; then xcrun simctl boot "$device_id"; fi
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" .build/ios/Build/Products/Debug-iphonesimulator/Inkstone.app
xcrun simctl launch "$device_id" com.inkstone.mobile
developer_root="${DEVELOPER_DIR:-$(xcode-select -p)}"
for candidate in "$developer_root/Applications/Simulator.app" \
    "$developer_root/../Applications/Simulator.app" \
    "$developer_root/../Applications/DeviceHub.app"; do
    if [[ -d "$candidate" ]]; then
        open -a "$candidate"
        break
    fi
done
echo "已启动 $device_name 上的墨砚。构建日志：.build/ios-build.log"
