//
//  TVController.swift
//  Universal TV Remote for Mac
//
//  The brand-agnostic core every other file plugs into:
//
//    DiscoveredTV   — one TV found on (or remembered from) the network
//    RemoteKey      — every button the UI can press, in one enum
//    TVDriver       — the small protocol each brand driver implements
//    RemoteSession  — the ObservableObject the UI talks to; it owns a driver,
//                     persists pairing tokens, and republishes state changes
//
//  Adding a sixth TV brand means: add a TVBrand case, write one driver file,
//  and register it in RemoteSession.makeDriver(for:). Nothing else changes.
//

import Foundation
import Darwin

// MARK: - Brands

enum TVBrand: String, Codable, CaseIterable {
    case fireTV
    case androidTV
    case samsung
    case lg
    case roku

    /// Human-readable name shown in the device picker.
    var displayName: String {
        switch self {
        case .fireTV:    return "Fire TV"
        case .androidTV: return "Android TV"
        case .samsung:   return "Samsung"
        case .lg:        return "LG"
        case .roku:      return "Roku"
        }
    }

    /// SF Symbol used next to the device name in the picker.
    var symbolName: String {
        switch self {
        case .fireTV:    return "flame"
        case .androidTV: return "play.tv"
        case .samsung:   return "tv"
        case .lg:        return "tv.inset.filled"
        case .roku:      return "appletvremote.gen1"
        }
    }
}

// MARK: - Discovered device

/// One TV on the network. Produced by Discovery, persisted to UserDefaults so
/// known TVs appear instantly on the next launch (before a fresh scan lands).
struct DiscoveredTV: Identifiable, Codable, Hashable {
    /// Stable identity across launches: "<brand>:<unique part>", where the
    /// unique part is the Bonjour service name or SSDP USN when available,
    /// falling back to the IP address.
    let id: String
    let brand: TVBrand
    var name: String
    var host: String
    /// Control port when the protocol needs a specific one (Roku's ECP port
    /// comes from its SSDP LOCATION header; other brands use fixed ports).
    var port: Int?
}

// MARK: - Remote vocabulary

/// Every button the remote UI can press. Each driver maps these onto its own
/// protocol's key codes; unsupported keys are simply ignored by a driver.
enum RemoteKey {
    case power
    case up, down, left, right, ok
    case back, home, menu
    case playPause, rewind, fastForward
    case volumeUp, volumeDown, mute
}

/// A launchable app shown in the app-shortcut row. `id` is whatever the brand
/// protocol wants (package name, Tizen app id, Roku channel id, deep link…).
struct TVApp: Identifiable, Hashable {
    let name: String
    let id: String
}

// MARK: - Session state

/// What kind of user interaction pairing needs, so the UI can render the
/// right prompt.
enum PairingKind: Equatable {
    /// TV shows a code the user types into our popover (Fire TV: 4 digits,
    /// Android TV: 6 hex characters).
    case pin(digits: Int)
    /// TV shows an Allow/Deny dialog the user accepts with the TV's own
    /// remote (Samsung, LG). We just wait.
    case onScreenAllow
}

enum SessionState: Equatable {
    case idle
    case connecting
    case awaitingPairing(PairingKind)
    case connected
    case failed(String)
}

// MARK: - Driver protocol

/// The contract each brand driver implements. Drivers are plain classes that
/// do their networking on background queues and report back through the two
/// callbacks; RemoteSession hops them onto the main thread for SwiftUI.
protocol TVDriver: AnyObject {
    /// Fired on every state transition (connecting → pairing → connected…).
    var onStateChange: ((SessionState) -> Void)? { get set }
    /// Fired when the TV hands us a credential worth persisting (Samsung/LG
    /// token or client-key, Fire TV token, Android TV "paired" marker).
    var onTokenIssued: ((String) -> Void)? { get set }

    /// Open the control channel. `token` is the previously persisted
    /// credential, or nil on first contact (which starts pairing).
    func connect(token: String?)
    /// Deliver the PIN the user typed (only meaningful for .pin pairing).
    func submitPairingCode(_ code: String)
    func disconnect()

