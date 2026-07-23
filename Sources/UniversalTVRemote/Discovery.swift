//
//  Discovery.swift
//  Universal TV Remote for Mac
//
//  Finds TVs on the local network and keeps a remembered list so known TVs
//  show up instantly on launch. Two mechanisms cover all five brands:
//
//    Bonjour (mDNS), continuous browsers via NWBrowser:
//      _androidtvremote2._tcp   → Android TV / Google TV
//      _amzn-wplay._tcp         → Fire TV
//
//    SSDP (UDP multicast M-SEARCH), burst on demand via a BSD socket
//    (Network.framework cannot do the send-multicast/receive-unicast dance
//    SSDP needs):
//      roku:ecp                                    → Roku
//      urn:lge-com:service:webos-second-screen:1   → LG webOS
//      urn:samsung.com:device:RemoteControlReceiver:1 → Samsung Tizen
//
//  First use triggers macOS's one-time "allow local network access" prompt;
//  nothing is discoverable until the user allows it.
//

import Foundation
import Network
import Darwin

final class DiscoveryEngine: NSObject, ObservableObject {
    /// Everything we know about: remembered devices merged with live finds.
    @Published private(set) var devices: [DiscoveredTV] = []
    @Published private(set) var isScanning = false

    private var browsers: [NWBrowser] = []
    private let ssdpQueue = DispatchQueue(label: "ssdp.scan", qos: .utility)
    private static let rememberedKey = "rememberedDevices"

    // MARK: lifecycle

    /// Called once at app start: load remembered TVs and keep the Bonjour
    /// browsers running for the whole app lifetime (they are cheap and make
    /// Fire/Android TVs appear the moment they join the network).
    func start() {
        if let data = UserDefaults.standard.data(forKey: DiscoveryEngine.rememberedKey),
           let remembered = try? JSONDecoder().decode([DiscoveredTV].self, from: data) {
            devices = remembered
        }
        startBonjourBrowser(serviceType: "_androidtvremote2._tcp", brand: .androidTV)
        startBonjourBrowser(serviceType: "_amzn-wplay._tcp", brand: .fireTV)
        scan()
    }

