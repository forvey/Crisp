# Crisp 远程音频验证记录

软件验证：2026-10-27；系统安装验证：2026-10-28。环境：mini，macOS 27.0（26A425），arm64，Xcode 27.1。
本次交付包含此前的虚拟屏互斥、HiDPI 和分辨率恢复改动；具体提交以 Git 记录为准。

## 2026-10-28 源码交付前检查

- Crisp `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make -o vendor check` 通过：
  严格 SwiftLint、macOS 单元测试、x86_64 类型检查、310 个本地化 key 及 HAL fake-host 测试。
- 与共享增强最新传输源码进行真实 localhost 合成双向互通通过，包括握手限时、第二客户端拒绝、
  错误消息断开、关麦/掉线清空、重连默认关麦及没有虚拟输入时仍可收听。
- 首次互通检查因正式 49555 已被运行中的 Crisp 占用而未能启动测试服务；未向实际会话注入测试音频。
  合成测试现使用独立 loopback 49556，重跑通过，正式服务端口和线协议不变。
- 共享增强 0.4.5 的播放缓冲修复提交为 `7b85eef810f6ea1316563875d2c91ae36bdd7e97`，
  原输入路由、共享列表、协议及 AVAudioPlayerNode 离线播放检查通过。安装在 MacBook 主控端；
  仅这个播放修复不要求重装 mini 的 Crisp/HAL。
- 本地文件和固定连续音的真实下行试听已由用户确认仍有断点；网络存在重传/乱序。
  新主控缓冲版本尚未在真实 MacBook 试听，不能宣称断续已解决；详见 [断续诊断](remote-audio-stutter-20261028.md)。
- 记录位于 `build/audio-evidence/publish-check-20261028.log`、`publish-interop-20261028.log`
  和 `stutter-20261028/`，这些本机生成证据由 Git 忽略。下文较早状态均为当时验证快照。

## 2026-10-28 菜单精简及统一安装包

已更新本机 `forvey/sound-menu-audio-20261028-115843`。原来的独立音频窗口已删除，
设置菜单只保留“扬声器”开关。开启后按需显示连接/麦克风状态，麦克风开关留在共享增强。
没有组件管理菜单、IP 列表、安装/卸载/刷新按钮。系统设备名称仍是用户指定的“远程麦克风”。

- Release 构建、严格 SwiftLint 及 310 个本地化 key 检查通过；这轮未改音频线协议。
- 已从安装后的 zh-Hans 资源确认“扬声器”和“麦克风已开启”标签，显示配置未改，
  当前依然是 3440×1440 HiDPI、60Hz；安装后的组件仍被系统正常枚举。
- 机器可读记录为 `build/audio-evidence/menu-update-20261028.json`。原生 UI 自动化在读取
  Crisp 状态栏应用时返回 ScreenCaptureKit -3811，未取得更新后的菜单截图，也未为验证
  UI 而启用真实声音采集；不能将资源/构建检查称为实际界面或声音验收。
- `scripts/package-local-install.sh` 已生成 `build/LocalInstaller/Crisp.pkg`，解包后确认同时
  携带主程序与 HAL 驱动，包内应用签名通过，驱动返回正确名称/UID。统一安装包尚未在
  本机重复执行，以免为界面更新再次重启 CoreAudio。
- `UninstallCrisp.pkg` 会一并清理应用和组件，保留用户偏好；已对包内脚本执行 dry-run，
  没有实际卸载。移除组件管理不等于在退出应用时删除驱动。

本轮更新前备份：
`/Users/cd03/Documents/Codex/2026-10-14/uu-betterdisplay-uu/work/crisp-install/audio-20261028-115843/`。

## 2026-10-28 输入列表为空：修复安装完成

用户截图及系统设置 AX 均显示“未找到音频输入设备”，而 CoreAudio 底层能枚举到设备、
一个输入通道且未隐藏。实际查询旧驱动 `inputSelectable=false`。原因是 1.0.0 为避免主动
切换默认设备，错误地把输入端 `kAudioDevicePropertyDeviceCanBeDefaultDevice` 设成了 0。
Apple SDK 明确该值表示可被选择为输入/输出候选，不是自动切换请求。之前的“已枚举”
验证没有覆盖系统设置是否可选择，不能将此前安装成功视为完整输入功能验收。

- 1.0.1 将输入端候选设为 1，输出端/系统声音输出仍为 0；没有增加默认设备 setter。
- 回归检查覆盖真实驱动 factory 的输入可选/输出不可选及原有静音、队列、掉线行为。
- 源码与统一安装包中实际二进制的 fake-host 检查均通过，设备名称和 UID 未变。
- 安装前系统快照：`build/audio-evidence/device-before-input-fix.json`。旧驱动和安装包
  备份：`build/audio-evidence/input-selection-backup/`。
- 用户完成管理员验证后，统一 `Crisp.pkg` 安装成功。磁盘及实际加载驱动均为 1.0.1，
  CoreAudio 返回 `inputSelectable=true`，系统设置 AX 和截图均已看到“远程麦克风 / 虚拟”
  输入行；原来的“未找到音频输入设备”已消失。没有为验证创建录音文件或发起通话。
- 原默认输入为空，安装后 macOS 自动将唯一可用输入设为“远程麦克风”；代理没有调用
  默认输入 setter 或点击输入行。默认输出和 Crisp 显示配置未变，仍为 3440×1440 HiDPI、60Hz。
