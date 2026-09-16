# Next Token Studio

原生 macOS 音频工作区，使用 SwiftUI 和 AVFoundation。支持 macOS 14 及以上版本。

## 功能

- 左侧录音资料库，右侧多轨工作区；选中录音后显示各路完整波形、统一时间刻度和同步播放游标。
- 可选麦克风或聚集输入设备，显示实际通道数并记住所选设备。每路独立显示最近 8 秒波形、通道来源和 dBFS 峰值；支持暂停、继续与停止保存。输入设备断开或配置改变时停止并保存。
- CAF 无损录音保留设备原始采样率和全部输入通道，通道名称保存在同名 JSON 旁文件中；兼容已有 M4A 录音。回放自动混合全部通道，总峰值过高时统一衰减以防削波，原始录音保持不变。
- 播放器支持播放、暂停、回到开头、进度拖动及点击任意轨道波形定位；空格键控制播放与暂停。导出保留原始多通道音频文件。
- 支持工具栏删除、右键「移到废纸篓」和 ⌘⌫。音频与通道信息一起移到废纸篓，删除正在回放的录音会先停止播放；录音期间不可删除。
- 首次录音请求麦克风授权。录音保存在应用沙盒的 Application Support/NextTokenStudio/Recordings 中。

## 开发

在 Xcode 中打开 `next-token-studio.xcodeproj`，选择 My Mac 后运行。

工程使用本机已有的 Apple Development 证书，开发团队为 `ZT865R3GDR`，Debug 和 Release 均启用开发签名。App Sandbox、Hardened Runtime 和音频输入权限已启用。发行签名和公证尚未配置。

```sh
xcodebuild -project next-token-studio.xcodeproj -scheme next-token-studio -configuration Debug -derivedDataPath build build
```

快捷键：⌘R 开始录音，⇧⌘P 暂停或继续，⌘. 停止并保存。

## 验证

录音检查覆盖 44.1 / 48 kHz 下的 1、4、5 路输入，验证各路独立波形、静音通道、反相信号、暂停继续、保存后的逐样本一致性与时长。回放检查验证全部通道混音、防削波、各轨波形与时间对齐，以及源文件不被修改：

```sh
swiftc next-token-studio/AudioCapture.swift Tests/AudioCaptureChecks.swift -o /tmp/next-token-audio-checks
/tmp/next-token-audio-checks
swiftc next-token-studio/PlaybackRender.swift Tests/PlaybackRenderChecks.swift -o /tmp/next-token-playback-checks
/tmp/next-token-playback-checks
swiftc next-token-studio/RecordingTrash.swift Tests/RecordingTrashChecks.swift -o /tmp/next-token-trash-checks
/tmp/next-token-trash-checks
```
