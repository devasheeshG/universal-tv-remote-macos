import Testing
import Foundation
@testable import UniversalTVRemote

private final class SelectionDriver: TVDriver {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?
    var onAppsChanged: (() -> Void)?
    var connectionCount = 0
    var disconnectCount = 0
    var apps: [TVApp] { [] }
    func connect(token: String?) { connectionCount += 1; onStateChange?(.connected) }
    func disconnect() { disconnectCount += 1; onStateChange?(.idle) }
    func submitPairingCode(_ code: String) {}
    func send(_ key: RemoteKey) { Issue.record("Unexpected command") }
    func sendText(_ text: String) { Issue.record("Unexpected command") }
    func launchApp(_ appID: String) { Issue.record("Unexpected command") }
}

struct SelectionTests {
    @Test @MainActor
    func testSavedSelectionRestoresAfterDelayedDiscoveryAndAddressChange() {
        let suite = "SelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fireTV:demo", forKey: "selectedDevice")
        defaults.set("test-token", forKey: "token.fireTV:demo")
        let discovery = DiscoveryEngine(defaults: defaults)
        var drivers: [SelectionDriver] = []
        let state = AppState(discovery: discovery, startsDiscovery: false, defaults: defaults) { device in
            let driver = SelectionDriver()
            drivers.append(driver)
            return RemoteSession(device: device, driver: driver, defaults: defaults)
        }
        #expect(state.session == nil)
        discovery.upsert(DiscoveredTV(id: "fireTV:demo", brand: .fireTV, name: "Demo", host: "192.0.2.1"))
        #expect(state.session?.device.host == "192.0.2.1")
        #expect(drivers.count == 1)
        #expect(drivers[0].connectionCount == 1)
        discovery.upsert(DiscoveredTV(id: "fireTV:demo", brand: .fireTV, name: "Demo", host: "192.0.2.2"))
        #expect(state.session?.device.host == "192.0.2.2")
        #expect(drivers.count == 2)
        #expect(drivers[0].disconnectCount == 1)
        #expect(drivers[1].connectionCount == 1)
        state.session?.disconnect()
    }

    @Test @MainActor
    func testDiscoveryDoesNotAutomaticallyPairAnUnknownTV() {
        let suite = "SelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = DiscoveryEngine(defaults: defaults)
        let state = AppState(discovery: discovery, startsDiscovery: false, defaults: defaults) { device in
            Issue.record("Automatic discovery must not start pairing")
            return RemoteSession(device: device, driver: SelectionDriver(), defaults: defaults)
        }
        discovery.upsert(DiscoveredTV(id: "fireTV:new", brand: .fireTV, name: "New TV", host: "192.0.2.1"))
        #expect(state.session == nil)
    }
}
