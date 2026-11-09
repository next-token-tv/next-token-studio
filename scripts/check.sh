#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
src=next-token-studio
reader=("$src/RecordingAudioReader.swift")
capture=("${reader[@]}" "$src/RecordingRecovery.swift" "$src/AudioCapture.swift")
run() {
 local name=$1; shift
 swiftc -O "$@" "Tests/$name.swift" -o "$bin/$name"
 "$bin/$name"
}
run AudioCaptureChecks "${capture[@]}"
run InputSelectionChecks "${capture[@]}"
run RecordingRecoveryChecks "${capture[@]}"
run RecoveryRestartChecks "${capture[@]}"
run CaptureResilienceChecks "${capture[@]}"
run RecordingTrashChecks "$src/RecordingTrash.swift"
run PlaybackRenderChecks "${reader[@]}" "$src/PlaybackRender.swift"
run StreamingPlaybackChecks "${reader[@]}" "$src/StreamingPlayback.swift"
run ExportMixChecks "${reader[@]}" "$src/ExportMix.swift"
run AudioExportChecks "${reader[@]}" "$src/ExportMix.swift" "$src/AudioExport.swift"
run SplitRecordingChecks "${capture[@]}" "$src/PlaybackRender.swift" "$src/ExportMix.swift" "$src/AudioExport.swift" "$src/WaveformAmplitude.swift"
swiftc -O "$src/WorkspaceData.swift" Tests/WorkspaceChecks.swift -o "$bin/WorkspaceChecks"
"$bin/WorkspaceChecks" "$src/WorkspaceSeed"
run HostMatchingChecks "$src/WorkspaceData.swift" "$src/HostBinding.swift" "$src/MatchingAudio.swift"
