//
// TVController.swift Universal TV Remote for Mac
//
//  The brand-agnostic core every other file plugs into:
//
//    DiscoveredTV   — one TV found on (or remembered from) the network
//    RemoteKey      — every button the UI can press, in one enum
//    TVDriver       — the small protocol each brand driver implements
// RemoteSession  — the ObservableObject the UI talks to; it owns a driver, persists pairing tokens, and republishes state changes
//
// Adding a sixth TV brand means: add a TVBrand case, write one driver file, and register it in RemoteSession.makeDriver(for:). Nothing else changes.
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

/// One TV on the network. Produced by Discovery, persisted to UserDefaults so known TVs appear instantly on the next launch (before a fresh scan lands).
struct DiscoveredTV: Identifiable, Codable, Hashable {
    /// Stable identity across launches: "<brand>:<unique part>", where the unique part is the Bonjour service name or SSDP USN when available, falling back to the IP address.
    let id: String
    let brand: TVBrand
    var name: String
    var host: String
    /// Control port when the protocol needs a specific one (Roku's ECP port comes from its SSDP LOCATION header; other brands use fixed ports).
    var port: Int?

    /// Fire TV appends a changing session and port to its Bonjour name. Only the device component identifies the physical TV.
    var discoveryIdentity: String {
        guard brand == .fireTV, id.hasPrefix("fireTV:amzn.dmgr:") else { return id }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[2].isEmpty else { return id }
        return parts.prefix(3).joined(separator: ":")
    }
}

// MARK: - Remote vocabulary

/// Every button the remote UI can press. Each driver maps these onto its own protocol's key codes; unsupported keys are simply ignored by a driver.
enum RemoteKey {
    case power
    case up, down, left, right, ok
    case back, home, menu
    case playPause, rewind, fastForward
    /// ~10 s jumps. Brands without a dedicated skip key map these onto their
    /// scan/seek keys, which modern streaming apps treat as a short skip.
    case skipForward, skipBackward
    case volumeUp, volumeDown, mute
}

/// A launchable app shown in the app-shortcut row. `id` is whatever the brand protocol wants (package name, Tizen app id, Roku channel id, deep link…). `domain` powers the icon: we fetch the service's favicon rather than bundling trademarked logos.
struct TVApp: Identifiable, Hashable {
    let name: String
    let id: String
    var domain: String? = nil
    /// Icon URL supplied by the TV itself (Fire TV's Amazon CDN art, Roku's
    /// /query/icon, LG's listApps icons). Beats any lookup when present.
    var iconArt: String? = nil

    /// Ordering weight so household staples lead the collapsed row; apps the TV lists that we don't recognize keep their device order after them.
    static let favorites = ["Netflix", "YouTube", "Prime Video", "Disney+", "Spotify", "Max", "Hulu"]
    var favoriteRank: Int { TVApp.favorites.firstIndex(where: { name.hasPrefix($0) }) ?? Int.max }

    /// Favicon lookup for names that arrive without a domain (Roku's live channel list) — best-effort, unknown apps fall back to a letter avatar.
    static let knownDomains: [String: String] = [
        "Netflix": "netflix.com", "YouTube": "youtube.com",
        "Prime Video": "primevideo.com", "Disney+": "disneyplus.com",
        "Spotify": "spotify.com", "Hulu": "hulu.com", "Max": "max.com",
        "HBO Max": "max.com", "Apple TV+": "tv.apple.com", "Plex": "plex.tv",
        "Twitch": "twitch.tv", "Crunchyroll": "crunchyroll.com",
    ]

    /// Best icon we can point AsyncImage at without a lookup: the TV's own art when it gave us any, else the service's favicon, else nil.
    var iconURL: URL? {
        if let iconArt { return URL(string: iconArt) }
        let resolved = domain ?? TVApp.knownDomains[name]
        guard let resolved else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(resolved)&sz=128")
    }
}

// MARK: - Session state

