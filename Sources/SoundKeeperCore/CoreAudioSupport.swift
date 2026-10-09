import CoreAudio
import Foundation

// Thin helpers over the C API of the CoreAudio HAL (AudioObject properties).

let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)

func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// "'!hog' (560492391)" for errors that are four character codes, a plain number otherwise.
func describeStatus(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
    return String(status)
}

func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(decoding: bytes, as: UTF8.self)
    }
    return String(format: "0x%08X", value)
}

extension AudioObjectID {

    func hasProperty(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = audioPropertyAddress(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    /// Reads a property that is a plain fixed size value: UInt32, Float64, pid_t, AudioStreamBasicDescription, etc.
    func getValue<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type = T.self) -> T? {
        var address = audioPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)

        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer) == noErr, size == UInt32(MemoryLayout<T>.size) else {
            return nil
        }
        return buffer.load(as: T.self)
    }

    /// Reads a property that is an array of plain values, like a list of object IDs.
    func getArray<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type = T.self) -> [T] {
        var address = audioPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }

        size = UInt32(count * MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer) == noErr else { return [] }

        return Array(UnsafeBufferPointer(start: buffer, count: Swift.min(count, Int(size) / MemoryLayout<T>.stride)))
    }

    func getString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = audioPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }

        return value.takeRetainedValue() as String
    }

    @discardableResult
    func setValue<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, to value: T) -> OSStatus {
        var address = audioPropertyAddress(selector, scope: scope)
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    /// Number of channels in each output stream. The IOProc of the device gets one buffer per stream, in this order.
    func outputStreamChannels() -> [UInt32] {
        var address = audioPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, Int(size) >= MemoryLayout<UInt32>.size else {
            return []
        }

        let byteCount = Swift.max(Int(size), MemoryLayout<AudioBufferList>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer) == noErr else { return [] }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }
}

extension AudioStreamBasicDescription {
    /// Interleaved native endian 32-bit float PCM: the format of all mixable streams of the HAL.
    var isNativeFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && (mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
            && (mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            && mBitsPerChannel == 32
            && mChannelsPerFrame > 0
            && mBytesPerFrame == 4 * mChannelsPerFrame
    }

    /// Integer PCM with 16 bits or less.
    var isInteger16OrLess: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) == 0
            && mBitsPerChannel > 0
            && mBitsPerChannel <= 16
    }
}

/// Listens for changes of a property of an audio object. The handler is called on the specified queue.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init?(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue = .main,
        handler: @escaping (AudioObjectPropertySelector) -> Void
    ) {
        self.object = object
        self.address = audioPropertyAddress(selector, scope: scope)
        self.queue = queue

        // The very same block object has to be passed to remove the listener, so it's kept.
        let block: AudioObjectPropertyListenerBlock = { count, addresses in
            for index in 0..<Int(count) {
                handler(addresses[index].mSelector)
            }
        }

        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        self.block = block
    }

    func invalidate() {
        guard let block else { return }
        self.block = nil

        let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        if status != noErr && status != kAudioHardwareBadObjectError {
            Log.debug("Unable to remove listener of '\(fourCharacterCode(address.mSelector))' from object \(object): \(describeStatus(status)).")
        }
    }

    deinit {
        invalidate()
    }
}
