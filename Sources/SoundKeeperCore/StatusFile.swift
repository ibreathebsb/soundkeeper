import Foundation

/// The running instance describes what it is doing in a small JSON file, so `soundkeeper status` can show it.
public struct StatusFile {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func write(_ status: KeeperStatus) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try encoder.encode(status).write(to: url, options: .atomic)
        } catch {
            Log.debug("Unable to write \(url.path): \(error.localizedDescription)")
        }
    }

    public func read() -> KeeperStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeeperStatus.self, from: data)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
