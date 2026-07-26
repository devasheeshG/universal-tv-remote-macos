//
//  Roku.swift
//  Universal TV Remote for Mac
//
//  Driver for Roku sticks/boxes and Roku TVs via ECP (External Control
//  Protocol): plain HTTP on port 8060, no pairing at all.
//
//    Keys      POST /keypress/<Key>
//    Text      POST /keypress/Lit_<percent-encoded character>   (one per char)
//    Apps      GET  /query/apps      → XML list, live-queried
//              POST /launch/<appID>
//    Power     POST /keypress/PowerOn | PowerOff  (Roku TVs; we read
//              /query/device-info power-mode to pick the right one)
//
//  Reference: developer.roku.com ECP docs; Home Assistant `roku` integration.
//  NOTE (untested driver): written from the official ECP documentation — the
//  developer has no Roku hardware, so this ships untested on real devices.
//  Roku OS 14.1+ gates ECP behind Settings → System → Advanced system
//  settings → Control by mobile apps → Enabled; connect() surfaces that hint.
//

import Foundation

final class RokuDriver: TVDriver {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?
    var onAppsChanged: (() -> Void)?

    private let device: DiscoveredTV
    private let base: URL
    private let session = URLSession(configuration: .ephemeral)
    /// Filled from /query/apps on connect so the shortcut row shows what is
    /// actually installed; starts with well-known channel ids as a fallback.
    private var liveApps: [TVApp] = [
        TVApp(name: "Netflix", id: "12", domain: "netflix.com"),
        TVApp(name: "YouTube", id: "837", domain: "youtube.com"),
        TVApp(name: "Prime Video", id: "13", domain: "primevideo.com"),
        TVApp(name: "Disney+", id: "291097", domain: "disneyplus.com"),
    ]

    init(device: DiscoveredTV) {
        self.device = device
        // Port comes from the SSDP LOCATION header during discovery; 8060 is
        // the documented default for every Roku.
        self.base = URL(string: "http://\(device.host):\(device.port ?? 8060)")!
    }

    // MARK: TVDriver

    func connect(token: String?) {
        // No pairing on Roku — "connecting" is just proving the box answers.
        var request = URLRequest(url: base.appendingPathComponent("query/device-info"))
        request.timeoutInterval = 4
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                self.onStateChange?(.failed("Roku not responding — check that "
                    + "Settings → Advanced → Control by mobile apps is Enabled"))
                return
            }
            self.onStateChange?(.connected)
            self.refreshInstalledApps()
        }.resume()
    }

    func submitPairingCode(_ code: String) { /* Roku never pairs */ }

    func disconnect() { onStateChange?(.idle) }

    func send(_ key: RemoteKey) {
        // Power is the only stateful key: ECP has separate PowerOn/PowerOff,
        // so peek at power-mode to decide which the user means.
        if key == .power {
            let request = URLRequest(url: base.appendingPathComponent("query/device-info"), timeoutInterval: 4)
            session.dataTask(with: request) { [weak self] data, _, _ in
                let xml = String(data: data ?? Data(), encoding: .utf8) ?? ""
                // <power-mode>PowerOn</power-mode> means awake; anything else
                // (DisplayOff, Headless, or no answer) means asleep.
                let awake = xml.contains("<power-mode>PowerOn</power-mode>")
                self?.keypress(awake ? "PowerOff" : "PowerOn")
            }.resume()
            return
        }

        let name: String
        switch key {
        case .up:          name = "Up"
        case .down:        name = "Down"
        case .left:        name = "Left"
        case .right:       name = "Right"
        case .ok:          name = "Select"
        case .back:        name = "Back"
        case .home:        name = "Home"
        case .menu:        name = "Info"       // the Roku "*" options key
        case .playPause:   name = "Play"       // Roku's Play key is a toggle
        // ECP has no skip key; Rev/Fwd single-press is the closest match.
        case .rewind, .skipBackward:     name = "Rev"
        case .fastForward, .skipForward: name = "Fwd"
        case .volumeUp:    name = "VolumeUp"   // volume keys work on Roku TVs
        case .volumeDown:  name = "VolumeDown" // (ignored by sticks/boxes)
        case .mute:        name = "VolumeMute"
        case .power:       return              // handled above
        }
        keypress(name)
    }

    func sendText(_ text: String) {
        // ECP types one character per request: /keypress/Lit_<char>.
        // Requests are fired in order; ECP handles bursts fine.
        for char in text {
            let encoded = String(char).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            keypress("Lit_\(encoded)")
        }
    }

    func launchApp(_ appID: String) {
        post(base.appendingPathComponent("launch/\(appID)"))
    }

    var apps: [TVApp] { liveApps }

    // MARK: internals

    private func keypress(_ name: String) {
        post(base.appendingPathComponent("keypress/\(name)"))
    }

    private func post(_ url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        session.dataTask(with: request).resume()
    }

    /// GET /query/apps returns XML like:
    ///   <app id="12" type="appl" version="...">Netflix</app>
    /// A full XML parser is overkill for that shape — a regex keeps this
    /// driver dependency-free.
    private func refreshInstalledApps() {
        let request = URLRequest(url: base.appendingPathComponent("query/apps"), timeoutInterval: 5)
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let xml = String(data: data ?? Data(), encoding: .utf8) else { return }
            let pattern = #/<app id="([^"]+)"[^>]*>([^<]+)</app>/#
            // Everything the box reports is by definition installed; the box
            // also serves each channel's icon over ECP.
            let found = xml.matches(of: pattern).map {
                TVApp(name: String($0.2), id: String($0.1),
                      iconArt: self.base.appendingPathComponent("query/icon/\($0.1)").absoluteString)
            }
            guard !found.isEmpty else { return }
            self.liveApps = found.enumerated()
                .sorted { ($0.element.favoriteRank, $0.offset) < ($1.element.favoriteRank, $1.offset) }
                .map(\.element)
            self.onAppsChanged?()
        }.resume()
    }
}
