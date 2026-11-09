# Release readiness

[简体中文](RELEASING.zh-Hans.md)

Next Token Studio has been used for multiple podcast recordings of approximately two hours each. Release checks maintain this established recording workflow as the software evolves. CI compiles an unsigned app and runs synthetic/offline checks; it neither signs, notarizes nor publishes a release. The deployment target is macOS 14, but testing on every supported OS and architecture has not been completed. Default Xcode selection on hosted runners may change; CI prints the toolchain version.

Before a public source release, review all branches/tags and release attachments for secrets and private data, confirm contributor rights and asset exclusions, and decide whether commit-author email visibility is acceptable. Local history checks do not cover remote-only references. Enable private vulnerability reporting in GitHub settings if desired.

Before distributing a binary:

1. Require hosted CI success on the exact release commit and record the Xcode/OS versions.
2. For changes to capture, buffering, disk writes or recovery, run a representative long recording with the target hardware; inspect memory, queue backlog, sample counts and continuity. Add concurrent CPU/disk load when relevant to the change.
3. Test device disconnection, sample-rate change, pause/stop/rollover boundaries, disk-full behavior and repeated crashes during recording/recovery. Actual power-loss testing remains unverified.
4. Verify permissions and first-run folder access on a clean user account; check supported macOS versions and architectures.
5. Use the distributor's Developer ID signing identity and notarization, verify the downloaded artifact, and supply corresponding source, LICENSE and asset notices. No private signing keys belong in Git.
6. State tested hardware, known issues, recovery limits and backup guidance. Freeze the tested build; do not substitute an untested last-minute binary.

When changing the signing identity or bundle identifier, permissions and workspace bookmarks may need authorization again. Do not replace a running recorder. The CI workflow deliberately has no publishing or signing credentials.
