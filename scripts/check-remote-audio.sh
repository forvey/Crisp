#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/audio-evidence
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -std=c11 -fblocks -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework CoreAudio -framework CoreFoundation AudioDriver/CrispRemoteMicrophone.c \
    Tests/RemoteAudio/AudioDriverTests.c -o build/audio-evidence/driver-tests
build/audio-evidence/driver-tests | tee build/audio-evidence/driver-tests.txt
CONTROLLER="${CRISP_CONTROLLER_SOURCE:-$ROOT/build/audio-evidence/controller}"
if [ ! -f "$CONTROLLER/Sources/ScreenSharingEnhancer/AudioWire.swift" ]; then
    echo "Set CRISP_CONTROLLER_SOURCE to the ScreenSharingEnhancer checkout for actual-client interoperability tests." >&2
    exit 2
fi
git -C "$CONTROLLER" rev-parse HEAD > build/audio-evidence/controller-revision.txt
# Both independent repositories carry the diagnostics schema; prevent drift before
# the test links the server's copy with the controller's actual implementation.
cmp Crisp/Models/LagData.swift "$CONTROLLER/Sources/ScreenSharingEnhancer/LagData.swift"
cmp Crisp/Models/LagScreenTrace.swift "$CONTROLLER/Sources/ScreenSharingEnhancer/LagScreenTrace.swift"
cmp Crisp/Models/LagQuality.swift "$CONTROLLER/Sources/ScreenSharingEnhancer/LagQuality.swift"
cmp Crisp/Models/AudioProbe.swift "$CONTROLLER/Sources/ScreenSharingEnhancer/AudioProbe.swift"
# Actual writer and streaming resampler, replacing only HAL property IPC.
xcrun swiftc -O -swift-version 6 -parse-as-library -import-objc-header AudioShared/CrispAudioShared.h \
    Crisp/Models/CrispAudioWire.swift Crisp/Models/CrispAudioResampler.swift \
    Crisp/Models/AudioProbe.swift Crisp/Models/LagData.swift Crisp/Models/LagQuality.swift \
    Crisp/Services/CrispAudioDevice.swift Tests/RemoteAudio/MicrophoneWriterTests.swift \
    -o build/audio-evidence/microphone-writer-tests
build/audio-evidence/microphone-writer-tests | tee build/audio-evidence/microphone-writer-tests.txt
# The peer project uses Swift 5.9. Compile its unchanged transport with the actual server.
xcrun swiftc -O -swift-version 5 -parse-as-library \
    Crisp/Models/CrispAudioWire.swift Crisp/Services/CrispAudioServer.swift \
    Crisp/Models/AudioProbe.swift \
    Crisp/Models/LagData.swift Crisp/Models/LagQuality.swift \
    Crisp/Services/CrispLagSession.swift Crisp/Services/CrispLagPattern.swift Crisp/Models/LagScreenTrace.swift \
    "$CONTROLLER/Sources/ScreenSharingEnhancer/AudioWire.swift" \
    "$CONTROLLER/Sources/ScreenSharingEnhancer/LagSession.swift" \
    "$CONTROLLER/Sources/ScreenSharingEnhancer/LagMotion.swift" \
    Tests/RemoteAudio/Interop.swift Tests/RemoteAudio/LagLifecycleTests.swift \
    -o build/audio-evidence/interop
build/audio-evidence/interop "$@" | tee build/audio-evidence/interop.json
