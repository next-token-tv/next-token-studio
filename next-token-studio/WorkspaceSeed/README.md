# Next Token Studio workspace

[简体中文](README.zh-Hans.md)

- `recordings/`: original recordings and adjacent JSON channel metadata.
- `hosts/hosts.json`: host list, displayed in array order.
- `hosts/avatars/`: local avatar images.
- `exports/`: individual WAV and mixed M4A exports.
- `cache/`: rebuildable waveform data; remove only after the app exits while idle.

Edit the `hosts` array to add, update or remove hosts. Each entry has a stable unique `id`, display `name`, and an `avatar` path relative to `hosts/`. PNG and JPEG are supported. Do not change existing IDs; avatars must remain inside `hosts/`.

```json
{"id": "new-host", "name": "New host", "avatar": "avatars/new-host.png"}
```

Return to the app or refresh the host list to reload. Invalid JSON retains the last valid list and displays an error. The matching screen uses Chinese self-introductions and manual adjustment, not voiceprints. Optional `aliases` adds alternative names, for example `["乔木"]`. Bindings in `hosts/microphones.json` use device UID and channel order and label new recordings.

Default hosts are 杨攀, 歸藏, 橘子 and 向阳乔木, from the NextToken website. Existing `hosts.json` is never replaced by defaults. Portraits and branding belong to Next Token 词元之外 and are excluded from the code's AGPL license; see NOTICE.md in the source repository.
