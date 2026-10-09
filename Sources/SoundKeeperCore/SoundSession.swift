import CoreAudio
import CSoundKeeperRender
import Foundation

/// Something that keeps one audio output awake. The real one is `SoundSession`; tests use fakes.
public protocol KeepSession: AnyObject {
    var device: OutputDevice { get }
    /// The device is gone, so the session can't be used anymore.
    var isDead: Bool { get }
    var health: SessionHealth { get }
    /// A short description of the current state for humans.
    var stateDescription: String { get }

    var onInvalidated: (() -> Void)? { get set }
    var onStateChanged: (() -> Void)? { get set }

    func start()
    func stop()
    /// Called once in a while to check that the stream is still flowing.
    func checkHealth()
}

/// Keeps one audio output awake by running an IOProc on it. The counterpart of CSoundSession of the original.
///
/// The HAL powers the hardware of a device up when the first IOProc is started on it, and powers it down when the
/// last one is stopped. So an always running IOProc is what prevents the device from sleeping.
///
/// All methods are called on the main queue. Only the IOProc itself runs on the real-time thread of the HAL.
public final class SoundSession: KeepSession {

    enum State: Equatable {
        case stopped
        case running
        /// Another process uses the device in exclusive (hog) mode.
        case waitingExclusive(owner: pid_t)
        case retrying(attempt: Int)
        case dead
    }

    /// What the IOProc of the device is going to get, and what it is going to generate.
    struct StreamFormat: Equatable, CustomStringConvertible {
        var sampleRate: Double
        /// Number of channels in every output stream of the device.
        var channels: [UInt32]
        /// Whether every stream is 32-bit float PCM, which is the only format samples are written to.
        var writable: [Bool]
        var use16BitStep: Bool

        var description: String {
            var result = "\(Settings.format(sampleRate)) Hz, \(channels.map(String.init).joined(separator: "+")) ch"
            if writable.contains(false) { result += ", not float PCM (zeroes only)" }
            return result
        }
    }

    public let device: OutputDevice
    public var onInvalidated: (() -> Void)?
    public var onStateChanged: (() -> Void)?

    private let settings: Settings
    private let queue = DispatchQueue.main
    private var id: AudioDeviceID { device.id }
    private var label: String { "\"\(device.name)\"" }

    private var wantsRunning = false
    private var state = State.stopped {
        didSet { if state != oldValue { stateChanged() } }
    }

    private var procID: AudioDeviceIOProcID?
    private var context: OpaquePointer?
    private var startedWithoutProc = false
    private var format: StreamFormat?
    private var bufferFrames: UInt32 = 0

    private var deviceListeners: [PropertyListener] = []
    private var streamListeners: [PropertyListener] = []
    private var listenedStreams: [AudioStreamID] = []

    private var retryWork: DispatchWorkItem?
    private var formatWork: DispatchWorkItem?
    private var attempts = 0
    private var lastCallbackCount: UInt64 = 0
    private var stalledChecks = 0
    private var stallRestarts = 0

    public init(device: OutputDevice, settings: Settings) {
        self.device = device
        self.settings = settings
    }

    deinit {
        removeListeners()
        halt()
    }

    public var isDead: Bool { state == .dead }

    public var health: SessionHealth {
        switch state {
        case .running: return .active
        case .waitingExclusive: return .waiting
        case .retrying: return .failing
        case .stopped, .dead: return .inactive
        }
    }

