# Next Token Studio 工作文件夹

- `recordings/`：原始多通道录音及同名 `.json` 通道资料。
- `hosts/hosts.json`：主播名单，按数组顺序显示。
- `hosts/avatars/`：头像文件。
- `exports/`：分轨 WAV 与混音 M4A 导出。
- `cache/`：可重新生成的音频缓存，App 空闲退出后可清理。

## 主播资料

编辑 `hosts/hosts.json` 的 `hosts` 数组即可添加、修改或删除主播。每条资料包括唯一且稳定的 `id`、显示名字 `name`、相对于 `hosts/` 的头像路径 `avatar`。头像使用 PNG 或 JPEG。不要更改已有主播的 ID；头像必须位于 `hosts/` 内。

```json
{"id": "new-host", "name": "新主播", "avatar": "avatars/new-host.png"}
```

保存后切回 App 自动重新读取，也可点击主播列表的刷新按钮。JSON 无效时保留上次成功读取的名单并显示错误。主播列表的「匹配麦克风」入口可通过中文自我介绍匹配通道，并支持手工调整；这不是声纹识别。可选字段 `aliases` 用来添加简称，例如向阳乔木的 `["乔木"]`。绑定保存在 `hosts/microphones.json`，按设备 UID 和通道顺序区分，保存后用于新录音。

默认资料和头像来自 NextToken 网站人物库：杨攀、歸藏、橘子、向阳乔木。已有 `hosts.json` 不会被默认资料覆盖。