- 更新后网络麦克风处于关闭/静音，需要主控端重新开启。以上证明设备可见、可选，尚未
  证明企业微信真实输入音量或完整双向通话效果。记录见
  `build/audio-evidence/input-selection-fix-installed.json`。

## 已完成

| 验证 | 证据与结果 |
| --- | --- |
| `DEVELOPER_DIR=… make -o vendor check` | 严格 SwiftLint、245 个 XCTest、x86_64 类型检查、翻译完整性及 C 驱动 fake-host 测试通过 |
| XCTest | `build/audio-evidence/unit-summary.json`：245 通过、0 失败、0 跳过 |
| 与真实主控传输代码互通 | `scripts/check-remote-audio.sh` 使用 ScreenSharingEnhancer 的原始 AudioWire.swift，与真实 CrispAudioServer 进行 localhost 合成 PCM 收发 |
| 主控源版本 | `1962c6757fb1a392e10eaf0fad1c04e5507ad396`；0.4.1 对外层自动连接的更改未修改 AudioWire.swift |
| 协议与生命周期 | 拆包/合包、错误版本/长度/顺序、重复 hello、8 秒握手超时、拒绝第二客户端、mic 开关、约 200 ms 缺包静音、断线清空、重连默认关麦克风通过 |
| 仅收听 | 合成后端模拟没有虚拟输入：握手及连续下行仍正常；主控发送 mic=1 后明确断开，未注入任何上行采样 |
| 持续重采样 | 44.1/48/96 kHz → 24 kHz 和 24 → 48 kHz 的软件转换帧数/幅度检查通过 |
| 驱动 fake-host | 实际 C factory/vtable：仅输入流、默认关闭、generation 隔离、off/欠载/超时静音、同周期多客户端、溢出丢旧、非阻塞 trylock 通过 |
| 组件打包 | universal arm64+x86_64 驱动、安装/卸载 pkg 构建；解包后的实际驱动哈希/签名及 dlopen factory 测试通过 |
| 系统安装 | 2026-10-28 用户完成 macOS 安装器验证，安装收据 `com.forvey.Crisp.RemoteMicrophone.install` 1.0.0 存在，组件 root:wheel、签名检查通过 |
| 实际 HAL 枚举 | 系统返回名称“远程麦克风”、固定 UID、1 个输入通道、0 个输出通道、状态版本 1、麦克风关闭；没有启动音频 IO |
| Crisp 应用更新 | 已安装 `forvey/audio-v1-audio-20261028-101159`；默认输入/输出 UID 未变，3440×1440 HiDPI（6880×2880 backing）、60Hz 恢复，保存的显示配置未变 |

机器可读互通结果在 `build/audio-evidence/interop.json`，详细输出在 `remote-check.log`。
最近一次五秒合成双向传输约 2.03% 单核 CPU、峰值 RSS 9,453,568 字节，下行 250 包，
前 50 包跨度约 0.978 秒。**这个进程同时包含合成服务端和主控，没有音频硬件/tap，数值
不是实际 Crisp 的资源开销，也不是屏幕共享打字、LAN 时延或听感验收。**

测试主控位于 `/Users/cd03/workspace/ScreenSharingEnhancer`；新增自动选择的实现和测试见其
`docs/audio-follow-validation.md`。没有改变 TCP 49555、消息编号、采样格式或加密方式。

系统安装证据：`build/audio-evidence/installation-20261028.json`、`device-before-install.json`、
`device-after-install.json`。元数据核对程序在 `Tests/RemoteAudio/DeviceInventory.swift`，仅查询
设备属性，不打开输入流。应用和配置备份在
`/Users/cd03/Documents/Codex/2026-10-14/uu-betterdisplay-uu/work/crisp-install/audio-20261028-101159/`。
首次正常退出旧应用超时后，安装程序结束了旧应用进程；更新和配置恢复随后验证通过。

## 尚未完成

- HAL 安装和系统枚举已完成，企业微信设备列表/输入音量实测尚未进行。
- 当前已通过现有会话实际收听 mini 本地播放，没有为了测试另开录音/通话。
- MacBook 耳机已有下行声音，但断续待修复版本实测；企业微信输入音量、同时双向无自我回送仍未验收。
- 没有真实音频开/关的完整 Crisp CPU/RSS/流量及屏幕共享打字对照。
- 临时音频 UI 预览已关闭；没有把预览助手作为第二个应用安装。真实试听使用已安装 Crisp 内的服务。

后续需用户授予系统音频权限，在 MacBook 手动开启麦克风、在企业微信手动选择
`远程麦克风` 后验证。只听 mini 声音不依赖 HAL 组件，仍需系统音频权限。
安装已获授权并完成；安装/卸载会重启 CoreAudio 并短暂中断音频，仍由系统管理员批准。

## 构建说明

Release 产物位于 `build/RemoteAudioRelease/Build/Products/Release/Crisp.app`，组件包在其
`Contents/Resources/RemoteAudio/`。开发包使用 ad-hoc 驱动签名，pkg 尚未 Developer ID
签名/公证；正式分发要求和安装/卸载步骤见 [remote-audio.md](remote-audio.md)。
Xcode 的 CoreSimulator 版本不匹配警告与 macOS 测试分开记录：上述 macOS 检查通过。
未自动提交或推送。
