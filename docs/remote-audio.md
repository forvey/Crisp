# Crisp 远程音频（线协议 v1）

这是 forvey/Crisp 中的可选音频服务。入口在 **Crisp → 设置 → 扬声器**，与其他设置一样只有一行开关。
每次启动默认关闭，需用户启用。正常时不另开窗口，不显示 IP、组件安装/卸载或刷新按钮；只在开启后显示连接状态，出错时显示原因。麦克风由主控的“麦克风”开关控制，不自动恢复。
mini 服务端不主动连接。MacBook 的共享增强 0.4.5 在用户打开“扬声器”或“麦克风”时，
从原生屏幕共享当前打开的连接文档中选择唯一目标或仍有效的已选目标，多目标时由用户选择。
不要求手填 IP，不主动恢复断线音频或麦克风。0.4.0 的兼容客户端仍可手填地址连接。
0.4.5 的下行播放器保留 60 ms 音频再起播，约 100 ms 应用队列上限不变；麦克风上行未加此预缓冲。
当前主控参考仓库为 <https://github.com/forvey/ScreenSharingEnhancer>，验证使用的提交见
`build/audio-evidence/controller-revision.txt` 和 [验证记录](remote-audio-validation.md)。

## 两条音频路由

```text
MacBook 麦克风 → TCP PCM16/24k → Crisp 软件重采样 → HAL 虚拟输入 → 企业微信
mini 应用播放 → CoreAudio process tap → Crisp 软件重采样 → TCP PCM16/24k → MacBook 耳机
```

Crisp 不监听网络麦克风到本地扬声器。虚拟设备只有输入流，没有输出流；下行 tap 只取
应用的播放输出，并在可用时排除 Crisp 进程。代码不设置默认输入、默认输出或企业微信的
设备选择。企业微信中的 **远程麦克风** 由用户明确选择。用户应在 MacBook
使用耳机；这条路由不包含完整声学回声消除，应用主动监听麦克风或远端通话回声仍需另行处理。

## API、版本与权限

mini 当前核实为 macOS 27.0、arm64。Crisp 本体仍支持 macOS 14.0；音频服务要求
**macOS 14.2+**，使用公开的 `AudioHardwareCreateProcessTap` / `CATapDescription`
和私有 aggregate device 的输入 IOProc。这里的 private 指设备仅对本进程可见，不是私有 API。
不使用 ScreenCaptureKit，不创建或发送视频，不接管键盘、鼠标或剪贴板。

tap 为 mono global output mix，`muteBehavior = unmuted`。不在 aggregate 中加入实体麦克风
subdevice；输出设备或其采样率、tap 格式改变后，当前连接关闭，界面要求手动重连。
首次有效连接才创建 tap 并可能申请“系统音频录制”权限。拒绝、API 失败或持续三秒没有采集
回调都会报错并断开，不能用无限静音表示成功。没有应用播放时，正常采集到的静音仍按节奏发送。

本体声明 `NSAudioCaptureUsageDescription`、`NSLocalNetworkUsageDescription` 和 hardened
runtime 的 `com.apple.security.device.audio-input` entitlement。声明本身不授予录音权限。
mini 不需要打开实体麦克风；MacBook 麦克风授权由主控在用户显式开启麦克风时申请。
软件与合成测试不使用这些权限。真实下行试听在用户已开启的音频会话中进行，未另开录音或保存用户音频。

参考：[Apple process tap](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)、
[Apple AudioServerPlugIn](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)。

## 真正的虚拟麦克风

**仅收听 mini 的声音不需要安装组件**。服务可以在没有虚拟麦克风时监听、握手并发送
系统声音；直到主控显式发送 mic=1 时才检查/启动虚拟输入。组件缺失时明确报错并断开该
连接，不声称麦克风正常。主控自动重连后恢复仅收听，麦克风仍关闭。

Crisp 原来只有音量控制，没有可被别的应用选择的输入设备。已安装的 Apple Parrot HAL
组件没有可供本项目复用的公开写入接口，因此本实现不依赖或修改它。

