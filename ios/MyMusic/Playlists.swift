import SwiftUI

struct PlaylistSong: Codable, Identifiable {
    var id = UUID()
    let track: Track
}
struct MusicPlaylist: Codable, Identifiable {
    var id = UUID()
    var name: String
    var songs: [PlaylistSong] = []
}
@MainActor final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()
    @Published private(set) var playlists: [MusicPlaylist]
    @Published var error: String?
    init() { playlists = Disk.read([MusicPlaylist].self,"playlists.json") ?? [] }
    private func save(_ updated: [MusicPlaylist]) -> Bool {
        do {
            try Disk.write(updated,"playlists.json")
            playlists = updated; error = nil
            return true
        } catch {
            self.error = "Couldn't save your playlist. \(error.localizedDescription)"
            return false
        }
    }
    func create(_ name: String, tracks: [Track] = []) -> Bool {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return save(playlists + [MusicPlaylist(name:trimmed,songs:tracks.map { PlaylistSong(track:$0) })])
    }
    func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return false }
        var updated = playlists; updated[i].name = trimmed
        return save(updated)
    }
    func delete(_ id: UUID) -> Bool { save(playlists.filter { $0.id != id }) }
    func add(_ tracks: [Track], to id: UUID) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return false }
        var updated = playlists
        updated[i].songs.append(contentsOf:tracks.map { PlaylistSong(track:$0) })
        return save(updated)
    }
    func remove(_ offsets: IndexSet, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists; updated[i].songs.remove(atOffsets:offsets)
        _ = save(updated)
    }
    func move(_ offsets: IndexSet, to destination: Int, in id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists; updated[i].songs.move(fromOffsets:offsets,toOffset:destination)
        _ = save(updated)
    }
}

struct PlaylistNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var playlists: PlaylistStore
    let title: String
    let onSave: (String) -> Bool
    @State private var name: String
    @FocusState private var focused: Bool
    init(title: String, name: String = "", onSave: @escaping (String) -> Bool) {
        self.title = title; self.onSave = onSave; _name = State(initialValue:name)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name",text:$name).focused($focused).submitLabel(.done)
                    .accessibilityIdentifier("playlistName").onSubmit(save)
                if let error = playlists.error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("Save",action:save).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("savePlaylist")
                    }
                }.task { focused = true }
        }
    }
    private func save() { if onSave(name) { dismiss() } }
}

