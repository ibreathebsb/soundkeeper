import CoreAudio
import Foundation
import SoundKeeperCore
import Testing

enum Fixture {
    static let speakers = OutputDevice(id: 71, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn)
    static let jbl = OutputDevice(id: 85, uid: "00-11-22-33-44-55:output", name: "JBL GO 2", transport: .bluetooth, sampleRate: 44100)
    static let display = OutputDevice(id: 90, uid: "AppleGFXHDAEngineOutputDP:0", name: "LG HDR 4K", transport: .displayPort)
    static let receiver = OutputDevice(id: 91, uid: "hdmi", name: "DENON-AVR", transport: .hdmi, channels: 8)
    static let optical = OutputDevice(id: 92, uid: "optical", name: "Digital Out", transport: .builtIn, hasDigitalTerminal: true)
    static let dac = OutputDevice(id: 93, uid: "usb", name: "USB DAC!", transport: .usb)
    static let airPlay = OutputDevice(id: 94, uid: "airplay", name: "Living Room", transport: .airPlay)
    static let blackHole = OutputDevice(id: 95, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: .virtual)
    static let multiOutput = OutputDevice(id: 96, uid: "aggregate", name: "Multi-Output Device", transport: .aggregate)
    static let hidden = OutputDevice(id: 97, uid: "hidden", name: "Hidden", transport: .usb, isHidden: true)
    static let special = OutputDevice(id: 98, uid: "special", name: "Special", transport: .usb, canBeDefault: false)
    static let airPods = OutputDevice(id: 99, uid: "airpods", name: "Alice’s AirPods Pro", transport: .bluetooth)

    static let everything = [speakers, jbl, display, receiver, optical, dac, airPlay, blackHole, multiOutput, hidden, special, airPods]
}

private func kept(_ line: String, default defaultDevice: OutputDevice? = Fixture.jbl, devices: [OutputDevice] = Fixture.everything) throws -> [String] {
    let settings = try SettingsParser.parse(arguments: line.split(separator: " ").map(String.init)).settings
    return kept(settings, default: defaultDevice, devices: devices)
}

private func kept(_ settings: Settings, default defaultDevice: OutputDevice? = Fixture.jbl, devices: [OutputDevice] = Fixture.everything) -> [String] {
    decideDevices(settings: settings, snapshot: AudioSnapshot(devices: devices, defaultOutputID: defaultDevice?.id))
        .filter(\.keep)
        .map(\.device.name)
}

@Suite struct DeviceSelectionTests {

    @Test func primaryIsTheDefaultOutput() throws {
        #expect(try kept("") == ["JBL GO 2"])
        #expect(try kept("", default: Fixture.speakers) == ["MacBook Pro Speakers"])
        #expect(try kept("", default: nil) == [])
        #expect(try kept("", devices: []) == [])

        // Whatever the default output is, it is kept: virtual and aggregate devices play to real ones.
        #expect(try kept("", default: Fixture.blackHole) == ["BlackHole 2ch"])
        #expect(try kept("", default: Fixture.multiOutput) == ["Multi-Output Device"])
    }

    @Test func airPlayIsIgnoredUnlessAllowed() throws {
        #expect(try kept("", default: Fixture.airPlay) == [])
        #expect(try kept("remote", default: Fixture.airPlay) == ["Living Room"])
        #expect(!(try kept("all")).contains("Living Room"))
        #expect(try kept("all remote").contains("Living Room"))
    }

    @Test func allMeansRealHardware() throws {
        #expect(try kept("all") == ["MacBook Pro Speakers", "JBL GO 2", "LG HDR 4K", "DENON-AVR", "Digital Out", "USB DAC!", "Alice’s AirPods Pro"])
    }

    @Test func digitalAndAnalog() throws {
        #expect(try kept("digital") == ["LG HDR 4K", "DENON-AVR", "Digital Out"])
        #expect(try kept("analog") == ["MacBook Pro Speakers", "JBL GO 2", "USB DAC!", "Alice’s AirPods Pro"])

        // Together they are all.
        #expect(Set(try kept("digital") + kept("analog")) == Set(try kept("all")))
    }

    @Test func marked() throws {
        #expect(try kept("marked") == ["USB DAC!"])
    }

    @Test func named() {
        var settings = Settings()

        settings.devices = .named(["jbl"])
        #expect(kept(settings) == ["JBL GO 2"])

        settings.devices = .named(["BuiltInSpeakerDevice", "denon"])
        #expect(kept(settings) == ["MacBook Pro Speakers", "DENON-AVR"])

        // An explicitly named device is kept whatever it is.
        settings.devices = .named(["Living Room", "BlackHole", "Hidden"])
        #expect(kept(settings) == ["Living Room", "BlackHole 2ch", "Hidden"])

        // A usual apostrophe matches the typographic one of the system.
        settings.devices = .named(["alice's airpods"])
        #expect(kept(settings) == ["Alice’s AirPods Pro"])

        settings.devices = .named(["nothing like this"])
        #expect(kept(settings) == [])
    }

    @Test func everyDeviceGetsAReason() throws {
        let settings = try SettingsParser.parse(arguments: ["digital"]).settings
        let decisions = decideDevices(settings: settings, snapshot: AudioSnapshot(devices: Fixture.everything, defaultOutputID: Fixture.jbl.id))

        #expect(decisions.count == Fixture.everything.count)
        #expect(decisions.allSatisfy { !$0.reason.isEmpty })
        #expect(decisions.filter(\.isDefault).map(\.device.name) == ["JBL GO 2"])
        #expect(decisions.first { $0.device.name == "BlackHole 2ch" }?.reason == "virtual device")
        #expect(decisions.first { $0.device.name == "JBL GO 2" }?.reason == "not a digital output")
    }
}
