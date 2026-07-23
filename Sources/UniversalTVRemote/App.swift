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
            case NX_KEYTYPE_PLAY:       session.send(.playPause);    return nil
            case NX_KEYTYPE_SOUND_UP:   session.send(.volumeUp);     return nil
            case NX_KEYTYPE_SOUND_DOWN: session.send(.volumeDown);   return nil
            case NX_KEYTYPE_MUTE:       session.send(.mute);         return nil
            case NX_KEYTYPE_FAST:       session.send(.skipForward);  return nil
            case NX_KEYTYPE_REWIND:     session.send(.skipBackward); return nil
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
    /// Whether the app row shows the full catalog or just the top few.
    @State private var appsExpanded = false

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
            // borderlessButton menus draw their own disclosure chevron.
            Text(state.session?.device.name ?? "Choose a TV")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
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
        DPad(send: send)
    }

    // MARK: back/home/menu · transport · volume

    private var controlRows: some View {
        VStack(spacing: 10) {
            HStack(spacing: 24) {
                RemoteButton(symbol: "arrow.uturn.backward", size: 38) { send(.back) }
                RemoteButton(symbol: "house", size: 38) { send(.home) }
                RemoteButton(symbol: "line.3.horizontal", size: 38) { send(.menu) }
            }
            // ~10 s skips flank play/pause — how modern streaming UIs seek.
            HStack(spacing: 24) {
                RemoteButton(symbol: "gobackward.10", size: 38) { send(.skipBackward) }
                RemoteButton(symbol: "playpause.fill", size: 38) { send(.playPause) }
                RemoteButton(symbol: "goforward.10", size: 38) { send(.skipForward) }
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

    // MARK: app shortcuts — top row of icons, expandable to the full catalog

    @ViewBuilder
    private var appShortcuts: some View {
        if let session = state.session, !session.apps.isEmpty {
            VStack(spacing: 8) {
                if !appsExpanded {
                    // Collapsed: just the top few, icon-only.
                    HStack(spacing: 10) {
                        ForEach(session.apps.prefix(5)) { app in
                            AppIconButton(app: app, size: 36, showName: false) {
                                session.launchApp(app.id)
                            }
                        }
                        Spacer(minLength: 0)
                        if session.apps.count > 5 { expandToggle }
                    }
                } else {
                    // Expanded: the full catalog REPLACES the top row (no
                    // duplicate icons), scrolling inside a capped height so
                    // the popover never outgrows the screen.
                    HStack {
                        Text("All apps").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        expandToggle
                    }
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                            ForEach(session.apps) { app in
                                AppIconButton(app: app, size: 36, showName: true) {
                                    session.launchApp(app.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // A fixed height, not maxHeight: ScrollView has no
                    // intrinsic content height, so inside this size-hugging
                    // popover a maxHeight-only frame collapses to zero.
                    .frame(height: 180)
                }
            }
        }
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { appsExpanded.toggle() }
        } label: {
            Image(systemName: appsExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(appsExpanded ? "Show fewer apps" : "Show all apps")
    }

    private func send(_ key: RemoteKey) { state.session?.send(key) }
}

// MARK: - Reusable button pieces

/// A circular remote button: SF Symbol in a subtle filled circle.
///
/// Fires on mouse-DOWN, not mouse-up: real remotes act the instant you press,
/// and the ~100 ms saved per press is most of what makes the remote feel
/// responsive. (SwiftUI Buttons fire on release, which reads as lag here.)
struct RemoteButton: View {
    let symbol: String
    var tint: Color = .primary
    let size: CGFloat
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(pressed ? 0.2 : 0.08)))
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            // minimumDistance 0 → onChanged fires immediately on mouse-down.
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                }
                .onEnded { _ in pressed = false })
    }
}

/// The circular d-pad: one ring with four directional segments around an OK
/// hub, driven by a single mouse-down gesture (press position → region).
/// Pressing highlights the touched wedge and fires instantly.
struct DPad: View {
    let send: (RemoteKey) -> Void

    private enum Region { case up, down, left, right, ok }
    @State private var pressed: Region?

    private let diameter: CGFloat = 196
    private let hubRadius: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.07))

            // Pressed-wedge highlight (drawn under the chevrons).
            if let pressed, pressed != .ok {
                wedge(for: pressed)
                    .fill(.white.opacity(0.14))
            }

            // Direction glyphs at the four compass points.
            chevron("chevron.up",    x: 0, y: -0.36)
            chevron("chevron.down",  x: 0, y: 0.36)
            chevron("chevron.left",  x: -0.36, y: 0)
            chevron("chevron.right", x: 0.36, y: 0)

            // OK hub — the visual anchor of the remote.
            Text("OK")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(width: hubRadius * 2, height: hubRadius * 2)
                .background(Circle().fill(.tint.opacity(pressed == .ok ? 0.45 : 0.25)))
                .overlay(Circle().strokeBorder(.tint.opacity(0.4), lineWidth: 1))
                .scaleEffect(pressed == .ok ? 0.94 : 1)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard pressed == nil else { return }   // one key per press
                let region = region(at: gesture.startLocation)
                pressed = region
                switch region {
                case .up: send(.up)
                case .down: send(.down)
                case .left: send(.left)
                case .right: send(.right)
                case .ok: send(.ok)
                }
            }
            .onEnded { _ in pressed = nil })
    }

    /// Map a press location onto hub-or-wedge: distance decides OK vs ring,
    /// angle decides which direction (45°-centered quadrants).
    private func region(at point: CGPoint) -> Region {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        if (dx * dx + dy * dy).squareRoot() <= hubRadius { return .ok }
        // atan2 with screen coordinates (y grows downward): 0° = right.
        let degrees = atan2(dy, dx) * 180 / .pi
        switch degrees {
        case -45..<45:    return .right
        case 45..<135:    return .down
        case -135 ..< -45: return .up
        default:          return .left
        }
    }

    private func chevron(_ symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .offset(x: x * diameter, y: y * diameter)
    }

    /// Annulus wedge used as the pressed-state highlight for a direction.
    private func wedge(for region: Region) -> Path {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let start: Double
        switch region {
        case .right: start = -45
        case .down:  start = 45
        case .left:  start = 135
        case .up:    start = 225
        case .ok:    start = 0   // never drawn
        }
        var path = Path()
        path.addArc(center: center, radius: diameter / 2,
                    startAngle: .degrees(start), endAngle: .degrees(start + 90), clockwise: false)
        path.addArc(center: center, radius: hubRadius + 6,
                    startAngle: .degrees(start + 90), endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Resolves crisp app icons: real App Store artwork via the iTunes Search
/// API (uniform rounded-square 256 px images), falling back to the service's
/// favicon, then a letter avatar. Resolved artwork URLs are cached in
/// UserDefaults so the lookup happens once per app ever; the images
/// themselves are cached by URLCache.
enum AppIconResolver {
    static func artworkURL(for appName: String) async -> URL? {
        let cacheKey = "iconURL.\(appName)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            return URL(string: cached)   // "" caches a known miss
        }
        let query = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
        let search = URL(string: "https://itunes.apple.com/search?term=\(query)&entity=software&country=us&limit=1")!
        var found = ""
        if let (data, _) = try? await URLSession.shared.data(from: search),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let artwork = results.first?["artworkUrl100"] as? String,
           let track = results.first?["trackName"] as? String,
           // Only trust the hit when the names overlap ("Max" → "HBO Max…"
           // is fine; "Silk Browser" → "Private Browsing Web Browser" is a
           // miss that should fall back to the favicon instead).
           track.lowercased().contains(appName.lowercased())
            || appName.lowercased().contains(track.lowercased()) {
            // The artwork URL pattern allows requesting other sizes directly.
            found = artwork.replacingOccurrences(of: "100x100", with: "256x256")
        }
        UserDefaults.standard.set(found, forKey: cacheKey)
        return URL(string: found)
    }
}

/// One app shortcut tile. Icon precedence: App Store artwork → favicon →
/// letter avatar. (Fetched, not bundled — shipping trademarked logos in the
/// repo is the alternative nobody wants.)
struct AppIconButton: View {
    let app: TVApp
    let size: CGFloat
    let showName: Bool
    let action: () -> Void
    @State private var artworkURL: URL?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let url = artworkURL ?? app.iconURL {
                        AsyncImage(url: url) { image in
                            // Store artwork is full-bleed; favicons keep a
                            // little breathing room.
                            if artworkURL != nil {
                                image.resizable().scaledToFill()
                            } else {
                                image.resizable().scaledToFit().padding(size * 0.14)
                            }
                        } placeholder: {
                            letterAvatar
                        }
                    } else {
                        letterAvatar
                    }
                }
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24).fill(.white.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
                if showName {
                    Text(app.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .help(app.name)
        .task(id: app.id) { artworkURL = await AppIconResolver.artworkURL(for: app.name) }
    }

    private var letterAvatar: some View {
        Text(String(app.name.prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

/// Scales the button down slightly while pressed — cheap tactile feedback.
/// (Used for app tiles and other non-latency-critical buttons; the remote
/// keys use the fire-on-mouse-down RemoteButton instead.)
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