struct PlaylistsView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @State private var creating = false
    @State private var renaming: MusicPlaylist?
    @State private var deleting: MusicPlaylist?
    var body: some View {
        List {
            if let error = playlists.error { Text(error).foregroundStyle(.orange) }
            if playlists.playlists.isEmpty {
                ContentUnavailableView("Your own mixes",systemImage:"music.note.list",description:Text("Create a playlist, then add songs from your library."))
                    .listRowBackground(Color.clear)
            }
            ForEach(playlists.playlists) { playlist in
                NavigationLink { PlaylistDetailView(id:playlist.id) } label: {
                    HStack(spacing:14) {
                        Image(systemName:"music.note.list").font(.title2).foregroundStyle(Theme.mint)
                            .frame(width:48,height:48).background(Theme.surface,in:RoundedRectangle(cornerRadius:12))
                        VStack(alignment:.leading,spacing:4) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.songs.count) songs").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }.padding(.vertical,4)
                }.accessibilityIdentifier("playlist-" + playlist.id.uuidString)
                    .swipeActions(edge:.trailing) { Button("Delete",role:.destructive) { deleting = playlist } }
                    .contextMenu {
                        Button("Rename",systemImage:"pencil") { renaming = playlist }
                        Button("Delete playlist",systemImage:"trash",role:.destructive) { deleting = playlist }
                    }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Playlists").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar(.visible,for:.navigationBar)
            .toolbar { Button("New playlist",systemImage:"plus") { creating = true }.accessibilityIdentifier("newPlaylist") }
            .sheet(isPresented:$creating) { PlaylistNameEditor(title:"New playlist") { playlists.create($0) } }
            .sheet(item:$renaming) { playlist in PlaylistNameEditor(title:"Rename playlist",name:playlist.name) { playlists.rename(playlist.id,to:$0) } }
            .confirmationDialog("Delete playlist?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) {
                Button("Delete playlist",role:.destructive) {
                    if let deleting { _ = playlists.delete(deleting.id) }; deleting = nil
                }
            } message: { Text("Songs and downloads stay in your library.") }
    }
}

struct PlaylistDetailView: View {
    let id: UUID
    @AppStorage private var sortValue: String
    @State private var editMode: EditMode = .inactive
    init(id: UUID) {
        self.id = id
        _sortValue = AppStorage(wrappedValue:MusicSort.manual.rawValue,"sort.playlist." + id.uuidString)
    }
    private var sortSelection: Binding<MusicSort> {
        Binding(get:{ MusicSort(rawValue:sortValue) ?? .manual },set:{ sortValue = $0.rawValue })
    }
    private var displayedSongs: [PlaylistSong] {
        let lookup = Dictionary(library.tracks.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        return sortSelection.wrappedValue.ordered(playlist?.songs ?? [],track:{ lookup[$0.track.id] ?? $0.track })
    }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var player: MusicPlayer
    @State private var adding = false
    @State private var renaming = false
    @State private var deleting = false
    private var playlist: MusicPlaylist? { playlists.playlists.first { $0.id == id } }
    private func resolved(_ song: PlaylistSong) -> Track { library.tracks.first { $0.id == song.track.id } ?? song.track }
    var body: some View {
        List {
            if let playlist {
                let songs = displayedSongs
                Section {
                    HStack(spacing:16) {
                        Button { let tracks = songs.map(resolved); if let first = tracks.first { player.play(first,in:tracks) } } label: {
                            Label("Play",systemImage:"play.fill").frame(maxWidth:.infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.mint).foregroundStyle(Theme.background)
                            .disabled(playlist.songs.isEmpty).accessibilityIdentifier("playPlaylist")
                        Button { player.addToQueue(songs.map(resolved)) } label: {
                            Label("Queue",systemImage:"text.badge.plus").frame(maxWidth:.infinity)
                        }.buttonStyle(.bordered).disabled(playlist.songs.isEmpty).accessibilityIdentifier("queuePlaylist")
                    }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top:8,leading:0,bottom:8,trailing:0))
                    Button("Add songs",systemImage:"plus") { adding = true }.accessibilityIdentifier("addPlaylistSongs")
                }
                if let error = playlists.error { Text(error).foregroundStyle(.orange) }
                Section {

                    if playlist.songs.isEmpty { Text("Add songs to start your playlist.").foregroundStyle(Theme.muted) }
                    ForEach(Array(songs.enumerated()),id:\.element.id) { offset, song in
                        let track = resolved(song)
                        Button {
                            player.play(track,in:songs.map(resolved),at:offset)
                        } label: {
                            HStack(spacing:12) {
                                Cover(track:track,size:42)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(track.title).foregroundStyle(.white)
                                    Text(track.artist).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                            }.padding(.vertical,4)
                        }.buttonStyle(.plain).accessibilityIdentifier("playlistSong-" + song.id.uuidString)
                        .moveDisabled(sortSelection.wrappedValue != .manual)
                    }.onDelete { offsets in
                        let ids = Set(offsets.map { songs[$0].id })
                        playlists.remove(IndexSet(playlist.songs.indices.filter { ids.contains(playlist.songs[$0].id) }),from:id)
                    }.onMove { playlists.move($0,to:$1,in:id) }
                } header: {
                    HStack {
                        Text("\(songs.count) songs")
                        Spacer()
                        MusicSortMenu(selection:sortSelection,options:MusicSort.playlistOptions,identifier:"sortPlaylist")
                            .disabled(editMode.isEditing)
                    }.textCase(nil)
                }
            }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(playlist?.name ?? "Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible,for:.navigationBar)
            .toolbar {
                EditButton().accessibilityIdentifier("editPlaylist")
                Menu {
                    Button("Rename",systemImage:"pencil") { renaming = true }
                    Button("Delete playlist",systemImage:"trash",role:.destructive) { deleting = true }
                } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("Playlist options")
            }
            .environment(\.editMode,$editMode)
            .onChange(of:editMode) { _, mode in
                if mode.isEditing { sortValue = MusicSort.manual.rawValue }
            }
            .sheet(isPresented:$adding) { PlaylistSongPicker(playlistID:id) }
            .sheet(isPresented:$renaming) {
                PlaylistNameEditor(title:"Rename playlist",name:playlist?.name ?? "") { playlists.rename(id,to:$0) }
            }
            .confirmationDialog("Delete playlist?",isPresented:$deleting,titleVisibility:.visible) {
                Button("Delete playlist",role:.destructive) { if playlists.delete(id) { dismiss() } }
            } message: { Text("Songs and downloads stay in your library.") }
    }
}

struct PlaylistSongPicker: View {
    let playlistID: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var library: MusicLibrary
    @EnvironmentObject var playlists: PlaylistStore
    @State private var query = ""
    @State private var selected = Set<String>()
    private var results: [Track] {
        query.isEmpty ? library.tracks : library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error = playlists.error { Text(error).foregroundStyle(.orange) }
                ForEach(results) { track in
                    Button {
                        if !selected.insert(track.id).inserted { selected.remove(track.id) }
                    } label: {
                        HStack(spacing:12) {
                            Cover(track:track,size:40)
                            VStack(alignment:.leading) { Text(track.title).foregroundStyle(.white); Text(track.artist).font(.caption).foregroundStyle(Theme.muted) }
                            Spacer()
                            Image(systemName:selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.mint)
                        }
                    }.accessibilityIdentifier("selectPlaylistSong-" + track.id)
                        .accessibilityValue(selected.contains(track.id) ? "Selected" : "Not selected")
                }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .searchable(text:$query,prompt:"Songs, artists, albums").navigationTitle("Add songs").toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .safeAreaInset(edge:.bottom) {
                    Button {
                        if playlists.add(library.tracks.filter { selected.contains($0.id) },to:playlistID) { dismiss() }
                    } label: {
                        Text("Add (\(selected.count))").font(.headline).frame(maxWidth:.infinity).padding(.vertical,14)
                    }.buttonStyle(.plain).foregroundStyle(Theme.background).background(Theme.mint,in:Capsule())
                        .disabled(selected.isEmpty).opacity(selected.isEmpty ? 0.45 : 1)
                        .accessibilityIdentifier("addSelectedTracks")
                        .padding(16).background(Theme.background)
                }
        }
    }
}

struct PlaylistDestinationPicker: View {
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var playlists: PlaylistStore
    @State private var creating = false
    @State private var created = false
    var body: some View {
        NavigationStack {
            List {
                if let error = playlists.error { Text(error).foregroundStyle(.orange) }
                if playlists.playlists.isEmpty { Text("Create a playlist to save these songs.").foregroundStyle(Theme.muted) }
                ForEach(playlists.playlists) { playlist in
                    Button { if playlists.add(tracks,to:playlist.id) { dismiss() } } label: {
                        Label(playlist.name,systemImage:"music.note.list")
                    }
                }
            }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Add to playlist").toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("New playlist") { creating = true } }
                }
                .sheet(isPresented:$creating,onDismiss:{ if created { dismiss() } }) {
                    PlaylistNameEditor(title:"New playlist") {
                        created = playlists.create($0,tracks:tracks)
                        return created
                    }
                }
        }
    }
}
