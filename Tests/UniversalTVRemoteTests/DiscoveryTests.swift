import Testing
import Foundation
@testable import UniversalTVRemote

struct DiscoveryTests {
    @Test
    func testRememberedDevicesStaySeparateFromLiveDiscoveryAndExpire() throws {
        let suite = "DiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tv = DiscoveredTV(id: "fireTV:demo", brand: .fireTV, name: "TV", host: "192.0.2.1")
        defaults.set(try JSONEncoder().encode([tv]), forKey: "rememberedDevices")
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.loadRememberedDevices()
        #expect(discovery.availableDevices.isEmpty)
        #expect(discovery.savedDevices == [tv])
        discovery.upsert(tv)
        #expect(discovery.availableDevices == [tv])
        #expect(discovery.savedDevices.isEmpty)
        discovery.refreshAvailability(now: Date().addingTimeInterval(46))
        #expect(discovery.availableDevices.isEmpty)
        #expect(discovery.savedDevices == [tv])
    }
    @Test
    func testLegacyDuplicatesPreserveSelectionPairingAndNickname() throws {
        let suite = "DiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = DiscoveredTV(id: "fireTV:uuid", brand: .fireTV, name: "Bedroom", host: "192.0.2.1")
        let duplicates = (1...15).map {
            DiscoveredTV(id: "fireTV:amzn.dmgr:device:session:\($0)", brand: .fireTV,
                         name: "Bedroom", host: "192.0.2.1")
        }
        defaults.set(try JSONEncoder().encode(duplicates + [selected]), forKey: "rememberedDevices")
        defaults.set(selected.id, forKey: "selectedDevice")
        defaults.set("test-token", forKey: "token.\(selected.id)")
        defaults.set([duplicates[0].id: "My TV"], forKey: "customNames")
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.loadRememberedDevices()
        #expect(discovery.devices.count == 1)
        #expect(discovery.devices[0].id == selected.id)
        #expect(discovery.displayName(for: discovery.devices[0]) == "My TV")
        #expect(defaults.string(forKey: "selectedDevice") == selected.id)
        #expect(defaults.string(forKey: "token.\(selected.id)") == "test-token")
        discovery.loadRememberedDevices()
        #expect(discovery.devices.count == 1)
    }

    @Test
    func testChangingFireTVServiceSuffixAndAddressUseSameIdentity() {
        let suite = "DiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.upsert(DiscoveredTV(id: "fireTV:amzn.dmgr:abc:session:100", brand: .fireTV,
                                     name: "TV", host: "192.0.2.1"))
        discovery.upsert(DiscoveredTV(id: "fireTV:amzn.dmgr:abc:newsession:200", brand: .fireTV,
                                     name: "TV", host: "192.0.2.2"))
        #expect(discovery.devices.count == 1)
        #expect(discovery.devices[0].host == "192.0.2.2")
        discovery.upsert(DiscoveredTV(id: "fireTV:other", brand: .fireTV, name: "TV", host: "192.0.2.3"))
        discovery.upsert(DiscoveredTV(id: "androidTV:other", brand: .androidTV, name: "TV", host: "192.0.2.2"))
        #expect(discovery.devices.count == 3)
    }

    @Test
    func testCanonicalMigrationCopiesCredentialsAndSelection() throws {
        let suite = "DiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = DiscoveredTV(id: "fireTV:amzn.dmgr:abc:session:100", brand: .fireTV,
                                  name: "TV", host: "192.0.2.1")
        defaults.set(try JSONEncoder().encode([device]), forKey: "rememberedDevices")
        defaults.set(device.id, forKey: "selectedDevice")
        defaults.set("test-token", forKey: "token.\(device.id)")
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.loadRememberedDevices()
        #expect(defaults.string(forKey: "selectedDevice") == "fireTV:amzn.dmgr:abc")
        #expect(defaults.string(forKey: "token.fireTV:amzn.dmgr:abc") == "test-token")
    }

    @Test
    func testProtocolAliasFollowsAddressChangesAcrossLaunches() {
        let suite = "DiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = DiscoveryEngine(defaults: defaults)
        discovery.upsert(DiscoveredTV(id: "fireTV:uuid", brand: .fireTV, name: "TV", host: "192.0.2.1"))
        discovery.upsert(DiscoveredTV(id: "fireTV:amzn.dmgr:abc:session:1", brand: .fireTV,
                                     name: "TV", host: "192.0.2.1"))
        let nextLaunch = DiscoveryEngine(defaults: defaults)
        nextLaunch.loadRememberedDevices()
        nextLaunch.upsert(DiscoveredTV(id: "fireTV:amzn.dmgr:abc:session:2", brand: .fireTV,
                                     name: "TV", host: "192.0.2.2"))
        #expect(nextLaunch.devices.count == 1)
        #expect(nextLaunch.devices[0].id == "fireTV:uuid")
        #expect(nextLaunch.devices[0].host == "192.0.2.2")
    }
}
