# Next Token Studio

原生 macOS 音频工作区，使用 SwiftUI 和 AVFoundation。支持 macOS 14 及以上版本。

## 功能

- 左侧录音资料库，右侧多轨工作区；选中录音后显示各路完整波形、统一时间刻度和同步播放游标。
- 启动应用或当前输入设备不可用时，自动选择通道数最多的多路输入；手动选择优先，开始录音或主播匹配时保留当前可用设备，不重新覆盖选择。没有多路设备时选择系统默认麦克风。通道数并列时优先上次使用的设备，其次系统默认设备；自动选择排除 BlackHole（包括系统默认或上次使用的 BlackHole）及音频引擎创建的临时聚集设备；BlackHole 仍保留在手动选择列表。显示实际输入通道数。每路独立显示最近 8 秒波形（10 ms 峰值粒度，各轨共用固定幅度曲线，不按各轨峰值归一化）、通道来源和 dBFS 峰值；支持暂停、继续与停止保存。输入设备断开或配置改变时停止并保存。
- 每路输入直接录制为独立的单声道 WAV（32-bit float），保留设备原始采样率及共同时间起点，通道名称保存在同名 JSON 旁文件中；兼容已有 CAF 和 M4A 录音。回放直接分块读取原始文件，实时混合全部通道，不生成混音文件，总峰值过高时统一衰减以防削波，原始录音保持不变。
- 播放器支持播放、暂停、回到开头、进度拖动及点击任意轨道波形定位；空格键控制播放与暂停。
- 导出分轨 WAV：每个输入通道生成一个单声道 32-bit float WAV，保留原始采样率、完整时长与静音段；文件名为 `host-ch01.wav` 等，并附带 `channels.json` 通道来源表，适用于 NextToken 的分轨转写与后期流程。
- 导出混音 M4A：全部通道混合，经带门限的 RMS 电平调整及前瞻限幅，输出 AAC-LC、48 kHz、双声道，目标码率 320 kbps。此导出不包含片头片尾编辑。导出在后台执行，可取消；默认保存到工作文件夹的 `exports/`，完成后可在 Finder 中定位。
- 支持工具栏删除、右键「移到废纸篓」和 ⌘⌫；所有入口均先显示录音名称并要求确认，默认按钮为「取消」。音频与通道信息一起移到废纸篓，删除正在回放的录音会先停止播放；录音期间不可删除。
- 首次录音请求麦克风授权。工作文件夹为 `~/Documents/Next Token Studio`，首次通过系统文件夹选择器授权，后续以安全作用域书签恢复访问。旧沙盒中的录音及通道资料迁移至 `recordings/`，同名冲突不会覆盖。

