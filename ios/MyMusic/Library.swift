import SwiftUI
import AVFoundation

@MainActor final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()
    @Published var tracks: [Track] = []
    @Published var connected = false
    @Published var refreshing = false
    @Published var status = "Connecting to your library…"
    @Published var error: String?
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey:"favorites") ?? [])
    @Published var lastSync: Date?
    @Published var albums: [Album] = []
    init() { tracks = Disk.read([Track].self, "library.json") ?? []; rebuildAlbums() }
    func rebuildAlbums() {
        albums = Dictionary(grouping: tracks, by: \.albumID).map { Album(id:$0.key, tracks:$0.value.sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) }) }.sorted { ($0.artist.localizedLowercase,$0.title.localizedLowercase) < ($1.artist.localizedLowercase,$1.title.localizedLowercase) }
    }
    func sync() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        do {
            let response = try JSONDecoder().decode(LibraryResponse.self, from: await API.shared.data("v1/library"))
            tracks = response.tracks; rebuildAlbums(); try Disk.write(tracks, "library.json")
            connected = true; error = nil; lastSync = Date()
            status = response.scanning ? "Indexing your music… pull to refresh" : "\(tracks.count.formatted()) tracks · Original quality"
            if response.scanErrors > 0 { status += " · \(response.scanErrors) unreadable files" }
            if response.scanning {
                Task { try? await Task.sleep(for:.seconds(10)); await self.sync() }
            }
        } catch {
            connected = false
            status = "Offline · Your downloads are ready"
            self.error = tracks.isEmpty ? "Can't reach your music server. Connect to your home Wi-Fi and refresh." : nil
        }
    }
    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        UserDefaults.standard.set(Array(favorites), forKey:"favorites")
    }
}

