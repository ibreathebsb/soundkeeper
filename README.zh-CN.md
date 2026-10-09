# Sound Keeper for macOS

[![Build](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml/badge.svg)](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml)

[English](README.md) | **简体中文**

防止音频输出设备“睡着”的菜单栏小工具：蓝牙音箱、HDMI / DisplayPort / 光纤功放、USB DAC、带自动待机的有源音箱等。

这类设备在一段时间没有声音后会自动休眠或断开音频链路，下一次出声时要花零点几秒到几秒“醒来”，
于是提示音被吞掉、每首歌的开头被切掉，有的设备干脆自动关机。Sound Keeper 的办法很简单：
**一直向设备播放一路听不见的音频流**，让它始终认为“正在播放”。

## 安装

需要 Apple 芯片的 Mac，以及 macOS 12 或更新版本。

1. 从[最新的 Release](https://github.com/ibreathebsb/soundkeeper/releases/latest) 下载 `SoundKeeper-<版本>-macos-arm64.zip` 并解压。
2. 把 `SoundKeeper.app` 拖进“应用程序”文件夹。
3. 去掉 App 的隔离属性。**不做这一步，macOS 不会让它打开：**

   ```sh
   xattr -dr com.apple.quarantine /Applications/SoundKeeper.app
   ```

4. 打开 App。菜单栏里会出现一个喇叭图标，从这时起默认输出设备就被保活了。
   想让它一直运行，请在它的菜单里勾选 *Start at Login*。

**为什么需要第 3 步。** 浏览器下载的每个文件都会被打上 `com.apple.quarantine` 属性，
而 macOS 只允许打开经过 Apple 公证的隔离 App。这个 App 没有公证：它只有 ad-hoc 签名，因为公证需要付费的 Apple 开发者账号。
所以 macOS 会提示 App“已损坏，无法打开”（或者无法验证），并建议把它移到废纸篓。App 并没有损坏。
这条命令只是把这个属性从 App 上去掉，别的什么都不做：既不改动 App，也不改动任何系统设置。
如果第一次尝试打开之后，“系统设置 → 隐私与安全性”里出现了针对它的“仍要打开”，用那个按钮也可以。

zip 里还有命令行工具 `soundkeeper`（见[命令行工具](#命令行工具)）。它是可选的，同样带有隔离属性，所以首次使用前：

```sh
xattr -d com.apple.quarantine soundkeeper
```

更新时，先退出 App（菜单里的 *Quit Sound Keeper*），再用同样的方法换成新版本。
卸载时，取消勾选 *Start at Login*，退出并删除 App。它的其他文件见[文件位置](#文件位置)。

## 从源码构建

需要 macOS 12 或更新版本，以及 Command Line Tools（`xcode-select --install`）。不需要 Xcode。

```sh
make app        # 生成 build/SoundKeeper.app（菜单栏 App）和 build/soundkeeper（命令行工具）
make run        # 构建并启动 App
make install    # 构建、复制到 /Applications 并从那里启动
make package    # 构建并打包成 dist/SoundKeeper-<版本>-macos-<架构>.zip
make test       # 运行测试
make uninstall  # 删除 App、登录项和它的全部文件
```

在自己的 Mac 上构建出来的 App 不带隔离属性，所以不需要去掉什么，直接就能运行。

### GitHub Actions

有两个工作流运行在 GitHub 的 macOS 运行器上：

- `.github/workflows/build.yml` 在每次推送到 `main`、每个 Pull Request 以及手动触发时测试并构建项目。
  包含 `SoundKeeper.app` 和命令行工具的 zip 可以在那次运行页面底部的 Artifacts 里下载。
- `.github/workflows/release.yml` 在推送版本标签时做同样的事情，并把 zip 发布为一个 Release：

  ```sh
  git tag v1.2.3 && git push origin v1.2.3
  ```

  标签必须和 App 的版本一致，版本写在 `Resources/Info.plist` 和 `Sources/SoundKeeperCore/AppInfo.swift` 里。

从 GitHub 下载的所有东西都带有隔离属性，见[安装](#安装)。

## 菜单栏 App

启动后没有窗口、没有 Dock 图标，只在菜单栏右侧多一个喇叭图标：

| 图标 | 含义 |
| --- | --- |
| 喇叭 + 声波 | 正在给至少一个输出设备保活 |
| 喇叭 | 已开启，但当前没有可保活的设备（或因显示器关闭 / 锁屏而暂停） |
| 喇叭 + 斜线 | 已被你关闭 |
| 喇叭 + 感叹号 | 某个设备的保活流无法启动，正在重试 |

点开菜单：

- **最上方**：当前正在保活哪些设备。绿点表示正常；黄点表示设备被其他应用独占，Sound Keeper 在等待；
  红点表示保活流无法启动，正在重试。鼠标悬停可以看到采样率、声道数等细节。
- **Keep Outputs Awake**：总开关。
- **Outputs**：给哪些设备保活。
  - *Default Output*：“声音”设置里选定的输出设备，切换输出时自动跟随。默认选项。
  - *All / Digital / Analog Outputs*：所有硬件输出 / 仅 HDMI、DisplayPort、S/PDIF / 除此之外的。
  - *Only Selected*：只给勾选的设备保活。设备断开后仍然保持勾选，重新连接后立即恢复保活。
  - *Include AirPlay Outputs*：默认忽略 AirPlay，因为给它保活意味着一直通过网络推流。
- **Signal**：播放什么信号，见下一节。
- **Sleep**
  - 默认情况下 **Mac 仍然可以正常自动睡眠**，Sound Keeper 不会像普通播放器那样让电脑一直醒着。
  - *Keep the Mac Awake*：反过来，Sound Keeper 播放期间 Mac 不会自动睡眠。
  - *Pause While Displays Are Off / the Screen Is Locked*：人不在时保持安静，让音箱自己去休眠。
- **Start at Login**：登录时自动启动。请先把 App 放进 /Applications（`make install`）。

界面提供英文和简体中文，跟随系统语言。

## 信号类型怎么选

| 类型 | 说明 | 适用 |
| --- | --- | --- |
| Fluctuate（默认） | 全零数据流，每秒 50 次插入一个幅度最小的非零采样（24 位音频的 ±1 LSB，约 −138 dBFS）。听不见，但不是纯粹的数字静音。 | 数字输出的首选：HDMI、光纤、USB DAC |
| Zero | 全零数据流。 | 只要音频链路不断就不休眠的设备 |
| Open Only | 只让硬件保持运行，进程本身不渲染任何数据，最省电。 | 同上，有时这样就够了 |
| Sine | 正弦波，默认 1 Hz、1% 幅度，频率和幅度可调。低频听不见，却是真实存在的信号。 | 检测不到信号就休眠的设备：有源音箱、部分蓝牙音箱 |
| White / Brown / Pink Noise | 噪声，默认 1% 幅度。0.1% 基本听不见。 | 同上，Sine 无效时再试 |

参数（菜单里有预设，也可以在 *More Parameters…* 里填写精确数值）：

- **Frequency**：Fluctuate 是每秒“微扰”的次数（默认 50），Sine 是音调的频率（默认 1 Hz）。
- **Amplitude**：Sine 和噪声的幅度，单位 %（默认 1）。
- **Length / Waiting**：每段声音持续多久、两段之间停多久，单位秒。只设 Length 不设 Waiting 等于一直播放。
- **Fading**：淡入淡出时间（默认 0.1 秒）。

**建议的尝试顺序**：先用默认的 Fluctuate。如果设备过一阵仍然休眠或关机，换成 Sine（10 Hz、5% 听不见）。
还不行再试 0.1% 的 Brown Noise。想确认声音确实送到了设备，可以临时选 1000 Hz 的 Sine：它能听见，仅用于测试。

> **蓝牙音箱**：蓝牙音频是有损编码（SBC / AAC），Fluctuate 那种 ±1 LSB 的信号在编码后就成了静音。
> 所以它在蓝牙上的效果和 Zero 完全一样：让音箱保持清醒的，是一直开着的音频链路。对大多数音箱这就够了；
> 如果你的音箱是按“安静了多久”来计时关机的，请改用 Sine 或噪声。

## 命令行工具

`build/soundkeeper` 是不带任何界面的 Sound Keeper，启动后立即开始工作。设置名不区分大小写。
它和菜单栏 App 共用同一把单实例锁：新启动的实例会让之前的实例退出，所以两者不会同时运行。

```
soundkeeper [设置]              一直运行，直到被停止
soundkeeper install [设置]      立即启动，并在每次登录时启动（用户级 launchd 代理）
soundkeeper uninstall           停止并移除登录项
soundkeeper kill                停止正在运行的实例（包括菜单栏 App）
soundkeeper status              查看谁在运行、在给哪些设备保活
soundkeeper list [设置]         列出所有输出设备，以及这组设置会给哪些设备保活
```

设置可以分开写，也可以连在一起写：`sine -f 1000 -a 15` 和 `SineF1000A15` 是一样的。

| 类别 | 设置 |
| --- | --- |
| 输出设备 | `primary`（默认）、`all`、`digital`、`analog`、`marked`（名称里带 `!` 的设备）、`-d 名称`（名称包含该文字，或 UID 与之相同；可重复）、`remote`（不忽略 AirPlay） |
| 信号 | `openonly`、`zero`、`fluctuate`（默认）、`sine`、`white`、`brown`、`pink` |
| 信号参数 | `-f` 频率 Hz、`-a` 幅度 %、`-l` 时长（秒）、`-w` 间隔（秒）、`-t` 淡入淡出（秒） |
| 休眠 | `sleepd`（显示器关闭时暂停）、`sleepl`（锁屏时暂停）、`sleepld` 或 `sleepy`（两者）、`nosleep`（阻止 Mac 睡眠） |
| 其他 | `-v` 输出正在发生的事情 |

```sh
soundkeeper                          # 默认输出设备，听不见的 Fluctuate
soundkeeper all zero                 # 所有输出设备，全零数据流
soundkeeper sine -f 10 -a 5          # 10 Hz、5% 的正弦波，听不见
soundkeeper sine -f 1000 -a 15       # 1000 Hz、15%，能听见！仅用于测试
soundkeeper brown -a 0.1             # 0.1% 的布朗噪声
soundkeeper install -d JBL sine      # 只给名字里带 JBL 的输出保活，并在登录时启动
```

设置也可以写在可执行文件的名字里（`SoundKeeperSineF10A5`）。命令行里无法识别的参数会报错。

## 工作原理

CoreAudio 有一条简单的规则：**设备上只要有一个 IOProc 在运行，HAL 就让它的硬件保持工作；
最后一个 IOProc 停止的那一刻，硬件也随之停止**（`kAudioDevicePropertyDeviceIsRunningSomewhere` 从 1 变成 0）。
蓝牙的 A2DP 链路、HDMI 的音频数据、USB 的等时传输都是在这一刻消失的，设备也从这一刻开始为休眠倒计时。

所以 Sound Keeper 在每个需要保活的设备上注册一个 IOProc（`AudioDeviceCreateIOProcID` 和 `AudioDeviceStart`），并且永不停止。
IOProc 由 HAL 的实时线程回调，负责把保活信号写进输出缓冲区。
*Open Only* 则是 `AudioDeviceStart(device, NULL)`：只启动硬件，不注册任何 IOProc。

其余的代码都在处理它周围发生的各种事情：

| 发生了什么 | Sound Keeper 怎么做 |
| --- | --- |
| 默认输出设备改变，设备接入或断开 | 监听 `kAudioHardwarePropertyDefaultOutputDevice` 和 `kAudioHardwarePropertyDevices` 并“对账”：给现在需要保活的设备启动数据流，停掉不再需要的；仍然需要保活的设备，它的流不会被打断 |
| 设备的采样率或格式改变 | 立即让信号发生器静音；确认格式确实变了再重启数据流 |
| 其他应用独占了设备（Hog 模式） | 停下来，等到设备被释放（`kAudioDevicePropertyHogMode`） |
| 数据流不明原因地停了 | 看门狗每 10 秒检查一次已渲染的缓冲区数量，重启停滞的流 |
| Mac 进入睡眠又被唤醒，或切换到了另一个用户 | 在那之前停止，之后重新开始（`NSWorkspace` 通知） |
| 显示器进入睡眠，屏幕被锁定 | 如果在设置里开启了，就暂停 |
| 音频服务（coreaudiod）重启 | 一切从头重建（`kAudioHardwarePropertyServiceRestarted`） |
| 又启动了一个 Sound Keeper | 新实例让旧实例退出：文件上的 POSIX 锁给出谁在运行，`SIGTERM` 请它退出 |
| 登录 | 由用户级 launchd 代理启动（`~/Library/LaunchAgents/local.soundkeeper.plist`） |

几个细节：

- **不会让 Mac 一直醒着。** 默认情况下，coreaudiod 会替任何在播放音频的进程持有一个电源断言（`PreventUserIdleSystemSleep`），
  所以一路永不停止的流会让 Mac 再也不会自己睡眠。Sound Keeper 为自己的进程设置了 `kAudioHardwarePropertySleepingIsAllowed`，
  这个断言就不会被创建。可以自行验证：Sound Keeper 运行时，`pmset -g assertions | grep audio`
  不会显示 `Created for PID: <Sound Keeper 的 PID>`。
- **尽量少唤醒 CPU。** IO 缓冲区的大小在 macOS 上是每个进程各自的设置，不影响别的应用。
  Sound Keeper 把自己的缓冲区调到设备允许的最大值（内置扬声器 4096 帧，约每秒回调 12 次；蓝牙 1024 帧，约每秒 43 次），
  Fluctuate 的渲染方式是“清空缓冲区，再写几个采样”。同时给两个设备保活 30 秒，大约只用掉 0.03 秒 CPU 时间。
- **实时线程上只有 C。** IOProc 和信号发生器是一个独立的 C 模块（`Sources/CSoundKeeperRender`），
  渲染路径上没有内存分配、没有锁，也没有 Swift 运行时。缓冲区的声道数或大小与启动数据流时不一致的时候，一律写零：
  把浮点采样写进别的格式的流里会变成巨响。
- **不碰麦克风。** 对带输入的设备（USB 耳机、声卡），IOProc 声明自己不使用输入流（`kAudioDevicePropertyIOProcStreamUsage`），
  这样不会启动录音，也就没有麦克风指示和权限请求。（这一点尚未在真实硬件上测试：开发用的 Mac 上没有同时带输入和输出的设备。）

## 注意事项

- **耗电。** 让设备保持工作是要耗电的。这对蓝牙耳机和音箱的电池有影响，对内置扬声器被保活时的 MacBook 电池也有影响。
  如果只关心某一个设备，请在 *Outputs → Only Selected* 里只勾选它：这样它断开之后，Sound Keeper 不会转而去给内置扬声器保活。
- **AirPods 等会在设备之间自动切换的耳机。** Mac 一直处于“正在播放”的状态，可能妨碍它自动切换到 iPhone。
  给这类耳机保活之前请想清楚。
- **音量。** Fluctuate 的信号只有 1 个 LSB。如果设备的音量是在软件里实现的，并且不在 100%，这个信号会被舍入成零，
  Fluctuate 的效果就和 Zero 一样了。数字输出通常没有这个问题。
- **独占。** 有播放器独占设备（Hog 模式）时，Sound Keeper 会等待。这时让设备保持清醒是那个播放器的事。
- **噪声** 是按设备当前的采样率生成的，所以在 96 kHz 及以上的设备上，它的频谱会相应上移。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/SoundKeeper/soundkeeper.lock` | 单实例锁 |
| `~/Library/Application Support/SoundKeeper/status.json` | 正在运行的实例的状态，供 `soundkeeper status` 读取 |
| `~/Library/Application Support/SoundKeeper/soundkeeper` | `soundkeeper install` 复制出来的可执行文件 |
| `~/Library/LaunchAgents/local.soundkeeper.plist` | 登录项。App 的 *Start at Login* 和命令行工具的 `install` 共用它，后设置的生效 |
| `defaults read local.soundkeeper` | 菜单栏 App 的设置，保存的就是同一套命令行参数 |

## 排查问题

```sh
build/soundkeeper status      # 谁在运行、在给哪些设备保活、它们的硬件此刻是否醒着
build/soundkeeper list        # 所有输出设备：连接方式、格式、此刻是否醒着、当前设置是否会给它保活
build/soundkeeper list all    # 换一组设置再看
/usr/bin/log show --last 10m --predicate 'subsystem == "local.soundkeeper"'    # 事件日志
pmset -g assertions | grep -i audio                                            # 谁在阻止 Mac 睡眠
```

`list` 的 AWAKE 一列就是 `kAudioDevicePropertyDeviceIsRunningSomewhere`。Sound Keeper 运行时，每个被保活的设备都应当是 `yes`。

## 源代码

```
Sources/CSoundKeeperRender   C：信号发生器和 IOProc，运行在实时线程上
Sources/SoundKeeperCore      设置及其解析、设备及其选择、会话（SoundSession）、运行会话的调度器（SoundKeeper）、
                             电源事件、单实例锁、登录项
Sources/SoundKeeperUI        菜单栏 App：状态栏图标、菜单、参数面板
Sources/SoundKeeperApp       App 的入口
Sources/soundkeeper          命令行工具
Resources                    Info.plist、图标、本地化
Tests                        信号发生器与一个直白的参考实现逐采样对照；IOProc 对意外的缓冲区和格式的防护；设置解析；
                             设备选择；调度逻辑；菜单行为；本地化的完整性；以及可选的真实硬件测试
```

真实硬件测试默认不运行。它们是无声的，并且只使用空闲的内置扬声器：

```sh
SOUNDKEEPER_HARDWARE_TESTS=1 make test
SOUNDKEEPER_HARDWARE_TESTS=1 swift test --sanitize=address --filter HardwareTests   # 仅有 Command Line Tools 时，加上 Makefile 里的 TEST_FLAGS
```

## 许可

MIT，见 [LICENSE](LICENSE)。基于 Evgeny Vrublevsky 的 [Sound Keeper](https://github.com/vrubleg/soundkeeper)。
