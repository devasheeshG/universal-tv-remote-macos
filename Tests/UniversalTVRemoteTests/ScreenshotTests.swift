import Testing
import SwiftUI
import AppKit
@testable import UniversalTVRemote

private final class ScreenshotDriver: TVDriver {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?
    var onAppsChanged: (() -> Void)?
    var nextState: SessionState = .connected
    let apps = [TVApp(name: "Netflix", id: "netflix"), TVApp(name: "YouTube", id: "youtube"),
                TVApp(name: "Prime Video", id: "prime"), TVApp(name: "Disney+", id: "disney"),
                TVApp(name: "Spotify", id: "spotify"), TVApp(name: "Max", id: "max")]
    func connect(token: String?) { onStateChange?(nextState) }
    func disconnect() { onStateChange?(.idle) }
    func submitPairingCode(_ code: String) {}
    func send(_ key: RemoteKey) { Issue.record("Screenshot must not send keys") }
    func sendText(_ text: String) { Issue.record("Screenshot must not send text") }
    func launchApp(_ appID: String) { Issue.record("Screenshot must not launch apps") }
}

struct ScreenshotTests {
    @Test @MainActor
    func testCaptureOfflineAppScreenshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["README_SCREENSHOTS"] else {
            return
        }
        let suite = "ScreenshotTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = DiscoveredTV(id: "fireTV:demo", brand: .fireTV, name: "Living Room", host: "192.0.2.1")
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.upsert(device)
        let driver = ScreenshotDriver()
        let session = RemoteSession(device: device, driver: driver, defaults: defaults)
        let state = AppState(discovery: discovery, initialSession: session, startsDiscovery: false, defaults: defaults)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (filename, status) in [("remote-connected.png", SessionState.connected),
                                   ("remote-disconnected.png", .failed("Disconnected — Fire TV remote service is unavailable"))] {
            driver.nextState = status
            session.connect()
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000_000)
            let view = RemoteView().environmentObject(state)
                .background(Color(red: 0.10, green: 0.10, blue: 0.11))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
            session.disconnect()
        }
    }
}