    /// SSDP burst (Roku / LG / Samsung). Called on popover open and refresh.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        ssdpQueue.async { [weak self] in
            self?.runSSDPScan()
            DispatchQueue.main.async { self?.isScanning = false }
        }
    }

    /// Drop a TV from the remembered list (Settings → Forget).
    func forget(_ device: DiscoveredTV) {
        devices.removeAll { $0.id == device.id }
        persist()
    }

    /// Manually add a TV that discovery didn't find (different subnet, mDNS
    /// blocked by the router, etc.). The user supplies brand + IP; we still
    /// try to upgrade the placeholder name from the device itself.
    func addManual(brand: TVBrand, host: String) -> DiscoveredTV {
        let device = DiscoveredTV(id: "\(brand.rawValue):\(host)", brand: brand,
                                  name: "\(brand.displayName) (\(host))", host: host, port: nil)
        upsert(device)
        fetchFriendlyName(for: device)
        return device
    }

    // MARK: Bonjour (Fire TV + Android TV)

    private func startBonjourBrowser(serviceType: String, brand: TVBrand) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                // TXT records sometimes carry a friendlier name than the mDNS
                // instance name (Fire TV instances look like "amzn.dmgr:<hash>…").
                var friendly = name
                if case .bonjour(let txt) = result.metadata,
                   let fn = txt.dictionary["fn"] ?? txt.dictionary["n"], !fn.isEmpty {
                    friendly = fn
                }
                if brand == .fireTV, friendly.hasPrefix("amzn.dmgr") {
                    friendly = "Fire TV"
                }
                self?.resolveAndUpsert(endpoint: result.endpoint, serviceName: name,
                                       displayName: friendly, brand: brand)
            }
        }
        // Surfacing browser health in the unified log makes "no TVs found"
        // diagnosable: a `waiting(DNSServiceError…)` state here means macOS
        // denied Local Network access.
        browser.stateUpdateHandler = { state in
            NSLog("[discovery] \(serviceType) browser: \(String(describing: state))")
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    /// Bonjour gives us a service endpoint, not an IP — and the TV drivers
    /// need an IP to hit their fixed control ports. Briefly open a TCP
    /// connection to the advertised service and read the remote address off
    /// the connected path.
    private func resolveAndUpsert(endpoint: NWEndpoint, serviceName: String,
                                  displayName: String, brand: TVBrand) {
        // Force IPv4: left alone, the resolver happily picks an IPv6
        // link-local address (fe80::…%en0) whose scope suffix the TV drivers'
        // URL-based transports cannot carry around. Every TV also has an A
        // record, so v4 always exists.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else {
                if case .failed = state { connection.cancel() }
                return
            }
            if let path = connection.currentPath,
               case .hostPort(let host, _) = path.remoteEndpoint {
                // Host renders like "192.168.1.7%en0" — strip the interface.
                let ip = "\(host)".components(separatedBy: "%")[0]
                let device = DiscoveredTV(
                    // Service name is stable across IP changes → good identity.
                    id: "\(brand.rawValue):\(serviceName)",
                    brand: brand, name: displayName, host: ip, port: nil)
                NSLog("[discovery] resolved \(displayName) (\(brand.rawValue)) → \(ip)")
                self?.upsert(device)
            }
            connection.cancel()
        }
        connection.start(queue: .main)
    }

    // MARK: SSDP (Roku + LG + Samsung)

    private func runSSDPScan() {
        let searchTargets = [
            "roku:ecp",
            "urn:lge-com:service:webos-second-screen:1",
            "urn:samsung.com:device:RemoteControlReceiver:1",
            // Fire TV: modern Fire OS builds no longer advertise the
            // _amzn-wplay Bonjour service (verified on a 2025 Fire TV Stick),
            // but they do answer DIAL searches while awake. Chromecasts and
            // some smart TVs answer this too, so DIAL replies are confirmed
            // as Amazon via their description XML before being added.
            "urn:dial-multiscreen-org:service:dial:1",
        ]

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        // Collect replies for ~2.5 s total via short recv timeouts.
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var multicast = sockaddr_in()
        multicast.sin_family = sa_family_t(AF_INET)
        multicast.sin_port = UInt16(1900).bigEndian
        multicast.sin_addr.s_addr = inet_addr("239.255.255.250")

        for target in searchTargets {
            let message = "M-SEARCH * HTTP/1.1\r\n"
                + "HOST: 239.255.255.250:1900\r\n"
                + "MAN: \"ssdp:discover\"\r\n"
                + "MX: 2\r\n"
                + "ST: \(target)\r\n\r\n"
            withUnsafePointer(to: &multicast) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = message.withCString {
                        sendto(sock, $0, strlen($0), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // Read replies until ~2.5 s of quiet has passed. Devices reply to
        // every M-SEARCH they match, so duplicates are normal — upsert by id.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sender = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var quietRounds = 0
        while quietRounds < 5 {
            let received = withUnsafeMutablePointer(to: &sender) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buffer, buffer.count, 0, sa, &senderLen)
                }
            }
            guard received > 0 else { quietRounds += 1; continue }
            let reply = String(bytes: buffer[0..<received], encoding: .utf8) ?? ""
            var ipBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &ipBytes, socklen_t(INET_ADDRSTRLEN))
            handleSSDPReply(reply, from: String(cString: ipBytes))
        }
    }

    private func handleSSDPReply(_ reply: String, from ip: String) {
        // Case-insensitive header lookup ("ST:" vs "St:" varies by device).
        func header(_ name: String) -> String? {
            for line in reply.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix(name.lowercased() + ":") {
                    return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        guard let st = header("ST") else { return }
        NSLog("[discovery] SSDP reply from \(ip): \(st)")

        // DIAL replies need the extra Amazon-or-not check; everything else
        // maps straight from the search target.
        if st.contains("dial-multiscreen-org") {
            if let location = header("LOCATION") { confirmFireTV(location: location, ip: ip) }
            return
        }

        let brand: TVBrand
        if st.contains("roku:ecp") { brand = .roku }
        else if st.contains("webos-second-screen") { brand = .lg }
        else if st.contains("RemoteControlReceiver") { brand = .samsung }
        else { return }

        // USN survives IP changes; fall back to the IP if a device omits it.
        let usn = header("USN")?.components(separatedBy: "::")[0] ?? ip
        // Roku's ECP port officially is 8060, but trust the LOCATION header
        // (e.g. "http://192.168.1.9:8060/") when present.
        var port: Int? = nil
        if brand == .roku, let location = header("LOCATION"),
           let locationPort = URLComponents(string: location)?.port {
            port = locationPort
        }

        let device = DiscoveredTV(id: "\(brand.rawValue):\(usn)", brand: brand,
                                  name: brand.displayName, host: ip, port: port)
        DispatchQueue.main.async { [weak self] in
            self?.upsert(device)
            self?.fetchFriendlyName(for: device)
        }
    }

    /// A DIAL responder is only a Fire TV if its device-description XML says
    /// manufacturer Amazon (Chromecasts/smart TVs answer DIAL too — those are
    /// ignored here because Android TVs arrive via their own mDNS service).
    private func confirmFireTV(location: String, ip: String) {
        guard let url = URL(string: location) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 4)) { [weak self] data, _, _ in
            guard let xml = String(data: data ?? Data(), encoding: .utf8),
                  xml.contains("<manufacturer>Amazon</manufacturer>") else { return }
            var name = "Fire TV"
            if let match = xml.firstMatch(of: #/<friendlyName>([^<]+)</#) {
                name = String(match.1)
            }
            // The UDN uuid is stable across reboots and IP changes.
            let uuid = xml.firstMatch(of: #/<UDN>uuid:([^<]+)</#).map { String($0.1) } ?? ip
            let device = DiscoveredTV(id: "fireTV:\(uuid)", brand: .fireTV,
                                      name: name, host: ip, port: nil)
            NSLog("[discovery] confirmed Fire TV \"\(name)\" at \(ip)")
            DispatchQueue.main.async { self?.upsert(device) }
        }.resume()
    }

    /// SSDP replies don't include a human name — each brand exposes one over
    /// a small unauthenticated HTTP endpoint, fetched best-effort.
    private func fetchFriendlyName(for device: DiscoveredTV) {
        let url: URL
        switch device.brand {
        case .roku:
            url = URL(string: "http://\(device.host):\(device.port ?? 8060)/query/device-info")!
        case .samsung:
            url = URL(string: "http://\(device.host):8001/api/v2/")!
        case .lg:
            // The webOS SSDP description document. 3000 hosts it unencrypted.
            url = URL(string: "http://\(device.host):3000/")!
        default:
            return
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 4)) { [weak self] data, _, _ in
            guard let data else { return }
            var name: String?
            if device.brand == .samsung {
                // JSON: {"device": {"name": "Living Room TV", ...}, ...}
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                name = (json?["device"] as? [String: Any])?["name"] as? String
            } else {
                // XML with <friendlyName> (LG) / <friendly-device-name> (Roku).
                let xml = String(data: data, encoding: .utf8) ?? ""
                if let match = xml.firstMatch(of: #/<friendlyName>([^<]+)</#) {
                    name = String(match.1)
                } else if let match = xml.firstMatch(of: #/<friendly-device-name>([^<]+)</#) {
                    name = String(match.1)
                }
            }
            guard let name, !name.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let index = self.devices.firstIndex(where: { $0.id == device.id }) else { return }
                self.devices[index].name = name
                self.persist()
            }
        }.resume()
    }

    // MARK: bookkeeping

    /// Insert or refresh one device, keeping any better name we already had,
    /// and persist so the list survives restarts.
    private func upsert(_ device: DiscoveredTV) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].host = device.host
            devices[index].port = device.port ?? devices[index].port
            // Only overwrite the name when the new one is more specific than
            // a bare brand placeholder.
            if device.name != device.brand.displayName {
                devices[index].name = device.name
            }
        } else {
            devices.append(device)
            devices.sort { $0.name < $1.name }
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: DiscoveryEngine.rememberedKey)
        }
    }
}
