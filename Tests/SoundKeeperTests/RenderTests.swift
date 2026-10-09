import CoreAudio
import CSoundKeeperRender
import Foundation
import Testing

/// A straightforward port of CSoundSession::Render() of Sound Keeper for Windows: one sample at a time, exactly like
/// the original does it. The optimized generator must produce the same signal.
private struct ReferenceSignal {
    var type: SKStreamType
    var rate: Double
    var frequency: Double
    var amplitude: Double
    var playSeconds: Double
    var waitSeconds: Double
    var fadeSeconds: Double
    var use16BitStep: Bool
    var lcg: UInt64

    var current: UInt64 = 0
    var theta = 0.0
    var brown = 0.0
    var pink = [Double](repeating: 0, count: 7)

    mutating func render(_ frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)

        var playFrames = UInt64(playSeconds * rate)
        var waitFrames = UInt64(waitSeconds * rate)
        var fadeFrames = UInt64(fadeSeconds * rate)

        if waitFrames == 0 && fadeFrames == 0 {
            playFrames = 0
        } else if playFrames == 0 {
            waitFrames = 0
        }
        if playFrames != 0 {
            fadeFrames = min(fadeFrames, playFrames / 2)
        }
        let periodFrames = playFrames + waitFrames

        func advance(_ current: inout UInt64) {
            current += 1
            if periodFrames != 0 { current %= periodFrames }
        }

        func envelope(_ current: UInt64) -> Double {
            var amplitude = self.amplitude
            if periodFrames != 0 || current < fadeFrames {
                if current < fadeFrames {
                    let volume = (1.0 / Double(fadeFrames)) * Double(current)
                    amplitude *= volume * volume
                } else if playFrames == 0 || current < (playFrames - fadeFrames) {
                    // Max volume.
                } else if current < playFrames {
                    let volume = (1.0 / Double(fadeFrames)) * Double(playFrames - current)
                    amplitude *= volume * volume
                } else {
                    amplitude = 0
                }
            }
            return amplitude
        }

        let isNoise = type == .whiteNoise || type == .brownNoise || type == .pinkNoise

        if periodFrames != 0 && playFrames <= current && (current + UInt64(frames)) <= periodFrames {
            current = (current + UInt64(frames)) % periodFrames
        } else if type == .fluctuate && frequency != 0 {
            let onceInFrames = max(UInt64(rate / frequency), 2)
            for index in 0..<frames {
                var bits: UInt32 = 0
                if (periodFrames == 0 || current < playFrames) && current % onceInFrames == 0 {
                    bits = use16BitStep ? 0x3800_0100 : 0x3400_0001
                    if (current / onceInFrames) & 1 != 0 { bits |= 0x8000_0000 }
                }
                out[index] = Float(bitPattern: bits)
                advance(&current)
            }
        } else if type == .sine && frequency != 0 && amplitude != 0 {
            let thetaIncrement = (min(frequency, rate / 2.0) * (Double.pi * 2)) / rate
            for index in 0..<frames {
                let amplitude = envelope(current)
                if amplitude != 0 {
                    out[index] = Float(sin(theta) * amplitude)
                    theta += thetaIncrement
                }
                advance(&current)
            }
        } else if isNoise && amplitude != 0 {
            for index in 0..<frames {
                let amplitude = envelope(current)
                if amplitude != 0 {
                    lcg = lcg &* 6364136223846793005 &+ 1
                    var value = (Double((lcg >> 32) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)) * 2.0 - 1.0

                    if type == .brownNoise {
                        brown += value * (1.0 / 16)
                        brown /= 1.02
                        brown = fmod(brown, 4)
                        value = brown
                        if value < -1.0 || 1.0 < value {
                            let sign = value < 0.0 ? -1.0 : 1.0
                            value = abs(value)
                            value = (value <= 3.0 ? (2.0 - value) : (value - 4.0)) * sign
                        }
                    } else if type == .pinkNoise {
                        let white = value
                        pink[0] = 0.99886 * pink[0] + white * 0.0555179
                        pink[1] = 0.99332 * pink[1] + white * 0.0750759
                        pink[2] = 0.96900 * pink[2] + white * 0.1538520
                        pink[3] = 0.86650 * pink[3] + white * 0.3104856
                        pink[4] = 0.55000 * pink[4] + white * 0.5329522
                        pink[5] = -0.7616 * pink[5] - white * 0.0168980
                        value = pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362
                        value *= 0.11
                        pink[6] = white * 0.115926
                    }

                    out[index] = Float(value * amplitude)
                }
                advance(&current)
            }
        }