`AudioDriver/CrispRemoteMicrophone.c` 实现标准 `AudioServerPlugInDriverInterface`：

- 设备名：`远程麦克风`。
- UID：`com.forvey.Crisp.RemoteMicrophone`。
- 安装位置：`/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver`。
- 格式：48 kHz、单声道、Float32 输入流；没有输出流。
- 输入端允许用户/应用选择为输入设备；没有输出端。代码不主动设置系统默认设备。
  1.0.0 将输入候选能力关闭的做法有误，会导致声音设置过滤设备；1.0.1 已修正。
- 应用通过 HAL 的 CFPropertyList/CFData 自定义属性写入控制和 Float32 音频。驱动不直接
  建网络连接、访问用户文件或调用客户端 HAL API；不需要辅助网络守护进程或第二个应用。

网络到虚拟设备使用连续的 `AVAudioConverter` 将 24 kHz 转为 48 kHz；下行按 tap 实际
采样率转为 24 kHz。不会仅修改采样率标签。设备端控制带本地 generation，用于丢弃旧连接的
残留写入；它不是配对密钥，不存在于网络协议中。

网络关闭麦克风或断线时清空软件缓冲并发送设备静音控制；进程退出时尝试等待静音写入最多
300 ms。插件还有 200 ms 无新数据自动清空/静音的独立保护，覆盖网络或应用崩溃。一个硬件
IO quantum 内已交付的采样不能撤回，不能将此描述成绝对零延迟静音。

## 安装、状态和卸载

完整安装包用以下命令生成（应用须先签名）：

```sh
bash scripts/package-local-install.sh /path/to/Crisp.app
```

输出目录 `build/LocalInstaller/`：

1. `Crisp.pkg`：一次系统安装同时放入 Crisp 应用和虚拟麦克风，不要求用户另装音频软件。
2. `UninstallCrisp.pkg`：退出并移除 `/Applications/Crisp.app`、本项目 HAL 组件及指向该
   应用的 crispctl 链接。先校验两个 bundle ID；保留用户偏好和显示配置，不删除个人文件。

日常菜单没有组件管理入口。卸载时使用统一卸载包；只把 `.app` 拖进废纸篓不会触发
macOS 自动清理 HAL 插件。卸载包也保存在应用资源 `RemoteAudio/UninstallCrisp.pkg`。
管理员密码由用户在 macOS 安装器中输入；安装/卸载均会短暂重启 CoreAudio，不改默认
输入/输出。内部仍打包一个组件安装载荷，用于构建流程，不作为日常界面功能。

安装路径存在不代表设备已加载。界面通过 CoreAudio 枚举 UID，并检查插件状态属性及版本，
加载失败会在使用麦克风时明确提示。已完成本机系统枚举；企业微信输入和真实听感仍需单独验收。

当前开发构建使用本地 ad-hoc 代码签名，安装包未做 Developer ID Installer 签名或公证。
它们用于本机经管理员批准的开发测试，是否能加载以本机枚举为准。正式分发应设置：

```sh
export CRISP_SIGN_ID='Developer ID Application: …'
export CRISP_AUDIO_SIGN_ID="$CRISP_SIGN_ID"
export CRISP_AUDIO_INSTALLER_SIGN_ID='Developer ID Installer: …'
```

驱动使用 Application 身份签名，`.pkg` 使用 Installer 身份签名，并分别完成 Apple 公证和
staple 后再打包分发。没有使用内核扩展、DriverKit system extension 或关闭 SIP 的方案。
驱动需要系统 HAL 目录的管理员安装权限；客户端普通用户运行 Crisp 即可。

## 固定网络协议

普通 TCP，默认端口 **49555**，TCP_NODELAY，单连接双向，最多一个活动客户端。
第二个连接直接关闭，不重置第一连接的麦克风。无 TLS、配对、登录、云转发或服务发现。
菜单只显示扬声器开关及必要的连接/麦克风状态；停止或睡眠后不自动恢复。