    public var stateDescription: String {
        switch state {
        case .stopped:
            return "stopped"
        case .running:
            let details = [format?.description, bufferFrames > 0 ? "buffer \(bufferFrames) frames" : nil].compactMap { $0 }.joined(separator: ", ")
            return (startedWithoutProc ? "open, no stream" : "streaming") + (details.isEmpty ? "" : " (\(details))")
        case .waitingExclusive(let owner):
            return "waiting, the device is used exclusively by PID \(owner)"
        case .retrying(let attempt):
            return "can't start, retrying (attempt \(attempt))"
        case .dead:
            return "device is gone"
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Control.
    // -----------------------------------------------------------------------------------------------------------------

    public func start() {
        guard !wantsRunning, state != .dead else { return }

        wantsRunning = true
        attempts = 0
        installDeviceListeners()
        attemptStart()
    }

    public func stop() {
        wantsRunning = false
        cancelPendingWork()
        removeListeners()
        halt()
        if state != .dead { state = .stopped }
    }

    public func checkHealth() {
        guard wantsRunning else { return }

        switch state {
        case .running:
            if startedWithoutProc {
                let isRunning = (id.getValue(kAudioDevicePropertyDeviceIsRunning, as: UInt32.self) ?? 0) != 0
                stalledChecks = isRunning ? 0 : stalledChecks + 1
            } else if let context {
                let count = SKRenderContextGetCallbackCount(context)
                stalledChecks = count != lastCallbackCount ? 0 : stalledChecks + 1
                lastCallbackCount = count
            }

            if stalledChecks == 0 {
                stallRestarts = 0
                return
            }

            // The HAL pauses and resumes IO on its own in some cases, so one check without progress is not a problem.
            guard stalledChecks >= 2 else { return }
            stalledChecks = 0

            guard isAlive else { return markDead() }
            guard exclusiveOwner == nil else { return exclusiveOwnerChanged() }

            stallRestarts += 1
            if stallRestarts == 1 {
                Log.warning("The stream to \(label) is stalled. Restarting it.")
            } else {
                Log.debug("The stream to \(label) is still stalled. Restarting it (\(stallRestarts)).")
            }
            attemptStart()

        case .waitingExclusive:
            guard isAlive else { return markDead() }
            exclusiveOwnerChanged()

        case .stopped, .retrying, .dead:
            break
        }
    }

    private func attemptStart() {
        guard wantsRunning else { return }

        cancelPendingWork()
        halt()

        guard isAlive else { return markDead() }

        if let owner = exclusiveOwner {
            state = .waitingExclusive(owner: owner)
            return
        }

        refreshStreamListeners()

        let status = open()
        if status == noErr {
            attempts = 0
            stalledChecks = 0
            lastCallbackCount = 0
            // The format could be the same as before a restart, so the state has to be refreshed explicitly.
            if state == .running { stateChanged() } else { state = .running }
            return
        }

        guard isAlive else { return markDead() }

        attempts += 1
        let delays: [TimeInterval] = [0.5, 1, 2, 5]
        let delay = attempts <= delays.count ? delays[attempts - 1] : 10

        if attempts == 1 {
            Log.warning("Unable to start the stream to \(label): \(describeStatus(status)). Retrying.")
        } else {
            Log.debug("Unable to start the stream to \(label): \(describeStatus(status)). Attempt \(attempts), next in \(delay) s.")
        }
        state = .retrying(attempt: attempts)

        let work = DispatchWorkItem { [weak self] in self?.attemptStart() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func markDead() {
        guard state != .dead else { return }

        wantsRunning = false
        cancelPendingWork()
        removeListeners()
        halt()
        state = .dead
        onInvalidated?()
    }

    private func cancelPendingWork() {
        retryWork?.cancel()
        retryWork = nil
        formatWork?.cancel()
        formatWork = nil
    }

    private func stateChanged() {
        switch state {
        case .running:
            Log.info("Keeping \(label) awake: \(stateDescription).")
        case .waitingExclusive(let owner):
            Log.info("\(label) is used in exclusive mode by PID \(owner). Waiting until it is released.")
        case .dead:
            Log.info("\(label) is gone.")
        case .stopped, .retrying:
            break
        }
        onStateChanged?()
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Device state.
    // -----------------------------------------------------------------------------------------------------------------

    private var isAlive: Bool {
        (id.getValue(kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 0) != 0
    }

    /// PID of another process that owns the device in exclusive (hog) mode.
    private var exclusiveOwner: pid_t? {
        guard let owner = id.getValue(kAudioDevicePropertyHogMode, as: pid_t.self), owner != -1, owner != getpid() else {
            return nil
        }
        return owner
    }

    private func readFormat() -> StreamFormat {
        let channels = id.outputStreamChannels()
        let streams: [AudioStreamID] = id.getArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)

        var writable = [Bool](repeating: false, count: channels.count)
        var use16BitStep = false
        var streamRate: Double = 0

        // Buffers of the IOProc correspond to streams. If they can't be matched, nothing but zeroes is written.
        if streams.count == channels.count {
            for (index, stream) in streams.enumerated() {
                if let virtual = stream.getValue(kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) {
                    writable[index] = virtual.isNativeFloat32 && virtual.mChannelsPerFrame == channels[index]
                    if streamRate == 0 { streamRate = virtual.mSampleRate }
                }
                if let physical = stream.getValue(kAudioStreamPropertyPhysicalFormat, as: AudioStreamBasicDescription.self), physical.isInteger16OrLess {
                    use16BitStep = true
                }
            }
        }

        var sampleRate = id.getValue(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        if !(sampleRate > 0) { sampleRate = streamRate > 0 ? streamRate : 48000 }

        return StreamFormat(sampleRate: sampleRate, channels: channels, writable: writable, use16BitStep: use16BitStep)
    }

    // -----------------------------------------------------------------------------------------------------------------
    // IO.
    // -----------------------------------------------------------------------------------------------------------------

    private func open() -> OSStatus {
        let format = readFormat()
        self.format = format
        bufferFrames = maximizeBufferSize()

        if settings.stream == .openOnly {
            // The hardware is started, but there is no IOProc, so nothing is rendered by this process.
            let status = AudioDeviceStart(id, nil)
            startedWithoutProc = status == noErr
            return status
        }

        var config = SKSignalConfig(
            type: settings.stream.renderType,
            sampleRate: format.sampleRate,
            frequency: settings.frequency,
            amplitude: settings.amplitude,
            playSeconds: settings.playSeconds,
            waitSeconds: settings.waitSeconds,
            fadeSeconds: settings.fadeSeconds,
            use16BitStep: format.use16BitStep,
            seed: mach_absolute_time() ^ (UInt64(id) << 32)
        )
        let layouts = zip(format.channels, format.writable).map { SKStreamLayout(channels: $0, writable: $1) }

        guard let context = SKRenderContextCreate(&config, layouts, UInt32(layouts.count)) else {
            return OSStatus(kAudio_MemFullError)
        }

        var proc: AudioDeviceIOProcID?
        var status = SKRenderContextCreateIOProc(context, id, &proc)
        guard status == noErr, let proc else {
            SKRenderContextDestroy(context)
            return status != noErr ? status : kAudioHardwareUnspecifiedError
        }

        // Microphones of the device are not needed.
        let usageStatus = SKDisableInputStreams(id, proc)
        if usageStatus != noErr {
            Log.debug("Unable to disable input streams of \(label): \(describeStatus(usageStatus)).")
        }

        status = AudioDeviceStart(id, proc)
        guard status == noErr else {
            // The IOProc has never been called, so everything can be destroyed right away.
            AudioDeviceDestroyIOProcID(id, proc)
            SKRenderContextDestroy(context)
            return status
        }

        self.procID = proc
        self.context = context
        return noErr
    }

    /// Stops IO and frees everything. Does nothing if nothing is started.
    private func halt() {
        if let proc = procID {
            procID = nil
            // Errors are expected when the device is already gone.
            let stopStatus = AudioDeviceStop(id, proc)
            let destroyStatus = AudioDeviceDestroyIOProcID(id, proc)
            if stopStatus != noErr || destroyStatus != noErr {
                Log.debug("Stopping IO of \(label): stop \(describeStatus(stopStatus)), destroy \(describeStatus(destroyStatus)).")
            }
        }

        if let context {
            self.context = nil
            // AudioDeviceStop returns when the IOProc is not running anymore. But a use after free on the real-time
            // thread would be so nasty, that the memory is freed a bit later just in case, especially for the case
            // when the calls above failed because the device is gone.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                SKRenderContextDestroy(context)
            }
        }

        if startedWithoutProc {
            startedWithoutProc = false
            AudioDeviceStop(id, nil)
        }
    }

    /// The size of the IO buffer is a per-process setting, it doesn't affect other apps. The IOProc is called once
    /// per buffer, so the biggest possible buffer means the least possible number of wake-ups.
    private func maximizeBufferSize() -> UInt32 {
        if let range = id.getValue(kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self), range.mMaximum >= 1 {
            let wanted = UInt32(min(range.mMaximum, 65536))
            if id.getValue(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) != wanted {
                let status = id.setValue(kAudioDevicePropertyBufferFrameSize, to: wanted)
                if status != noErr {
                    Log.debug("Unable to set IO buffer size of \(label) to \(wanted) frames: \(describeStatus(status)).")
                }
            }
        }
        return id.getValue(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Notifications.
    // -----------------------------------------------------------------------------------------------------------------

    private func installDeviceListeners() {
        guard deviceListeners.isEmpty else { return }

        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceHasChanged, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]

        for (selector, scope) in properties {
            let listener = PropertyListener(object: id, selector: selector, scope: scope, queue: queue) { [weak self] selector in
                self?.deviceChanged(selector)
            }
            if let listener { deviceListeners.append(listener) }
        }
    }

    /// Formats are properties of streams, and streams of a device can be replaced with new ones.
    private func refreshStreamListeners() {
        let streams: [AudioStreamID] = id.getArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard streams != listenedStreams else { return }

        streamListeners.forEach { $0.invalidate() }
        streamListeners.removeAll()
        listenedStreams = streams

        for stream in streams {
            for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
                let listener = PropertyListener(object: stream, selector: selector, queue: queue) { [weak self] selector in
                    self?.deviceChanged(selector)
                }
                if let listener { streamListeners.append(listener) }
            }
        }
    }

    private func removeListeners() {
        (deviceListeners + streamListeners).forEach { $0.invalidate() }
        deviceListeners.removeAll()
        streamListeners.removeAll()
        listenedStreams.removeAll()
    }

    private func deviceChanged(_ selector: AudioObjectPropertySelector) {
        guard wantsRunning else { return }

        switch selector {
        case kAudioDevicePropertyDeviceIsAlive:
            if !isAlive { markDead() }
        case kAudioDevicePropertyHogMode:
            exclusiveOwnerChanged()
        default:
            formatMayHaveChanged()
        }
    }

    private func exclusiveOwnerChanged() {
        if let owner = exclusiveOwner {
            guard state != .waitingExclusive(owner: owner) else { return }
            // Be polite: don't mix anything into the exclusive stream of another app. It keeps the device awake itself.
            cancelPendingWork()
            halt()
            state = .waitingExclusive(owner: owner)
        } else if case .waitingExclusive = state {
            Log.info("\(label) is not used in exclusive mode anymore.")
            attemptStart()
        }
    }

    /// The HAL stops IO, changes the format, sends notifications, and then resumes IO with the same IOProc.
    /// So the generator is silenced right away, and then it's restarted if the format is really different.
    private func formatMayHaveChanged() {
        if let context { SKRenderContextSetArmed(context, false) }

        formatWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyFormatChange() }
        formatWork = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyFormatChange() {
        formatWork = nil
        guard wantsRunning, state == .running else { return }
        guard isAlive else { return markDead() }

        let current = readFormat()
        if startedWithoutProc || current == format {
            refreshStreamListeners()
            if let context { SKRenderContextSetArmed(context, true) }
            return
        }

        Log.info("Format of \(label) is changed to \(current). Restarting the stream.")
        attemptStart()
    }
}