        return out
    }
}

private func makeConfig(
    _ type: SKStreamType,
    rate: Double = 48000,
    frequency: Double = 0,
    amplitude: Double = 0,
    play: Double = 0,
    wait: Double = 0,
    fade: Double = 0,
    use16BitStep: Bool = false,
    seed: UInt64 = 0x1234_5678_9ABC_DEF0
) -> SKSignalConfig {
    SKSignalConfig(type: type, sampleRate: rate, frequency: frequency, amplitude: amplitude, playSeconds: play, waitSeconds: wait, fadeSeconds: fade, use16BitStep: use16BitStep, seed: seed)
}

/// Renders the same signal with the generator and with the reference in blocks of random sizes, and returns
/// the biggest difference between them.
private func maxDifference(_ config: SKSignalConfig, totalFrames: Int, channels: Int = 2, maxBlock: Int = 5000) -> Float {
    var config = config
    var signal = SKSignal()
    SKSignalInit(&signal, &config)

    var reference = ReferenceSignal(
        type: config.type, rate: config.sampleRate, frequency: config.frequency, amplitude: config.amplitude,
        playSeconds: config.playSeconds, waitSeconds: config.waitSeconds, fadeSeconds: config.fadeSeconds,
        use16BitStep: config.use16BitStep, lcg: config.seed
    )

    var random = SystemRandomNumberGenerator()
    var worst: Float = 0
    var done = 0

    while done < totalFrames {
        let frames = min(Int.random(in: 1...maxBlock, using: &random), totalFrames - done)

        var block = [Float](repeating: 123, count: frames * channels)
        SKSignalRender(&signal, &block, UInt32(frames), UInt32(channels))
        let expected = reference.render(frames)

        for frame in 0..<frames {
            for channel in 0..<channels {
                let difference = abs(block[frame * channels + channel] - expected[frame])
                if !(difference <= worst) { worst = difference.isNaN ? .infinity : difference }
            }
        }
        done += frames
    }

    return worst
}

@Suite struct SignalTests {

    @Test func fluctuateIsBitExact() {
        // 44100 / 50 = 882 frames between fluctuations, 48000 / 7 is not an integer, 1 Hz is one fluctuation per second.
        for rate in [8000.0, 44100, 48000, 96000, 192000] {
            for frequency in [50.0, 7, 1, 1000, 30000, 1_000_000] {
                for use16BitStep in [false, true] {
                    let config = makeConfig(.fluctuate, rate: rate, frequency: frequency, use16BitStep: use16BitStep)
                    #expect(maxDifference(config, totalFrames: Int(rate) * 3) == 0, "rate \(rate), frequency \(frequency)")
                }
            }
        }
    }

    @Test func fluctuateWithPeriodIsBitExact() {
        let cases: [(play: Double, wait: Double, fade: Double)] = [
            (0.5, 0.25, 0), (0.1, 1.0, 0.05), (1.0, 0, 0.1), (0.013, 0.007, 0), (2, 3, 0), (0, 1, 0), (1, 0, 0),
        ]
        for rate in [44100.0, 48000] {
            for parameters in cases {
                let config = makeConfig(.fluctuate, rate: rate, frequency: 50, play: parameters.play, wait: parameters.wait, fade: parameters.fade)
                #expect(maxDifference(config, totalFrames: Int(rate) * 8) == 0, "\(parameters)")
            }
        }
    }

    @Test func fluctuateSamplesAreTheSmallestSteps() {
        for (use16BitStep, bits) in [(false, UInt32(0x3400_0001)), (true, UInt32(0x3800_0100))] {
            var config = makeConfig(.fluctuate, rate: 48000, frequency: 50, use16BitStep: use16BitStep)
            var signal = SKSignal()
            SKSignalInit(&signal, &config)

            var block = [Float](repeating: 1, count: 48000)
            SKSignalRender(&signal, &block, 48000, 1)

            let nonZero = block.enumerated().filter { $0.element != 0 }
            #expect(nonZero.count == 50)
            #expect(nonZero.map(\.offset) == (0..<50).map { $0 * 960 })
            // The sign is flipped each time.
            #expect(nonZero.map(\.element.bitPattern) == (0..<50).map { $0 % 2 == 0 ? bits : bits | 0x8000_0000 })
        }

        // The values survive conversion to integer PCM, even when it truncates and scales by 2^N-1.
        #expect(Int32(Float(bitPattern: 0x3800_0100) * 32767) == 1)
        #expect(Int32(Float(bitPattern: 0x3400_0001) * 8_388_607) == 1)
    }

