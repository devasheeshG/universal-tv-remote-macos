//
//  AndroidTV.swift
//  Universal TV Remote for Mac
//
//  Driver for Android TV / Google TV (Sony, TCL, Hisense, Chromecast with
//  Google TV, NVIDIA Shield…) via Google's "Remote v2" protocol — length-
//  prefixed protobuf over TLS with client-certificate authentication.
//
//    Pairing    TLS to port 6467. The TV displays a 6-character code; the
//               protocol proves we saw it by hashing it together with both
//               certificates' public keys. After success the TV remembers
//               OUR CLIENT CERTIFICATE — that cert *is* the credential.
//    Remote     TLS to port 6466 with the same cert; protobuf messages for
//               key events (Android KEYCODE_*), deep-link app launches, and
//               state the TV pushes back.
//
//  The protocol plumbing comes from the vendored AndroidTVRemoteControl
//  package (MIT, Roman Odyshew). This driver's own work is:
//    - generating the self-signed client identity (openssl, one time)
//    - walking pairing-manager / remote-manager state machines
//    - mapping RemoteKey/text/apps onto Android key codes and deep links
//
//  Fire TV does NOT speak this protocol despite running Android.
//

import Foundation
import Security
import AndroidTVRemoteControl

final class AndroidTVDriver: TVDriver {
    var onStateChange: ((SessionState) -> Void)?
    var onTokenIssued: ((String) -> Void)?

    private let device: DiscoveredTV
    private let cryptoManager = CryptoManager()
    private let tlsManager: TLSManager
    private var pairingManager: PairingManager?
    private var remoteManager: RemoteManager?
    /// Set once the TLS handshake captures the TV's certificate; the pairing
    /// code hash needs both our public key and the TV's.
    private var serverKey: SecKey?

    // The client identity lives in Application Support and is shared by every
    // Android TV we ever pair with (the TV remembers the cert, not a token).
    private static let certDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UniversalTVRemote", isDirectory: true)
    private static let p12Password = "atvremote"   // local file, not a secret

    init(device: DiscoveredTV) {
        self.device = device

        // TLSManager wants a closure producing the SecPKCS12Import result for
        // our client identity; generate the identity on first use.
        tlsManager = TLSManager { AndroidTVDriver.importClientIdentity() }
        // Capture the TV-side certificate during the handshake and feed both
        // public keys to the crypto manager (used to verify the pairing code).
        tlsManager.secTrustClosure = { [weak self] trust in
            self?.serverKey = SecTrustCopyKey(trust)
        }
        cryptoManager.clientPublicCertificate = {
            CertManager().getSecKey(AndroidTVDriver.certDirectory.appendingPathComponent("cert.der"))
        }
        cryptoManager.serverPublicCertificate = { [weak self] () -> AndroidTVRemoteControl.Result<SecKey> in
            guard let key = self?.serverKey else { return .Error(.noServerPublicCertificate) }
            return .Result(key)
        }
    }

    // MARK: TVDriver

    func connect(token: String?) {
        // "token" here is just a marker that pairing once succeeded — the
        // real credential is the client certificate the TV remembers.
        if token != nil {
            startRemoteSession()
        } else {
            startPairing()
        }
    }

    func submitPairingCode(_ code: String) {
        pairingManager?.sendSecret(code.uppercased())
    }

    func disconnect() {
        pairingManager?.disconnect()
        remoteManager?.disconnect()
        pairingManager = nil
        remoteManager = nil
        onStateChange?(.idle)
    }

    func send(_ key: RemoteKey) {
        let code: Key
        switch key {
        case .power:       code = .KEYCODE_POWER
        case .up:          code = .KEYCODE_DPAD_UP
        case .down:        code = .KEYCODE_DPAD_DOWN
        case .left:        code = .KEYCODE_DPAD_LEFT
        case .right:       code = .KEYCODE_DPAD_RIGHT
        case .ok:          code = .KEYCODE_DPAD_CENTER
        case .back:        code = .KEYCODE_BACK
        case .home:        code = .KEYCODE_HOME
        case .menu:        code = .KEYCODE_MENU
        case .playPause:   code = .KEYCODE_MEDIA_PLAY_PAUSE
        case .rewind:      code = .KEYCODE_MEDIA_REWIND
        case .fastForward: code = .KEYCODE_MEDIA_FAST_FORWARD
        case .volumeUp:    code = .KEYCODE_VOLUME_UP
        case .volumeDown:  code = .KEYCODE_VOLUME_DOWN
        case .mute:        code = .KEYCODE_VOLUME_MUTE
        }
        remoteManager?.send(KeyPress(code))
    }

    func sendText(_ text: String) {
        // Remote v2's real text path is a complex IME message exchange the
        // vendored library doesn't implement, but search boxes accept plain
        // key events just fine — so type letter by letter. Uppercase/symbols
        // outside this map are skipped (search UIs are case-insensitive).
        for char in text.lowercased() {
            let code: Key?
            switch char {
            case "a"..."z":
                // KEYCODE_A is 29 and the alphabet is contiguous.
                code = Key(rawValue: 29 + UInt(char.asciiValue! - Character("a").asciiValue!))
            case "0"..."9":
                // KEYCODE_0 is 7, digits contiguous.
                code = Key(rawValue: 7 + UInt(char.asciiValue! - Character("0").asciiValue!))
            case " ":  code = .KEYCODE_SPACE
            case ".":  code = .KEYCODE_PERIOD
            case "-":  code = .KEYCODE_MINUS
            default:   code = nil
            }
            if let code { remoteManager?.send(KeyPress(code)) }
        }
    }

    func launchApp(_ appID: String) {
        // appID is a deep link; Google TV routes https links into the
        // matching installed app (or its store page when missing).
        remoteManager?.send(DeepLink(appID))
    }

