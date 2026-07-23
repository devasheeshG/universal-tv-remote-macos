//
//  Samsung.swift
//  Universal TV Remote for Mac
//
//  Driver for Samsung Tizen Smart TVs (2016+) via the WebSocket remote API.
//
//    Channel    wss://<ip>:8002/api/v2/channels/samsung.remote.control
//                   ?name=<base64 app name>&token=<token>
//               (self-signed cert → trust override below)
//    Pairing    First connect pops an Allow/Deny dialog on the TV. Accepting
//               it delivers an "ms.channel.connect" event whose payload may
//               carry data.token — persist it and every later connect is
//               silent.
//    Keys       {"method":"ms.remote.control","params":{"Cmd":"Click",
//                "DataOfCmd":"KEY_VOLUP","Option":"false",
//                "TypeOfRemote":"SendRemoteKey"}}
//    Text       Cmd = base64(text), DataOfCmd:"base64",
//               TypeOfRemote:"SendInputString"  (needs a focused text field
//               on the TV), then SendInputEnd to commit.
//    Apps       POST http://<ip>:8001/api/v2/applications/<appId>  (the
//               unauthenticated legacy REST port — simpler than the ws event)
//    Power      OFF = KEY_POWER. ON = Wake-on-LAN (the API is down when the
//               TV is off), so we cache the MAC from the ARP table while
//               connected.
//
//  Reference: github.com/xchwarze/samsung-tv-ws-api (Home Assistant's
//  backend) and ollo69/ha-samsungtv-smart for the text-input frames.
//  NOTE (untested driver): the developer has no Samsung hardware — written
//  faithfully from those references but unverified on a real TV.
//

import Foundation

final class SamsungDriver: NSObject, TVDriver, URLSessionWebSocketDelegate, URLSessionDelegate {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?

    private let device: DiscoveredTV
    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var hadStoredToken = false
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var macKey: String { "mac.\(device.id)" }

    init(device: DiscoveredTV) {
        self.device = device
    }

    // MARK: TVDriver

    func connect(token: String?) {
        hadStoredToken = (token != nil)
        // The `name` parameter is what the TV's Allow/Deny dialog displays.
        let name = Data("Universal TV Remote".utf8).base64EncodedString()
        var urlString = "wss://\(device.host):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if let token { urlString += "&token=\(token)" }

        socket = session.webSocketTask(with: URL(string: urlString)!)
        socket?.resume()
        receiveLoop()

        // Without a token the TV is now showing its Allow dialog; tell the
        // UI to say "accept on your TV". With a token, we stay "connecting"
        // until ms.channel.connect confirms.
        if token == nil {
            onStateChange?(.awaitingPairing(.onScreenAllow))
        }

        // WebSockets to TVs silently die without traffic; a ping every 30 s
        // keeps the channel (and the TV's interest) alive.
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                self?.socket?.sendPing { _ in }
            }
        }
    }

    func submitPairingCode(_ code: String) { /* Samsung pairs on the TV, not with a PIN */ }

    func disconnect() {
        pingTimer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        onStateChange?(.idle)
    }

    func send(_ key: RemoteKey) {
        // Power ON can't travel over a socket that doesn't exist — if we are
        // not connected, throw a WoL packet at the cached MAC instead.
        if key == .power, socket == nil || socket?.state != .running {
            if let mac = UserDefaults.standard.string(forKey: macKey) {
                sendWakeOnLAN(macAddress: mac)
            }
            return
        }

        let code: String
        switch key {
        case .power:       code = "KEY_POWER"
        case .up:          code = "KEY_UP"
        case .down:        code = "KEY_DOWN"
        case .left:        code = "KEY_LEFT"
        case .right:       code = "KEY_RIGHT"
        case .ok:          code = "KEY_ENTER"
        case .back:        code = "KEY_RETURN"
        case .home:        code = "KEY_HOME"
        case .menu:        code = "KEY_MENU"
        // Tizen has no play/pause toggle key; KEY_PLAY_BACK behaves as the
        // toggle on recent models (falling back to plain play elsewhere).
        case .playPause:   code = "KEY_PLAY_BACK"
        case .rewind:      code = "KEY_REWIND"
        case .fastForward: code = "KEY_FF"
        case .volumeUp:    code = "KEY_VOLUP"
        case .volumeDown:  code = "KEY_VOLDOWN"
        case .mute:        code = "KEY_MUTE"
        }
        sendJSON([
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Click",
                "DataOfCmd": code,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey",
            ],
        ])
    }

    func sendText(_ text: String) {
        // Types into whatever text field the TV currently has focused.
        sendJSON([
            "method": "ms.remote.control",
            "params": [
                "Cmd": Data(text.utf8).base64EncodedString(),
                "DataOfCmd": "base64",
                "TypeOfRemote": "SendInputString",
            ],
        ])
        // Commit the string (what the on-screen keyboard's Done does).
        sendJSON([
            "method": "ms.remote.control",
            "params": ["TypeOfRemote": "SendInputEnd"],
        ])
    }

    func launchApp(_ appID: String) {
        // The :8001 REST port launches apps without any auth — far simpler
        // than the ws ed.apps.launch event and works on the same models.
        var request = URLRequest(url: URL(string: "http://\(device.host):8001/api/v2/applications/\(appID)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }

    /// Tizen app ids, collected from samsung-tv-ws-api issue threads — these
    /// are stable store ids, but Samsung has been known to change them.
    var apps: [TVApp] {
        [
            TVApp(name: "Netflix", id: "11101200001"),
            TVApp(name: "YouTube", id: "111299001912"),
            TVApp(name: "Prime Video", id: "3201512006785"),
            TVApp(name: "Disney+", id: "3201901017640"),
            TVApp(name: "Spotify", id: "3201606009684"),
        ]
    }

    // MARK: internals

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(string)) { [weak self] error in
            if error != nil { self?.onStateChange?(.failed("Samsung TV connection lost")) }
        }
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // A refused/dropped socket with no stored token usually means
                // the user hit Deny on the TV.
                self.onStateChange?(self.hadStoredToken
                    ? .failed("Samsung TV connection lost")
                    : .failed("Pairing was denied on the TV"))
            case .success(let message):
                if case .string(let text) = message,
                   let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   json["event"] as? String == "ms.channel.connect" {
                    // Officially connected. A fresh token rides along on the
                    // very first (post-Allow) connect.
                    if let data = json["data"] as? [String: Any],
                       let newToken = data["token"] as? String ?? (data["token"] as? Int).map(String.init) {
                        self.onTokenIssued?(newToken)
                    }
                    self.onStateChange?(.connected)
                    self.cacheMACForWakeOnLAN()
                }
                self.receiveLoop()   // keep listening
            }
        }
    }

    /// Remember the TV's MAC while we can see it, so the power button can
    /// Wake-on-LAN it later when the TV is off and unreachable.
    private func cacheMACForWakeOnLAN() {
        if let mac = macAddressFromARP(ip: device.host) {
            UserDefaults.standard.set(mac, forKey: macKey)
        }
    }

    // MARK: TLS — trust the TV's self-signed certificate (its host only)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == device.host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