    @Test func sineMatchesReference() {
        let cases: [(frequency: Double, amplitude: Double, play: Double, wait: Double, fade: Double)] = [
            (1, 0.01, 0, 0, 0.1),        // Defaults.
            (1000, 0.15, 0, 0, 0.1),     // The audible test tone.
            (10, 0.05, 0, 0, 0),
            (440, 1.0, 0.5, 0.5, 0.1),   // Periodic with fading.
            (440, 0.5, 0.2, 0, 0.05),    // Fades in and out without pauses.
            (440, 0.5, 0.01, 0.3, 1.0),  // Fading is longer than the sound.
            (90000, 0.3, 0, 0, 0),       // Above the half of the sample rate.
        ]
        for rate in [44100.0, 48000, 96000] {
            for parameters in cases {
                let config = makeConfig(.sine, rate: rate, frequency: parameters.frequency, amplitude: parameters.amplitude, play: parameters.play, wait: parameters.wait, fade: parameters.fade)
                // The phase of the original grows forever and slowly loses precision, while the generator keeps
                // it within one turn. So they drift apart a bit, most noticeably at the highest frequencies.
                #expect(maxDifference(config, totalFrames: Int(rate) * 4) < 1e-5, "rate \(rate), \(parameters)")
            }
        }
    }

    @Test func noiseMatchesReference() {
        for type in [SKStreamType.whiteNoise, .brownNoise, .pinkNoise] {
            for parameters in [(play: 0.0, wait: 0.0, fade: 0.1), (play: 0.3, wait: 0.2, fade: 0.1), (play: 0.0, wait: 0.0, fade: 0.0)] {
                let config = makeConfig(type, rate: 48000, amplitude: 0.01, play: parameters.play, wait: parameters.wait, fade: parameters.fade)
                #expect(maxDifference(config, totalFrames: 48000 * 4) < 1e-7, "\(type), \(parameters)")
            }
        }
    }

    @Test func signalsStayInRange() {
        // Full amplitude for a long time: nothing leaves -1...1, and there are no NaNs.
        for type in [SKStreamType.sine, .whiteNoise, .brownNoise, .pinkNoise] {
            var config = makeConfig(type, rate: 48000, frequency: 100, amplitude: 1.0, seed: 42)
            var signal = SKSignal()
            SKSignalInit(&signal, &config)

            var peak: Float = 0
            var sum = 0.0
            var block = [Float](repeating: 0, count: 4096)
            for _ in 0..<500 {
                SKSignalRender(&signal, &block, 4096, 1)
                for sample in block {
                    #expect(sample.isFinite)
                    peak = max(peak, abs(sample))
                    sum += Double(sample) * Double(sample)
                }
            }

            let rms = (sum / Double(4096 * 500)).squareRoot()
            #expect(peak <= 1.0, "\(type)")
            #expect(rms > 0.05, "\(type) is suspiciously quiet: \(rms)")
        }
    }

    @Test func amplitudeIsRespected() {
        // The default amplitude is 1%: nothing is louder than that.
        for type in [SKStreamType.sine, .whiteNoise, .brownNoise] {
            var config = makeConfig(type, rate: 48000, frequency: 100, amplitude: 0.01)
            var signal = SKSignal()
            SKSignalInit(&signal, &config)

            var block = [Float](repeating: 0, count: 48000)
            SKSignalRender(&signal, &block, 48000, 1)
            #expect((block.map { abs($0) }.max() ?? 1) <= 0.010001, "\(type)")
        }

        // Amplitude above 100% is clamped.
        var config = makeConfig(.sine, rate: 48000, frequency: 100, amplitude: 5)
        var signal = SKSignal()
        SKSignalInit(&signal, &config)
        var block = [Float](repeating: 0, count: 48000)
        SKSignalRender(&signal, &block, 48000, 1)
        #expect((block.map { abs($0) }.max() ?? 2) <= 1.0)
    }

    @Test func silentConfigurationsRenderZeroes() {
        let silent = [
            makeConfig(.openOnly), makeConfig(.zero, frequency: 50, amplitude: 1),
            makeConfig(.fluctuate, frequency: 0), makeConfig(.sine, frequency: 0, amplitude: 1), makeConfig(.sine, frequency: 100, amplitude: 0),
            makeConfig(.whiteNoise, amplitude: 0), makeConfig(.pinkNoise, amplitude: -1), makeConfig(.sine, frequency: .nan, amplitude: .nan),
        ]
        for config in silent {
            var config = config
            var signal = SKSignal()
            SKSignalInit(&signal, &config)
            var block = [Float](repeating: 0.5, count: 1024)
            SKSignalRender(&signal, &block, 512, 2)
            #expect(block.allSatisfy { $0 == 0 }, "\(config.type)")
        }
    }

