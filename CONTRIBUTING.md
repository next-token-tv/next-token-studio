# Contributing

[简体中文](CONTRIBUTING.zh-Hans.md)

Use the build and test commands in [README](README.md). Keep changes scoped, add meaningful regression coverage for audio/data-loss bugs, and use Conventional Commits. Explain user-visible behavior, validation and limitations in pull requests. Changes to covered code are contributed under AGPL-3.0-only; do not submit material you cannot license accordingly.

English is the default documentation language; Chinese siblings use `.zh-Hans.md` before the extension, for example `README.zh-Hans.md`. Update both languages together. Do not commit recordings, personal workspaces, credentials, certificates, signing teams, derived builds or private device identifiers. Use generated audio fixtures. Do not change bundled brand/portrait rights without owner authorization.

Run `bash scripts/check.sh`. Real microphone tests require a deliberate, separate session; never interrupt an active user recording to test or restart the application.
