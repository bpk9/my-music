import Foundation
import SwiftUI

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let duration: Double
    let bytes: Int64
    let format: String
    let fileExtension: String
    let lossless: Bool
    let sampleRate: Int
    let bitDepth: Int
    let bitrate: Int
    let trackNumber: Int
    let added: Double
    var albumID: String { albumArtist + "\u{1F}" + album }
    var quality: String {
        if lossless {
            return [format, bitDepth > 0 ? "\(bitDepth)-bit" : nil, sampleRate > 0 ? String(format: "%g kHz", Double(sampleRate)/1000) : nil].compactMap { $0 }.joined(separator: " · ")
        }
        return [format, bitrate > 0 ? "\(bitrate/1000) kbps" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
struct Album: Identifiable {
    let id: String
    let tracks: [Track]
    var title: String { tracks[0].album }
    var artist: String { tracks[0].albumArtist }
    var cover: Track { tracks[0] }
    var lossless: Bool { tracks.allSatisfy(\.lossless) }
}
struct LibraryResponse: Decodable {
    let tracks: [Track]
    let scanning: Bool
    let lastScan: Double
    let scanErrors: Int
}
struct SavedDownload: Codable, Identifiable {
    var id: String { track.id }
    let track: Track
    var state: String = "queued"
    var progress: Double = 0
    var error: String?
}
enum Disk {
    static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = support.appendingPathComponent("MyMusic", isDirectory: true)
        let previous = support.appendingPathComponent("Undertone", isDirectory: true)
        if !FileManager.default.fileExists(atPath:url.path), FileManager.default.fileExists(atPath:previous.path) {
            // Preserve completed downloads and the saved library across the rename.
            do { try FileManager.default.moveItem(at:previous,to:url) }
            catch { url = previous } // Keep existing downloads usable if migration cannot finish.
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }()
    static func file(_ track: Track) -> URL { root.appendingPathComponent(track.id + "." + track.fileExtension) }
    static func write<T: Encodable>(_ value: T, _ name: String) throws { try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic) }
    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
func durationLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", value/60, value%60)
}
func byteLabel(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
