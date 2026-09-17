# Next Token Studio

原生 macOS 音频工作区，使用 SwiftUI 和 AVFoundation。支持 macOS 14 及以上版本。

## 功能

- 左侧录音资料库，右侧多轨工作区；选中录音后显示各路完整波形、统一时间刻度和同步播放游标。
- 可选麦克风或聚集输入设备，显示实际通道数并记住所选设备。每路独立显示最近 8 秒波形（10 ms 峰值粒度，−60 至 0 dBFS 对数显示）、通道来源和 dBFS 峰值；支持暂停、继续与停止保存。输入设备断开或配置改变时停止并保存。
- CAF 无损录音保留设备原始采样率和全部输入通道，通道名称保存在同名 JSON 旁文件中；兼容已有 M4A 录音。回放自动混合全部通道，总峰值过高时统一衰减以防削波，原始录音保持不变。
- 播放器支持播放、暂停、回到开头、进度拖动及点击任意轨道波形定位；空格键控制播放与暂停。
- 导出分轨 WAV：每个输入通道生成一个单声道 32-bit float WAV，保留原始采样率、完整时长与静音段；文件名为 `host-ch01.wav` 等，并附带 `channels.json` 通道来源表，适用于 NextToken 的分轨转写与后期流程。
- 导出混音 M4A：全部通道按回放规则混合，输出 AAC-LC、48 kHz、双声道，目标码率 320 kbps。此导出不包含片头片尾编辑或响度母带处理。导出在后台执行，可取消；默认保存到工作文件夹的 `exports/`，完成后可在 Finder 中定位。
- 支持工具栏删除、右键「移到废纸篓」和 ⌘⌫。音频与通道信息一起移到废纸篓，删除正在回放的录音会先停止播放；录音期间不可删除。
- 首次录音请求麦克风授权。工作文件夹为 `~/Documents/Next Token Studio`，首次通过系统文件夹选择器授权，后续以安全作用域书签恢复访问。旧沙盒中的录音及通道资料迁移至 `recordings/`，同名冲突不会覆盖。

分轨文件保留共同的录音时间起点。通道编号不代表说话人身份，后期需确认通道与人物的对应关系。内部录音仍保存为多通道 CAF，导出不会修改原始录音。

## 工作文件夹与主播

- `recordings/`：原始录音与通道 JSON。
- `hosts/hosts.json`：主播实体，字段为稳定唯一的 `id`、`name`、相对于 `hosts/` 的 `avatar` 路径；默认包含杨攀、歸藏、橘子、向阳乔木。
- `hosts/avatars/`：本地头像。默认图片来自 NextToken 网站人物库。
- `exports/`：WAV 分轨与 M4A 混音输出，使用唯一文件名。
- `cache/`：回放和编码中间音频，正常完成或取消后清理。

主播资料直接编辑 JSON，App 不提供添加和编辑表单。回到前台或点击刷新时重新读取；无效 JSON、重复 ID、缺失或无效头像会显示错误并保留上次成功加载的名单。初始化不覆盖已有资料。主播当前不自动绑定麦克风，也不自动识别说话人。

录音和主播数据保存在工作文件夹，macOS 授权书签及设备偏好由系统偏好设置管理。Speech 语音识别尚未接入。

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
swiftc next-token-studio/PlaybackRender.swift Tests/PlaybackRenderChecks.swift -o /tmp/next-token-playback-checks
/tmp/next-token-playback-checks
swiftc next-token-studio/RecordingTrash.swift Tests/RecordingTrashChecks.swift -o /tmp/next-token-trash-checks
/tmp/next-token-trash-checks
swiftc next-token-studio/PlaybackRender.swift next-token-studio/AudioExport.swift Tests/AudioExportChecks.swift -o /tmp/next-token-export-checks
/tmp/next-token-export-checks
swiftc next-token-studio/WorkspaceData.swift Tests/WorkspaceChecks.swift -o /tmp/next-token-workspace-checks
/tmp/next-token-workspace-checks next-token-studio/WorkspaceSeed
```
