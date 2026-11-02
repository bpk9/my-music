import SwiftUI
import AVKit
import UniformTypeIdentifiers

@main struct MyMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var library = MusicLibrary.shared
    @StateObject private var downloads = Downloads.shared
    @StateObject private var player = MusicPlayer.shared
    @StateObject private var playlists = PlaylistStore.shared
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library).environmentObject(downloads).environmentObject(player).environmentObject(playlists)
                .preferredColorScheme(.dark).tint(Theme.mint)
                .task { await library.sync() }
        }
    }
}
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
enum Theme {
    static let background = Color(red:0.045,green:0.063,blue:0.071)
    static let surface = Color(red:0.09,green:0.115,blue:0.12)
    static let mint = Color(red:0.69,green:0.94,blue:0.76)
    static let muted = Color(red:0.56,green:0.65,blue:0.63)
}
struct Cover: View {
    let track: Track
    var size: CGFloat = 52
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors:[Theme.surface,Color(red:0.19,green:0.30,blue:0.27)],startPoint:.topLeading,endPoint:.bottomTrailing)
            if let image { Image(uiImage:image).resizable().scaledToFill() }
            else { Image(systemName:"waveform").font(.system(size:size*0.3,weight:.light)).foregroundStyle(Theme.mint.opacity(0.7)) }
        }
        .frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:size > 100 ? 16 : 9))
        .task(id:track.id) { image = await ArtworkStore.shared.image(track) }
        .accessibilityHidden(true)
    }
}
struct RootView: View {
    @EnvironmentObject var player: MusicPlayer
    @State private var nowPlaying = false
    var body: some View {
        Group {
            if #available(iOS 26.1, *) {
                tabs.tabViewBottomAccessory(isEnabled:player.current != nil) { miniPlayer }
            } else if #available(iOS 26.0, *) {
                tabs.tabViewBottomAccessory { miniPlayer }
            } else {
                tabs
            }
        }
        .sheet(isPresented:$nowPlaying) { NowPlayingView().presentationDragIndicator(.visible) }
    }
    private var tabs: some View {
        TabView {
            tabRoot(LibraryView(), titleInset:0).tabItem { Label("Library",systemImage:"square.stack.fill") }
            tabRoot(SearchView()).tabItem { Label("Search",systemImage:"magnifyingglass") }
            tabRoot(OfflineView()).tabItem { Label("Downloads",systemImage:"arrow.down.circle.fill") }
            tabRoot(SettingsView()).tabItem { Label("Settings",systemImage:"slider.horizontal.3") }
        }
    }
    private func tabRoot<Content: View>(_ content: Content, titleInset: CGFloat = 22) -> some View {
        NavigationStack { content }
        // Align toolbar titles with MyMusic below the Library eyebrow.
        .padding(.top,titleInset)
        .background(Theme.background)
        .safeAreaInset(edge:.bottom,spacing:0) {
            // Older tab bars reserve their space inside each tab's content.
            if #unavailable(iOS 26.0) { miniPlayer }
        }
    }
    private var systemAccessory: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    @ViewBuilder private var miniPlayer: some View {
        if let track = player.current {
            HStack(spacing:12) {
                Button { nowPlaying = true } label: {
                    HStack(spacing:12) {
                        Cover(track:track,size:36)
                        VStack(alignment:.leading,spacing:2) {
                            Text(track.title).font(.system(size:14,weight:.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(track.artist).font(.system(size:11)).foregroundStyle(Theme.muted).lineLimit(1)
                            GeometryReader { proxy in
                                Capsule().fill(Theme.mint.opacity(0.12))
                                    .overlay(alignment:.leading) {
                                        Capsule().fill(Theme.mint.opacity(0.8)).frame(width:proxy.size.width * min(1,max(0,player.elapsed/max(1,track.duration))))
                                    }
                            }.frame(height:2).padding(.top,2).accessibilityHidden(true)
                        }
                        Spacer(minLength:0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer")
                Button { player.toggle() } label: { Image(systemName:player.playing || player.loading ? "pause.fill" : "play.fill").font(.system(size:18,weight:.semibold)).frame(width:40,height:44) }.accessibilityLabel(player.playing || player.loading ? "Pause" : "Play").accessibilityIdentifier("miniToggle")
                Button { player.next() } label: { Image(systemName:"forward.end.fill").font(.system(size:17,weight:.semibold)).frame(width:36,height:44) }.accessibilityLabel("Next track")
            }
            .foregroundStyle(Theme.mint)
            .padding(.horizontal,12).frame(height:systemAccessory ? 48 : 64)
            .background(systemAccessory ? Color.clear : Theme.surface,in:Capsule())
            .padding(.horizontal,systemAccessory ? 0 : 10).padding(.bottom,systemAccessory ? 0 : 3)
        }
    }
}
struct LibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: MusicLibrary
    @State private var filter = "Albums"
    @AppStorage("sort.albums") private var albumSort = MusicSort.artistAZ.rawValue
    @AppStorage("sort.tracks") private var trackSort = MusicSort.titleAZ.rawValue
    @AppStorage("sort.favorites") private var favoriteSort = MusicSort.titleAZ.rawValue
    private var sortSelection: Binding<MusicSort> {
        Binding(get:{
            MusicSort(rawValue:filter == "Albums" ? albumSort : (filter == "Favorites" ? favoriteSort : trackSort)) ?? .titleAZ
        },set:{ mode in
            if filter == "Albums" { albumSort = mode.rawValue }
            else if filter == "Favorites" { favoriteSort = mode.rawValue }
            else { trackSort = mode.rawValue }
        })
    }
    private let columns = [GridItem(.flexible(),spacing:18,alignment:.top),GridItem(.flexible(),spacing:18,alignment:.top)]
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("YOUR MUSIC, UNCOMPROMISED").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(Theme.mint)
                        Text("MyMusic").font(.system(size:39,weight:.bold,design:.rounded)).tracking(-1.5)
                        HStack(spacing:6) { Circle().fill(library.connected ? Theme.mint : .orange).frame(width:5,height:5); Text(library.status).font(.caption).foregroundStyle(Theme.muted) }
                    }
                    Spacer(minLength:0)
                    Button { Task { await library.sync() } } label: {
                        Image(systemName:"arrow.clockwise").font(.system(size:18)).frame(width:42,height:42).background(Theme.surface,in:Circle())
                    }.accessibilityLabel("Refresh library").disabled(library.refreshing)
                }.padding(.top,12)
                if !library.tracks.isEmpty {
                    HStack(spacing:14) {
                        Image(systemName:"waveform.path").font(.system(size:30,weight:.light)).foregroundStyle(Theme.mint)
                        VStack(alignment:.leading,spacing:5) {
                            Text("The whole record.").font(.headline)
                            Text("Original files. Every detail.").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(library.tracks.filter(\.lossless).count.formatted())\nLOSSLESS").font(.system(size:10,weight:.semibold,design:.monospaced)).multilineTextAlignment(.trailing).foregroundStyle(Theme.mint)
                    }.padding(20).background(Theme.surface,in:RoundedRectangle(cornerRadius:20))
                }
                NavigationLink { PlaylistsView() } label: {
                    HStack(spacing:12) {
                        Image(systemName:"music.note.list").foregroundStyle(Theme.mint)
                        Text("Playlists").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text("\(playlists.playlists.count)").foregroundStyle(Theme.muted)
                        Image(systemName:"chevron.right").font(.caption).foregroundStyle(Theme.muted)
                    }.padding(16).background(Theme.surface,in:RoundedRectangle(cornerRadius:16))
                }.buttonStyle(.plain).accessibilityIdentifier("openPlaylists")
                Picker("Library view",selection:$filter) { ForEach(["Albums","Tracks","Favorites"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
                if let error = library.error { ContentUnavailableView("Your library is at home",systemImage:"wifi.slash",description:Text(error)) }
                else if library.tracks.isEmpty { ContentUnavailableView("Finding your music",systemImage:"waveform",description:Text("Your server is indexing the music folder. Pull to refresh in a moment.")) }
                else if filter == "Albums" {
                    HStack {
                        Text("\(library.albums.count) albums").font(.title3.bold())
                        Spacer()
                        MusicSortMenu(selection:sortSelection,options:MusicSort.albumOptions,identifier:"sortLibrary")
                    }
                    LazyVGrid(columns:columns,spacing:24) {
                        ForEach(sortSelection.wrappedValue.orderedAlbums(library.albums)) { album in
                            NavigationLink { AlbumView(album:album) } label: { AlbumCard(album:album) }.buttonStyle(.plain).accessibilityIdentifier("album-" + album.cover.id)
                        }
                    }
                } else {
                    let source = filter == "Favorites" ? library.tracks.filter { library.favorites.contains($0.id) } : library.tracks
                    let tracks = sortSelection.wrappedValue.ordered(source,track:{ $0 })
                    HStack {
                        Text("\(tracks.count) songs").font(.title3.bold())
                        Spacer()
                        MusicSortMenu(selection:sortSelection,options:MusicSort.trackOptions,identifier:"sortLibrary")
                    }
                    if tracks.isEmpty { ContentUnavailableView("Keep your favorites close",systemImage:"heart",description:Text("Tap the heart in Now Playing to add a favorite.")) }
                    LazyVStack(spacing:3) { ForEach(tracks) { track in TrackRow(track:track,queue:tracks) } }
                }
            }.padding(.horizontal,22).padding(.bottom,30)
        }.background(Theme.background).toolbar(.hidden,for:.navigationBar).refreshable { await library.sync() }
    }
}
struct AlbumCard: View {
    let album: Album
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            GeometryReader { proxy in
                Cover(track:album.cover,size:proxy.size.width).overlay(alignment:.bottomLeading) {
                    if album.lossless { Text("LOSSLESS").font(.system(size:8,weight:.heavy,design:.monospaced)).tracking(1).padding(.horizontal,7).padding(.vertical,5).background(.black.opacity(0.7),in:Capsule()).padding(10) }
                }
            }.aspectRatio(1,contentMode:.fit)
            Text(album.title).font(.system(size:14,weight:.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text(album.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}
struct TrackRow: View {
    @State private var choosingPlaylist = false
    @State private var addedToQueue = false
    let track: Track
    let queue: [Track]
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var library: MusicLibrary
    var body: some View {
        HStack(spacing:12) {
            Button { player.play(track,in:queue) } label: {
                HStack(spacing:12) {
                    Cover(track:track)
                    VStack(alignment:.leading,spacing:5) {
                        Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(player.current?.id == track.id ? Theme.mint : .white).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(track.quality).font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength:4)
                    if downloads.localURL(track) != nil { Image(systemName:"checkmark.circle.fill").font(.caption).foregroundStyle(Theme.mint) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("track-" + track.id)
            Menu {
                Button("Add to queue",systemImage:"text.badge.plus") {
                    player.addToQueue([track]); addedToQueue = true
                    UIAccessibility.post(notification:.announcement,argument:"Added to queue")
                }
                Button("Add to playlist",systemImage:"music.note.list") { choosingPlaylist = true }
                Button(library.favorites.contains(track.id) ? "Remove favorite" : "Add favorite",systemImage:"heart") { library.toggleFavorite(track) }
                if downloads.localURL(track) != nil { Button("Remove download",systemImage:"trash",role:.destructive) { downloads.remove(track) } }
                else { Button("Download original",systemImage:"arrow.down.circle") { downloads.enqueue([track]) } }
            } label: { Image(systemName:addedToQueue ? "checkmark" : "ellipsis").foregroundStyle(addedToQueue ? Theme.mint : Theme.muted).frame(width:32,height:48) }.accessibilityLabel("Options for " + track.title)
        }.padding(.vertical,8)
        .sheet(isPresented:$choosingPlaylist) { PlaylistDestinationPicker(tracks:[track]) }
        .task(id:addedToQueue) {
            guard addedToQueue else { return }
            try? await Task.sleep(for:.seconds(2)); addedToQueue = false
        }
    }
}
struct AlbumView: View {
    @State private var addedToQueue = false
    let album: Album
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var downloads: Downloads
    private var savedTracks: [Track] { album.tracks.filter { downloads.localURL($0) != nil } }
    private var albumDownloads: [SavedDownload] {
        let ids = Set(album.tracks.map(\.id))
        return downloads.records.filter { ids.contains($0.id) }
    }
    private var fullyDownloaded: Bool { savedTracks.count == album.tracks.count }
    private var downloading: Bool { albumDownloads.contains { ["queued","downloading"].contains($0.state) } }
    private var failed: Bool { albumDownloads.contains { $0.state == "failed" } }
    private var downloadProgress: Double {
        let saved = Double(savedTracks.reduce(Int64(0)) { $0 + $1.bytes })
        let pending = albumDownloads.filter { $0.state == "downloading" }.reduce(0.0) { $0 + Double($1.track.bytes) * $1.progress }
        return min(1,(saved + pending) / Double(max(1,album.tracks.reduce(Int64(0)) { $0 + $1.bytes })))
    }
    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                Cover(track:album.cover,size:260).shadow(color:.black.opacity(0.4),radius:20,y:12).padding(.top,14)
                VStack(spacing:7) {
                    Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(album.artist).foregroundStyle(Theme.muted)
                    Text("\(album.tracks.count) tracks · \(Int(album.tracks.reduce(0) { $0+$1.duration }/60)) min").font(.caption).foregroundStyle(Theme.muted)
                }
                HStack(spacing:12) {
                    Button { player.play(album.cover,in:album.tracks) } label: { Label("Play",systemImage:"play.fill").frame(maxWidth:.infinity).padding(13) }.buttonStyle(.plain).foregroundStyle(Theme.background).background(Theme.mint,in:Capsule()).accessibilityIdentifier("playAlbum")
                    Button { downloads.enqueue(album.tracks) } label: {
                        HStack(spacing:7) {
                            if downloading { ProgressView().tint(Theme.mint) }
                            else { Image(systemName:fullyDownloaded ? "checkmark.circle.fill" : (failed ? "arrow.clockwise" : "arrow.down")) }
                            Text(fullyDownloaded ? "Downloaded" : (downloading ? "Saving…" : (failed ? "Retry" : "Download")))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth:.infinity).padding(13)
                    }.buttonStyle(.plain).foregroundStyle(fullyDownloaded ? Theme.mint : .white)
                        .background(Theme.surface,in:Capsule()).disabled(fullyDownloaded || downloading)
                        .accessibilityIdentifier("downloadAlbum")
                }.font(.subheadline.bold())
                Button {
                    player.addToQueue(album.tracks); addedToQueue = true
                } label: {
                    Label(addedToQueue ? "Added to queue" : "Add to queue",systemImage:addedToQueue ? "checkmark" : "text.badge.plus")
                        .font(.subheadline.weight(.medium)).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(Theme.mint).accessibilityIdentifier("queueAlbum")
                    .task(id:addedToQueue) {
                        guard addedToQueue else { return }
                        try? await Task.sleep(for:.seconds(2)); addedToQueue = false
                    }
                if downloading {
                    VStack(spacing:6) {
                        ProgressView(value:downloadProgress).tint(Theme.mint)
                        Text("\(savedTracks.count) of \(album.tracks.count) tracks saved · \(Int(downloadProgress * 100))%")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }.accessibilityIdentifier("albumDownloadProgress")
                }
                Text("\(album.lossless ? "LOSSLESS" : "ORIGINAL QUALITY") · \(byteLabel(album.tracks.reduce(0) { $0+$1.bytes }))").font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(Theme.muted)
                if let error = downloads.error { Text(error).font(.caption).foregroundStyle(.orange) }
                LazyVStack(spacing:1) { ForEach(album.tracks) { TrackRow(track:$0,queue:album.tracks) } }
            }.padding(22)
        }.background(Theme.background).navigationBarTitleDisplayMode(.inline)
    }
}
struct SearchView: View {
    @EnvironmentObject var library: MusicLibrary
    @State private var query = ""
    var results: [Track] {
        guard !query.trimmingCharacters(in:.whitespaces).isEmpty else { return [] }
        return Array(library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }.prefix(250))
    }
    var body: some View {
        ScrollView {
            if query.isEmpty { ContentUnavailableView("Find your next listen",systemImage:"magnifyingglass",description:Text("Search tracks, artists, and albums.")) }
            else if results.isEmpty { ContentUnavailableView.search(text:query) }
            else { LazyVStack { ForEach(results) { TrackRow(track:$0,queue:results) } }.padding(.horizontal,20) }
        }.background(Theme.background).navigationTitle("Search").toolbarTitleDisplayMode(.inlineLarge).searchable(text:$query,placement:.navigationBarDrawer(displayMode:.always),prompt:"Tracks, artists, albums")
    }
}
struct OfflineView: View {
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var player: MusicPlayer
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:10) {
                    HStack { Image(systemName:"tram.fill").foregroundStyle(Theme.mint); Text("Made for the underground.").font(.headline) }
                    Text("\(downloads.ready.count) tracks ready · \(byteLabel(downloads.usedBytes)) of \(downloads.limitGB) GB").font(.caption).foregroundStyle(Theme.muted)
                    ProgressView(value:Double(downloads.usedBytes),total:Double(downloads.limitGB)*1e9).tint(Theme.mint)
                    if !downloads.ready.isEmpty { Button { let tracks = downloads.ready.map(\.track); player.play(tracks[0],in:tracks) } label: { Label("Play downloads",systemImage:"play.fill") }.font(.subheadline.bold()).padding(.top,4).accessibilityIdentifier("playDownloads") }
                }.padding(20).background(Theme.surface,in:RoundedRectangle(cornerRadius:18))
                if let error = downloads.error { Text(error).font(.callout).foregroundStyle(.orange) }
                if downloads.records.isEmpty { ContentUnavailableView("Take your music with you",systemImage:"arrow.down.circle",description:Text("Download an album or track. Originals stay on your iPhone until you remove them.")) }
                LazyVStack(spacing:12) {
                    ForEach(downloads.records) { record in
                        if record.state == "ready" { TrackRow(track:record.track,queue:downloads.ready.map(\.track)) }
                        else {
                            HStack(spacing:12) {
                                Cover(track:record.track,size:48)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(record.track.title).font(.subheadline).lineLimit(1)
                                    if record.state == "failed" { Text(record.error ?? "Download failed").font(.caption2).foregroundStyle(.orange) }
                                    else { Text(record.state == "queued" ? "Queued" : (downloads.wifiOnly ? "Downloading · Wi-Fi only" : "Downloading")).font(.caption).foregroundStyle(Theme.muted); ProgressView(value:record.progress) }
                                }
                                Spacer()
                                if record.state == "failed" { Button("Retry") { downloads.enqueue([record.track]) }.font(.caption) }
                                Button { downloads.remove(record.track) } label: { Image(systemName:"xmark.circle").padding(8) }.accessibilityLabel("Cancel download")
                            }
                        }
                    }
                }
            }.padding(22)
        }.background(Theme.background).navigationTitle("Downloads").toolbarTitleDisplayMode(.inlineLarge)
    }
}
struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var downloads: Downloads
    @State private var scrubbing = false
    @State private var scrub = 0.0
    @State private var showQueue = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let track = player.current {
                    VStack(spacing:24) {
                        HStack {
                            Text(player.localPlayback ? "PLAYING FROM DOWNLOADS" : "PLAYING FROM YOUR LIBRARY").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(1.8)
                            Spacer()
                            Button { player.stop(); dismiss() } label: {
                                Label("Stop",systemImage:"stop.fill").font(.caption.weight(.semibold))
                                    .padding(.horizontal,12).frame(minHeight:44)
                                    .background(Theme.surface,in:Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("stopPlayback")
                        }.foregroundStyle(Theme.muted)
                        Cover(track:track,size:max(1,min(geometry.size.width-64,350))).shadow(color:Theme.mint.opacity(0.08),radius:35,y:10)
                        HStack(alignment:.center) {
                            VStack(alignment:.leading,spacing:7) { Text(track.title).font(.title2.bold()).lineLimit(2).accessibilityIdentifier("nowPlayingTitle"); Text(track.artist).font(.body).foregroundStyle(Theme.muted).lineLimit(1) }
                            Spacer()
                            Button { library.toggleFavorite(track) } label: { Image(systemName:library.favorites.contains(track.id) ? "heart.fill" : "heart").font(.title2).frame(width:40,height:44) }.accessibilityLabel("Favorite")
                        }
                        VStack(spacing:4) {
                            Slider(value:Binding(get:{ scrubbing ? scrub : min(player.elapsed,track.duration) },set:{ scrub = $0 }),in:0...max(1,track.duration),onEditingChanged:{ editing in
                                if editing { scrub = player.elapsed; scrubbing = true } else { player.seek(scrub); scrubbing = false }
                            }).accessibilityLabel("Playback position")
                            HStack { Text(durationLabel(scrubbing ? scrub : player.elapsed)).accessibilityIdentifier("elapsedTime"); Spacer(); Text("−" + durationLabel(track.duration-(scrubbing ? scrub : player.elapsed))) }.font(.system(size:11,design:.monospaced)).foregroundStyle(Theme.muted)
                        }
                        HStack(spacing:0) {
                            Button { player.toggleShuffle() } label: { Image(systemName:"shuffle").font(.title3).foregroundStyle(player.shuffle ? Theme.mint : Theme.muted).frame(maxWidth:.infinity) }.accessibilityLabel("Shuffle").accessibilityValue(player.shuffle ? "On" : "Off")
                            Button { player.previous() } label: { Image(systemName:"backward.end.fill").font(.title).frame(maxWidth:.infinity) }.accessibilityLabel("Previous track")
                            Button { player.toggle() } label: {
                                ZStack { Circle().fill(Theme.mint).frame(width:76,height:76); if player.loading { ProgressView().tint(Theme.background) } else { Image(systemName:player.playing ? "pause.fill" : "play.fill").font(.system(size:29,weight:.semibold)).foregroundStyle(Theme.background) } }
                            }.accessibilityLabel(player.playing || player.loading ? "Pause" : "Play").accessibilityIdentifier("playerToggle")
                            Button { player.next() } label: { Image(systemName:"forward.end.fill").font(.title).frame(maxWidth:.infinity) }.accessibilityLabel("Next track")
                            Button { player.repeatMode = (player.repeatMode+1)%3 } label: { Image(systemName:player.repeatMode == 2 ? "repeat.1" : "repeat").font(.title3).foregroundStyle(player.repeatMode > 0 ? Theme.mint : Theme.muted).frame(maxWidth:.infinity) }.accessibilityLabel("Repeat mode \(player.repeatMode)")
                        }.foregroundStyle(.white)
                        VStack(spacing:7) {
                            Text(track.quality).font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(Theme.mint)
                            Text(player.route + (player.outputSampleRate > 0 ? String(format:" · %g kHz output",player.outputSampleRate/1000) : "")).font(.caption).foregroundStyle(Theme.muted)
                        }
                        if let error = player.error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("playbackError") }
                        if let error = downloads.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button { downloads.enqueue([track]) } label: { Label(downloads.localURL(track) != nil ? "Saved" : (downloads.record(track)?.state == "downloading" || downloads.record(track)?.state == "queued" ? "Saving…" : "Save offline"),systemImage:downloads.localURL(track) != nil ? "checkmark.circle.fill" : "arrow.down.circle") }.accessibilityIdentifier("saveOffline")
                            Spacer()
                            RoutePicker().frame(width:34,height:34)
                            Spacer()
                            Button { showQueue = true } label: { Image(systemName:"list.bullet").font(.title3) }.accessibilityLabel("Up next")
                        }.font(.caption).foregroundStyle(Theme.muted)
                    }.padding(.horizontal,32).padding(.top,34).padding(.bottom,30)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.background)
        }.sheet(isPresented:$showQueue,onDismiss:{ if player.current == nil { dismiss() } }) {
            QueueView()
        }
    }
}
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context:Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = UIColor(Theme.muted); view.activeTintColor = UIColor(Theme.mint); return view }
    func updateUIView(_ uiView:AVRoutePickerView,context:Context) {}
}
struct SettingsView: View {
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var downloads: Downloads
    @State private var scanning = false
    @State private var scanMessage: String?
    var body: some View {
        Form {
            Section("Your library") {
                LabeledContent("Server",value:library.connected ? "Connected" : "Offline")
                LabeledContent("Collection",value:"\(library.tracks.count.formatted()) tracks")
                Button(scanning ? "Scanning…" : "Scan for new music") {
                    scanning = true; scanMessage = nil
                    Task {
                        do { _ = try await API.shared.data("v1/scan",method:"POST"); await library.sync(); scanMessage = "Library updated." }
                        catch { scanMessage = "Couldn't reach the server. Try again on home Wi-Fi." }
                        scanning = false
                    }
                }.disabled(scanning)
                if let scanMessage { Text(scanMessage).font(.caption) }
            }
            Section {
                Toggle("Download on Wi-Fi only",isOn:$downloads.wifiOnly)
                Picker("Download limit",selection:$downloads.limitGB) { ForEach([5,10,20,50,100],id:\.self) { Text("\($0) GB").tag($0) } }
                LabeledContent("On this iPhone",value:byteLabel(downloads.usedBytes))
            } header: { Text("Offline listening") } footer: { Text("Changes apply to newly started downloads. Saved music stays until you remove it. iOS may pause transfers after force-quitting; reopen MyMusic to continue.") }
            Section("Audio") {
                LabeledContent("Streaming",value:"Original file")
                LabeledContent("Downloads",value:"Original file")
                Text("No transcoding, upsampling, or normalization. Lossless labels describe the file's encoding; they can't prove the original recording was lossless. Bluetooth and AirPlay may change the output quality. For high-resolution playback, use a compatible wired DAC.").font(.caption).foregroundStyle(Theme.muted)
            }
            Section("New music") {
                Text("The server checks your music folder every five minutes. Files added by your existing workflow appear automatically after they finish copying.").font(.subheadline)
                Text("SoundCloud downloads preserve the quality the artist or service provides. Compressed sources remain labeled as compressed.").font(.caption).foregroundStyle(Theme.muted)
            }
            Section { Text("MyMusic 0.1 · Your music. No subscription.").font(.caption).foregroundStyle(Theme.muted) }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Settings").toolbarTitleDisplayMode(.inlineLarge)
    }
}
