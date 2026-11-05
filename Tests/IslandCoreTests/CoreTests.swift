import XCTest
@testable import IslandCore

final class CoreTests: XCTestCase {
    private let notch = NotchMetrics(width: 200, height: 37, centerX: 756, topY: 982)

    func testDetectsNotch() {
        let m = NotchMetrics.detect(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 37, leftWidth: 656, rightWidth: 656)
        XCTAssertEqual(m, NotchMetrics(width: 200, height: 37, centerX: 756, topY: 982))
    }

    func testNoNotchOnExternalDisplay() {
        let frame = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertNil(NotchMetrics.detect(frame: frame, safeTop: 0, leftWidth: 0, rightWidth: 0))
    }

    func testCenterRespectsScreenOrigin() {
        let m = NotchMetrics.detect(frame: CGRect(x: 1000, y: 0, width: 1512, height: 982), safeTop: 37, leftWidth: 656, rightWidth: 656)
        XCTAssertEqual(m?.centerX, 1756)
    }

    func testHiddenBodyMatchesNotchExactly() {
        XCTAssertEqual(IslandLayout.bodySize(mode: .hidden, notch: notch), CGSize(width: 200, height: 37))
    }

    func testPanelContainsEveryModeAndTouchesTop() {
        let panel = IslandLayout.panelFrame(notch: notch)
        XCTAssertEqual(panel.maxY, notch.topY)
        XCTAssertEqual(panel.midX, notch.centerX)
        for mode in [IslandMode.hidden, .compact, .expanded] {
            XCTAssertLessThanOrEqual(IslandLayout.bodySize(mode: mode, notch: notch).width, panel.width)
        }
    }

    func testHotZoneCoversNotchButNotMenuBarIcons() {
        let zone = IslandLayout.hotZone(notch: notch)
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 970)))
        XCTAssertFalse(zone.contains(CGPoint(x: 900, y: 970)))
        XCTAssertFalse(zone.contains(CGPoint(x: 756, y: 900)))
    }

    func testFirstBatteryReadingIsSilent() {
        XCTAssertNil(batteryEvent(previous: nil, current: BatteryState(percent: 10, onAC: false, charging: false)))
    }

    func testPlugInFiresOnceOnTransition() {
        let off = BatteryState(percent: 50, onAC: false, charging: false)
        let on = BatteryState(percent: 50, onAC: true, charging: true)
        XCTAssertEqual(batteryEvent(previous: off, current: on), .pluggedIn(percent: 50))
        XCTAssertNil(batteryEvent(previous: on, current: on))
    }

    func testLowBatteryFiresOnlyWhenCrossing() {
        let a = BatteryState(percent: 21, onAC: false, charging: false)
        let b = BatteryState(percent: 20, onAC: false, charging: false)
        let c = BatteryState(percent: 19, onAC: false, charging: false)
        XCTAssertEqual(batteryEvent(previous: a, current: b), .low(percent: 20))
        XCTAssertNil(batteryEvent(previous: b, current: c))
    }

    func testMusicParsing() {
        let playing = MusicState.parse(userInfo: ["Name": "Song", "Artist": "A", "Player State": "Playing"], source: .spotify)
        XCTAssertEqual(playing, MusicState(source: .spotify, title: "Song", artist: "A", isPlaying: true))
        XCTAssertNil(MusicState.parse(userInfo: ["Player State": "Stopped"], source: .music))
        XCTAssertNil(MusicState.parse(userInfo: ["Player State": "Playing"], source: .music))
    }

    func testMusicAnnouncesNewTrackAndResumeOnly() {
        let a = MusicState(source: .music, title: "A", artist: "x", isPlaying: true)
        let paused = MusicState(source: .music, title: "A", artist: "x", isPlaying: false)
        let b = MusicState(source: .music, title: "B", artist: "x", isPlaying: true)
        XCTAssertTrue(a.shouldAnnounce(after: nil))
        XCTAssertFalse(a.shouldAnnounce(after: a))
        XCTAssertFalse(paused.shouldAnnounce(after: a))
        XCTAssertTrue(a.shouldAnnounce(after: paused))
        XCTAssertTrue(b.shouldAnnounce(after: a))
    }
}

final class HUDTests: XCTestCase {
    func testVolumeSymbols() {
        XCTAssertEqual(volumeSymbol(level: 0.5, muted: true), "speaker.slash.fill")
        XCTAssertEqual(volumeSymbol(level: 0, muted: false), "speaker.slash.fill")
        XCTAssertEqual(volumeSymbol(level: 0.2, muted: false), "speaker.wave.1.fill")
        XCTAssertEqual(volumeSymbol(level: 0.5, muted: false), "speaker.wave.2.fill")
        XCTAssertEqual(volumeSymbol(level: 1, muted: false), "speaker.wave.3.fill")
    }