    @Test func weirdParametersDoNotBreakAnything() {
        // Nothing here may crash, hang, or produce something that is not a number.
        let values: [Double] = [0, -1, 1e-9, 1e-300, 1e9, 1e300, .infinity, -.infinity, .nan]
        for type in [SKStreamType.fluctuate, .sine, .brownNoise] {
            for value in values {
                for rate in [48000.0, 0, -1, .nan, 1e12] {
                    var config = makeConfig(type, rate: rate, frequency: value, amplitude: 0.5, play: value, wait: value, fade: value)
                    var signal = SKSignal()
                    SKSignalInit(&signal, &config)
                    var block = [Float](repeating: 0, count: 2048)
                    for _ in 0..<4 { SKSignalRender(&signal, &block, 1024, 2) }
                    #expect(block.allSatisfy { $0.isFinite && abs($0) <= 1 }, "\(type), value \(value), rate \(rate)")
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------

/// Output buffers like the HAL passes to an IOProc: one interleaved buffer per stream, filled with garbage.
private final class OutputBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutableRawPointer] = []

    init(_ buffers: [(channels: Int, frames: Int, bytesPerSample: Int)], garbage: UInt8 = 0x7F) {
        list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        list.count = buffers.count
        for (index, buffer) in buffers.enumerated() {
            let size = buffer.channels * buffer.frames * buffer.bytesPerSample
            let data = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
            data.initializeMemory(as: UInt8.self, repeating: garbage, count: max(size, 1))
            storage.append(data)
            list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channels), mDataByteSize: UInt32(size), mData: data)
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func floats(_ index: Int) -> [Float] {
        let buffer = list[index]
        return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4))
    }

    func bytes(_ index: Int) -> [UInt8] {
        let buffer = list[index]
        return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize)))
    }
}

private func makeContext(_ config: SKSignalConfig, _ streams: [(channels: UInt32, writable: Bool)]) -> OpaquePointer {
    var config = config
    let layouts = streams.map { SKStreamLayout(channels: $0.channels, writable: $0.writable) }
    return SKRenderContextCreate(&config, layouts, UInt32(layouts.count))!
}

@Suite struct RenderContextTests {
    /// Audible on purpose: every sample is far from zero, so it's obvious where the signal was written.
    private let loud = makeConfig(.whiteNoise, amplitude: 1.0)

    @Test func writesTheSameSignalToAllChannelsAndStreams() {
        let context = makeContext(loud, [(2, true), (6, true), (1, true)])
        defer { SKRenderContextDestroy(context) }

        let buffers = OutputBuffers([(2, 512, 4), (6, 512, 4), (1, 512, 4)])
        SKRenderContextRender(context, buffers.list.unsafeMutablePointer)

        let mono = buffers.floats(2)
        #expect(mono.contains { $0 != 0 })
        #expect(buffers.floats(0) == mono.flatMap { [$0, $0] })
        #expect(buffers.floats(1) == mono.flatMap { [Float](repeating: $0, count: 6) })

        #expect(SKRenderContextGetCallbackCount(context) == 1)
        #expect(SKRenderContextGetFrameCount(context) == 512)
        #expect(SKRenderContextGetMismatchCount(context) == 0)
    }

    @Test func consecutiveCallsContinueTheSignal() {
        let config = makeConfig(.sine, frequency: 100, amplitude: 0.5)
        let context = makeContext(config, [(1, true)])
        defer { SKRenderContextDestroy(context) }

        var rendered: [Float] = []
        for frames in [100, 1, 512, 4096, 33] {
            let buffers = OutputBuffers([(1, frames, 4)])
            SKRenderContextRender(context, buffers.list.unsafeMutablePointer)
            rendered += buffers.floats(0)
        }

        var copy = config
        var signal = SKSignal()
        SKSignalInit(&signal, &copy)
        var expected = [Float](repeating: 0, count: rendered.count)
        SKSignalRender(&signal, &expected, UInt32(expected.count), 1)

        #expect(rendered == expected)
        #expect(SKRenderContextGetCallbackCount(context) == 5)
        #expect(SKRenderContextGetFrameCount(context) == UInt64(rendered.count))
    }

