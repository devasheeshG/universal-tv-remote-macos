//
//  LG.swift
//  Universal TV Remote for Mac
//
//  Driver for LG webOS Smart TVs via SSAP (Secure Sockets Application
//  Protocol) — JSON over WebSocket, plus a second raw-ish socket for buttons.
//
//    Channel    wss://<ip>:3001  (2020+ firmware; self-signed cert)
//               older sets only speak ws://<ip>:3000 — we fall back.
//    Pairing    Send a "register" message carrying a permission manifest.
//               The TV shows an Accept dialog; accepting returns a
//               "client-key" we persist for silent re-registration.
//    Commands   {"type":"request","id":"...","uri":"ssap://audio/volumeUp"}
//    Buttons    D-pad & friends do NOT have SSAP URIs. Instead we request
//               ssap://com.webos.service.networkinput/getPointerInputSocket,
//               open the returned WebSocket, and send plain-text frames:
//                   type:button\nname:UP\n\n
//    Text       ssap://com.webos.service.ime/insertText
//    Apps       ssap://system.launcher/launch {"id":"netflix"}
//    Power      OFF = ssap://system/turnOff. ON = Wake-on-LAN (MAC cached
//               from the ARP table while connected).
//
//  Reference: home-assistant-libs/aiowebostv and lgtv2 (the manifest below
//  is the canonical one every client sends).
//  NOTE (untested driver): the developer has no LG hardware — written
//  faithfully from those references but unverified on a real TV.
//

import Foundation

final class LGDriver: NSObject, TVDriver, URLSessionDelegate {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?

    private let device: DiscoveredTV
    private var socket: URLSessionWebSocketTask?
    /// The secondary "pointer input" socket used for button presses.
    private var inputSocket: URLSessionWebSocketTask?
    private var requestCounter = 0
    private var triedLegacyPort = false
    private var storedKey: String?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var macKey: String { "mac.\(device.id)" }
    /// Local play/pause toggle: webOS exposes separate play & pause URIs and
    /// no toggle, so we alternate and let the first press mean "pause"
    /// (you reach for the button mid-playback far more often than mid-pause).
    private var nextTransportIsPause = true

    init(device: DiscoveredTV) {
        self.device = device
    }

    // MARK: TVDriver

    func connect(token: String?) {
        storedKey = token
        open(urlString: "wss://\(device.host):3001")
    }

    func submitPairingCode(_ code: String) { /* LG pairs on the TV, not with a PIN */ }

