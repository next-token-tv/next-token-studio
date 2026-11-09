# Next Token Studio

[English](README.md)

使用 SwiftUI 和 AVFoundation 开发的原生 macOS 多轨录音软件。运行需要 macOS 14 或以上；构建需要支持 Icon Composer 的 Xcode 26 或以上。应用界面目前为中文。

**预览阶段软件：**自动测试不保证录音永不中断。真实四／五路设备在并行 CPU／磁盘负载下连续三小时的测试仍属于发布验收要求。重要录音应保留独立备份。

## 录制与回放

- 可选择输入设备，手动选择优先。自动选择输入通道最多的设备，排除 BlackHole 和系统临时聚集设备，否则回退到系统默认麦克风。BlackHole 仍可手动选择。
- 每路输入以设备原始采样率保存为独立、同步的单声道 32-bit float WAV。实时波形显示最近八秒，按 10 ms 峰值分箱，各轨采用统一幅度比例。支持暂停与继续。
- `.recording` 文件夹包含 `track-01.wav` 等轨道、`tracks.json` 和恢复状态，旁边的 JSON 保存元数据。每轨达到 3.9 GB 时全部轨道一起分段；各段在资料库中独立显示、独立导出。
- 回放直接流式读取并相加全部轨道，通过整段统一增益防止回放削波。波形缓存每轨最多 1,600 个峰值，不缓存混音。兼容旧 CAF、WAV 和 M4A。
- 可导出无损分轨 WAV 与 `channels.json`，或居中的双单声道 M4A：左右内容相同，AAC-LC、48 kHz、目标 320 kbps。导出可取消，不改变源文件。
- M4A 使用 400 ms 带门限 RMS 分析（绝对门限 −60 dBFS、相对门限 −20 dB），目标为有效单声道 RMS −19 dBFS，最多提升 12 dB。5 ms 前瞻、100 ms 释放的限幅器将采样峰值控制在 −2 dBFS。这不是 LUFS 归一化，也不保证任意素材编码后的真峰值上限；不能修复录制时已削波的音频。应用内回放响度可能与导出不同。
- 删除录音需要确认，默认取消；音频和元数据一起移至废纸篓。

## 工作文件夹与主播

默认工作文件夹为 `~/Documents/Next Token Studio`。首次通过文件夹选择器授权，以安全作用域书签恢复访问。旧沙盒录音迁移时不覆盖冲突文件。

| 路径 | 内容 |
| --- | --- |
| `recordings/` | 原始录音与通道资料 |
| `hosts/hosts.json` | 主播 ID、姓名、头像路径、可选别名和颜色 |
| `hosts/avatars/` | 本地头像 |
| `hosts/microphones.json` | 设备 UID、通道与主播的绑定 |
| `exports/` | 按需导出的 WAV 和 M4A |
| `cache/` | 可重建的波形数据 |

直接编辑主播 JSON；稳定且唯一的 ID 不应改变，头像路径必须位于 `hosts/` 内。配置无效时保留上次成功读取的名单。默认主播为杨攀、歸藏、橘子、向阳乔木。可选 `color` 为 `#RRGGBB`，`aliases` 为别名数组。通道编号不代表说话人身份。

匹配界面使用 macOS Speech 识别中文自我介绍，也可手动调整；这不是声纹识别。绑定依据设备 UID 和通道顺序保存，匹配流程独立于正式录音。

## 隐私与恢复

录音与主播资料保存在工作文件夹；偏好设置保存设备选择和授权书签。**语音匹配可能由 macOS 将音频发送给 Apple 的语音识别服务**，需要权限且仅在匹配界面运行。应用不保存匹配音频与识别文字，也不在后台转写正式录音。

录音预分配约十秒 PCM 缓冲，使用独立磁盘队列；界面读取快照和最终保存不会在主线程等待磁盘。显示已写入／已同步时长、缓冲积压和预计磁盘剩余录制时间。每五秒音频同步轨道文件头及共同检查点，这不代表最多只丢五秒。磁盘不足、溢出、写入失败及设备中断都会报告；正常退出等待保存。录音期间阻止系统自动空闲睡眠。

恢复保留原文件，创建各轨对齐的 `.recovered.recording` 副本。单段损坏不阻断其他恢复；检查点损坏时可回退到验证过的固定格式 WAV 文件头。恢复前检查磁盘空间，通过独占恢复锁避免并发清理；恢复中断遗留的带归属标记临时副本会在重试前清理。未知或旧版无标记目录保留供人工检查；标记用于临时文件管理，不是防御恶意工作文件夹的安全边界。恢复期间不要编辑工作文件夹。

## 构建与测试

打开 `next-token-studio.xcodeproj`。构建可运行的签名版本时，在 Signing & Capabilities 中选择自己的开发团队及自己控制的 Bundle ID。不要提交个人签名配置或证书。Apple 权限必须用相应签名版本实测。

无需开发凭据的编译检查（不是已签名的分发包）：

```sh
xcodebuild -project next-token-studio.xcodeproj -scheme next-token-studio -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
bash scripts/check.sh
```

CI 在 `macos-26` 上执行同样的无签名构建和回归检查，仅有仓库只读权限，不使用签名秘密、不访问真实麦克风、不发布安装包。覆盖 1／4／5 路、44.1／48 kHz、WAV 逐样本一致、回放、AAC 导出、导出失败清理、溢出、写入错误、设备中断、恢复及恢复过程中重复 SIGKILL。本地测试通过不代表托管 CI 已通过。

可选的三小时／五轨加速测试写入约 10.368 GB，需要约 15.4 GB 空闲空间。每生成一秒音频后等待写入完成，因此不是真实硬件实时长测：

```sh
swiftc -O next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/LongRecordingChecks.swift -o /tmp/next-token-long-checks
/tmp/next-token-long-checks
```

快捷键：⌘R 录音，⇧⌘P 暂停／继续，⌘. 停止保存，空格回放，⌘⌫ 确认删除。

## 许可与参与

代码、测试、脚本和文档采用 **AGPL-3.0-only**，[版权说明](NOTICE.zh-Hans.md)中明确排除的素材除外。四位主播头像和 Next Token 品牌属于 **Next Token 词元之外**，不纳入 AGPL 许可。[LICENSE](LICENSE) 中的官方英文文本为准；中文文档是说明，不替代许可证。

参见[贡献指南](CONTRIBUTING.zh-Hans.md)、[安全说明](SECURITY.zh-Hans.md)、[发布说明](RELEASING.zh-Hans.md)。公开源码不代表已经发布官方签名、公证的安装包。
