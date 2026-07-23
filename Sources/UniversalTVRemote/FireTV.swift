//
//  FireTV.swift
//  Universal TV Remote for Mac
//
//  Driver for Amazon Fire TV via the (private, reverse-engineered) REST API
//  the official mobile remote apps use. No ADB, no developer options — the
//  user just types a PIN the TV displays.
//
//    Base       https://<ip>:8080  (self-signed cert → trust override below)
//    Headers    X-Api-Key: 0987654321       (hardcoded, same for everyone)
//               X-Client-Token: <token>     (after pairing)
//    Pairing    POST /v1/FireTV/pin/display {"friendlyName": ...} → PIN on TV
//               POST /v1/FireTV/pin/verify  {"pin": "1234"}
//                    → 200 {"description": "<persistent token>"}
//    Keys       POST /v1/FireTV?action=dpad_up|select|back|home|menu|...
//                    body {"keyActionType": "keyDownUp"}
//    Media      POST /v1/media?action=play|pause|scan  (scan takes direction)
//    Text       POST /v1/FireTV/text  {"text": "..."}
//    Apps       POST /v1/FireTV/app/<package>
//    Wake       POST http://<ip>:8009/apps/FireTVRemote   (plain-HTTP DIAL
//               wake — the 8080 service is down while the TV sleeps)
//
//  Reference: github.com/mase1981/uc-intg-firetv (endpoints verified against
//  its client.py). Older Fire OS builds answer some commands with HTTP 500
//  yet still execute them, so 500 is treated as success like uc-intg does.
//

import Foundation

final class FireTVDriver: NSObject, TVDriver, URLSessionDelegate {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?
    var onAppsChanged: (() -> Void)?

    /// The TV's real installed-app list, fetched after connecting. While nil
    /// the static catalog below stands in.
    private var liveApps: [TVApp]?

    private let device: DiscoveredTV
    private let base: URL
    private var token: String?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        // delegate: self → accepts the TV's self-signed certificate.
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(device: DiscoveredTV) {
        self.device = device
        self.base = URL(string: "https://\(device.host):8080")!
    }

    // MARK: TVDriver

    func connect(token: String?) {
        self.token = token
        if token != nil {
            // Already paired: a reachability probe is all "connect" means for
            // a stateless REST protocol. Any HTTP answer (even 404) proves
            // the service is up; only a transport error means unreachable.
            var request = URLRequest(url: base)
            request.allHTTPHeaderFields = headers(includeToken: false)
            session.dataTask(with: request) { [weak self] _, response, error in
                guard let self else { return }
                if response != nil {
                    self.onStateChange?(.connected)
                    self.fetchInstalledApps()
                } else {
                    // Service down — probably asleep. Fire the DIAL wake and
                    // re-probe once; Fire TVs need a few seconds to boot it.
                    self.wakeUp()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                        var retry = URLRequest(url: self.base)
                        retry.allHTTPHeaderFields = self.headers(includeToken: false)
                        self.session.dataTask(with: retry) { _, response2, _ in
                            if response2 != nil {
                                self.onStateChange?(.connected)
                                self.fetchInstalledApps()
                            } else {
                                self.onStateChange?(.failed("Fire TV unreachable at \(self.device.host)"))
                            }
                        }.resume()
                    }
                    _ = error   // transport error details aren't user-useful here
                }
            }.resume()
            return
        }