    func testFocusActiveAndInactive() {
        let on = #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.sleep.sleep-mode"}}]}]}"#
        let off = #"{"data":[{"storeAssertionRecords":null,"storeInvalidationRecords":[]}]}"#
        XCTAssertEqual(FocusParser.activeModeIdentifier(assertions: Data(on.utf8)), "com.apple.sleep.sleep-mode")
        XCTAssertNil(FocusParser.activeModeIdentifier(assertions: Data(off.utf8)))
        XCTAssertNil(FocusParser.activeModeIdentifier(assertions: Data("garbage".utf8)))
    }

    func testFocusModeNames() {
        let json = #"{"data":[{"modeConfigurations":{"com.apple.sleep.sleep-mode":{"mode":{"name":"Sleep","symbolImageName":"bed.double.fill"}}}}]}"#
        let modes = FocusParser.modes(configurations: Data(json.utf8))
        XCTAssertEqual(FocusParser.resolve(id: "com.apple.sleep.sleep-mode", modes: modes), FocusMode(name: "Sleep", symbol: "bed.double.fill"))
        XCTAssertEqual(FocusParser.resolve(id: "unknown", modes: modes).name, "Focus")
        XCTAssertEqual(FocusParser.resolve(id: "com.apple.donotdisturb.mode.default", modes: [:]).name, "Do Not Disturb")
    }

    func testBrightnessGate() {
        XCTAssertFalse(brightnessChangeIsUserDriven(previous: 0.5, current: 0.5, keyArmed: true))
        XCTAssertFalse(brightnessChangeIsUserDriven(previous: 0.5, current: 0.51, keyArmed: false))
        XCTAssertTrue(brightnessChangeIsUserDriven(previous: 0.5, current: 0.51, keyArmed: true))
        XCTAssertTrue(brightnessChangeIsUserDriven(previous: 0.5, current: 0.6, keyArmed: false))
    }
}

final class SystemIndicatorTests: XCTestCase {
    func testPrivacyAnnouncesOnlyWhenTurningOn() {
        let off = PrivacyState(camera: false, mic: false)
        let cam = PrivacyState(camera: true, mic: false)
        let both = PrivacyState(camera: true, mic: true)
        XCTAssertNil(privacyAnnouncement(previous: nil, current: cam))
        XCTAssertEqual(privacyAnnouncement(previous: off, current: cam), cam)
        XCTAssertEqual(privacyAnnouncement(previous: cam, current: both), both)
        XCTAssertNil(privacyAnnouncement(previous: both, current: cam))
        XCTAssertNil(privacyAnnouncement(previous: cam, current: cam))
    }

    func testBluetoothSymbols() {
        XCTAssertEqual(BluetoothInfo.symbol(forName: "Sam’s AirPods Pro"), "airpodspro")
        XCTAssertEqual(BluetoothInfo.symbol(forName: "AirPods Max"), "airpodsmax")
        XCTAssertEqual(BluetoothInfo.symbol(forName: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(BluetoothInfo.symbol(forName: "Sony WH-1000XM5"), "headphones")
    }

    func testBluetoothBatteryUsesLowestEarbud() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Pods":{"device_batteryLevelLeft":"83%","device_batteryLevelRight":"80%","device_batteryLevelCase":"100%"}},{"Mouse":{"device_batteryLevelMain":"55%"}},{"Plain":{}}]}]}"#
        let data = Data(json.utf8)
        XCTAssertEqual(BluetoothInfo.battery(profilerJSON: data, deviceName: "Pods"), 80)
        XCTAssertEqual(BluetoothInfo.battery(profilerJSON: data, deviceName: "Mouse"), 55)
        XCTAssertNil(BluetoothInfo.battery(profilerJSON: data, deviceName: "Plain"))
        XCTAssertNil(BluetoothInfo.battery(profilerJSON: data, deviceName: "Missing"))
        XCTAssertNil(BluetoothInfo.battery(profilerJSON: Data("x".utf8), deviceName: "Pods"))
    }
}

final class NowPlayingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testProgressExtrapolatesWhilePlaying() {
        let m = MusicState(source: .music, title: "A", artist: "x", isPlaying: true, duration: 200, position: 50, updatedAt: t0)
        XCTAssertEqual(m.elapsed(at: t0.addingTimeInterval(10)), 60)
        XCTAssertEqual(m.progress(at: t0.addingTimeInterval(10)), 0.3)
        XCTAssertEqual(m.elapsed(at: t0.addingTimeInterval(1000)), 200)
    }

    func testProgressFrozenWhenPaused() {
        let m = MusicState(source: .spotify, title: "A", artist: "x", isPlaying: false, duration: 100, position: 25, updatedAt: t0)
        XCTAssertEqual(m.progress(at: t0.addingTimeInterval(30)), 0.25)
    }

    func testProgressUnknownWithoutDurationOrPosition() {
        XCTAssertNil(MusicState(source: .music, title: "A", artist: "x", isPlaying: true, duration: nil, position: 5).progress(at: t0))
        XCTAssertNil(MusicState(source: .music, title: "A", artist: "x", isPlaying: true, duration: 100, position: nil).progress(at: t0))
    }