@MainActor final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()
    @Published var records: [SavedDownload] = []
    @Published var error: String?
    @Published var wifiOnly = UserDefaults.standard.object(forKey:"wifiOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wifiOnly, forKey:"wifiOnly") }
    }
    @Published var limitGB = UserDefaults.standard.object(forKey:"limitGB") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(limitGB, forKey:"limitGB") }
    }
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private let delegate = DownloadDelegate()
    private var active: [String:Int] = [:]
    private var recovering = true
    var ready: [SavedDownload] { records.filter { $0.state == "ready" } }
    var usedBytes: Int64 { ready.reduce(0) { $0 + $1.track.bytes } }
    var reservedBytes: Int64 { records.filter { ["ready","queued","downloading"].contains($0.state) }.reduce(0) { $0 + $1.track.bytes } }
    override init() {
        super.init()
        records = Disk.read([SavedDownload].self,"downloads.json") ?? []
        delegate.owner = self
        let config = URLSessionConfiguration.background(withIdentifier:(Bundle.main.bundleIdentifier ?? "MyMusic") + ".downloads")
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.waitsForConnectivity = true; config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration:config, delegate:delegate, delegateQueue:nil)
        for i in records.indices where records[i].state == "ready" {
            if !validFile(records[i].track) { records[i].state = "failed"; records[i].error = "File is missing or incomplete. Tap retry." }
        }
        Task {
            for task in await session.allTasks {
                if let id = task.taskDescription, records.contains(where: { $0.id == id && $0.state == "downloading" }) { active[id] = task.taskIdentifier }
                else { task.cancel() }
            }
            for i in records.indices where records[i].state == "downloading" && active[records[i].id] == nil {
                records[i].state = validFile(records[i].track) ? "ready" : "queued"
            }
            recovering = false; persist(); pump()
        }
    }
    func validFile(_ track: Track) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: Disk.file(track).path)[.size] as? NSNumber)?.int64Value
        return size == track.bytes
    }
    func localURL(_ track: Track) -> URL? {
        records.contains(where: { $0.id == track.id && $0.state == "ready" }) && validFile(track) ? Disk.file(track) : nil
    }
    func record(_ track: Track) -> SavedDownload? { records.first { $0.id == track.id } }
    func persist() {
        do { try Disk.write(records, "downloads.json") }
        catch { self.error = "Couldn't save download state: " + error.localizedDescription }
    }
    func enqueue(_ tracks: [Track]) {
        error = nil
        for track in tracks {
            if let r = record(track), ["ready","queued","downloading"].contains(r.state) { continue }
            guard reservedBytes + track.bytes <= Int64(limitGB) * 1_000_000_000 else { error = "Download limit reached. Remove some downloads or increase the limit in Settings."; break }
            let available = (try? Disk.root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
            let pending = reservedBytes - usedBytes
            guard available > pending + track.bytes + 256_000_000 else { error = "Your iPhone needs more free space for these downloads."; break }
            records.removeAll { $0.id == track.id }; records.append(SavedDownload(track:track))
        }
        persist(); pump()
    }
    private func pump() {
        guard !recovering else { return }
        for i in records.indices where records[i].state == "queued" {
            guard active.count < 2 else { break }
            do {
                var request = try API.shared.request("v1/tracks/\(records[i].id)/file")
                request.allowsCellularAccess = !wifiOnly; request.allowsExpensiveNetworkAccess = !wifiOnly
                request.timeoutInterval = 60
                let task = session.downloadTask(with:request)
                task.taskDescription = records[i].id; active[records[i].id] = task.taskIdentifier
                records[i].state = "downloading"; records[i].error = nil; task.resume()
            } catch { records[i].state = "failed"; records[i].error = error.localizedDescription }
        }
        persist()
    }
    func progress(_ id: String, taskID: Int, bytes: Int64) {
        guard active[id] == taskID, let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].progress = min(1,Double(bytes)/Double(max(1,records[i].track.bytes)))
    }
    func finished(_ id: String, taskID: Int, temporary: URL?, failure: String?) {
        guard active[id] == taskID, let i = records.firstIndex(where: { $0.id == id }) else {
            if let temporary { try? FileManager.default.removeItem(at:temporary) }; return
        }
        active[id] = nil
        do {
            if let failure { throw NSError(domain:"Download",code:1,userInfo:[NSLocalizedDescriptionKey:failure]) }
            guard let temporary else { throw URLError(.cannotCreateFile) }
            let size = (try FileManager.default.attributesOfItem(atPath:temporary.path)[.size] as? NSNumber)?.int64Value
            guard size == records[i].track.bytes else { try? FileManager.default.removeItem(at:temporary); throw NSError(domain:"Download",code:2,userInfo:[NSLocalizedDescriptionKey:"The file was incomplete or changed on the server. Refresh and retry."]) }
            let destination = Disk.file(records[i].track)
            if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
            try FileManager.default.moveItem(at:temporary, to:destination)
            records[i].state = "ready"; records[i].progress = 1; records[i].error = nil
            let track = records[i].track
            Task { _ = await ArtworkStore.shared.image(track) }
        } catch { records[i].state = "failed"; records[i].error = error.localizedDescription }
        persist(); pump()
    }
    func remove(_ track: Track) {
        let taskID = active.removeValue(forKey:track.id)
        if let taskID { Task { for task in await session.allTasks where task.taskIdentifier == taskID { task.cancel() } } }
        do {
            if FileManager.default.fileExists(atPath:Disk.file(track).path) { try FileManager.default.removeItem(at:Disk.file(track)) }
            records.removeAll { $0.id == track.id }; persist(); pump()
        } catch { self.error = error.localizedDescription }
    }
}
final class DownloadDelegate: PinnedDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: Downloads?
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in owner?.progress(id, taskID:downloadTask.taskIdentifier, bytes:totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        var temporary: URL?; var failure: String?
        if (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 { failure = "Server couldn't provide this file. Refresh the library and retry." }
        else {
            do {
                let target = Disk.root.appendingPathComponent(UUID().uuidString + ".incoming")
                try FileManager.default.moveItem(at:location,to:target); temporary = target
            } catch { failure = error.localizedDescription }
        }
        let saved = temporary; let message = failure
        Task { @MainActor in owner?.finished(id,taskID:downloadTask.taskIdentifier,temporary:saved,failure:message) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        Task { @MainActor in owner?.finished(id,taskID:task.taskIdentifier,temporary:nil,failure:error.localizedDescription) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in owner?.backgroundCompletion?(); owner?.backgroundCompletion = nil }
    }
}
