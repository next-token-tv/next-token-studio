# Next Token Studio

原生 macOS 音频工作区，使用 SwiftUI 和 AVFoundation。支持 macOS 14 及以上版本。

## 功能

- 左侧录音资料库，右侧多轨工作区；选中录音后显示各路完整波形、统一时间刻度和同步播放游标。
- 启动应用或当前输入设备不可用时，自动选择通道数最多的多路输入；手动选择优先，开始录音或主播匹配时保留当前可用设备，不重新覆盖选择。没有多路设备时选择系统默认麦克风。通道数并列时优先上次使用的设备，其次系统默认设备；自动选择排除 BlackHole（包括系统默认或上次使用的 BlackHole）及音频引擎创建的临时聚集设备；BlackHole 仍保留在手动选择列表。显示实际输入通道数。每路独立显示最近 8 秒波形（10 ms 峰值粒度，−60 至 0 dBFS 对数显示）、通道来源和 dBFS 峰值；支持暂停、继续与停止保存。输入设备断开或配置改变时停止并保存。
- WAV（32-bit float）无损录音保留设备原始采样率和全部输入通道，通道名称保存在同名 JSON 旁文件中；兼容已有 CAF 和 M4A 录音。回放直接分块读取原始文件，实时混合全部通道，不生成混音文件，总峰值过高时统一衰减以防削波，原始录音保持不变。
- 播放器支持播放、暂停、回到开头、进度拖动及点击任意轨道波形定位；空格键控制播放与暂停。
- 导出分轨 WAV：每个输入通道生成一个单声道 32-bit float WAV，保留原始采样率、完整时长与静音段；文件名为 `host-ch01.wav` 等，并附带 `channels.json` 通道来源表，适用于 NextToken 的分轨转写与后期流程。
- 导出混音 M4A：全部通道按回放规则混合，输出 AAC-LC、48 kHz、双声道，目标码率 320 kbps。此导出不包含片头片尾编辑或响度母带处理。导出在后台执行，可取消；默认保存到工作文件夹的 `exports/`，完成后可在 Finder 中定位。
- 支持工具栏删除、右键「移到废纸篓」和 ⌘⌫。音频与通道信息一起移到废纸篓，删除正在回放的录音会先停止播放；录音期间不可删除。
- 首次录音请求麦克风授权。工作文件夹为 `~/Documents/Next Token Studio`，首次通过系统文件夹选择器授权，后续以安全作用域书签恢复访问。旧沙盒中的录音及通道资料迁移至 `recordings/`，同名冲突不会覆盖。

分轨文件保留共同的录音时间起点。通道编号不代表说话人身份，后期需确认通道与人物的对应关系。新录音保存为多通道 WAV；每段音频数据达到 3.9 GB 时自动续写下一段（`.part-002.wav` 等），各段独立显示在资料库中，导出不会修改原始录音。

## 工作文件夹与主播

- `recordings/`：原始录音与通道 JSON。
- `hosts/hosts.json`：主播实体，字段为稳定唯一的 `id`、`name`、相对于 `hosts/` 的 `avatar` 路径；默认包含杨攀、歸藏、橘子、向阳乔木。
- `hosts/avatars/`：本地头像。默认图片来自 NextToken 网站人物库。
- `exports/`：WAV 分轨与 M4A 混音输出，使用唯一文件名。
- `cache/`：持久保存每路最多 1600 个峰值的只读波形，重复打开和重启后直接复用；源文件大小或修改时间变化、缓存损坏时重建，删除录音时清理对应缓存。缓存可删除并自动重建。M4A 编码临时文件在完成或取消后清理。

主播资料直接编辑 JSON，App 不提供添加和编辑表单。回到前台或点击刷新时重新读取；无效 JSON、重复 ID、缺失或无效头像会显示错误并保留上次成功加载的名单。初始化不覆盖已有资料。主播列表提供「匹配麦克风」入口，打开后使用系统中文语音识别匹配自我介绍；各位依次对自己的麦克风说「我是姓名」并停顿。每路显示电平、识别文字和主播选择，可手工调整，保存后用于新录音的通道名称与主播 ID 标注。匹配不在每次开始录音前弹出，也不影响未匹配时直接录音。

录音和主播数据保存在工作文件夹，macOS 授权书签及设备偏好由系统偏好设置管理。语音识别使用 macOS Speech 框架（zh-CN），在线或设备端由系统决定，首次使用遵循系统权限提示。匹配只在该界面开启，不对正式录音后台转写，不保存匹配音频或识别文字。

### 主播颜色

