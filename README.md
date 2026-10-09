# Sound Keeper for macOS

[![Build](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml/badge.svg)](https://github.com/ibreathebsb/soundkeeper/actions/workflows/build.yml)

**English** | [简体中文](README.zh-CN.md)

A menu bar app that keeps audio outputs from falling asleep: Bluetooth speakers, HDMI / DisplayPort / optical receivers,
USB DACs, active monitors with auto standby.

Such devices go to sleep or drop the audio link after a while without sound. When the next sound starts, it takes them
from a fraction of a second to several seconds to wake up, so notification sounds are swallowed, the beginning of every
track is cut off, and some devices just power themselves off. Sound Keeper has a simple cure:
**it always plays an inaudible stream to the device**, so the device believes that something is playing.

## Install

Requires a Mac with Apple silicon and macOS 12 or later.

1. Download `SoundKeeper-<version>-macos-arm64.zip` from the [latest release](https://github.com/ibreathebsb/soundkeeper/releases/latest) and unzip it.
2. Move `SoundKeeper.app` to the Applications folder.
3. Remove the quarantine attribute from the app. **macOS doesn't open the app without this step:**

   ```sh
   xattr -dr com.apple.quarantine /Applications/SoundKeeper.app
   ```

4. Open the app. A speaker icon appears in the menu bar, and the default output is kept awake from now on.
   Turn on *Start at Login* in its menu to have it always running.

**Why step 3 is needed.** Every file that is downloaded by a browser gets the `com.apple.quarantine` attribute,
and macOS opens a quarantined app only if it is notarized by Apple. This app is not: it has just an ad-hoc signature,
since notarization requires a paid Apple Developer account. So macOS says that the app "is damaged and can't be opened"
(or that it can't be verified) and offers to move it to the Trash. The app is not damaged. The command removes
the attribute from the app and does nothing else: neither the app nor any setting of the system is changed.
If System Settings → Privacy & Security offers *Open Anyway* for the app after the first attempt to open it, that works too.

The zip also has the command line tool `soundkeeper` (see [Command line tool](#command-line-tool)). It is optional,
and it is quarantined as well, so before the first use:

```sh
xattr -d com.apple.quarantine soundkeeper
```

To update, quit the app (*Quit Sound Keeper* in its menu) and replace it with the new version in the same way.
To uninstall, turn off *Start at Login*, quit the app and delete it. Its other files are listed in [Files](#files).

## Build from source

Requires macOS 12 or later and Command Line Tools (`xcode-select --install`). Xcode is not needed.

```sh
make app        # build/SoundKeeper.app (the menu bar app) and build/soundkeeper (the command line tool)
make run        # build and start the app
make install    # build, copy to /Applications and start it from there
make package    # build and pack everything into dist/SoundKeeper-<version>-macos-<arch>.zip
make test       # run the tests
make uninstall  # remove the app, its login item and all its files
```

An app that is built on your Mac is not quarantined, so there is nothing to remove: it just runs.

### GitHub Actions

Two workflows run on macOS runners of GitHub:

- `.github/workflows/build.yml` tests and builds the project on every push to `main`, on every pull request, and when
  it is started manually. The zip with `SoundKeeper.app` and the command line tool can be downloaded from Artifacts
  at the bottom of the page of a run.
- `.github/workflows/release.yml` does the same when a version tag is pushed, and publishes the zip as a release:

  ```sh
  git tag v1.2.3 && git push origin v1.2.3
  ```

  The tag has to match the version of the app, which is set in `Resources/Info.plist` and `Sources/SoundKeeperCore/AppInfo.swift`.

Everything that is downloaded from GitHub is quarantined, see [Install](#install).

## The menu bar app

There are no windows and no Dock icon, just a speaker icon on the right side of the menu bar:

| Icon | Meaning |
| --- | --- |
| Speaker with waves | At least one output is being kept awake |
| Speaker | Turned on, but there is nothing to keep awake right now (or it is paused because displays are off or the screen is locked) |
| Speaker with a slash | Turned off by you |
| Speaker with an exclamation mark | A stream to some output can't be started; Sound Keeper keeps retrying |

The menu:

- **At the top**: outputs that are being kept awake right now. A green dot means that everything is fine. A yellow one
  means that the device is used exclusively by another app, and Sound Keeper waits. A red one means that the stream
  can't be started, and Sound Keeper keeps retrying. Hover over a line to see the sample rate, the number of channels,
  and other details.
- **Keep Outputs Awake**: the main switch.
- **Outputs**: which outputs are kept awake.
  - *Default Output*: the output that is selected in Sound settings. It is followed when you switch outputs. Used by default.
  - *All / Digital / Analog Outputs*: all hardware outputs / HDMI, DisplayPort and S/PDIF only / everything else.
  - *Only Selected*: only the outputs you check. A device stays checked when it is disconnected, and it is kept awake
    again as soon as it comes back.
  - *Include AirPlay Outputs*: AirPlay is ignored by default, since keeping it awake means streaming over the network all the time.
- **Signal**: what is played, see the next section.
- **Sleep**
  - By default **the Mac is still free to go to sleep** on its own. Sound Keeper doesn't keep it awake like a usual audio player does.
  - *Keep the Mac Awake*: the opposite. The Mac doesn't go to sleep automatically while Sound Keeper is playing.
  - *Pause While Displays Are Off / the Screen Is Locked*: be silent while you are away, so your speakers can fall asleep.
- **Start at Login**: start Sound Keeper when you log in. Put the app into /Applications first (`make install`).

The interface is available in English and Simplified Chinese. It follows the language of the system.

## Choosing a signal

| Type | What it is | Good for |
| --- | --- | --- |
| Fluctuate (default) | A stream of zeroes with the smallest non-zero sample inserted 50 times a second (±1 LSB of 24-bit audio, about −138 dBFS). It is inaudible, but it is not pure digital silence. | The first choice for digital outputs: HDMI, optical, USB DACs |
| Zero | A stream of zeroes. | Devices that stay awake as long as the audio link is up |
| Open Only | Only keeps the hardware running. The process doesn't render anything, so it takes the least power. | The same. Sometimes it is enough |
| Sine | A sine wave, 1 Hz at 1% by default. Frequency and amplitude can be changed. A low frequency is inaudible, but it is a real signal. | Devices that fall asleep when they detect no signal: active monitors, some Bluetooth speakers |
| White / Brown / Pink Noise | Noise, at 1% by default. 0.1% is practically inaudible. | The same, when Sine doesn't help |

Parameters (the menu has presets; exact values can be typed in *More Parameters…*):

- **Frequency**: the number of fluctuations per second for Fluctuate (50 by default), the frequency of the tone for Sine (1 Hz by default).
- **Amplitude**: for Sine and noise, in percent (1 by default).
- **Length / Waiting**: how long a sound lasts, and how long the pause between sounds is, in seconds.
  A length without waiting is the same as playing all the time.
- **Fading**: fade-in and fade-out time (0.1 seconds by default).

**What to try, in this order**: start with the default Fluctuate. If the device still falls asleep or powers off after
a while, switch to Sine (10 Hz at 5% is inaudible). If that doesn't help either, try Brown Noise at 0.1%.
To make sure that the sound really reaches the device, choose Sine at 1000 Hz for a moment: it is audible, so use it for testing only.

> **Bluetooth speakers**: Bluetooth audio is lossy (SBC / AAC), and the ±1 LSB signal of Fluctuate turns into silence
> after encoding. So on Bluetooth it works exactly like Zero: what keeps the speaker awake is the audio link that stays open.
> It is enough for most speakers. If yours powers off by measuring how long it has been silent, use Sine or noise.

## Command line tool

`build/soundkeeper` is Sound Keeper without any user interface. It starts to do its job right after it is started.
Setting names are case insensitive.
It shares the single instance lock with the menu bar app: a newly started instance makes the previous one quit,
so they never run at the same time.

```
soundkeeper [settings]             Run until it is stopped
soundkeeper install [settings]     Start now and at every login (a per-user launchd agent)
soundkeeper uninstall              Stop and remove the login item
soundkeeper kill                   Stop the running instance (the menu bar app too)
soundkeeper status                 Show what is running and which outputs are kept awake
soundkeeper list [settings]        List outputs and show which of them the settings keep awake
```

Settings can be separate arguments or be glued together: `sine -f 1000 -a 15` and `SineF1000A15` are the same.

| Kind | Settings |
| --- | --- |
| Outputs | `primary` (default), `all`, `digital`, `analog`, `marked` (outputs with `!` in their name), `-d NAME` (the name contains NAME, or the UID is NAME; can be repeated), `remote` (don't ignore AirPlay) |
| Signal | `openonly`, `zero`, `fluctuate` (default), `sine`, `white`, `brown`, `pink` |
| Signal parameters | `-f` frequency in Hz, `-a` amplitude in %, `-l` length in seconds, `-w` waiting in seconds, `-t` fading in seconds |
| Sleep | `sleepd` (pause while displays are off), `sleepl` (pause while the screen is locked), `sleepld` or `sleepy` (both), `nosleep` (keep the Mac awake) |
| Other | `-v` prints what is going on |

```sh
soundkeeper                          # the default output, inaudible Fluctuate
soundkeeper all zero                 # a stream of zeroes on all outputs
soundkeeper sine -f 10 -a 5          # a 10 Hz sine wave at 5%, inaudible
soundkeeper sine -f 1000 -a 15       # 1000 Hz at 15%, audible! For testing only
soundkeeper brown -a 0.1             # brown noise at 0.1%
soundkeeper install -d JBL sine      # keep outputs named like "JBL" awake, starting at login
```

Settings can also be a part of the name of the executable file (`SoundKeeperSineF10A5`).
Unknown command line arguments are reported as errors.

## How it works

CoreAudio has a simple rule: **as long as at least one IOProc is running on a device, the HAL keeps its hardware working.
The moment the last IOProc is stopped, the hardware is stopped too** (`kAudioDevicePropertyDeviceIsRunningSomewhere`
goes from 1 to 0). That is the moment when the Bluetooth A2DP link, the audio data of HDMI, or the isochronous stream
of USB goes away, and the device starts counting the time until it falls asleep.

So Sound Keeper registers an IOProc on every device that has to be kept awake (`AudioDeviceCreateIOProcID` and
`AudioDeviceStart`) and never stops it. The IOProc is called by the real-time thread of the HAL and writes the keep-alive
signal into the output buffers. *Open Only* is `AudioDeviceStart(device, NULL)`: the hardware is started without any IOProc.

Everything else is about things that happen around it:

| What happens | What Sound Keeper does |
| --- | --- |
| The default output is changed, a device is connected or disconnected | It listens for `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices` and reconciles: streams are started for devices that are wanted now and stopped for those that are not. Streams of devices that are still wanted are not interrupted |
| The sample rate or the format of a device is changed | The generator is silenced at once, and the stream is restarted if the format is really different |
| Another app takes a device for exclusive use (hog mode) | It stops and waits until the device is released (`kAudioDevicePropertyHogMode`) |
| A stream stops for no known reason | A watchdog looks at the number of rendered buffers every 10 seconds and restarts a stalled stream |
| The Mac goes to sleep and wakes up, another user takes the screen | It stops before that and starts again after it (`NSWorkspace` notifications) |
| Displays go to sleep, the screen is locked | It pauses, if it is turned on in settings |
| The audio server (coreaudiod) is restarted | Everything is built again from scratch (`kAudioHardwarePropertyServiceRestarted`) |
| Sound Keeper is started once more | The new instance stops the old one: a POSIX lock on a file tells who is running, and `SIGTERM` asks it to quit |
| You log in | A per-user launchd agent starts it (`~/Library/LaunchAgents/local.soundkeeper.plist`) |

Some details:

- **It doesn't keep the Mac awake.** By default, coreaudiod holds a power assertion (`PreventUserIdleSystemSleep`)
  on behalf of any process that plays audio, so an endless stream would never let the Mac go to sleep on its own.
  Sound Keeper sets `kAudioHardwarePropertySleepingIsAllowed` for its process, and the assertion is not created.
  You can check it: while Sound Keeper is running, `pmset -g assertions | grep audio` doesn't show
  `Created for PID: <PID of Sound Keeper>`.
- **It wakes the CPU up as rarely as possible.** The size of the IO buffer is a per-process setting in macOS, it doesn't
  affect other apps. Sound Keeper sets its buffers to the biggest size a device allows (4096 frames for built-in speakers,
  which is about 12 callbacks a second; 1024 frames for Bluetooth, about 43 a second), and Fluctuate is rendered as
  "clear the buffer and set a few samples". Keeping two devices awake for 30 seconds takes about 0.03 seconds of CPU time.
- **There is only C on the real-time thread.** The IOProc and the signal generator are a separate C module
  (`Sources/CSoundKeeperRender`): no memory allocation, no locks and no Swift runtime on the render path.
  When the number of channels or the size of a buffer is not what it was when the stream was started, zeroes are written:
  float samples in a stream of another format would be a loud noise.
- **It doesn't touch microphones.** For devices with inputs (USB headsets, audio interfaces) the IOProc declares that
  it doesn't use input streams (`kAudioDevicePropertyIOProcStreamUsage`), so that recording is not started, and there is
  no microphone indicator and no permission request. (It is not tested with real hardware yet: the Mac it was developed on
  has no device with both inputs and outputs.)

## Things to know

- **Power.** A device that is kept working takes power. It matters for batteries of Bluetooth headphones and speakers,
  and for the battery of a MacBook when its built-in speakers are kept awake. If you care about just one device,
  check only it in *Outputs → Only Selected*: when it is disconnected, Sound Keeper won't start keeping built-in speakers awake instead.
- **AirPods and other headphones that switch between devices on their own.** The Mac is always "playing",
  which can get in the way of automatic switching to an iPhone. Think twice before keeping such headphones awake.
- **Volume.** The signal of Fluctuate is just 1 LSB. If the volume of a device is applied in software and it is not at 100%,
  the signal is rounded to zero, and Fluctuate works like Zero. Digital outputs usually don't have this problem.
- **Exclusive use.** While a player uses a device exclusively (hog mode), Sound Keeper waits.
  Keeping the device awake is the job of that player then.
- **Noise** is generated at the current sample rate of the device, so its spectrum is shifted up on devices that run at 96 kHz and higher.

## Files

| Path | What it is |
| --- | --- |
| `~/Library/Application Support/SoundKeeper/soundkeeper.lock` | The single instance lock |
| `~/Library/Application Support/SoundKeeper/status.json` | State of the running instance, for `soundkeeper status` |
| `~/Library/Application Support/SoundKeeper/soundkeeper` | The copy of the executable that `soundkeeper install` makes |
| `~/Library/LaunchAgents/local.soundkeeper.plist` | The login item. *Start at Login* of the app and `install` of the command line tool share it: the last one wins |
| `defaults read local.soundkeeper` | Settings of the menu bar app. They are saved as the same command line arguments |

## Troubleshooting

```sh
build/soundkeeper status      # what is running, which outputs are kept awake, whether their hardware is awake right now
build/soundkeeper list        # all outputs: transport, format, whether they are awake, whether the settings keep them awake
build/soundkeeper list all    # the same for another set of settings
/usr/bin/log show --last 10m --predicate 'subsystem == "local.soundkeeper"'    # the log of events
pmset -g assertions | grep -i audio                                            # who keeps the Mac awake
```

The AWAKE column of `list` is `kAudioDevicePropertyDeviceIsRunningSomewhere`. While Sound Keeper is running,
it has to be `yes` for every output that is kept awake.

## Source code

```
Sources/CSoundKeeperRender   C: the signal generator and the IOProc. It runs on the real-time thread
Sources/SoundKeeperCore      Settings and their parser, devices and their selection, sessions (SoundSession),
                             the keeper that runs them (SoundKeeper), power events, the single instance lock, the login item
Sources/SoundKeeperUI        The menu bar app: the status bar icon, the menu, the panel with parameters
Sources/SoundKeeperApp       The entry point of the app
Sources/soundkeeper          The command line tool
Resources                    Info.plist, the icon, localizations
Tests                        The signal generator against a straightforward reference implementation, sample by sample;
                             protection of the IOProc against unexpected buffers and formats; parsing of settings;
                             selection of devices; the logic of the keeper; behavior of the menu; completeness of
                             localizations; and optional tests with real hardware
```

Tests with real hardware are not run by default. They are silent and use only built-in speakers that are idle:

```sh
SOUNDKEEPER_HARDWARE_TESTS=1 make test
SOUNDKEEPER_HARDWARE_TESTS=1 swift test --sanitize=address --filter HardwareTests   # with Command Line Tools only, add TEST_FLAGS from the Makefile
```

## License

MIT, see [LICENSE](LICENSE). Based on [Sound Keeper](https://github.com/vrubleg/soundkeeper) by Evgeny Vrublevsky.