    func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        inputSocket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        inputSocket = nil
        onStateChange?(.idle)
    }

    func send(_ key: RemoteKey) {
        // Power ON while unreachable → Wake-on-LAN, like the Samsung driver.
        if key == .power, socket == nil || socket?.state != .running {
            if let mac = UserDefaults.standard.string(forKey: macKey) {
                sendWakeOnLAN(macAddress: mac)
            }
            return
        }

        switch key {
        case .power:
            request(uri: "ssap://system/turnOff", payload: nil)
        case .playPause:
            request(uri: nextTransportIsPause ? "ssap://media.controls/pause"
                                              : "ssap://media.controls/play", payload: nil)
            nextTransportIsPause.toggle()
        case .rewind:
            request(uri: "ssap://media.controls/rewind", payload: nil)
        case .fastForward:
            request(uri: "ssap://media.controls/fastForward", payload: nil)
        case .volumeUp:
            request(uri: "ssap://audio/volumeUp", payload: nil)
        case .volumeDown:
            request(uri: "ssap://audio/volumeDown", payload: nil)

        // Everything else is a button on the pointer-input socket.
        default:
            let button: String
            switch key {
            case .up:    button = "UP"
            case .down:  button = "DOWN"
            case .left:  button = "LEFT"
            case .right: button = "RIGHT"
            case .ok:    button = "ENTER"
            case .back:  button = "BACK"
            case .home:  button = "HOME"
            case .menu:  button = "MENU"
            case .mute:  button = "MUTE"
            default:     return   // handled above
            }
            // The input socket speaks newline-delimited key:value frames,
            // terminated by a blank line — not JSON.
            inputSocket?.send(.string("type:button\nname:\(button)\n\n")) { _ in }
        }
    }

    func sendText(_ text: String) {
        // Replaces nothing, just inserts at the cursor of the focused field.
        request(uri: "ssap://com.webos.service.ime/insertText",
                payload: ["text": text, "replace": 0])
    }

    func launchApp(_ appID: String) {
        request(uri: "ssap://system.launcher/launch", payload: ["id": appID])
    }

    /// webOS app ids (stable across firmware versions per aiowebostv docs).
    var apps: [TVApp] {
        [
            TVApp(name: "Netflix", id: "netflix"),
            TVApp(name: "YouTube", id: "youtube.leanback.v4"),
            TVApp(name: "Prime Video", id: "amazon"),
            TVApp(name: "Disney+", id: "disneyplus"),
            TVApp(name: "Spotify", id: "spotify-beehive"),
        ]
    }

    // MARK: connection + registration

    private func open(urlString: String) {
        socket = session.webSocketTask(with: URL(string: urlString)!)
        socket?.resume()
        receiveLoop()
        register()
    }

    /// The registration handshake. With a stored client-key the TV answers
    /// "registered" silently; without one it shows its Accept dialog first.
    private func register() {
        // The canonical permission manifest every webOS client sends (from
        // lgtv2). The TV grants what it recognizes; asking for more than we
        // use today is harmless and saves re-pairing when features grow.
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "permissions": [
                    "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CONTROL_AUDIO",
                    "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
                    "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING",
                    "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV", "CONTROL_MOUSE_AND_KEYBOARD",
                    "CONTROL_POWER", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
                    "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS", "READ_NETWORK_STATE",
                    "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST",
                ] as [String],
            ] as [String: Any],
        ]
        if let storedKey { payload["client-key"] = storedKey }

        sendJSON(["type": "register", "id": "register_0", "payload": payload])

        if storedKey == nil {
            onStateChange?(.awaitingPairing(.onScreenAllow))
        }
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // New LG firmware requires wss:3001, old firmware only has
                // ws:3000 — if the first flavor dies immediately, try the
                // other before declaring failure.
                if !self.triedLegacyPort {
                    self.triedLegacyPort = true
                    self.open(urlString: "ws://\(self.device.host):3000")
                } else {
                    self.onStateChange?(.failed("LG TV connection failed — if a pairing "
                        + "dialog appeared, it may have been denied"))
                }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any]

        if type == "registered" {
            // Paired (or silently re-registered). Persist the key, grab the
            // button socket, cache the MAC for Wake-on-LAN.
            if let clientKey = payload?["client-key"] as? String {
                storedKey = clientKey
                onTokenIssued?(clientKey)
            }
            onStateChange?(.connected)
            requestPointerInputSocket()
            if let mac = macAddressFromARP(ip: device.host) {
                UserDefaults.standard.set(mac, forKey: macKey)
            }
        } else if type == "error" {
            // 401 errors during registration mean the user hit Deny.
            let message = (json["error"] as? String) ?? "unknown error"
            if message.contains("401") || message.lowercased().contains("denied") {
                onStateChange?(.failed("Pairing was denied on the TV"))
            }
        } else if type == "response",
                  let socketPath = payload?["socketPath"] as? String {
            // Answer to getPointerInputSocket: connect the button channel.
            inputSocket = session.webSocketTask(with: URL(string: socketPath)!)
            inputSocket?.resume()
        }
    }

    private func requestPointerInputSocket() {
        request(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket", payload: nil)
    }

    private func request(uri: String, payload: [String: Any]?) {
        requestCounter += 1
        var object: [String: Any] = ["type": "request", "id": "req_\(requestCounter)", "uri": uri]
        if let payload { object["payload"] = payload }
        sendJSON(object)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(string)) { [weak self] error in
            if error != nil { self?.onStateChange?(.failed("LG TV connection lost")) }
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