分轨文件保留共同的录音时间起点。通道编号不代表说话人身份，后期需确认通道与人物的对应关系。新录音保存为 `.recording` 文件夹，内含 `track-01.wav` 等独立轨道和 `tracks.json` 清单；资料库将文件夹显示为一条录音，回放同步混合所有轨道。每路达到 3.9 GB 时全部轨道一起续写下一段文件夹，各段独立显示在资料库中，导出不会修改原始录音。

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
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/AudioCaptureChecks.swift -o /tmp/next-token-audio-checks
/tmp/next-token-audio-checks
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/StreamingPlayback.swift Tests/StreamingPlaybackChecks.swift -o /tmp/next-token-stream-checks
/tmp/next-token-stream-checks
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/PlaybackRender.swift Tests/PlaybackRenderChecks.swift -o /tmp/next-token-playback-checks
/tmp/next-token-playback-checks
swiftc next-token-studio/RecordingTrash.swift Tests/RecordingTrashChecks.swift -o /tmp/next-token-trash-checks
/tmp/next-token-trash-checks
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/PlaybackRender.swift next-token-studio/ExportMix.swift next-token-studio/AudioExport.swift Tests/AudioExportChecks.swift -o /tmp/next-token-export-checks
/tmp/next-token-export-checks
swiftc next-token-studio/WorkspaceData.swift Tests/WorkspaceChecks.swift -o /tmp/next-token-workspace-checks
/tmp/next-token-workspace-checks next-token-studio/WorkspaceSeed
swiftc next-token-studio/WorkspaceData.swift next-token-studio/HostBinding.swift next-token-studio/MatchingAudio.swift Tests/HostMatchingChecks.swift -o /tmp/next-token-host-checks
/tmp/next-token-host-checks
```

## 录音恢复与保护

分轨 WAV 由独立写入队列保存，采集回调只复制音频块；预分配约 10 秒音频缓冲（2,048 帧一块），缓冲耗尽时停止接收并标记异常中断。波形与写入状态通过独立快照读取，界面不等待磁盘队列；停止后后台排空缓冲并同步文件，保存完成前禁止开始新录音，退出等待保存结果。每 5 秒音频更新 WAV 文件头、同步各路文件并原子保存共同检查点。开始录制就写入通道及主播资料；正常停止保存最后的音频。

重新打开工作文件夹时，后台检查未完成录音，按共同安全帧数创建 `.recovered.recording` 副本，重建 WAV 文件头并对齐所有轨道。异常原文件保留，重复启动不会重复恢复。单段恢复失败不阻断其他录音，未恢复条目会提示并在下次打开时重试。检查点损坏时只使用通过固定 WAV 格式校验的文件头，不猜测原始音频格式。恢复前检查副本所需空间，按 1 MB 块复制可恢复部分。没有可用检查点或有效文件头的短录音保留原文件并提示。该机制不承诺断电、磁盘损坏或系统故障下零丢失；尚未完成检查点的尾部音频可能无法恢复。

录音期间阻止自动空闲睡眠，正常退出需要确认停止并保存。开始及检查点检查磁盘空间，低于 100 MB 时停止；输入断开、写入失败或写入队列超载也会停止并报告。

恢复故障检查：

```sh
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/RecordingRecoveryChecks.swift -o /tmp/next-token-recovery-checks
/tmp/next-token-recovery-checks
```

该检查对生成测试音频的子进程发送 SIGKILL，并验证文件头损坏、尾部长度不一致时的共同检查点恢复、原文件保留及重复恢复幂等性。


录音界面显示已写入时长、已同步时长、待写入缓冲时长和按当前采样率估算的磁盘剩余录制分钟数；剩余空间在开始及检查点更新，不是磁盘配额保证。缓冲超过 2 秒时提示写入延迟。每 5 秒音频创建检查点不代表任何故障下最多丢失 5 秒；队列积压、同步失败及硬件故障均可能扩大损失。

故障注入与长文件检查：

```sh
swiftc next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/CaptureResilienceChecks.swift -o /tmp/next-token-resilience-checks
/tmp/next-token-resilience-checks
swiftc -O next-token-studio/RecordingAudioReader.swift next-token-studio/RecordingRecovery.swift next-token-studio/AudioCapture.swift Tests/LongRecordingChecks.swift -o /tmp/next-token-long-checks
/tmp/next-token-long-checks
```

故障检查覆盖写入阻塞时快照响应、缓冲溢出、磁盘满写入错误、损坏检查点、恢复隔离和重试幂等。长文件检查加速写入 3 小时、5 路、48 kHz Float32 音频（10.368 GB），跨 11 段通过独立 AVAudioFile 读取每一路，逐样本验证内容与总帧数。测试需要至少约 15.4 GB 空闲磁盘，临时文件在正常完成时清理。该测试在每秒音频后等待写入完成，验证文件规模及分段正确性，不代替实时采集压力测试。

生产验收仍需实际四／五路设备连续 3 小时录制至少三轮，覆盖并行 CPU／磁盘负载、设备拔插、采样率变化及暂停／停止／分段边界故障；核对各轨采样数、实际音频连续性、内存及缓冲积压。真实断电和真实耗尽磁盘尚未验证。正式录制应使用通过验收的固定 Release 构建。


### M4A 导出音量

M4A 导出将全部音轨相加，使用 400 ms 窗口进行带门限的 RMS 分析，排除低于 −60 dBFS 及低于有效平均能量 20 dB 的窗口，目标为单声道有效 RMS −19 dBFS，最大提升 12 dB。此值不是 LUFS。混音经过 5 ms 前瞻、100 ms 释放的峰值限幅，采样峰值上限 −2 dBFS，为 AAC 编码留出余量；它不承诺任意素材的编码后真峰值上限。左右声道复制同一混音，48 kHz、320 kbps AAC。

该处理只应用于显式 M4A 导出。原始 WAV、分轨导出、波形缓存和应用内回放不变，回放与新版 M4A 的响度可能不同。限幅不能修复录制时已削波的信号，也不包含降噪、去串音或逐位主播的自动音量均衡。

```sh
swiftc -O next-token-studio/RecordingAudioReader.swift next-token-studio/ExportMix.swift Tests/ExportMixChecks.swift -o /tmp/next-token-mix-checks
/tmp/next-token-mix-checks
```
