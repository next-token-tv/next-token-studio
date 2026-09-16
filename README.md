# Next Token Studio

原生 macOS 音频工作区，使用 SwiftUI 和 AVFoundation。支持 macOS 14 及以上版本。

## 功能

- 系统侧边栏、工具栏和「录音」菜单。
- 可选麦克风输入、最近 8 秒实时波形、暂停、继续与停止保存；输入设备断开或配置改变时停止并保存。
- AAC / 48 kHz 单声道 M4A 录音、本地资料库、回放和导出。播放器支持暂停、继续、时间显示和进度拖动。
- 首次录音请求麦克风授权。录音保存在应用沙盒的 Application Support/NextTokenStudio/Recordings 中。

## 开发

在 Xcode 中打开 `next-token-studio.xcodeproj`，选择 My Mac 后运行。

工程使用本机已有的 Apple Development 证书，开发团队为 `ZT865R3GDR`，Debug 和 Release 均启用开发签名。App Sandbox、Hardened Runtime 和音频输入权限已启用。发行签名和公证尚未配置。

```sh
xcodebuild -project next-token-studio.xcodeproj -scheme next-token-studio -configuration Debug -derivedDataPath build build
```

快捷键：⌘R 开始录音，⇧⌘P 暂停或继续，⌘. 停止并保存。

## 验证

合成音频检查覆盖 44.1 / 48 kHz 双声道输入转换、波形幅度与历史长度、暂停继续，以及保存后的格式和时长：

```sh
swiftc next-token-studio/AudioCapture.swift Tests/AudioCaptureChecks.swift -o /tmp/next-token-audio-checks
/tmp/next-token-audio-checks
```
