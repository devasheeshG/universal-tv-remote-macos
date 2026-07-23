//
//  App.swift
//  Universal TV Remote for Mac
//
//  Entry point and the entire menu-bar UI. The app lives as a TV icon in the
//  menu bar (LSUIElement in Info.plist keeps it out of the Dock); clicking it
//  opens a compact dark remote:
//
//      ┌──────────────────────────────┐
//      │ ⏻  [Living Room TV ⌄]  ⟳ ⚙  │  header: power, picker, refresh, gear
//      │        ● Connected           │  status / pairing prompts
//      │            ▲                 │
//      │        ◀  OK  ▶              │  d-pad
//      │            ▼                 │
//      │      ↩    ⌂    ☰            │  back / home / menu
//      │      ⏪   ⏯    ⏩            │  transport
//      │      −    🔇    +            │  volume
//      │ [ Type on TV…            ]   │  keyboard passthrough
//      │  Netflix YouTube Prime …     │  app shortcuts
//      └──────────────────────────────┘
//
//  While the popover is open, the physical keyboard drives the TV too:
//  arrows/Enter/Esc/Space, and the Mac's media keys (play, volume) are
//  captured and forwarded instead of acting on the Mac.
//

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - App state

/// One object owns everything the UI observes: the discovery engine, the
/// active session, and the keyboard monitors. Sessions are cached per device
/// so switching TVs doesn't re-pair or drop connections.
final class AppState: ObservableObject {
    let discovery = DiscoveryEngine()
    @Published var session: RemoteSession?
    /// True while the text field owns the keyboard; letter/arrow shortcuts
    /// must not fire mid-typing.
    var textFieldFocused = false

    private var sessions: [String: RemoteSession] = [:]
    private var keyMonitor: Any?
    private var mediaKeyMonitor: Any?

    init() {
        discovery.start()
        // Reconnect the last-used TV so the remote is live immediately.
        if let lastID = UserDefaults.standard.string(forKey: "selectedDevice"),
           let device = discovery.devices.first(where: { $0.id == lastID }) {
            select(device)
        }
    }

    func select(_ device: DiscoveredTV) {
        let session = sessions[device.id] ?? RemoteSession(device: device)
        sessions[device.id] = session
        self.session = session
        UserDefaults.standard.set(device.id, forKey: "selectedDevice")
        // (Re)connect unless a healthy connection already exists.
        switch session.state {
        case .connected, .connecting, .awaitingPairing: break
        case .idle, .failed: session.connect()
        }
    }

    // MARK: keyboard capture (only while the popover is open)

    func installKeyMonitors() {
        guard keyMonitor == nil else { return }

        // Regular keys: arrows, Enter, Esc, Space, plus a few letter/symbol
        // shortcuts. Returning nil swallows the event; returning it lets the
        // system keep processing (crucial while the text field is focused).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let session = self.session, !self.textFieldFocused else { return event }
            switch event.keyCode {
            case 126: session.send(.up);    return nil
            case 125: session.send(.down);  return nil
            case 123: session.send(.left);  return nil
            case 124: session.send(.right); return nil
            case 36, 76: session.send(.ok); return nil   // Return / keypad Enter
            case 53: session.send(.back);   return nil   // Esc
            case 49: session.send(.playPause); return nil // Space
            case 51: session.send(.back);   return nil   // Delete ≈ back
            default: break
            }
            switch event.charactersIgnoringModifiers {
            case "+", "=": session.send(.volumeUp);   return nil
            case "-", "_": session.send(.volumeDown); return nil
            case "m":      session.send(.mute);       return nil
            case "h":      session.send(.home);       return nil
            default:       return event
            }
        }