        // First contact: ask the TV to display a pairing PIN.
        var request = URLRequest(url: base.appendingPathComponent("v1/FireTV/pin/display"))
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers(includeToken: false)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["friendlyName": "Universal TV Remote for Mac"])
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                self.onStateChange?(.awaitingPairing(.pin(digits: 4)))
            } else {
                self.onStateChange?(.failed("Fire TV didn't offer a PIN — its remote "
                    + "API may be unavailable on this model/firmware"))
            }
        }.resume()
    }

    func submitPairingCode(_ code: String) {
        var request = URLRequest(url: base.appendingPathComponent("v1/FireTV/pin/verify"))
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers(includeToken: false)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["pin": code])
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            // The persistent token comes back in — of all places — the
            // "description" field of the JSON body.
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newToken = json["description"] as? String, !newToken.isEmpty {
                self.token = newToken
                self.onTokenIssued?(newToken)
                self.onStateChange?(.connected)
                self.fetchInstalledApps()
            } else {
                self.onStateChange?(.failed("Wrong PIN — pick the TV again to retry"))
            }
        }.resume()
    }

    func disconnect() { onStateChange?(.idle) }

    func send(_ key: RemoteKey) {
        switch key {
        // Media transport lives on its own endpoint with its own actions.
        case .playPause:
            post(path: "v1/media", query: "action=play", body: nil)
        // A single scan press behaves as the ~10 s skip inside Fire TV players
        // (same as one tap of ⏪/⏩ on the physical remote), so skip and
        // rewind/fast-forward share the endpoint.
        case .rewind, .skipBackward:
            post(path: "v1/media", query: "action=scan",
                 body: ["direction": "back", "keyAction": ["keyActionType": "keyDownUp"]])
        case .fastForward, .skipForward:
            post(path: "v1/media", query: "action=scan",
                 body: ["direction": "forward", "keyAction": ["keyActionType": "keyDownUp"]])

        // Power: "power" toggles when the TV is awake; when it's fully asleep
        // the 8080 service is gone, so also fire the DIAL wake — whichever
        // one the TV can hear wins.
        case .power:
            wakeUp()
            navigation("power")

        default:
            let action: String
            switch key {
            case .up:         action = "dpad_up"
            case .down:       action = "dpad_down"
            case .left:       action = "dpad_left"
            case .right:      action = "dpad_right"
            case .ok:         action = "select"
            case .back:       action = "back"
            case .home:       action = "home"
            case .menu:       action = "menu"
            case .volumeUp:   action = "volume_up"
            case .volumeDown: action = "volume_down"
            case .mute:       action = "mute"
            default:          return   // media/power handled above
            }
            navigation(action)
        }
    }

    func sendText(_ text: String) {
        post(path: "v1/FireTV/text", query: nil, body: ["text": text])
    }

    func launchApp(_ appID: String) {
        post(path: "v1/FireTV/app/\(appID)", query: nil, body: nil)
    }

    /// The TV's own installed-apps list once fetched; before that, a static
    /// catalog of common Fire OS packages (from the uc-intg-firetv database)
    /// so the row isn't empty during the first connect.
    var apps: [TVApp] {
        if let liveApps { return liveApps }
        return [
            TVApp(name: "Netflix", id: "com.netflix.ninja", domain: "netflix.com"),
            TVApp(name: "Prime Video", id: "com.amazon.avod", domain: "primevideo.com"),
            TVApp(name: "YouTube", id: "com.amazon.firetv.youtube", domain: "youtube.com"),
            TVApp(name: "Disney+", id: "com.disney.disneyplus", domain: "disneyplus.com"),
            TVApp(name: "Spotify", id: "com.spotify.tv.android", domain: "spotify.com"),
            TVApp(name: "Hulu", id: "com.hulu.plus", domain: "hulu.com"),
            TVApp(name: "Max", id: "com.wbd.stream", domain: "max.com"),
            TVApp(name: "Apple TV+", id: "com.apple.atve.amazon.appletv", domain: "tv.apple.com"),
            TVApp(name: "Plex", id: "com.plexapp.android", domain: "plex.tv"),
            TVApp(name: "VLC", id: "org.videolan.vlc", domain: "videolan.org"),
            TVApp(name: "Kodi", id: "org.xbmc.kodi", domain: "kodi.tv"),
            TVApp(name: "Silk Browser", id: "com.amazon.cloud9.silkbrowser", domain: "amazon.com"),
        ]
    }

    // MARK: internals

    /// GET /v1/FireTV/apps — an undocumented but very real endpoint that
    /// returns exactly what the shortcut row wants:
    ///   [{"appId": "com.netflix.ninja", "name": "Netflix",
    ///     "iconArtSmallUri": "https://m.media-amazon.com/…png",
    ///     "isInstalled": true}, …]
    /// (Discovered by probing; not in any reference implementation.)
    private func fetchInstalledApps() {
        var request = URLRequest(url: base.appendingPathComponent("v1/FireTV/apps"))
        request.allHTTPHeaderFields = headers()
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !list.isEmpty else { return }   // endpoint missing → keep static catalog
            let apps = list.compactMap { entry -> TVApp? in
                guard entry["isInstalled"] as? Bool == true,
                      let id = entry["appId"] as? String,
                      var name = entry["name"] as? String else { return nil }
                // Store listings are chatty ("Spotify - Music and Podcasts",
                // "VLC for Fire") — keep just the product name for the tile.
                name = name.components(separatedBy: " - ")[0]
                    .components(separatedBy: ":")[0]
                    .replacingOccurrences(of: " for Fire TV", with: "")
                    .replacingOccurrences(of: " for Fire", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return TVApp(name: name, id: id, iconArt: entry["iconArtSmallUri"] as? String)
            }
            guard !apps.isEmpty else { return }
            var installed = apps
            // The endpoint only lists store-installed apps; Prime Video is
            // part of Fire OS itself and never appears, yet always exists.
            if !installed.contains(where: { $0.id == "com.amazon.avod" }) {
                installed.append(TVApp(name: "Prime Video", id: "com.amazon.avod", domain: "primevideo.com"))
            }
            // Household staples first, everything else in the TV's order.
            self.liveApps = installed.enumerated()
                .sorted { ($0.element.favoriteRank, $0.offset) < ($1.element.favoriteRank, $1.offset) }
                .map(\.element)
            self.onAppsChanged?()
        }.resume()
    }

    private func headers(includeToken: Bool = true) -> [String: String] {
        var headers = [
            "X-Api-Key": "0987654321",
            "Content-Type": "application/json",
            // The API rejects unfamiliar user agents on some builds; mimic
            // the Android remote app like every other implementation does.
            "User-Agent": "okhttp/4.10.0",
        ]
        if includeToken, let token { headers["X-Client-Token"] = token }
        return headers
    }

    /// Navigation keys: POST /v1/FireTV?action=<action> with a keyDownUp body
    /// (a single full press — the API also supports keyDown/keyUp for holds).
    private func navigation(_ action: String) {
        post(path: "v1/FireTV", query: "action=\(action)", body: ["keyActionType": "keyDownUp"])
    }

    private func post(path: String, query: String?, body: [String: Any]?) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers()
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        session.dataTask(with: request) { [weak self] _, response, _ in
            // 401/403 = the pairing was revoked on the TV; tell the UI so the
            // user knows to re-pair rather than silently eating presses.
            if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
                self?.onStateChange?(.failed("Fire TV rejected our token — use "
                    + "Settings → Re-pair to authorize again"))
            }
        }.resume()
    }

    /// DIAL wake-up on port 8009 — plain HTTP, no auth. Wakes the TV (and its
    /// 8080 REST service) from sleep; harmless if it's already awake.
    private func wakeUp() {
        var request = URLRequest(url: URL(string: "http://\(device.host):8009/apps/FireTVRemote")!)
        request.httpMethod = "POST"
        request.setValue("okhttp/4.10.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request).resume()
    }

    // MARK: URLSessionDelegate — trust the TV's self-signed certificate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only bypass validation for this TV's own host, nothing else.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == device.host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
