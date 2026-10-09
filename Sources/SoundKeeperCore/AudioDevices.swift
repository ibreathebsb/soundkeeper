import CoreAudio
import Foundation

/// How an audio device is connected (kAudioDevicePropertyTransportType).
public struct Transport: Equatable {
    public var code: UInt32

    public init(code: UInt32) { self.code = code }

    public static let unknown = Transport(code: 0)
    public static let builtIn = Transport(code: kAudioDeviceTransportTypeBuiltIn)
    public static let aggregate = Transport(code: kAudioDeviceTransportTypeAggregate)
    public static let virtual = Transport(code: kAudioDeviceTransportTypeVirtual)
    public static let usb = Transport(code: kAudioDeviceTransportTypeUSB)
    public static let bluetooth = Transport(code: kAudioDeviceTransportTypeBluetooth)
    public static let bluetoothLE = Transport(code: kAudioDeviceTransportTypeBluetoothLE)
    public static let hdmi = Transport(code: kAudioDeviceTransportTypeHDMI)
    public static let displayPort = Transport(code: kAudioDeviceTransportTypeDisplayPort)
    public static let airPlay = Transport(code: kAudioDeviceTransportTypeAirPlay)
    public static let thunderbolt = Transport(code: kAudioDeviceTransportTypeThunderbolt)

    public var name: String {
        switch code {
        case 0: return "Unknown"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return fourCharacterCode(code)
        }
    }
}

/// An audio device that has output channels.
public struct OutputDevice: Equatable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var transport: Transport
    /// The device has a digital audio interface terminal: S/PDIF, HDMI or DisplayPort.
    public var hasDigitalTerminal: Bool
    /// The device is not shown to the user.
    public var isHidden: Bool
    /// The device can be selected as the default output.
    public var canBeDefault: Bool
    public var channels: Int
    public var sampleRate: Double
    /// Some process is playing something (maybe silence) on the device right now, so the hardware is awake.
    public var isRunningSomewhere: Bool

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        transport: Transport,
        hasDigitalTerminal: Bool = false,
        isHidden: Bool = false,
        canBeDefault: Bool = true,
        channels: Int = 2,
        sampleRate: Double = 48000,
        isRunningSomewhere: Bool = false
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasDigitalTerminal = hasDigitalTerminal
        self.isHidden = isHidden
        self.canBeDefault = canBeDefault
        self.channels = channels
        self.sampleRate = sampleRate
        self.isRunningSomewhere = isRunningSomewhere
    }

    /// S/PDIF, HDMI and DisplayPort outputs.
    public var isDigital: Bool {
        hasDigitalTerminal || transport == .hdmi || transport == .displayPort
    }

    /// AirPlay is the macOS counterpart of the remote desktop audio device, which the original ignores by default.
    public var isRemote: Bool { transport == .airPlay }
}

public struct AudioSnapshot: Equatable {
    public var devices: [OutputDevice]
    public var defaultOutputID: AudioDeviceID?

    public init(devices: [OutputDevice], defaultOutputID: AudioDeviceID?) {
        self.devices = devices
        self.defaultOutputID = defaultOutputID
    }
}

/// The audio hardware as seen by `SoundKeeper`. The real one is `CoreAudioSystem`; tests use a fake.
public protocol AudioSystem: AnyObject {
    /// Applies per-process settings of the audio hardware. Called before any IO is started.
    func configureProcess(preventSystemSleep: Bool)

    func snapshot() -> AudioSnapshot

    /// Called on the main queue when the list of devices or the default output device is changed.
    var onDevicesChanged: (() -> Void)? { get set }
    /// Called on the main queue when the audio server was restarted, so all known audio objects are gone.
    var onServiceRestarted: (() -> Void)? { get set }

    func startObserving()
    func stopObserving()
}

public final class CoreAudioSystem: AudioSystem {
    public var onDevicesChanged: (() -> Void)?
    public var onServiceRestarted: (() -> Void)?

    private var listeners: [PropertyListener] = []

    public init() {}