每条消息：`uint32_be length` + `uint8 kind` + payload。length 含 kind、不含四字节前缀，
范围 1…1024。解码器按流处理拆包/合包，仅保留一个有界消息；未知 kind、非法长度、错误
负载立即断开并显示原因。

| kind | 方向 | payload |
| --- | --- | --- |
| 0x01 | 客户端先发，服务端验证后回同样 hello | 精确 UTF-8 `SSE-CRISP-AUDIO/1 PCM_S16LE 24000 1 480`，无换行/NUL |
| 0x02 | 双向 | 960 字节 PCM_S16LE，24 kHz、mono、480 samples/20 ms |
| 0x03 | 仅客户端 → Crisp | 1 字节，0 关麦克风，1 开麦克风 |

首条不是 hello、重复 hello 或错误版本均断开。握手限时 8 秒。每次连接的麦克风初始关闭，
关闭时收到的 PCM 不进入虚拟设备；仅收到该连接的 mic=1 后放行。Mic=0 不要求持续上行
PCM，不会因此判定离线；TCP EOF/错误负责掉线判断。开启麦克风后，上行停顿约 200 ms
则清空输入，等新音频到来，不循环旧数据。

握手完成后 Crisp 只发 PCM，每 20 ms 一包；无播放时同样发送 960 字节全零。没有自定义
心跳或服务器 mic 状态消息。发送积压五条则断开提示手动重连，不批量攒整秒音频。

## 实时性与资源边界

音频实时回调只向预分配原生 Float32 ring buffer 拷贝，使用非阻塞 trylock，发生争用时丢
数据而不等待。重采样、PCM16 转换、CoreAudio 属性 IPC、TCP 均在普通工作队列进行。
虚拟设备的实时 ReadInput 也只读缓冲/补零，不分配、联网或做格式转换。

软件接收队列最多五个 20 ms 包，设备 ring 最多 4800 个 48 kHz 采样，tap ring 按原生
采样率限制在约 100 ms，下行缓存最多 2400 个 24 kHz 采样。超限丢弃最旧数据；TCP
待处理发送达到五条时断开。**这些是各应用队列的上限，不是端到端延迟保证**；TCP 内核
缓冲、系统混音、客户端播放及网络重传仍可能额外积压。

PCM 载荷每向 384 kbps、双向 768 kbps，另外有每包 5 字节头和 TCP/IP 开销。不要据此
推断真实 CPU、RSS 或键盘跟手性已经验收；相关边界见验证记录。

## 开发验证

```sh
make -o vendor check
CRISP_CONTROLLER_SOURCE=/path/to/ScreenSharingEnhancer bash scripts/check-remote-audio.sh
```

`-o vendor` 仅适用于已经准备好项目固定版本 Sparkle 的环境。正常环境用 `make check`。
第二条命令编译真实 `AudioWire.swift` / `AudioTransport`，与真实 Crisp TCP 服务在 localhost 的独立测试端口 49556
传输合成 PCM；不会调用主控 AudioIO、物理麦克风、播放器或 mini process tap。
独立端口避免干扰已经运行在正式 49555 端口的 Crisp；正式端口和线协议没有改变。

fake-host 驱动测试验证输入流属性、关闭/掉线/新 generation 静音、200 ms 超时、100 ms
溢出丢弃、同一 IO cycle 多客户端读取以及实时路径不等待锁。它不是系统安装/企业微信验收。
安装包验证另解包并核对二进制哈希、签名及打包二进制的相同 fake-host 行为。

真实验收需要用户批准组件安装、系统音频权限，并由用户在 MacBook 开启麦克风、在企业微信
选择设备。不得自动发起录音或通话。验收必须包含实际输入音量、实际耳机听音、双向无自我
回送、停止/重连后无残音，以及原生屏幕共享下音频关闭/开启的 CPU、RSS、流量与打字体验。