    func testParseReadsDurationAndPosition() {
        let spotify = MusicState.parse(userInfo: ["Name": "S", "Player State": "Playing", "Duration": 240000, "Playback Position": 12.5], source: .spotify)
        XCTAssertEqual(spotify?.duration, 240)
        XCTAssertEqual(spotify?.position, 12.5)
        let music = MusicState.parse(userInfo: ["Name": "S", "Player State": "Paused", "Total Time": 180000], source: .music)
        XCTAssertEqual(music?.duration, 180)
        XCTAssertNil(music?.position)
    }

    func testFormatClock() {
        XCTAssertEqual(formatClock(0), "0:00")
        XCTAssertEqual(formatClock(65.9), "1:05")
        XCTAssertEqual(formatClock(-3), "0:00")
    }
}

final class AuthPromptTests: XCTestCase {
    func testDetectsAuthWindows() {
        XCTAssertTrue(isAuthPromptVisible(owners: ["Dock", "coreautha"]))
        XCTAssertTrue(isAuthPromptVisible(owners: ["SecurityAgent"]))
        XCTAssertFalse(isAuthPromptVisible(owners: ["Dock", "Control Center", "Claude"]))
        XCTAssertFalse(isAuthPromptVisible(owners: []))
    }
}

final class LiveActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5000)

    func testTimerURL() {
        let cmd = ActivityURL.parse(URL(string: "notchisland://timer?seconds=300&title=Tea")!, now: now)
        guard case .start(let a)? = cmd else { return XCTFail() }
        XCTAssertEqual(a.title, "Tea")
        XCTAssertEqual(a.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(a.symbol, "timer")
    }

    func testActivityURLClampsAndSanitizes() {
        let url = URL(string: "notchisland://activity?id=b&title=Build&progress=7&tint=hotpink&symbol=bad%20symbol!&ttl=999999999")!
        guard case .start(let a)? = ActivityURL.parse(url, now: now) else { return XCTFail() }
        XCTAssertEqual(a.progress, 1)
        XCTAssertEqual(a.tint, "blue")
        XCTAssertEqual(a.symbol, "sparkles")
        XCTAssertEqual(a.expiresAt, now.addingTimeInterval(86_400))
    }

    func testRejectsBadURLs() {
        XCTAssertNil(ActivityURL.parse(URL(string: "https://example.com")!))
        XCTAssertNil(ActivityURL.parse(URL(string: "notchisland://activity?subtitle=x")!))
        XCTAssertNil(ActivityURL.parse(URL(string: "notchisland://timer?seconds=abc")!))
        XCTAssertNil(ActivityURL.parse(URL(string: "notchisland://rm?id=1")!))
        XCTAssertEqual(ActivityURL.parse(URL(string: "notchisland://end?id=build")!), .end(id: "build"))
    }

    func testTimerSecondsClamped() {
        guard case .start(let a)? = ActivityURL.parse(URL(string: "notchisland://timer?seconds=-5")!, now: now) else { return XCTFail() }
        XCTAssertEqual(a.endsAt, now.addingTimeInterval(1))
    }
}

final class IncomingAndAudioTests: XCTestCase {
    func testClassifiesAirDrop() {
        let r = classifyBanner(texts: ["AirDrop", "Sam’s iPhone would like to share a photo"], buttons: ["Decline", "Accept"])
        XCTAssertEqual(r?.kind, .airDrop)
        XCTAssertEqual(r?.title, "Sam’s iPhone would like to share a photo")
        XCTAssertEqual(r?.acceptLabel, "Accept")
    }

    func testClassifiesCall() {
        let r = classifyBanner(texts: ["Mom", "iPhone call"], buttons: ["Decline", "Answer"])
        XCTAssertEqual(r?.kind, .call)
        XCTAssertEqual(r?.title, "Mom")
        XCTAssertEqual(r?.acceptLabel, "Answer")
    }

    func testOrdinaryNotificationIsNotIncoming() {
        XCTAssertNil(classifyBanner(texts: ["Messages", "Hi"], buttons: ["Reply", "Close"]))
        XCTAssertNil(classifyBanner(texts: ["Call me"], buttons: []))
    }

    func testAudioOutputSymbols() {
        XCTAssertEqual(AudioOutputInfo.symbol(forName: "MacBook Pro Speakers"), "laptopcomputer")
        XCTAssertEqual(AudioOutputInfo.symbol(forName: "Sam’s AirPods Pro"), "airpodspro")
        XCTAssertEqual(AudioOutputInfo.symbol(forName: "LG HDR 4K"), "hifispeaker.fill")
        XCTAssertEqual(AudioOutputInfo.symbol(forName: "DELL Display"), "display")
    }

    func testCalculator() {
        XCTAssertEqual(Calculator.evaluate("2+2*3"), "8")
        XCTAssertEqual(Calculator.evaluate("(1+2)*3"), "9")
        XCTAssertEqual(Calculator.evaluate("10/4"), "2.5")
        XCTAssertEqual(Calculator.evaluate("-3 + 5"), "2")
        XCTAssertNil(Calculator.evaluate("42"))
        XCTAssertNil(Calculator.evaluate("1/0"))
        XCTAssertNil(Calculator.evaluate("safari"))
        XCTAssertNil(Calculator.evaluate("2+"))
    }
}