/// What kind of user interaction pairing needs, so the UI can render the right prompt.
enum PairingKind: Equatable {
    /// TV shows a code the user types into our popover (Fire TV: 4 digits, Android TV: 6 hex characters).
    case pin(digits: Int)
    /// TV shows an Allow/Deny dialog the user accepts with the TV's own remote (Samsung, LG). We just wait.
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

/// The contract each brand driver implements. Drivers are plain classes that do their networking on background queues and report back through the two callbacks; RemoteSession hops them onto the main thread for SwiftUI.
protocol TVDriver: AnyObject {
    /// Fired on every state transition (connecting → pairing → connected…).
    var onStateChange: ((SessionState) -> Void)? { get set }
    /// Fired when the TV hands us a credential worth persisting (Samsung/LG token or client-key, Fire TV token, Android TV "paired" marker).
    var onTokenIssued: ((String) -> Void)? { get set }
    /// Fired when the driver learns what's actually installed on the TV and `apps` changed as a result (Fire TV/Roku/LG query live lists).
    var onAppsChanged: (() -> Void)? { get set }

    /// Open the control channel. `token` is the previously persisted credential, or nil on first contact (which starts pairing).
    func connect(token: String?)
    /// Deliver the PIN the user typed (only meaningful for .pin pairing).
    func submitPairingCode(_ code: String)
    func disconnect()

    func send(_ key: RemoteKey)
    func sendText(_ text: String)
    func launchApp(_ appID: String)
    /// Brand's app shortcuts for the UI row (static list, or live-queried in the Roku driver's case).
    var apps: [TVApp] { get }
}

// MARK: - Session (what the UI observes)

/// Binds one DiscoveredTV to its driver and republishes driver callbacks as
/// @Published state. Also owns credential persistence: drivers never touch
/// UserDefaults themselves.
final class RemoteSession: ObservableObject {
    let device: DiscoveredTV
    @Published private(set) var state: SessionState = .idle
    /// What the shortcut row shows. Starts as the driver's static catalog and is replaced by the live installed-apps list once the driver has one.
    @Published private(set) var apps: [TVApp] = []

    private let driver: TVDriver
    private var reconnectTimer: Timer?
    private var isActive = false
    private let defaults: UserDefaults
    private var tokenKey: String { "token.\(device.id)" }

    init(device: DiscoveredTV, driver: TVDriver? = nil, defaults: UserDefaults = .standard) {
        self.device = device
        self.defaults = defaults
        self.driver = driver ?? RemoteSession.makeDriver(for: device)
        self.apps = self.driver.apps

        // Driver callbacks arrive on arbitrary queues; SwiftUI requires main.
        self.driver.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self, self.isActive, newState != .idle else { return }
                self.state = newState
                if case .connected = newState {
                    self.reconnectTimer?.invalidate()
                    self.reconnectTimer = nil
                }
                if case .failed = newState, self.device.brand != .fireTV, self.device.brand != .roku,
                   self.reconnectTimer == nil,
                   self.defaults.string(forKey: self.tokenKey) != nil {
                    self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                        self?.reconnectTimer = nil
                        self?.connect()
                    }
                }
            }
        }
        self.driver.onTokenIssued = { [weak self] token in
            guard let self else { return }
            self.defaults.set(token, forKey: self.tokenKey)
        }
        self.driver.onAppsChanged = { [weak self] in
            DispatchQueue.main.async { self?.apps = self?.driver.apps ?? [] }
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
        isActive = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        state = .connecting
        driver.connect(token: defaults.string(forKey: tokenKey))
    }

    /// Wipe the stored credential and pair from scratch (Settings → Re-pair).
    func forgetAndRepair() {
        defaults.removeObject(forKey: tokenKey)
        disconnect()
        connect()
    }

    func submitPairingCode(_ code: String) { driver.submitPairingCode(code) }
    func disconnect() {
        isActive = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        driver.disconnect()
        state = .idle
    }
    func send(_ key: RemoteKey) { driver.send(key) }
    func sendText(_ text: String) { driver.sendText(text) }
    func launchApp(_ appID: String) { driver.launchApp(appID) }
}

// MARK: - Shared power-on plumbing (used by Samsung + LG drivers)

/// Samsung and LG TVs power ON via a Wake-on-LAN magic packet (their control server is down while off, so no protocol message can reach them). This is the classic 6×0xFF + 16×MAC UDP broadcast, sent over a raw BSD socket because Network.framework has no broadcast support.
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

/// Read a device's MAC address out of the system ARP cache. After we have talked to a TV over TCP its MAC is guaranteed to be cached, so drivers call this right after connecting and persist the result for later Wake-on-LAN power-on. Returns nil if the IP is not in the cache.
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
