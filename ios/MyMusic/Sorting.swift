import SwiftUI

enum MusicSort: String, CaseIterable, Identifiable {
    case manual, titleAZ, titleZA, artistAZ, artistZA, albumOrder, newest, oldest, shortest, longest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Custom order"
        case .titleAZ: "Title A–Z"
        case .titleZA: "Title Z–A"
        case .artistAZ: "Artist A–Z"
        case .artistZA: "Artist Z–A"
        case .albumOrder: "Album / track order"
        case .newest: "Newest files"
        case .oldest: "Oldest files"
        case .shortest: "Shortest first"
        case .longest: "Longest first"
        }
    }
    static let albumOptions: [Self] = [.artistAZ,.artistZA,.titleAZ,.titleZA,.newest,.oldest]
    static let trackOptions: [Self] = [.titleAZ,.titleZA,.artistAZ,.artistZA,.albumOrder,.newest,.oldest,.shortest,.longest]
    static let playlistOptions: [Self] = [.manual] + trackOptions
    private func text(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
    private func number<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    func compare(_ a: Track, _ b: Track) -> ComparisonResult {
        let primary: ComparisonResult
        switch self {
        case .manual: return .orderedSame
        case .titleAZ: primary = text(a.title,b.title)
        case .titleZA: primary = text(b.title,a.title)
        case .artistAZ: primary = text(a.artist,b.artist)
        case .artistZA: primary = text(b.artist,a.artist)
        case .newest: primary = number(b.added,a.added)
        case .oldest: primary = number(a.added,b.added)
        case .shortest: primary = number(a.duration,b.duration)
        case .longest: primary = number(b.duration,a.duration)
        case .albumOrder:
            for order in [text(a.albumArtist,b.albumArtist),text(a.album,b.album),number(a.trackNumber > 0 ? a.trackNumber : Int.max,b.trackNumber > 0 ? b.trackNumber : Int.max)] {
                if order != .orderedSame { return order }
            }
            primary = text(a.title,b.title)
        }
        if primary != .orderedSame { return primary }
        for order in [text(a.artist,b.artist),text(a.album,b.album),text(a.title,b.title),number(a.trackNumber,b.trackNumber)] {
            if order != .orderedSame { return order }
        }
        return number(a.id,b.id)
    }
    func ordered<T>(_ items: [T], track: (T) -> Track) -> [T] {
        guard self != .manual else { return items }
        // Resolve metadata once per entry and retain the order of repeated songs.
        return items.enumerated().map { (offset:$0.offset,item:$0.element,track:track($0.element)) }
            .sorted {
                let result = compare($0.track,$1.track)
                return result == .orderedSame ? $0.offset < $1.offset : result == .orderedAscending
            }.map(\.item)
    }
    func orderedAlbums(_ albums: [Album]) -> [Album] {
        let dated = albums.map { (album:$0,date:$0.tracks.map(\.added).max() ?? 0) }
        return dated.sorted {
            let a = $0.album, b = $1.album
            let primary: ComparisonResult
            switch self {
            case .titleAZ: primary = text(a.title,b.title)
            case .titleZA: primary = text(b.title,a.title)
            case .artistZA: primary = text(b.artist,a.artist)
            case .newest: primary = number($1.date,$0.date)
            case .oldest: primary = number($0.date,$1.date)
            default: primary = text(a.artist,b.artist)
            }
            if primary != .orderedSame { return primary == .orderedAscending }
            for order in [text(a.artist,b.artist),text(a.title,b.title),number(a.id,b.id)] {
                if order != .orderedSame { return order == .orderedAscending }
            }
            return false
        }.map(\.album)
    }
}

struct MusicSortMenu: View {
    @Binding var selection: MusicSort
    let options: [MusicSort]
    let identifier: String
    var body: some View {
        Menu {
            Picker("Sort by",selection:$selection) {
                ForEach(options) { mode in Text(mode.label).tag(mode) }
            }
        } label: {
            Label(selection.label,systemImage:"arrow.up.arrow.down").font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mint).padding(.vertical,10)
        }.accessibilityLabel("Sort").accessibilityValue(selection.label).accessibilityIdentifier(identifier)
    }
}
