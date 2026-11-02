import XCTest

final class MyMusicUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func waitUntil(_ timeout: TimeInterval = 45, _ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in predicate() },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:timeout),.completed)
    }
    func openTestTrack(_ query: String = "Let It Go", title: String? = nil) {
        app.launch()
        XCTAssertTrue(app.buttons["Refresh library"].waitForExistence(timeout:10))
        app.buttons["Refresh library"].tap()
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText(query + "\n")
        let rows = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","track-"))
        let row = title.map { rows.matching(NSPredicate(format:"label CONTAINS[c] %@",$0)).firstMatch } ?? rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:60)); row.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout:15)); app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["playerToggle"].waitForExistence(timeout:10))
    }
    func testStreamingSeekingAndFavorite() throws {
        openTestTrack("Heaven")
        XCTAssertTrue(app.staticTexts["PLAYING FROM YOUR LIBRARY"].waitForExistence(timeout:10))
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("streaming-original-flac")
        app.buttons["playerToggle"].tap()
        waitUntil { self.app.buttons["playerToggle"].label == "Play" }
        let slider = app.sliders["Playback position"]; slider.adjust(toNormalizedSliderPosition:0.45)
        app.buttons["playerToggle"].tap()
        waitUntil(45) { self.app.buttons["playerToggle"].label == "Pause" }
        let time = app.staticTexts["elapsedTime"].label.split(separator:":").compactMap { Int($0) }
        XCTAssertEqual(time.count,2); XCTAssertGreaterThan(time[0]*60+time[1],20)
        app.buttons["Favorite"].tap(); capture("seek-and-favorite")
        app.buttons["playerToggle"].tap()
    }
    func testHoneyStartsFromOneTapAndResumes() throws {
        openTestTrack("Honey")
        waitUntil(60) {
            self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00"
        }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("one-tap-honey-playback")
        app.buttons["playerToggle"].tap()
        waitUntil { self.app.buttons["playerToggle"].label == "Play" }
        let pausedTime = app.staticTexts["elapsedTime"].label
        app.buttons["playerToggle"].tap()
        waitUntil(30) {
            self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != pausedTime
        }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        app.buttons["playerToggle"].tap()
    }
    func testQueueAutomaticallyPlaysNextTrack() throws {
        openTestTrack("Pink Floyd", title:"Speak to Me")
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        let firstTitle = app.staticTexts["nowPlayingTitle"].label
        // Exercise natural completion rather than the decoder's seek estimate.
        waitUntil(110) {
            self.app.staticTexts["nowPlayingTitle"].label != firstTitle && self.app.buttons["playerToggle"].label == "Pause"
        }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("autoplay-next-track")
        app.buttons["playerToggle"].tap()
    }
    func testQueueAutomaticallyPlaysAfterSeekingNearEnd() throws {
        openTestTrack("Pink Floyd")
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        let firstTitle = app.staticTexts["nowPlayingTitle"].label
        app.sliders["Playback position"].adjust(toNormalizedSliderPosition:0.999)
        waitUntil(45) {
            self.app.staticTexts["nowPlayingTitle"].label != firstTitle && self.app.buttons["playerToggle"].label == "Pause"
        }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("autoplay-after-seeking")
        app.buttons["playerToggle"].tap()
    }
    func testDownloadAndRelaunchOffline() throws {
        openTestTrack()
        app.buttons["saveOffline"].tap()
        waitUntil(120) { self.app.buttons["saveOffline"].label.contains("Saved") }
        capture("download-completed")
        app.terminate()
        app.launchArguments = ["--test-offline"]
        app.launch()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["playDownloads"].waitForExistence(timeout:15)); app.buttons["playDownloads"].tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["PLAYING FROM DOWNLOADS"].waitForExistence(timeout:10))
        waitUntil(30) { self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("offline-after-relaunch")
        app.buttons["playerToggle"].tap()
    }
    func testHighResolutionAndBackgroundPlayback() throws {
        openTestTrack("Breathe (In the Air)")
        XCTAssertTrue(app.staticTexts["PLAYING FROM YOUR LIBRARY"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["FLAC · 24-bit · 192 kHz"].waitForExistence(timeout:10))
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        let before = app.staticTexts["elapsedTime"].label
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:10))
        Thread.sleep(forTimeInterval:5)
        app.activate()
        waitUntil { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != before }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("24-bit-192-kHz-background-playback")
        app.buttons["playerToggle"].tap()
    }
    func testLibraryAndSettings() throws {
        app.launch(); XCTAssertTrue(app.buttons["Refresh library"].waitForExistence(timeout:10)); capture("library")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Download on Wi-Fi only"].waitForExistence(timeout:10))
        capture("settings")
    }
    func testMiniPlayerKeepsAllTabsAccessible() throws {
        openTestTrack("Honey")
        app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","PLAYING FROM ")).firstMatch
            .coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            .press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.85)))
        waitUntil(15) { self.app.tabBars.buttons["Library"].isHittable }
        app.tabBars.buttons["Library"].tap()
        for name in ["Library", "Search", "Downloads", "Settings"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout:10))
            XCTAssertTrue(tab.isHittable)
            let controls = app.buttons["miniToggle"]
            XCTAssertTrue(controls.exists)
            XCTAssertLessThanOrEqual(controls.frame.maxY,tab.frame.minY,"The mini player must sit above the \(name) tab")
            tab.tap()
            XCTAssertTrue(tab.isSelected,"The \(name) tab must respond while music is playing")
        }
        capture("mini-player-above-tabs")
        app.buttons["miniToggle"].tap()
    }
    func testStopClearsMiniPlayerAndAllowsNewPlayback() throws {
        openTestTrack("Honey")
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertTrue(app.buttons["stopPlayback"].isHittable)
        capture("stop-on-now-playing")
        app.buttons["stopPlayback"].tap()
        waitUntil(15) {
            !self.app.buttons["miniPlayer"].exists && !self.app.buttons["playerToggle"].exists && self.app.tabBars.buttons["Library"].isHittable
        }
        XCTAssertFalse(app.buttons["miniToggle"].exists)
        XCTAssertFalse(app.buttons["stopPlayback"].exists)
        capture("stopped-no-mini-player")
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","track-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10)); row.tap()
        waitUntil(60) { self.app.buttons["miniToggle"].label == "Pause" }
        app.buttons["miniPlayer"].tap()
        waitUntil(15) { self.app.buttons["stopPlayback"].isHittable }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        app.buttons["stopPlayback"].tap()
    }
    func testAlbumDownloadButtonShowsProgressAndDownloaded() throws {
        app.launch()
        XCTAssertTrue(app.buttons["Refresh library"].waitForExistence(timeout:10))
        app.buttons["Refresh library"].tap()
        let album = app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Honey - Single")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout:60)); album.tap()
        let button = app.buttons["downloadAlbum"]
        XCTAssertTrue(button.waitForExistence(timeout:10))
        if button.label.contains("Downloaded") {
            app.buttons["Options for Honey"].tap()
            app.buttons["Remove download"].tap()
            waitUntil(10) { button.isEnabled }
        }
        XCTAssertTrue(button.label.contains("Download"))
        button.tap()
        waitUntil(10) { button.label.contains("Saving") || button.label.contains("Downloaded") }
        XCTAssertFalse(button.isEnabled)
        waitUntil(120) { button.label.contains("Downloaded") }
        capture("album-downloaded")
        app.terminate(); app.launch()
        XCTAssertTrue(album.waitForExistence(timeout:30)); album.tap()
        XCTAssertTrue(button.waitForExistence(timeout:10))
        XCTAssertTrue(button.label.contains("Downloaded"))
        XCTAssertFalse(button.isEnabled)
    }
    func testAddTrackToQueueKeepsCurrentSongPlaying() throws {
        app.launch()
        let album = app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Honey - Single")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout:60)); album.tap()
        app.buttons["playAlbum"].tap()
        waitUntil(60) { self.app.buttons["miniToggle"].label == "Pause" }
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText("Heaven\n")
        let menu = app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Options for ")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout:30))
        let queuedTitle = String(menu.label.dropFirst("Options for ".count))
        menu.tap(); app.buttons["Add to queue"].tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["nowPlayingTitle"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["nowPlayingTitle"].label,"Honey")
        XCTAssertEqual(app.buttons["playerToggle"].label,"Pause")
        app.buttons["Up next"].tap()
        XCTAssertTrue(app.navigationBars["Up next"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons[queuedTitle].exists)
        capture("track-added-without-interruption")
        app.buttons["closeQueue"].tap()
        let next = try XCTUnwrap(app.buttons.matching(NSPredicate(format:"label == %@","Next track")).allElementsBoundByIndex.first { $0.isHittable })
        next.tap()
        waitUntil(60) {
            self.app.staticTexts["nowPlayingTitle"].label == queuedTitle && self.app.buttons["playerToggle"].label == "Pause"
        }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        app.buttons["stopPlayback"].tap()
    }
    func testQueueAlbumWaitsForPlayAndPreservesRepeatedTracks() throws {
        app.launch()
        let album = app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Honey - Single")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout:60)); album.tap()
        let queue = app.buttons["queueAlbum"]
        XCTAssertTrue(queue.waitForExistence(timeout:10)); queue.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["miniToggle"].label,"Play")
        queue.tap()
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["playerToggle"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["playerToggle"].label,"Play")
        XCTAssertEqual(app.staticTexts["elapsedTime"].label,"0:00")
        for _ in 0..<2 {
            app.buttons["Shuffle"].tap()
            app.buttons["Up next"].tap()
            XCTAssertTrue(app.navigationBars["Up next"].waitForExistence(timeout:10))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","queueEntry-")).count,2)
            app.buttons["closeQueue"].tap()
        }
        app.buttons["playerToggle"].tap()
        waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        capture("queued-album-playing-on-request")
        app.buttons["stopPlayback"].tap()
    }
    func playlistRow(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","playlist-",name)).firstMatch
    }
    func testPlaylistCreateEditPersistPlayAndDelete() throws {
        let name = "Test Mix " + UUID().uuidString.prefix(6)
        let renamed = name + " Edited"
        app.launch()
        XCTAssertTrue(app.buttons["openPlaylists"].waitForExistence(timeout:30)); app.buttons["openPlaylists"].tap()
        app.buttons["newPlaylist"].tap()
        let field = app.textFields["playlistName"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap(); field.typeText(name)
        app.buttons["savePlaylist"].tap()
        XCTAssertTrue(playlistRow(name).waitForExistence(timeout:10)); playlistRow(name).tap()
        for query in ["Honey", "Let It Go"] {
            app.buttons["addPlaylistSongs"].tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText(query + "\n")
            let song = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS[c] %@","selectPlaylistSong-",query)).firstMatch
            XCTAssertTrue(song.waitForExistence(timeout:15)); song.tap()
            app.buttons["addSelectedTracks"].tap()
        }
        let songs = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","playlistSong-"))
        waitUntil(15) { songs.count == 2 }
        let firstID = songs.firstMatch.identifier
        app.buttons["editPlaylist"].tap()
        waitUntil(10) { self.app.buttons["editPlaylist"].label == "Done" }
        let handles = app.buttons.matching(NSPredicate(format:"label BEGINSWITH[c] %@","Reorder"))
        capture("playlist-reorder-handles")
        if handles.count != 2 { print(app.debugDescription) }
        XCTAssertEqual(handles.count,2)
        handles.element(boundBy:1).press(forDuration:0.5,thenDragTo:handles.element(boundBy:0))
        app.buttons["editPlaylist"].tap()
        waitUntil(15) { songs.firstMatch.identifier != firstID }
        let reorderedFirst = songs.firstMatch.identifier
        capture("playlist-edit-reordered")
        app.buttons["Playlist options"].tap(); app.buttons["Rename"].tap()
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap()
        field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:name.count) + renamed)
        app.buttons["savePlaylist"].tap()
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout:10))
        capture("playlist-created-and-renamed")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openPlaylists"].waitForExistence(timeout:30)); app.buttons["openPlaylists"].tap()
        XCTAssertTrue(playlistRow(renamed).waitForExistence(timeout:10)); playlistRow(renamed).tap()
        waitUntil(15) { songs.count == 2 }
        XCTAssertEqual(songs.firstMatch.identifier,reorderedFirst)
        songs.firstMatch.swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(15) { songs.count == 1 }
        app.buttons["playPlaylist"].tap()
        waitUntil(60) { self.app.buttons["miniToggle"].label == "Pause" }
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["stopPlayback"].waitForExistence(timeout:10))
        waitUntil(60) { self.app.staticTexts["elapsedTime"].label != "0:00" }
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        app.buttons["stopPlayback"].tap()
        XCTAssertTrue(app.buttons["Playlist options"].waitForExistence(timeout:10))
        app.buttons["Playlist options"].tap(); app.buttons["Delete playlist"].tap()
        app.buttons["Delete playlist"].tap()
        waitUntil(15) { !self.playlistRow(renamed).exists && self.app.navigationBars["Playlists"].exists }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openPlaylists"].waitForExistence(timeout:30)); app.buttons["openPlaylists"].tap()
        XCTAssertFalse(playlistRow(renamed).exists)
    }
    func testCreatePlaylistFromTrackMenuWithoutPlaying() throws {
        let name = "Track Mix " + UUID().uuidString.prefix(6)
        app.launch(); app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText("Honey\n")
        XCTAssertTrue(app.buttons["Options for Honey"].waitForExistence(timeout:30)); app.buttons["Options for Honey"].tap()
        app.buttons["Add to playlist"].tap()
        XCTAssertTrue(app.navigationBars["Add to playlist"].waitForExistence(timeout:10))
        app.buttons["New playlist"].tap()
        let field = app.textFields["playlistName"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap(); field.typeText(name)
        app.buttons["savePlaylist"].tap()
        waitUntil(15) { !self.app.navigationBars["Add to playlist"].exists }
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
        app.tabBars.buttons["Library"].tap(); app.buttons["openPlaylists"].tap()
        XCTAssertTrue(playlistRow(name).waitForExistence(timeout:10)); playlistRow(name).tap()
        let songs = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","playlistSong-"))
        XCTAssertEqual(songs.count,1); XCTAssertTrue(songs.firstMatch.label.contains("Honey"))
        capture("track-added-to-new-playlist")
        app.buttons["Playlist options"].tap(); app.buttons["Delete playlist"].tap()
        app.buttons["Delete playlist"].tap()
        waitUntil(15) { !self.playlistRow(name).exists }
    }
    func chooseSort(_ identifier: String, _ title: String) {
        let menu = app.buttons[identifier]
        XCTAssertTrue(menu.waitForExistence(timeout:10)); menu.tap()
        app.buttons[title].tap()
        waitUntil(10) { (menu.value as? String) == title }
    }
    func testLibrarySortsAreIndependentAndPersist() throws {
        app.launch()
        XCTAssertTrue(app.buttons["sortLibrary"].waitForExistence(timeout:30))
        chooseSort("sortLibrary","Title A–Z")
        let albums = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","album-"))
        XCTAssertTrue(albums.firstMatch.waitForExistence(timeout:15))
        let firstAlbum = albums.firstMatch.identifier
        chooseSort("sortLibrary","Title Z–A")
        waitUntil(15) { albums.firstMatch.identifier != firstAlbum }
        app.buttons["Tracks"].tap()
        chooseSort("sortLibrary","Title A–Z")
        let tracks = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","track-"))
        XCTAssertTrue(tracks.firstMatch.waitForExistence(timeout:15))
        let firstTrack = tracks.firstMatch.identifier
        chooseSort("sortLibrary","Title Z–A")
        waitUntil(15) { tracks.firstMatch.identifier != firstTrack }
        app.buttons["Favorites"].tap(); chooseSort("sortLibrary","Artist Z–A")
        app.buttons["Albums"].tap()
        XCTAssertEqual(app.buttons["sortLibrary"].value as? String,"Title Z–A")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["sortLibrary"].waitForExistence(timeout:30))
        XCTAssertEqual(app.buttons["sortLibrary"].value as? String,"Title Z–A")
        chooseSort("sortLibrary","Artist A–Z")
        app.buttons["Tracks"].tap()
        XCTAssertEqual(app.buttons["sortLibrary"].value as? String,"Title Z–A")
        chooseSort("sortLibrary","Title A–Z")
        app.buttons["Favorites"].tap()
        XCTAssertEqual(app.buttons["sortLibrary"].value as? String,"Artist Z–A")
        chooseSort("sortLibrary","Title A–Z")
        app.buttons["Albums"].tap()
        capture("library-sort-menu")
    }
    func testPlaylistSortPreservesCustomOrderAndDeletesCorrectSong() throws {
        let name = "Sort Mix " + UUID().uuidString.prefix(6)
        app.launch()
        XCTAssertTrue(app.buttons["openPlaylists"].waitForExistence(timeout:30)); app.buttons["openPlaylists"].tap()
        XCTAssertTrue(app.buttons["newPlaylist"].waitForExistence(timeout:10)); app.buttons["newPlaylist"].tap()
        let field = app.textFields["playlistName"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap(); field.typeText(name)
        app.buttons["savePlaylist"].tap()
        XCTAssertTrue(playlistRow(name).waitForExistence(timeout:10)); playlistRow(name).tap()
        for query in ["Honey", "Let It Go"] {
            app.buttons["addPlaylistSongs"].tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText(query + "\n")
            let song = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS[c] %@","selectPlaylistSong-",query)).firstMatch
            XCTAssertTrue(song.waitForExistence(timeout:15)); song.tap(); app.buttons["addSelectedTracks"].tap()
        }
        let songs = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","playlistSong-"))
        waitUntil(15) { songs.count == 2 }
        let original = songs.allElementsBoundByIndex.map(\.identifier)
        chooseSort("sortPlaylist","Title Z–A")
        XCTAssertEqual(songs.firstMatch.identifier,original[1])
        chooseSort("sortPlaylist","Custom order")
        XCTAssertEqual(songs.allElementsBoundByIndex.map(\.identifier),original)
        chooseSort("sortPlaylist","Title Z–A")
        app.buttons["editPlaylist"].tap()
        waitUntil(10) { (self.app.buttons["sortPlaylist"].value as? String) == "Custom order" }
        XCTAssertEqual(songs.allElementsBoundByIndex.map(\.identifier),original)
        app.buttons["editPlaylist"].tap()
        chooseSort("sortPlaylist","Title Z–A")
        app.buttons["queuePlaylist"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["miniPlayer"].label.contains("Let It Go"))
        XCTAssertEqual(app.buttons["miniToggle"].label,"Play")
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["stopPlayback"].waitForExistence(timeout:10)); app.buttons["stopPlayback"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openPlaylists"].waitForExistence(timeout:30)); app.buttons["openPlaylists"].tap()
        XCTAssertTrue(playlistRow(name).waitForExistence(timeout:10)); playlistRow(name).tap()
        XCTAssertTrue(app.buttons["sortPlaylist"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["sortPlaylist"].value as? String,"Title Z–A")
        XCTAssertEqual(songs.firstMatch.identifier,original[1])
        songs.firstMatch.swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(15) { songs.count == 1 }
        XCTAssertEqual(songs.firstMatch.identifier,original[0])
        XCTAssertTrue(songs.firstMatch.label.contains("Honey"))
        chooseSort("sortPlaylist","Custom order")
        XCTAssertEqual(songs.firstMatch.identifier,original[0])
        capture("sorted-playlist-custom-order-safe")
        app.buttons["Playlist options"].tap(); app.buttons["Delete playlist"].tap(); app.buttons["Delete playlist"].tap()
        waitUntil(15) { !self.playlistRow(name).exists }
    }
    func openRepeatedQueue(autoplay: Bool = false) {
        app.launch(); app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10)); search.tap(); search.typeText("Honey\n")
        XCTAssertTrue(app.buttons["Options for Honey"].waitForExistence(timeout:30))
        for _ in 0..<3 {
            app.buttons["Options for Honey"].tap(); app.buttons["Add to queue"].tap()
        }
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout:10)); app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["playerToggle"].waitForExistence(timeout:10))
        if autoplay {
            app.buttons["playerToggle"].tap()
            waitUntil(60) { self.app.buttons["playerToggle"].label == "Pause" && self.app.staticTexts["elapsedTime"].label != "0:00" }
        }
    }
    func testQueueEditingPreservesCurrentEntryAndShuffleChanges() throws {
        openRepeatedQueue(autoplay:true)
        let before = app.staticTexts["elapsedTime"].label
        app.buttons["Shuffle"].tap()
        app.buttons["Up next"].tap()
        let rows = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","queueEntry-"))
        waitUntil(10) { rows.count == 3 }
        let original = rows.allElementsBoundByIndex.map(\.identifier)
        let active = original[0], moved = original[2], removed = original[1]
        XCTAssertEqual(app.buttons[active].value as? String,"Current song")
        app.buttons["editQueue"].tap()
        waitUntil(10) { self.app.buttons["editQueue"].label == "Done" }
        let handles = app.buttons.matching(NSPredicate(format:"label BEGINSWITH[c] %@","Reorder"))
        XCTAssertEqual(handles.count,3)
        handles.element(boundBy:2).press(forDuration:0.5,thenDragTo:handles.element(boundBy:0))
        app.buttons["editQueue"].tap()
        waitUntil(10) { rows.firstMatch.identifier == moved }
        XCTAssertEqual(app.buttons[active].value as? String,"Current song")
        app.buttons[removed].swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(10) { rows.count == 2 }
        XCTAssertFalse(app.buttons[removed].exists)
        XCTAssertEqual(app.buttons[active].value as? String,"Current song")
        capture("queue-reordered-and-edited")
        app.buttons["closeQueue"].tap()
        XCTAssertEqual(app.buttons["playerToggle"].label,"Pause")
        XCTAssertEqual(app.buttons["Shuffle"].value as? String,"Off")
        XCTAssertNotEqual(app.staticTexts["elapsedTime"].label,"0:00")
        XCTAssertNotEqual(app.staticTexts["elapsedTime"].label,before)
        app.buttons["Shuffle"].tap(); app.buttons["Shuffle"].tap()
        app.buttons["Up next"].tap()
        waitUntil(10) { rows.count == 2 }
        XCTAssertFalse(app.buttons[removed].exists)
        app.buttons[moved].swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(10) { rows.count == 1 }
        XCTAssertEqual(app.buttons[active].value as? String,"Current song")
        app.buttons[active].swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(15) { !self.app.buttons["miniPlayer"].exists && self.app.tabBars.buttons["Search"].isHittable }
        XCTAssertFalse(app.buttons["playerToggle"].exists)
    }
    func testRemovingCurrentQueuedSongKeepsPausedStateAndClearsEmptyQueue() throws {
        openRepeatedQueue()
        app.buttons["Up next"].tap()
        let rows = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","queueEntry-"))
        waitUntil(10) { rows.count == 3 }
        let original = rows.allElementsBoundByIndex.map(\.identifier)
        rows.firstMatch.swipeLeft(); app.buttons["Delete"].tap()
        waitUntil(10) { rows.count == 2 }
        XCTAssertFalse(app.buttons[original[0]].exists)
        XCTAssertEqual(app.buttons[original[1]].value as? String,"Current song")
        app.buttons["closeQueue"].tap()
        XCTAssertTrue(app.buttons["playerToggle"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["playerToggle"].label,"Play")
        XCTAssertEqual(app.staticTexts["elapsedTime"].label,"0:00")
        XCTAssertFalse(app.staticTexts["playbackError"].exists)
        app.buttons["Up next"].tap()
        for remaining in [1,0] {
            rows.firstMatch.swipeLeft(); app.buttons["Delete"].tap()
            if remaining > 0 { waitUntil(10) { rows.count == remaining } }
        }
        waitUntil(15) { !self.app.buttons["miniPlayer"].exists && self.app.tabBars.buttons["Search"].isHittable }
        XCTAssertFalse(app.buttons["playerToggle"].exists)
        capture("queue-cleared-player-dismissed")
    }
}