`hosts.json` 的可选 `color` 字段使用 `#RRGGBB`。默认颜色与 NextToken 网站文字稿的人物配色一致：杨攀 `#318FBD`、歸藏 `#A96A00`、橘子 `#F06A31`、向阳乔木 `#171717`（来源：网站 `src/styles/global.css` 的 `--speaker-accent`）。主播列表、匹配电平和已绑定音轨使用人物颜色；回放依据录音保存的主播 ID，而非当前麦克风绑定。未绑定音轨保留默认颜色。深色模式下黑色人物标识以浅灰显示以保持可读。

### 麦克风绑定

`hosts/microphones.json` 保存每个设备 UID、通道名称顺序及通道到主播 ID 的对应关系。通道索引从 0 开始。设备 UID、通道数量或名称顺序变化时不沿用旧绑定；已删除主播的绑定不再使用。修改同一设备保留其他设备的配置，保存采用原子写入。

每位主播可在 `hosts.json` 中添加可选的 `aliases` 字符串数组，例如向阳乔木的 `["乔木"]`。系统识别结合姓名和自我介绍提示词，支持繁简转换；仅提及别人、同时出现多个姓名或多路串音接近时不自动绑定。当前是自我介绍匹配，不是声纹识别。系统误识别的名字可重说或手工选择。

同一主播最多绑定一路；手工改选会将主播移到新通道。手工选择（包括未绑定）以及已保存的绑定不会被自动识别覆盖；单路重新识别按钮解除保护。取消丢弃本次更改，保存后生效。匹配界面关闭会释放麦克风，正式录制与匹配互斥。音频片段最长 8 秒，识别串行处理，待处理队列最多 2 段。

## 应用图标

`next-token-studio/AppIcon.icon` 为 Icon Composer 分层资源，字标与橙色方点来自 NextToken 标准 SVG。默认使用米白底、黑色字标和橙色标记；深色外观使用浅色字标。系统负责圆角、材质与外观切换，应用不在运行时覆盖 Dock 图标。构建需要支持 Icon Composer 的 Xcode 26 或更新版本。

## 开发

在 Xcode 中打开 `next-token-studio.xcodeproj`，选择 My Mac 后运行。

工程使用本机已有的 Apple Development 证书，开发团队为 `ZT865R3GDR`，Debug 和 Release 均启用开发签名。App Sandbox、Hardened Runtime 和音频输入权限已启用。发行签名和公证尚未配置。

```sh
xcodebuild -project next-token-studio.xcodeproj -scheme next-token-studio -configuration Debug -derivedDataPath build build
```

快捷键：⌘R 开始录音，⇧⌘P 暂停或继续，⌘. 停止并保存。

## 验证

录音检查覆盖 44.1 / 48 kHz 下的 1、4、5 路输入，验证各路独立波形、静音通道、反相信号、暂停继续、保存后的逐样本一致性与时长。回放检查验证全部通道混音、防削波、各轨波形与时间对齐，以及源文件不被修改。导出检查覆盖 1、4、5 路输入、WAV 逐样本一致性、M4A 编码参数与各通道可听信号，以及覆盖保护和失败清理：

```sh
swiftc next-token-studio/AudioCapture.swift Tests/AudioCaptureChecks.swift -o /tmp/next-token-audio-checks
/tmp/next-token-audio-checks
swiftc next-token-studio/StreamingPlayback.swift Tests/StreamingPlaybackChecks.swift -o /tmp/next-token-stream-checks
/tmp/next-token-stream-checks
swiftc next-token-studio/PlaybackRender.swift Tests/PlaybackRenderChecks.swift -o /tmp/next-token-playback-checks
/tmp/next-token-playback-checks
swiftc next-token-studio/RecordingTrash.swift Tests/RecordingTrashChecks.swift -o /tmp/next-token-trash-checks
/tmp/next-token-trash-checks
swiftc next-token-studio/PlaybackRender.swift next-token-studio/AudioExport.swift Tests/AudioExportChecks.swift -o /tmp/next-token-export-checks
/tmp/next-token-export-checks
swiftc next-token-studio/WorkspaceData.swift Tests/WorkspaceChecks.swift -o /tmp/next-token-workspace-checks
/tmp/next-token-workspace-checks next-token-studio/WorkspaceSeed
swiftc next-token-studio/WorkspaceData.swift next-token-studio/HostBinding.swift next-token-studio/MatchingAudio.swift Tests/HostMatchingChecks.swift -o /tmp/next-token-host-checks
/tmp/next-token-host-checks
```