    public func configureProcess(preventSystemSleep: Bool) {
        // By default, coreaudiod holds a PreventUserIdleSystemSleep power assertion on behalf of any process that is
        // doing audio IO, so the Mac would never go to sleep on its own while Sound Keeper is running. This property
        // tells the HAL that IO of this process is not a reason to stay awake.
        let sleepingIsAllowed: UInt32 = preventSystemSleep ? 0 : 1
        var status = systemAudioObject.setValue(kAudioHardwarePropertySleepingIsAllowed, to: sleepingIsAllowed)
        if status != noErr {
            Log.warning("Unable to set SleepingIsAllowed: \(describeStatus(status)). The Mac may not go to sleep automatically.")
        }

        // Latency doesn't matter here, so let the HAL choose what is the best for power consumption.
        status = systemAudioObject.setValue(kAudioHardwarePropertyPowerHint, to: AudioHardwarePowerHint.favorSavingPower.rawValue)
        if status != noErr {
            Log.debug("Unable to set PowerHint: \(describeStatus(status)).")
        }
    }

    public func snapshot() -> AudioSnapshot {
        let ids: [AudioDeviceID] = systemAudioObject.getArray(kAudioHardwarePropertyDevices)
        let devices = ids.compactMap { Self.outputDevice($0) }

        var defaultID: AudioDeviceID? = systemAudioObject.getValue(kAudioHardwarePropertyDefaultOutputDevice)
        if defaultID == kAudioObjectUnknown { defaultID = nil }

        return AudioSnapshot(devices: devices, defaultOutputID: defaultID)
    }

    static func outputDevice(_ id: AudioDeviceID) -> OutputDevice? {
        let channels = id.outputStreamChannels().reduce(0, +)
        guard channels > 0, let uid = id.getString(kAudioDevicePropertyDeviceUID) else { return nil }

        let output = kAudioObjectPropertyScopeOutput
        let streams: [AudioStreamID] = id.getArray(kAudioDevicePropertyStreams, scope: output)

        let digitalTerminals: Set<UInt32> = [
            kAudioStreamTerminalTypeDigitalAudioInterface,
            kAudioStreamTerminalTypeHDMI,
            kAudioStreamTerminalTypeDisplayPort,
        ]
        let spdifDataSource: UInt32 = 0x7370_6466 // 'spdf', the digital output of old built-in audio.

        let hasDigitalTerminal = streams.contains { stream in
            digitalTerminals.contains(stream.getValue(kAudioStreamPropertyTerminalType, as: UInt32.self) ?? 0)
        } || id.getValue(kAudioDevicePropertyDataSource, scope: output, as: UInt32.self) == spdifDataSource

        return OutputDevice(
            id: id,
            uid: uid,
            name: id.getString(kAudioObjectPropertyName) ?? uid,
            transport: Transport(code: id.getValue(kAudioDevicePropertyTransportType) ?? 0),
            hasDigitalTerminal: hasDigitalTerminal,
            isHidden: (id.getValue(kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) != 0,
            canBeDefault: (id.getValue(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: output, as: UInt32.self) ?? 1) != 0,
            channels: Int(channels),
            sampleRate: id.getValue(kAudioDevicePropertyNominalSampleRate) ?? 0,
            isRunningSomewhere: (id.getValue(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0) != 0
        )
    }

    public func startObserving() {
        guard listeners.isEmpty else { return }

        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            let listener = PropertyListener(object: systemAudioObject, selector: selector) { [weak self] _ in
                self?.onDevicesChanged?()
            }
            if let listener { listeners.append(listener) }
        }

        let listener = PropertyListener(object: systemAudioObject, selector: kAudioHardwarePropertyServiceRestarted) { [weak self] _ in
            self?.onServiceRestarted?()
        }
        if let listener { listeners.append(listener) }

        if listeners.count < 3 {
            Log.warning("Unable to listen for some audio hardware notifications.")
        }
    }

    public func stopObserving() {
        listeners.forEach { $0.invalidate() }
        listeners.removeAll()
    }
}
