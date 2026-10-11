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
        let directory = ProcessInfo.processInfo.environment["README_SCREENSHOTS"]
        let suite = "ScreenshotTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = DiscoveredTV(id: "fireTV:demo", brand: .fireTV, name: "Living Room", host: "192.0.2.1")
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.upsert(device)
        discovery.upsert(DiscoveredTV(id: "fireTV:saved", brand: .fireTV, name: "Bedroom",
                                     host: "192.0.2.2"), discovered: false)
        let driver = ScreenshotDriver()
        let session = RemoteSession(device: device, driver: driver, defaults: defaults)
        let state = AppState(discovery: discovery, initialSession: session, startsDiscovery: false, defaults: defaults)
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        var connectedHeight: CGFloat = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 272, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for (filename, status, expanded) in [("remote-connected.png", SessionState.connected, false),
                                   ("remote-expanded.png", .connected, true),
                                   ("remote-expanded-compact.png", .connected, true),
                                   ("remote-devices.png", .connected, false),
                                   ("remote-settings.png", .connected, false),
                                   ("remote-pairing.png", .awaitingPairing(.pin(digits: 4)), false),
                                   ("remote-pairing-android.png", .awaitingPairing(.pin(digits: 6)), false),
                                   ("remote-disconnected.png", .failed("Disconnected — Fire TV remote service is unavailable"), false)] {
            driver.nextState = status
            session.connect()
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000_000)
            let compact = filename == "remote-expanded-compact.png"
            let panel: RemotePanel = filename == "remote-devices.png" ? .devices : filename == "remote-settings.png" ? .settings : .remote
            let view = RemoteView(appsExpanded: expanded, availableHeight: compact ? 620 : nil, panel: panel).environmentObject(state)
                .background(Color(red: 0.10, green: 0.10, blue: 0.11))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            let size = hosting.fittingSize
            #expect(abs(size.width - 272) < 1)
            #expect(size.height > 100)
            #expect(size.height <= (NSScreen.main?.visibleFrame.height ?? 800) - 20)
            #expect(abs(window.contentView!.bounds.height - size.height) < 1)
            if compact { #expect(size.height <= 600) }
            if filename == "remote-connected.png" { connectedHeight = size.height }
            if filename == "remote-pairing.png" { #expect(size.height < connectedHeight) }
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            if let directory { try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename)) }
            session.disconnect()
        }
    }
}