    var apps: [TVApp] {
        [
            TVApp(name: "Netflix", id: "https://www.netflix.com/browse"),
            TVApp(name: "YouTube", id: "https://www.youtube.com"),
            TVApp(name: "Prime Video", id: "https://app.primevideo.com"),
            TVApp(name: "Disney+", id: "https://www.disneyplus.com"),
        ]
    }

    // MARK: pairing flow (port 6467)

    private func startPairing() {
        let manager = PairingManager(tlsManager, cryptoManager)
        pairingManager = manager
        manager.stateChanged = { [weak self] pairingState in
            guard let self else { return }
            switch pairingState {
            case .waitingCode:
                // The TV is now showing its 6-character code.
                self.onStateChange?(.awaitingPairing(.pin(digits: 6)))
            case .successPaired:
                // The TV has stored our certificate; persist the marker and
                // move straight on to the remote session.
                self.onTokenIssued?("paired")
                self.pairingManager?.disconnect()
                self.pairingManager = nil
                self.startRemoteSession()
            case .error(let error):
                self.onStateChange?(.failed("Android TV pairing failed: \(error)"))
            default:
                break   // intermediate handshake steps — nothing to show
            }
        }
        manager.connect(device.host, "Universal TV Remote", "com.universaltvremote.remote")
    }

    // MARK: remote session (port 6466)

    private func startRemoteSession() {
        // DeviceInfo is what we report about ourselves in the initial
        // configuration exchange (shows up in the TV's paired-devices list).
        let info = CommandNetwork.DeviceInfo("MacBook", "Universal TV Remote", "1", "com.universaltvremote", "1")
        let manager = RemoteManager(tlsManager, info)
        remoteManager = manager
        manager.stateChanged = { [weak self] remoteState in
            guard let self else { return }
            switch remoteState {
            case .paired:
                self.onStateChange?(.connected)
            case .error(let error):
                // The most common failure is the TV no longer recognizing our
                // certificate (unpaired from TV settings) — re-pairing fixes
                // it, so point the user there.
                self.onStateChange?(.failed("Android TV connection failed (\(error)). "
                    + "If this repeats, use Settings → Re-pair."))
            default:
                break   // connectionSetUp / config handshake steps
            }
        }
        manager.connect(device.host)
    }

    // MARK: client identity import (keychain-prompt-free)

    /// Cached for the process lifetime so repeated connects don't re-import.
    private static var cachedIdentity: CFArray?

    /// Imports identity.p12 for TLS — into a throwaway keychain in the temp
    /// directory, NEVER the login keychain.
    ///
    /// Why: on macOS SecPKCS12Import must land in *some* keychain, and the
    /// default is login. A private key in the login keychain is ACL-guarded
    /// per signing identity, and this app is ad-hoc signed — every rebuild
    /// looks like a different app, so macOS re-prompts "wants to access key"
    /// forever. A fresh temp keychain is created by the current binary, whose
    /// ACL therefore always matches: zero prompts, nothing persisted in the
    /// user's keychains. (SecKeychainCreate is deprecated but has no
    /// replacement for this use; the data-protection keychain needs
    /// provisioning entitlements an ad-hoc app can't carry.)
    private static func importClientIdentity() -> AndroidTVRemoteControl.Result<CFArray?> {
        if let cachedIdentity { return .Result(cachedIdentity) }
        ensureClientIdentityExists()
        guard let p12Data = try? Data(contentsOf: certDirectory.appendingPathComponent("identity.p12")) else {
            return .Error(.secPKCS12ImportNotSuccess)
        }

        let path = NSTemporaryDirectory() + "utvr-\(ProcessInfo.processInfo.processIdentifier).keychain"
        try? FileManager.default.removeItem(atPath: path)
        var keychain: SecKeychain?
        let created = "transient".withCString { pw in
            SecKeychainCreate(path, UInt32(strlen(pw)), pw, false, nil, &keychain)
        }
        guard created == errSecSuccess, let keychain else {
            return .Error(.secPKCS12ImportNotSuccess)
        }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportExportKeychain as String: keychain,
        ]
        var raw: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options as CFDictionary, &raw) == errSecSuccess else {
            return .Error(.secPKCS12ImportNotSuccess)
        }
        cachedIdentity = raw
        return .Result(raw)
    }

    // MARK: client identity generation (one-time, shared across TVs)

    /// Creates key.pem/cert.pem/cert.der/identity.p12 in Application Support
    /// on first use. Shelling out to the system LibreSSL is deliberate:
    /// macOS has no public API for *creating* X.509 certificates, and
    /// hand-writing ASN.1/DER is exactly the kind of code that shouldn't
    /// live in a remote-control app.
    private static func ensureClientIdentityExists() {
        let p12 = certDirectory.appendingPathComponent("identity.p12")
        guard !FileManager.default.fileExists(atPath: p12.path) else { return }
        try? FileManager.default.createDirectory(at: certDirectory, withIntermediateDirectories: true)

        let dir = certDirectory.path
        // Three quick openssl invocations: RSA-2048 self-signed pair (10 y),
        // DER copy of the cert (for SecCertificateCreateWithData), and a
        // PKCS#12 bundle (for SecPKCS12Import → TLS client identity).
        let script = """
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=Universal TV Remote for Mac" \
            -keyout "\(dir)/key.pem" -out "\(dir)/cert.pem" 2>/dev/null && \
        /usr/bin/openssl x509 -in "\(dir)/cert.pem" -outform der -out "\(dir)/cert.der" && \
        /usr/bin/openssl pkcs12 -export -inkey "\(dir)/key.pem" -in "\(dir)/cert.pem" \
            -out "\(dir)/identity.p12" -passout pass:\(p12Password)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        process.waitUntilExit()
    }
}
