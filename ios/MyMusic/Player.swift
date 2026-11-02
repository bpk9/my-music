import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

// AVFoundation asks for ranges; each range is fetched over certificate-pinned HTTPS.
// Bounded 512 KiB requests avoid loading whole FLAC albums into memory.
final class MusicResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let track: Track
    private var tasks: [ObjectIdentifier: Task<Void,Never>] = [:]
    private let queue = DispatchQueue(label:"MyMusic.media")
    init(track: Track) { self.track = track }
    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url:URL(string:"mymusic://library/\(track.id).\(track.fileExtension)")!,
                               options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        asset.resourceLoader.setDelegate(self, queue:queue)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        if let info = request.contentInformationRequest {
            info.contentLength = track.bytes
            info.contentType = UTType(filenameExtension:track.fileExtension)?.identifier ?? UTType.audio.identifier
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else { request.finishLoading(); return true }
        let offset = max(dataRequest.requestedOffset,dataRequest.currentOffset)
        let end = dataRequest.requestsAllDataToEndOfResource ? track.bytes : min(track.bytes, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        tasks[key] = Task {
            do {
                var cursor = offset
                while cursor < end {
                    try Task.checkCancellation()
                    let last = min(end-1,cursor+524287)
                    var network = try API.shared.request("v1/tracks/\(track.id)/file")
                    network.setValue("bytes=\(cursor)-\(last)",forHTTPHeaderField:"Range")
                    let (bytes, response) = try await API.shared.session.data(for:network)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                          bytes.count == Int(last-cursor+1) else { throw URLError(.badServerResponse) }
                    try Task.checkCancellation()
                    await withCheckedContinuation { continuation in
                        queue.async {
                            if !request.isCancelled { dataRequest.respond(with:bytes) }
                            continuation.resume()
                        }
                    }
                    cursor = last+1
                }
                queue.async { if !request.isCancelled { request.finishLoading() }; self.tasks[key] = nil }
            } catch {
                queue.async { if !request.isCancelled { request.finishLoading(with:error) }; self.tasks[key] = nil }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey:ObjectIdentifier(request))?.cancel()
    }
    func cancel() { queue.async { self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll() } }
}

struct QueueEntry: Identifiable {
    let id = UUID()
    let track: Track
}

@MainActor final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()
    @Published var current: Track?
    @Published var playing = false
    @Published var loading = false
    @Published var elapsed = 0.0
    @Published private(set) var queueEntries: [QueueEntry] = []
    var queue: [Track] { queueEntries.map(\.track) }
    @Published var index = 0
    @Published var error: String?
    @Published var shuffle = false
    @Published var repeatMode = 0 // off, queue, one
    @Published var localPlayback = false
    @Published var route = "iPhone"
    @Published var outputSampleRate = 0.0
    // Intent survives loading, while AVPlayer may still report a paused state.
    @Published private(set) var wantsPlayback = false
    private let player = AVPlayer()
    private var loader: MusicResourceLoader?
    private var tick: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var unshuffled: [QueueEntry] = []
    private var resumeAfterInterruption = false
    init() {
        tick = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.5,preferredTimescale:600), queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let seconds = self.player.currentTime().seconds
                self.elapsed = self.current != nil && seconds.isFinite ? seconds : 0
                self.updateNowPlaying()
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options:[.initial,.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = player.timeControlStatus == .playing
                self.loading = self.wantsPlayback && !self.playing && player.currentItem != nil && self.error == nil
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime, object:nil, queue:.main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if self.repeatMode == 2 { self.seek(0); self.player.play() } else { self.next() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification, object:nil, queue:.main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if kind == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.wantsPlayback
                    self.pause()
                } else {
                    let shouldResume = self.resumeAfterInterruption && options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
                    self.resumeAfterInterruption = false
                    if shouldResume { self.resume() }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification, object:nil, queue:.main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
                self?.updateRoute()
            }
        })
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        updateRoute()
    }
    func play(_ track: Track, in tracks: [Track], at position: Int? = nil) {
        let selected = tracks.contains(where: { $0.id == track.id }) ? tracks : [track] + tracks
        queueEntries = selected.map { QueueEntry(track:$0) }
        unshuffled = queueEntries; shuffle = false
        if let position, selected.indices.contains(position), selected[position].id == track.id { index = position }
        else { index = selected.firstIndex(where: { $0.id == track.id }) ?? 0 }
        start()
    }
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let entries = tracks.map { QueueEntry(track:$0) }
        queueEntries.append(contentsOf:entries)
        unshuffled.append(contentsOf:entries)
        // An empty queue becomes ready to play, without starting any audio.
        if current == nil {
            index = 0; current = queueEntries[0].track; elapsed = 0; error = nil
            localPlayback = Downloads.shared.localURL(queueEntries[0].track) != nil
            updateNowPlaying()
        }
    }
    private func activateAudioSession(for track: Track) throws {
        let session = AVAudioSession.sharedInstance()
        // .playback already supports AirPlay. Explicit .allowAirPlay is only
        // valid with .playAndRecord and returns OSStatus -50 on an iPhone here.
        try session.setCategory(.playback, mode:.default, options:[])
        if track.sampleRate > 0 { try? session.setPreferredSampleRate(Double(track.sampleRate)) }
        try session.setActive(true)
    }
    func start(autoplay: Bool = true) {
        guard queueEntries.indices.contains(index) else { return }
        statusObservation = nil
        player.pause(); loader?.cancel(); loader = nil
        player.replaceCurrentItem(with:nil)
        let track = queueEntries[index].track; current = track; elapsed = 0; error = nil; wantsPlayback = autoplay; loading = autoplay
        do {
            if autoplay { try activateAudioSession(for:track) }
            let asset: AVURLAsset
            if let url = Downloads.shared.localURL(track) {
                asset = AVURLAsset(url:url, options:[AVURLAssetPreferPreciseDurationAndTimingKey:true]); localPlayback = true
            }
            else { let source = MusicResourceLoader(track:track); loader = source; asset = source.asset(); localPlayback = false }
            let item = AVPlayerItem(asset:asset)
            item.preferredForwardBufferDuration = 20
            statusObservation = item.observe(\.status, options:[.initial,.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    if item.status == .readyToPlay, self.wantsPlayback {
                        self.player.play()
                    } else if item.status == .failed {
                        self.error = "Couldn't play this track. \(item.error?.localizedDescription ?? "Try downloading it first.")"
                        self.pause()
                    }
                }
            }
            player.replaceCurrentItem(with:item)
            if autoplay { player.play() }
            updateRoute(); updateNowPlaying()
            Task {
                if let image = await ArtworkStore.shared.image(track), current?.id == track.id {
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize:image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        } catch { self.error = error.localizedDescription; pause() }
    }
    func pause() {
        wantsPlayback = false; loading = false; playing = false
        player.pause(); updateNowPlaying()
    }
    func stop() {
        pause()
        statusObservation = nil
        loader?.cancel(); loader = nil
        player.replaceCurrentItem(with:nil)
        current = nil; queueEntries = []; unshuffled = []; index = 0
        elapsed = 0; error = nil; localPlayback = false; shuffle = false
        resumeAfterInterruption = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options:.notifyOthersOnDeactivation)
    }
    func resume() {
        guard let current else { return }
        // A previous failure may have occurred before an item was installed.
        if error != nil || player.currentItem == nil || player.currentItem?.status == .failed { start(); return }
        do {
            try activateAudioSession(for:current)
            error = nil; wantsPlayback = true; loading = true
            player.play(); updateRoute(); updateNowPlaying()
        } catch { self.error = error.localizedDescription; pause() }
    }
    func toggle() { if wantsPlayback { pause() } else { resume() } }
    func seek(_ seconds: Double) {
        player.seek(to:CMTime(seconds:max(0,min(seconds,current?.duration ?? 0)),preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        elapsed = seconds; updateNowPlaying()
    }
    func next() {
        if index+1 < queueEntries.count { index += 1; start() }
        else if repeatMode == 1 { index = 0; start() }
        else { pause() }
    }
    func previous() { if elapsed > 3 { seek(0) } else if index > 0 { index -= 1; start() } else { seek(0) } }
    func selectQueueEntry(_ id: UUID) {
        guard let position = queueEntries.firstIndex(where: { $0.id == id }) else { return }
        index = position; start()
    }
    func removeFromQueue(_ ids: Set<UUID>) {
        guard !ids.isEmpty, queueEntries.indices.contains(index) else { return }
        let activeID = queueEntries[index].id
        let nextID = queueEntries.dropFirst(index+1).first { !ids.contains($0.id) }?.id
        let wasPlaying = wantsPlayback
        let remaining = queueEntries.filter { !ids.contains($0.id) }
        if remaining.isEmpty || (ids.contains(activeID) && nextID == nil) { stop(); return }
        queueEntries = remaining
        unshuffled.removeAll { ids.contains($0.id) }
        if ids.contains(activeID) {
            index = queueEntries.firstIndex { $0.id == nextID } ?? 0
            start(autoplay:wasPlaying)
        } else {
            index = queueEntries.firstIndex { $0.id == activeID } ?? 0
        }
    }
    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        guard queueEntries.indices.contains(index), !offsets.isEmpty,
              offsets.allSatisfy({ queueEntries.indices.contains($0) }),
              (0...queueEntries.count).contains(destination) else { return }
        let activeID = queueEntries[index].id
        queueEntries.move(fromOffsets:offsets,toOffset:destination)
        index = queueEntries.firstIndex { $0.id == activeID } ?? 0
        // A manual arrangement becomes the new order restored after shuffle.
        unshuffled = queueEntries; shuffle = false
    }
    func toggleShuffle() {
        guard current != nil, queueEntries.indices.contains(index) else { return }
        let activeID = queueEntries[index].id
        shuffle.toggle()
        if shuffle {
            let active = queueEntries[index]
            var remaining = queueEntries; remaining.remove(at:index)
            queueEntries = [active] + remaining.shuffled(); index = 0
        } else {
            queueEntries = unshuffled
            index = queueEntries.firstIndex { $0.id == activeID } ?? 0
        }
    }
    func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        route = session.currentRoute.outputs.map(\.portName).joined(separator:", ")
        outputSampleRate = session.sampleRate
    }
    func updateNowPlaying() {
        guard let current else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if info[MPMediaItemPropertyTitle] as? String != current.title { info.removeValue(forKey:MPMediaItemPropertyArtwork) }
        info[MPMediaItemPropertyTitle] = current.title; info[MPMediaItemPropertyArtist] = current.artist
        info[MPMediaItemPropertyAlbumTitle] = current.album; info[MPMediaItemPropertyPlaybackDuration] = current.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed; info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
