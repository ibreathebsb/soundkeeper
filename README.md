# Sound Keeper for macOS

[![Build](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml/badge.svg)](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml)

防止音频输出设备“睡着”的菜单栏小工具：蓝牙音箱、HDMI / DisplayPort / 光纤功放、USB DAC、带自动待机的有源音箱等。
它是 Windows 上 [Sound Keeper](https://github.com/vrubleg/soundkeeper)（作者 Evgeny Vrublevsky）v1.3.7 的 macOS 移植版。

这类设备在一段时间没有声音后会自动休眠或断开音频链路，下一次出声时要花零点几秒到几秒“醒来”，
于是提示音被吞掉、每首歌的开头被切掉，有的设备干脆自动关机。Sound Keeper 的办法很简单：
**一直向设备播放一路听不见的音频流**，让它始终认为“正在播放”。

## 构建与安装

需要 macOS 12 或更新版本，以及 Command Line Tools（`xcode-select --install`）。不需要 Xcode。

```sh
make app        # 生成 build/SoundKeeper.app（菜单栏 App）和 build/soundkeeper（命令行工具）
make run        # 构建并启动 App
make install    # 构建、复制到 /Applications 并从那里启动
make test       # 运行测试
make uninstall  # 删除 App、登录项和它的全部文件
```

App 是在本机构建、仅作本机使用的，采用 ad-hoc 签名，不会被 Gatekeeper 拦截。

### GitHub Actions

`.github/workflows/build.yml` 会在每次推送到 `main`、每个 Pull Request 以及手动触发时，在 GitHub 的 macOS 运行器上跑测试并构建。
产物是一个 zip（`SoundKeeper.app` + 命令行工具），在那次运行页面底部的 Artifacts 里下载。

CI 构建的 App 同样只有 ad-hoc 签名，而从浏览器下载的文件带有隔离标记，所以首次运行前需要去掉它：

```sh
xattr -dr com.apple.quarantine SoundKeeper.app
```

## 菜单栏 App

启动后没有窗口、没有 Dock 图标，只在菜单栏右侧多一个喇叭图标：

| 图标 | 含义 |
| --- | --- |
| 喇叭 + 声波 | 正在给至少一个输出设备保活 |
| 喇叭 | 已开启，但当前没有可保活的设备（或因显示器关闭 / 锁屏而暂停） |
| 喇叭 + 斜线 | 已被你关闭 |
| 喇叭 + 感叹号 | 某个设备无法启动保活流，正在重试 |

点开菜单：

- **最上方**：当前正在保活哪些设备（绿点 = 正常，黄点 = 设备被其他应用独占、等待中，红点 = 启动失败、重试中）。
  鼠标悬停可以看到采样率、声道数等细节。
- **Keep Outputs Awake**：总开关。
- **Outputs**（给哪些设备保活）
  - *Default Output*：系统当前的默认输出设备，切换输出时自动跟随。默认选项。
  - *All / Digital / Analog Outputs*：所有硬件输出 / 仅 HDMI、DisplayPort、S/PDIF / 除此之外的。
  - *Only Selected*：只给勾选的设备保活。设备断开后仍然保持勾选，重新连接后自动恢复。
  - *Include AirPlay Outputs*：默认忽略 AirPlay（保活意味着一直通过网络推流）。
- **Signal**（播放什么信号，见下一节）
- **Sleep**
  - 默认情况下 **Mac 仍然可以正常自动睡眠**，Sound Keeper 不会像普通播放器那样让电脑一直醒着。
  - *Keep the Mac Awake*：反过来，像普通播放器一样阻止 Mac 自动睡眠。
  - *Pause While Displays Are Off / Screen Is Locked*：显示器关闭或锁屏时暂停保活，人不在时让音箱自己去休眠。
- **Start at Login**：登录时自动启动（建议先 `make install` 把 App 放进 /Applications 再勾选）。

系统语言为简体中文时界面显示中文，否则显示英文。

## 信号类型怎么选

| 类型 | 说明 | 适用 |
| --- | --- | --- |
| Fluctuate（默认） | 全零数据流，每秒 50 次插入一个幅度最小的非零采样（24 位下的 ±1 LSB，约 −138 dBFS）。完全听不见，但数据不是“纯静音”。 | 数字输出（HDMI / 光纤 / USB DAC）的首选 |
| Zero | 全零数据流。 | 只要链路不断就不休眠的设备 |
| Open Only | 只让硬件保持运行，本进程不产生任何数据。最省电。 | 同上，“有时就够了” |
| Sine | 正弦波，默认 1 Hz、1% 幅度；频率和幅度可调。低频听不见，却是真实存在的信号。 | 靠“检测有没有信号”来决定待机的设备：有源音箱、部分蓝牙音箱 |
| White / Brown / Pink Noise | 白 / 布朗 / 粉红噪声，默认 1% 幅度。0.1% 基本听不见。 | 同上，Sine 无效时再试 |

可调参数（菜单里有预设，也可以在 *More Parameters…* 里直接填）：

- **Frequency**：Fluctuate 是每秒“微扰”的次数（默认 50），Sine 是频率（默认 1 Hz）。
- **Amplitude**：Sine 和噪声的幅度，单位 %（默认 1）。
- **Length / Waiting**：每次响多久、两次之间停多久（秒）。只设 Length 不设 Waiting 等于一直响。
- **Fading**：淡入淡出时间（默认 0.1 秒）。

**建议的尝试顺序**：先用默认的 Fluctuate；如果设备过一阵仍然休眠或关机，换成 Sine（例如 10 Hz、5%，听不见）；
还不行再试 Brown Noise 0.1%。想确认声音确实送到了设备，可以临时选 Sine 1000 Hz —— 这个能听见，仅用于测试。

> **蓝牙音箱**：蓝牙是有损编码（SBC / AAC），Fluctuate 那种 ±1 LSB 的信号在编码后等同于静音，
> 所以它在蓝牙上的效果和 Zero 一样 —— 靠的是“音频链路一直开着”。多数蓝牙音箱这样就不会休眠了；
> 如果你的音箱是按“有没有声音”来计时关机的，请改用 Sine 或噪声。

## 命令行工具

`build/soundkeeper` 是不带界面的版本，行为和 Windows 原版一样：启动即工作，参数名不区分大小写。
它和菜单栏 App 共用同一把“单实例锁”：新启动的实例会自动让旧实例退出，所以两者不会同时运行。

```
soundkeeper [设置]              前台运行，直到被停止
soundkeeper install [设置]      立即启动，并在每次登录时启动（launchd 用户代理）
soundkeeper uninstall           停止并移除登录项
soundkeeper kill                停止正在运行的实例（包括菜单栏 App）
soundkeeper status              查看谁在运行、在给哪些设备保活
soundkeeper list [设置]         列出所有输出设备，以及这组设置会给哪些设备保活
```

设置（与原版相同的写法都支持，如 `sine -f 1000 -a 15` 或 `SineF1000A15`）：

| 类别 | 参数 |
| --- | --- |
| 设备 | `primary`（默认）、`all`、`digital`、`analog`、`marked`（名称里带 `!` 的设备）、`-d 名称`（名称包含该文字或 UID 相同，可重复）、`remote`（不忽略 AirPlay） |
| 信号 | `openonly`、`zero`、`fluctuate`（默认）、`sine`、`white`、`brown`、`pink` |
| 信号参数 | `-f` 频率 Hz、`-a` 幅度 %、`-l` 时长秒、`-w` 间隔秒、`-t` 淡入淡出秒 |
| 休眠 | `sleepd`（显示器关闭时暂停）、`sleepl`（锁屏时暂停）、`sleepld` / `sleepy`（两者）、`nosleep`（阻止 Mac 睡眠） |
| 其他 | `-v` 输出详细日志 |

```sh
soundkeeper                          # 默认输出设备，听不见的 Fluctuate
soundkeeper all zero                 # 所有输出设备，全零
soundkeeper sine -f 10 -a 5          # 10 Hz、5% 的正弦波，听不见
soundkeeper sine -f 1000 -a 15       # 1000 Hz、15%，能听见！仅用于测试
soundkeeper brown -a 0.1             # 0.1% 的布朗噪声
soundkeeper install -d JBL sine      # 只给名字里带 JBL 的设备保活，并开机自启
```

和原版一样，设置也可以写在可执行文件名里（`SoundKeeperSineF10A5`）。与原版不同的是，命令行里写错的参数会报错，而不是被悄悄忽略。

## 工作原理

### Windows 原版

用 WASAPI 在目标设备上打开一路共享模式的渲染流，申请 1 秒的缓冲区，每 750 毫秒醒来一次把缓冲区填满；
内容是全零，或每隔一段时间插入一个最小非零采样（Fluctuate），或正弦波 / 噪声。
只要这路流在播放，Windows 的音频引擎就不会停掉设备，S/PDIF、HDMI 链路上就一直有数据。
其余代码都在处理“意外”：默认设备变化、设备插拔、格式变化、其他程序独占设备、系统睡眠与唤醒、单实例。

### macOS 版

CoreAudio 的规则是：**设备上只要有一个 IOProc 在运行，HAL 就让硬件保持工作；最后一个 IOProc 停止的瞬间，硬件就停了**
（`kAudioDevicePropertyDeviceIsRunningSomewhere` 从 1 变 0）。蓝牙的 A2DP 链路、HDMI 的音频数据、USB 的等时传输都是在这一刻断掉的。
所以 macOS 版做的事是：在每个需要保活的设备上注册一个 IOProc 并一直运行，由它向输出缓冲区写入保活信号。

| Windows 原版 | macOS 版 |
| --- | --- |
| WASAPI 共享模式渲染流，定时填充 1 秒缓冲区 | HAL IOProc（`AudioDeviceCreateIOProcID` + `AudioDeviceStart`），由 HAL 的实时线程回调 |
| OpenOnly：打开设备但不写数据 | `AudioDeviceStart(device, NULL)`：只启动硬件，不注册 IOProc |
| 混音格式固定为 32 位浮点 | 流的虚拟格式固定为 32 位浮点；若不是（被切到编码格式），只写零 |
| `IMMNotificationClient` 监听设备变化 | 监听 `kAudioHardwarePropertyDevices`、`DefaultOutputDevice`、`ServiceRestarted` |
| 会话断开事件（格式变化） | 监听采样率、流格式、流配置变化，先让发生器静音，确认格式变了再重启 |
| WASAPI / ASIO 独占模式：等待独占结束 | Hog 模式：监听 `kAudioDevicePropertyHogMode`，等待释放 |
| “播放音频会阻止 Windows 11 自动睡眠”是已知问题，只能在锁屏 / 关屏时停播 | 设置 `kAudioHardwarePropertySleepingIsAllowed = 1`，coreaudiod 不再为本进程持有 `PreventUserIdleSystemSleep`，Mac 照常睡眠 |
| 挂起 / 恢复、显示器、锁屏通知 | `NSWorkspace` 的睡眠 / 唤醒、屏幕睡眠 / 唤醒、会话切换通知；锁屏用 `com.apple.screenIsLocked` 分布式通知 |
| 具名互斥量 + 具名事件实现单实例与 `kill` | 文件上的 POSIX 锁 + `SIGTERM`（`F_GETLK` 直接给出持锁进程的 PID） |
| 放进“启动”文件夹自启 | 用户级 launchd 代理（`~/Library/LaunchAgents/local.soundkeeper.plist`） |
| 忽略远程桌面音频设备（`Remote` 开关） | 忽略 AirPlay 设备（`remote` 开关） |

几个 macOS 上特有的细节：

- **不阻止睡眠**。默认情况下任何在播放音频的进程都会让 coreaudiod 持有一个阻止空闲睡眠的电源断言，
  这正是原版在 Windows 11 上的“已知问题”。macOS 提供了按进程关闭它的属性，所以这里默认就是“保活但不妨碍睡眠”。
  可以用 `pmset -g assertions | grep audio` 自行验证：Sound Keeper 运行时不会出现 `Created for PID: <它的 PID>`。
- **尽量少唤醒 CPU**。IO 缓冲区大小在 macOS 上是“每进程”的设置，不影响别的应用。Sound Keeper 把自己的缓冲区调到设备允许的最大值
  （内置扬声器 4096 帧 ≈ 每秒回调 12 次，蓝牙 1024 帧 ≈ 每秒 43 次），Fluctuate 的实现是“清零 + 写几个采样”。
  实测同时给两个设备保活，30 秒只用掉约 0.03 秒 CPU 时间。
- **实时线程里只有 C**。IOProc 和信号发生器在一个独立的 C 模块里（`Sources/CSoundKeeperRender`），
  渲染路径上没有内存分配、没有锁、没有 Swift 运行时。缓冲区的声道数、大小与启动时不一致时一律写零，
  避免把浮点数据写进别的格式的流里变成巨响。
- **只动需要动的设备**。设备列表变化时做的是“对账”而不是全部重启：仍然需要保活的设备，它的流不会被打断。
- **自愈**。每 10 秒检查一次回调计数；流停了（且不是因为被独占）就重启它。coreaudiod 重启后全部重建。
- **不碰麦克风**。对带输入的设备（USB 耳机、声卡），通过 `kAudioDevicePropertyIOProcStreamUsage` 声明不使用输入流，
  目的是不连带启动录音、不触发麦克风指示和权限请求。（开发机上没有同时带输入和输出的设备，这条路径尚未实测。）

## 注意事项

- **耗电**：让设备保持工作本身是要耗电的，尤其是蓝牙耳机 / 音箱的电池，以及电池供电时的 MacBook 内置扬声器。
  如果只关心某一个设备，建议在 *Outputs → Only Selected* 里只勾它：这样它断开后，Sound Keeper 不会转去给内置扬声器保活。
- **AirPods 等会在设备间自动切换的耳机**：Mac 一直在“播放”，可能影响它自动切到 iPhone。给这类耳机保活前请想清楚是否需要。
- **音量**：Fluctuate 的信号只有 1 个 LSB。如果设备的音量是在软件里做的（数字衰减）且不在 100%，它会被舍入成零，
  效果退化为 Zero。数字输出一般没有这个问题。
- **独占模式**：有播放器独占（Hog）设备时，Sound Keeper 会停下来等它释放 —— 此时保活本来就由那个播放器负责。
- 噪声是按设备当前采样率直接生成的，在 96 kHz 及以上的设备上频谱会相应上移（原版固定按 48 kHz 生成）。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/SoundKeeper/soundkeeper.lock` | 单实例锁 |
| `~/Library/Application Support/SoundKeeper/status.json` | 运行中的实例的状态（供 `soundkeeper status` 读取） |
| `~/Library/Application Support/SoundKeeper/soundkeeper` | `soundkeeper install` 时复制的可执行文件 |
| `~/Library/LaunchAgents/local.soundkeeper.plist` | 登录项（App 的 *Start at Login* 与命令行的 `install` 共用，后设置的生效） |
| `defaults read local.soundkeeper` | 菜单栏 App 的设置，保存的就是上面那套命令行参数 |

## 排查问题

```sh
build/soundkeeper status      # 谁在运行、在给谁保活、硬件此刻是否醒着
build/soundkeeper list        # 所有输出设备：传输方式、格式、此刻是否醒着、当前设置是否会给它保活
build/soundkeeper list all    # 换一组设置看看
/usr/bin/log show --last 10m --predicate 'subsystem == "local.soundkeeper"'    # 事件日志
pmset -g assertions | grep -i audio                                   # 谁在阻止睡眠
```

`list` 里的 AWAKE 一列读的是 `kAudioDevicePropertyDeviceIsRunningSomewhere`：Sound Keeper 运行时，被保活的设备应当始终是 `yes`。

## 代码结构

```
Sources/CSoundKeeperRender   C：信号发生器（移植自原版的 Render）与 IOProc，运行在实时线程
Sources/SoundKeeperCore      设置解析、设备枚举与选择、会话（SoundSession）、调度（SoundKeeper）、
                             电源事件、单实例锁、登录项
Sources/SoundKeeperUI        菜单栏 App：状态栏图标、菜单、参数面板
Sources/SoundKeeperApp       App 入口
Sources/soundkeeper          命令行工具
Resources                    Info.plist、图标、本地化
Tests                        信号发生器与原版逐采样对照、IOProc 的越界 / 格式保护、参数解析、设备选择、
                             调度逻辑、菜单行为、本地化完整性；以及可选的真实硬件测试
```

真实硬件测试默认不跑（它们是无声的，只使用空闲的内置扬声器）：

```sh
SOUNDKEEPER_HARDWARE_TESTS=1 make test
SOUNDKEEPER_HARDWARE_TESTS=1 swift test --sanitize=address --filter HardwareTests   # 仅有 Command Line Tools 时参考 Makefile 里的 TEST_FLAGS
```

## 许可

MIT，见 [LICENSE](LICENSE)。原版 Sound Keeper © 2014–2026 Evgeny Vrublevsky。