        // Media keys (play/pause, volume, mute) arrive as .systemDefined
        // subtype 8 events. Capturing them here means they control the TV
        // instead of the Mac while the remote is front-most — the requested
        // "media-key passthrough".
        mediaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let session = self.session, event.subtype.rawValue == 8 else { return event }
            let keyCode = Int32((event.data1 & 0xFFFF_0000) >> 16)
            let isKeyDown = ((event.data1 & 0x0000_FF00) >> 8) == 0x0A
            guard isKeyDown else { return nil }   // swallow key-ups of handled keys
            switch keyCode {
            case NX_KEYTYPE_PLAY:       session.send(.playPause);   return nil
            case NX_KEYTYPE_SOUND_UP:   session.send(.volumeUp);    return nil
            case NX_KEYTYPE_SOUND_DOWN: session.send(.volumeDown);  return nil
            case NX_KEYTYPE_MUTE:       session.send(.mute);        return nil
            case NX_KEYTYPE_FAST:       session.send(.fastForward); return nil
            case NX_KEYTYPE_REWIND:     session.send(.rewind);      return nil
            default: return event
            }
        }
    }

    func removeKeyMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mediaKeyMonitor { NSEvent.removeMonitor(mediaKeyMonitor) }
        keyMonitor = nil
        mediaKeyMonitor = nil
    }
}

// MARK: - App entry

@main
struct UniversalTVRemoteApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Universal TV Remote", systemImage: "tv") {
            RemoteView()
                .environmentObject(state)
        }
        // .window style = a real popover panel we can lay out freely
        // (default .menu style only allows menu items).
        .menuBarExtraStyle(.window)
    }
}

// MARK: - The remote

struct RemoteView: View {
    @EnvironmentObject private var state: AppState
    @State private var pinInput = ""
    @State private var textInput = ""
    @FocusState private var typingFocused: Bool
    // Manual "Add TV by IP" form state (shown in place of the status area).
    @State private var addingManually = false
    @State private var manualBrand: TVBrand = .fireTV
    @State private var manualIP = ""

    var body: some View {
        VStack(spacing: 14) {
            header
            if addingManually {
                addTVForm
            } else {
                statusSection
            }
            if case .connected = state.session?.state {
                dpad
                controlRows
                keyboardField
                appShortcuts
            } else if state.session == nil {
                emptyState
            }
        }
        .padding(16)
        .frame(width: 272)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .onAppear {
            state.discovery.scan()
            state.installKeyMonitors()
            // Auto-select the only TV when nothing is selected yet.
            if state.session == nil, let only = state.discovery.devices.first,
               state.discovery.devices.count == 1 {
                state.select(only)
            }
        }
        .onDisappear { state.removeKeyMonitors() }
        .onChange(of: typingFocused) { _, focused in state.textFieldFocused = focused }
    }

    // MARK: header — power · device picker · refresh · settings