    @Test func disarmedContextRendersZeroes() {
        let context = makeContext(loud, [(2, true)])
        defer { SKRenderContextDestroy(context) }

        SKRenderContextSetArmed(context, false)
        let silent = OutputBuffers([(2, 256, 4)])
        SKRenderContextRender(context, silent.list.unsafeMutablePointer)
        #expect(silent.bytes(0).allSatisfy { $0 == 0 })

        SKRenderContextSetArmed(context, true)
        let audible = OutputBuffers([(2, 256, 4)])
        SKRenderContextRender(context, audible.list.unsafeMutablePointer)
        #expect(audible.floats(0).contains { $0 != 0 })
        #expect(SKRenderContextGetMismatchCount(context) == 0)
    }

    @Test func zeroStreamClearsBuffers() {
        let context = makeContext(makeConfig(.zero), [(2, true)])
        defer { SKRenderContextDestroy(context) }

        let buffers = OutputBuffers([(2, 1024, 4)])
        SKRenderContextRender(context, buffers.list.unsafeMutablePointer)
        #expect(buffers.bytes(0).allSatisfy { $0 == 0 })
        #expect(SKRenderContextGetFrameCount(context) == 1024)
    }

    @Test func streamsThatAreNotFloatGetZeroes() {
        // The second stream is not float PCM (for example, it is switched to an encoded format): never write samples to it.
        let context = makeContext(loud, [(2, true), (2, false)])
        defer { SKRenderContextDestroy(context) }

        let buffers = OutputBuffers([(2, 512, 4), (2, 512, 2)])
        SKRenderContextRender(context, buffers.list.unsafeMutablePointer)

        #expect(buffers.floats(0).contains { $0 != 0 })
        #expect(buffers.bytes(1).allSatisfy { $0 == 0 })
        #expect(SKRenderContextGetMismatchCount(context) == 0)
    }

    @Test func unexpectedLayoutGetsZeroes() {
        // The device was reconfigured behind our back: the number of channels, the number of streams, or the size of
        // frames is not what was found when the stream was started. Everything must be silent.
        let cases: [[(channels: Int, frames: Int, bytesPerSample: Int)]] = [
            [(1, 512, 4)],                 // Stereo became mono.
            [(6, 512, 4)],                 // Stereo became 5.1.
            [(2, 512, 4), (2, 512, 4)],    // One more stream.
            [(2, 171, 3)],                 // 24-bit packed samples: the size is not a multiple of a float frame.
            [],                            // No streams at all.
        ]

        for layout in cases {
            let context = makeContext(loud, [(2, true)])
            defer { SKRenderContextDestroy(context) }

            let buffers = OutputBuffers(layout)
            SKRenderContextRender(context, buffers.list.unsafeMutablePointer)

            for index in 0..<layout.count {
                #expect(buffers.bytes(index).allSatisfy { $0 == 0 }, "\(layout)")
            }
            if !layout.isEmpty {
                #expect(SKRenderContextGetMismatchCount(context) == 1, "\(layout)")
            }
            #expect(SKRenderContextGetCallbackCount(context) == 1)
        }
    }

    @Test func streamsWithDifferentSizesAreNotOverrun() {
        // The second buffer is shorter than the first one. It must not be written past its end.
        let context = makeContext(loud, [(2, true), (2, true)])
        defer { SKRenderContextDestroy(context) }

        let buffers = OutputBuffers([(2, 512, 4), (2, 100, 4)])
        SKRenderContextRender(context, buffers.list.unsafeMutablePointer)

        #expect(buffers.floats(0).contains { $0 != 0 })
        #expect(buffers.bytes(1).allSatisfy { $0 == 0 })
        #expect(SKRenderContextGetMismatchCount(context) == 1)
    }

    @Test func buffersWithoutDataAreSkipped() {
        let context = makeContext(loud, [(2, true), (2, true)])
        defer { SKRenderContextDestroy(context) }

        // A stream that is disabled for the IOProc has no data.
        let buffers = OutputBuffers([(2, 512, 4), (2, 512, 4)])
        let kept = buffers.list[0].mData
        buffers.list[0].mData = nil
        SKRenderContextRender(context, buffers.list.unsafeMutablePointer)
        buffers.list[0].mData = kept

        #expect(buffers.bytes(0).allSatisfy { $0 == 0x7F })
        #expect(buffers.floats(1).contains { $0 != 0 })
    }
}