    func send(_ key: RemoteKey)
    func sendText(_ text: String)
    func launchApp(_ appID: String)
    /// Brand's app shortcuts for the UI row (static list, or live-queried
    /// in the Roku driver's case).
    var apps: [TVApp] { get }
}

// MARK: - Session (what the UI observes)

/// Binds one DiscoveredTV to its driver and republishes driver callbacks as
/// @Published state. Also owns credential persistence: drivers never touch
/// UserDefaults themselves.
final class RemoteSession: ObservableObject {
    let device: DiscoveredTV
    @Published private(set) var state: SessionState = .idle

    private let driver: TVDriver
    private var tokenKey: String { "token.\(device.id)" }

    init(device: DiscoveredTV) {
        self.device = device
        self.driver = RemoteSession.makeDriver(for: device)

        // Driver callbacks arrive on arbitrary queues; SwiftUI requires main.
        driver.onStateChange = { [weak self] newState in
            DispatchQueue.main.async { self?.state = newState }
        }
        driver.onTokenIssued = { [weak self] token in
            guard let self else { return }
            UserDefaults.standard.set(token, forKey: self.tokenKey)
        }
    }

    /// The one place brands are wired to their driver implementations.
    private static func makeDriver(for device: DiscoveredTV) -> TVDriver {
        switch device.brand {
        case .fireTV:    return FireTVDriver(device: device)
        case .androidTV: return AndroidTVDriver(device: device)
        case .samsung:   return SamsungDriver(device: device)
        case .lg:        return LGDriver(device: device)
        case .roku:      return RokuDriver(device: device)
        }
    }

    func connect() {
        state = .connecting
        driver.connect(token: UserDefaults.standard.string(forKey: tokenKey))
    }

    /// Wipe the stored credential and pair from scratch (Settings → Re-pair).
    func forgetAndRepair() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        driver.disconnect()
        connect()
    }

    func submitPairingCode(_ code: String) { driver.submitPairingCode(code) }
    func disconnect() { driver.disconnect() }
    func send(_ key: RemoteKey) { driver.send(key) }
    func sendText(_ text: String) { driver.sendText(text) }
    func launchApp(_ appID: String) { driver.launchApp(appID) }
    var apps: [TVApp] { driver.apps }
}

// MARK: - Shared power-on plumbing (used by Samsung + LG drivers)

/// Samsung and LG TVs power ON via a Wake-on-LAN magic packet (their control
/// server is down while off, so no protocol message can reach them). This is
/// the classic 6×0xFF + 16×MAC UDP broadcast, sent over a raw BSD socket
/// because Network.framework has no broadcast support.
func sendWakeOnLAN(macAddress: String) {
    // "AA:BB:CC:DD:EE:FF" (or dashes) → [0xAA, 0xBB, ...]
    let bytes = macAddress
        .split(whereSeparator: { $0 == ":" || $0 == "-" })
        .compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 6 else { return }

    var packet = Data(repeating: 0xFF, count: 6)
    for _ in 0..<16 { packet.append(contentsOf: bytes) }

    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return }
    defer { close(sock) }

    var enable: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(9).bigEndian          // discard port, WoL convention
    addr.sin_addr.s_addr = INADDR_BROADCAST.bigEndian

    packet.withUnsafeBytes { raw in
        withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = sendto(sock, raw.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Read a device's MAC address out of the system ARP cache. After we have
/// talked to a TV over TCP its MAC is guaranteed to be cached, so drivers
/// call this right after connecting and persist the result for later
/// Wake-on-LAN power-on. Returns nil if the IP is not in the cache.
func macAddressFromARP(ip: String) -> String? {
    // `arp -n <ip>` prints: "? (192.168.1.5) at aa:bb:cc:dd:ee:ff on en0 ..."
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    process.arguments = ["-n", ip]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()   // silence "no entry" noise
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let atRange = output.range(of: " at ") else { return nil }
    let mac = output[atRange.upperBound...].prefix(while: { $0 != " " })
    // arp prints "(incomplete)" when it has no entry; a real MAC has colons.
    return mac.contains(":") ? String(mac) : nil
}