    private var header: some View {
        HStack(spacing: 10) {
            RemoteButton(symbol: "power", tint: .red, size: 30) {
                state.session?.send(.power)
            }
            .disabled(state.session == nil)

            devicePicker
            Spacer(minLength: 0)

            Button {
                state.discovery.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(state.discovery.isScanning ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Scan the network again")

            settingsMenu
        }
    }

    private var devicePicker: some View {
        Menu {
            if state.discovery.devices.isEmpty {
                Text("No TVs found yet")
            }
            ForEach(state.discovery.devices) { device in
                Button {
                    state.select(device)
                } label: {
                    Label("\(device.name)  ·  \(device.brand.displayName)",
                          systemImage: device.brand.symbolName)
                }
            }
            Divider()
            Button("Add TV by IP…") { addingManually = true }
        } label: {
            HStack(spacing: 4) {
                Text(state.session?.device.name ?? "Choose a TV")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var settingsMenu: some View {
        Menu {
            if let session = state.session {
                Button("Re-pair \"\(session.device.name)\"") { session.forgetAndRepair() }
                Button("Forget \"\(session.device.name)\"") {
                    session.disconnect()
                    state.discovery.forget(session.device)
                    state.session = nil
                }
                Divider()
            }
            LaunchAtLoginToggle()
            Divider()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
            Button("Quit Universal TV Remote") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: status + pairing

    @ViewBuilder
    private var statusSection: some View {
        switch state.session?.state {
        case .none:
            EmptyView()
        case .idle, .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .connected:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Connected").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") { state.session?.connect() }
                    .controlSize(.small)
            }
        case .awaitingPairing(.onScreenAllow):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Accept the connection request\nshown on your TV")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case .awaitingPairing(.pin(let digits)):
            VStack(spacing: 8) {
                Text("Enter the \(digits)-character code\nshown on your TV")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Code", text: $pinInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onSubmit(submitPIN)
                    Button("Pair", action: submitPIN)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(pinInput.count < digits)
                }
            }
        }
    }

    // MARK: manual add (for TVs discovery can't see)

    private var addTVForm: some View {
        VStack(spacing: 8) {
            Picker("Brand", selection: $manualBrand) {
                ForEach(TVBrand.allCases, id: \.self) { brand in
                    Text(brand.displayName).tag(brand)
                }
            }
            .pickerStyle(.menu)
            TextField("IP address (e.g. 192.168.1.42)", text: $manualIP)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addManualTV)
            HStack {
                Button("Cancel") { addingManually = false; manualIP = "" }
                    .controlSize(.small)
                Button("Add & Connect", action: addManualTV)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    // Loose sanity check only — DNS names are fine too.
                    .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private func addManualTV() {
        let host = manualIP.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let device = state.discovery.addManual(brand: manualBrand, host: host)
        addingManually = false
        manualIP = ""
        state.select(device)
    }

    private func submitPIN() {
        guard !pinInput.isEmpty else { return }
        state.session?.submitPairingCode(pinInput.trimmingCharacters(in: .whitespaces))
        pinInput = ""
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tv")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(state.discovery.devices.isEmpty
                 ? "Searching for TVs on your network…"
                 : "Pick a TV to get started")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: d-pad

    private var dpad: some View {
        VStack(spacing: 8) {
            RemoteButton(symbol: "chevron.up", size: 44) { send(.up) }
            HStack(spacing: 8) {
                RemoteButton(symbol: "chevron.left", size: 44) { send(.left) }
                // The OK button is the visual anchor of the remote — bigger
                // and accent-tinted.
                Button { send(.ok) } label: {
                    Text("OK")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(.tint.opacity(0.25)))
                        .overlay(Circle().strokeBorder(.tint.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                RemoteButton(symbol: "chevron.right", size: 44) { send(.right) }
            }
            RemoteButton(symbol: "chevron.down", size: 44) { send(.down) }
        }
    }

    // MARK: back/home/menu · transport · volume

    private var controlRows: some View {
        VStack(spacing: 10) {
            HStack(spacing: 24) {
                RemoteButton(symbol: "arrow.uturn.backward", size: 38) { send(.back) }
                RemoteButton(symbol: "house", size: 38) { send(.home) }
                RemoteButton(symbol: "line.3.horizontal", size: 38) { send(.menu) }
            }
            HStack(spacing: 24) {
                RemoteButton(symbol: "backward.fill", size: 38) { send(.rewind) }
                RemoteButton(symbol: "playpause.fill", size: 38) { send(.playPause) }
                RemoteButton(symbol: "forward.fill", size: 38) { send(.fastForward) }
            }
            HStack(spacing: 24) {
                RemoteButton(symbol: "minus", size: 38) { send(.volumeDown) }
                RemoteButton(symbol: "speaker.slash", size: 38) { send(.mute) }
                RemoteButton(symbol: "plus", size: 38) { send(.volumeUp) }
            }
        }
    }

    // MARK: keyboard passthrough

    private var keyboardField: some View {
        TextField("Type on TV…", text: $textInput)
            .textFieldStyle(.roundedBorder)
            .focused($typingFocused)
            .onSubmit {
                guard !textInput.isEmpty else { return }
                state.session?.sendText(textInput)
                textInput = ""
            }
    }

    // MARK: app shortcuts

    @ViewBuilder
    private var appShortcuts: some View {
        if let session = state.session, !session.apps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.apps) { app in
                        Button(app.name) { session.launchApp(app.id) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                }
            }
        }
    }

    private func send(_ key: RemoteKey) { state.session?.send(key) }
}

// MARK: - Reusable button pieces

/// A circular remote button: SF Symbol in a subtle filled circle with a
/// press-down animation. Used for everything except the OK anchor.
struct RemoteButton: View {
    let symbol: String
    var tint: Color = .primary
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Scales the button down slightly while pressed — cheap tactile feedback.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// "Launch at Login" via SMAppService (macOS 13+). Lives in its own tiny view
/// because toggling needs local state + error tolerance.
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at Login", isOn: $enabled)
            .onChange(of: enabled) { _, newValue in
                // Registration can fail for unbundled dev builds; reflect
                // reality rather than the wish.
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
