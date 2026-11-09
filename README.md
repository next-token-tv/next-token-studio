# Next Token Studio

[简体中文](README.zh-Hans.md)

A native macOS multitrack recorder built with SwiftUI and AVFoundation. Requires macOS 14 or later; building requires Xcode 26 or later with Icon Composer support. The application UI is currently in Chinese.

Used to record multiple Next Token podcast episodes, each approximately two hours long. These real recording sessions complement automated checks of multitrack audio, export and recovery.

## Recording and playback

- Choose an input device; manual selection is preserved. Automatic selection prefers the most input channels, excludes BlackHole and transient system aggregate devices, and otherwise falls back to the system default microphone. BlackHole remains manually selectable.
- Record every input to its own synchronized, mono, 32-bit float WAV at the device sample rate. The app displays an eight-second waveform with 10 ms peak bins, using the same amplitude scale for all tracks. Pause and resume are supported.
- A `.recording` folder contains `track-01.wav`, subsequent tracks, `tracks.json`, and recovery state. Metadata is stored beside it as JSON. At 3.9 GB per track all tracks roll over together; segments appear separately in the library and are exported separately.
- Playback streams and sums all tracks. A whole-file gain prevents playback clipping. Waveform caches contain at most 1,600 peaks per channel, not mixed audio. Legacy CAF, WAV and M4A files remain readable.
- Export individual lossless WAV tracks and `channels.json`, or a centered dual-mono M4A: identical left/right audio, AAC-LC, 48 kHz, target 320 kbps. Export is cancellable and leaves source files unchanged.
- M4A uses gated 400 ms RMS analysis (absolute gate −60 dBFS, relative gate −20 dB), a −19 dBFS active mono RMS target, and at most +12 dB gain. A 5 ms lookahead limiter with 100 ms release caps sample peaks at −2 dBFS. This is not LUFS normalization or a universal encoded true-peak guarantee. It cannot repair previously clipped audio. Playback loudness can differ from export.
- Deleting a recording requires confirmation, defaults to Cancel, and moves audio plus metadata to Trash.

## Workspace and hosts

The default workspace is `~/Documents/Next Token Studio`. On first use, authorize it through the folder picker. A security-scoped bookmark restores access. Existing sandbox recordings migrate without overwriting conflicting files.

| Path | Contents |
| --- | --- |
| `recordings/` | Original recordings and channel metadata |
| `hosts/hosts.json` | Host IDs, names, avatar paths, optional aliases and colors |
| `hosts/avatars/` | Local avatars |
| `hosts/microphones.json` | Device UID/channel-to-host bindings |
| `exports/` | Explicit WAV and M4A exports |
| `cache/` | Rebuildable waveform data |

Edit host JSON directly; stable unique IDs must not change. Avatar paths must stay inside `hosts/`. Invalid configuration preserves the last successfully loaded list. Default hosts are 杨攀, 歸藏, 橘子 and 向阳乔木. Optional `color` uses `#RRGGBB`; `aliases` accepts alternative names. Channel numbers do not establish speaker identity.

The matching screen recognizes Chinese self-introductions with macOS Speech and allows manual adjustment. It is not voiceprint identification. Device UID/channel order determines saved bindings; matching is separate from recording.

## Privacy and recovery

Recording and host data stay in the workspace. Preferences store device choices and the authorization bookmark. **Speech matching may send audio to Apple's speech recognition service**, as selected by macOS; it requests permission and runs only in the matching screen. Matching audio and transcripts are not saved by the app. No background transcription of recorded sessions occurs.

Recording uses a preallocated approximately ten-second PCM pool and a separate disk queue. UI snapshots and finalization do not wait for disk work on the main thread. The UI shows written/synchronized duration, backlog and estimated remaining disk time. Every five seconds of audio, track headers and a shared checkpoint are synchronized. This is not a maximum five-second data-loss guarantee. Low disk space, overflow, write failure and device interruption are reported; normal exit waits for saving. Idle system sleep is inhibited during recording.

Recovery preserves originals and creates aligned `.recovered.recording` copies. A bad session does not block others; corrupt journals can fall back to validated fixed-layout WAV headers. Recovery checks available space. An exclusive recovery lock prevents concurrent cleanup, and marked temporary copies from interrupted recovery are removed before retry. Unknown or legacy unmarked directories are retained for manual inspection; markers are housekeeping identifiers, not a security boundary for hostile workspaces. Do not edit the workspace while recovery runs.

## Build and test

Open `next-token-studio.xcodeproj`. For a runnable signed build, choose your own development team under Signing & Capabilities and a bundle identifier you control. Do not commit personal signing changes or certificates. Apple permissions must be tested with that signed build.

Credential-free compilation (not a signed distribution artifact):

```sh
xcodebuild -project next-token-studio.xcodeproj -scheme next-token-studio -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
bash scripts/check.sh
```

CI runs the same unsigned build and regression suite on `macos-26`, with read-only repository permissions and no signing secrets. It does not access live microphones or publish binaries. The suite covers 1/4/5 tracks, 44.1/48 kHz, exact WAV samples, playback, AAC exports, failed-export cleanup, overflow, write errors, device interruption, recovery and repeated SIGKILL during recovery. Local passing tests do not establish hosted CI success.

The optional accelerated three-hour/5-track test writes about 10.368 GB and needs roughly 15.4 GB free. It drains the queue between generated audio seconds and is not a real-time hardware soak:

```sh
swiftc -O next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/LongRecordingChecks.swift -o /tmp/next-token-long-checks
/tmp/next-token-long-checks
```

Shortcuts: ⌘R record, ⇧⌘P pause/resume, ⌘. stop/save, Space playback, ⌘⌫ confirm deletion.

## License and participation

Code, tests, scripts and documentation are **AGPL-3.0-only**, except material explicitly excluded in [NOTICE](NOTICE.md). The four host portraits and Next Token branding belong to **Next Token 词元之外** and are not licensed under AGPL. The official English [LICENSE](LICENSE) is authoritative; Chinese documentation is explanatory, not a replacement license.

Read [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md), and [RELEASING](RELEASING.md). Public source availability does not imply that an officially signed/notarized binary has been released.
