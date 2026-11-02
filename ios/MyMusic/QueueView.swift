import SwiftUI

struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var player: MusicPlayer
    @State private var editMode: EditMode = .inactive
    var body: some View {
        NavigationStack {
            List {
                let entries = player.queueEntries
                Section {
                    ForEach(Array(entries.enumerated()),id:\.element.id) { offset, entry in
                        Button {
                            if !editMode.isEditing { player.selectQueueEntry(entry.id) }
                        } label: {
                            HStack(spacing:12) {
                                Cover(track:entry.track,size:42)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(entry.track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(entry.track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer()
                                if offset == player.index { Image(systemName:"waveform").foregroundStyle(Theme.mint) }
                            }.foregroundStyle(offset == player.index ? Theme.mint : .white).padding(.vertical,4)
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("queueEntry-" + entry.id.uuidString)
                            .accessibilityLabel(entry.track.title).accessibilityHint(entry.track.artist)
                            .accessibilityValue(offset == player.index ? "Current song" : (offset < player.index ? "Earlier in queue" : "Up next"))
                    }.onDelete { offsets in
                        player.removeFromQueue(Set(offsets.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }))
                    }.onMove { player.moveInQueue(from:$0,to:$1) }
                } header: { Text("\(entries.count) songs") }
                footer: { Text("Removing the current song skips to the next song. If nothing follows it, playback stops.") }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Up next").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible,for:.navigationBar)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeQueue") }
                    ToolbarItem(placement:.primaryAction) { EditButton().accessibilityIdentifier("editQueue") }
                }
                .environment(\.editMode,$editMode)
                .onChange(of:player.queueEntries.isEmpty) { _, empty in if empty { dismiss() } }
        }
    }
}
