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
//  arrows/Enter/Esc/Space and shortcut letters are captured while open.
//

import SwiftUI
import AppKit
import Combine
import ServiceManagement

private struct OfflinePreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var offlinePreview: Bool {
        get { self[OfflinePreviewKey.self] }
        set { self[OfflinePreviewKey.self] = newValue }
    }
}

// MARK: - App state

/// One object owns everything the UI observes: the discovery engine, the
/// active session, and the keyboard monitors. Sessions are cached per device
/// so switching TVs doesn't re-pair or drop connections.
final class AppState: ObservableObject {
    let discovery: DiscoveryEngine
    let startsDiscovery: Bool
    private let defaults: UserDefaults
    private let makeSession: (DiscoveredTV) -> RemoteSession
    @Published var session: RemoteSession?
    /// True while the text field owns the keyboard; letter/arrow shortcuts
    /// must not fire mid-typing.
    var textFieldFocused = false

    /// Bumped every time a keyboard shortcut fires a key; the on-screen
    /// controls watch this to flash their press animation. `lastKey` says
    /// which control to light up.
    @Published private(set) var keyPulse = 0
    private(set) var lastKey: RemoteKey = .ok

    /// Send a key to the TV AND pulse the matching on-screen control, so a
    /// keyboard press lights up the remote exactly like a click does.
    func fire(_ key: RemoteKey) {
        session?.send(key)
        lastKey = key
        keyPulse &+= 1
    }

    private var sessions: [String: RemoteSession] = [:]
    private var keyMonitor: Any?
    /// SwiftUI doesn't observe nested ObservableObjects, so the active
    /// session's changes (state, live app list) are forwarded to ours.
    private var sessionForwarder: AnyCancellable?
    private var discoveryForwarder: AnyCancellable?
    private var deviceForwarder: AnyCancellable?

    init(discovery: DiscoveryEngine = DiscoveryEngine(), initialSession: RemoteSession? = nil,
         startsDiscovery: Bool = true, defaults: UserDefaults = .standard,
         makeSession: ((DiscoveredTV) -> RemoteSession)? = nil) {
        self.discovery = discovery
        self.startsDiscovery = startsDiscovery
        self.defaults = defaults
        self.makeSession = makeSession ?? { RemoteSession(device: $0, defaults: defaults) }
        self.session = initialSession
        // Forward the discovery engine's changes (new devices, renames) so
        // views observing AppState re-render.
        discoveryForwarder = discovery.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        if startsDiscovery { discovery.start() }
        // Observe later discoveries too: the remembered list may be empty
        // or the selected TV may have changed its DHCP address.
        deviceForwarder = discovery.$devices.sink { [weak self] devices in
            self?.restoreSelection(from: devices)
        }
    }

    private func restoreSelection(from devices: [DiscoveredTV]) {
        let lastID = defaults.string(forKey: "selectedDevice")
        guard let device = devices.first(where: { $0.id == (session?.device.id ?? lastID) })
                ?? (session == nil && devices.count == 1 ? devices.first : nil),
              session == nil || session?.device.host != device.host || session?.device.port != device.port,
              device.brand == .roku || defaults.string(forKey: "token.\(device.id)") != nil
        else { return }
        select(device)
    }

    func select(_ device: DiscoveredTV) {
        if self.session?.device.id != device.id { self.session?.disconnect() }
        if let old = sessions[device.id], old.device.host != device.host || old.device.port != device.port {
            old.disconnect()
            sessions[device.id] = nil
        }
        let session = sessions[device.id] ?? makeSession(device)
        sessions[device.id] = session
        self.session = session
        sessionForwarder = session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        defaults.set(device.id, forKey: "selectedDevice")
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
            guard let self, self.session != nil, !self.textFieldFocused else { return event }
            switch event.keyCode {
            case 126: self.fire(.up);    return nil
            case 125: self.fire(.down);  return nil
            case 123: self.fire(.left);  return nil
            case 124: self.fire(.right); return nil
            case 36, 76: self.fire(.ok); return nil   // Return / keypad Enter
            case 53: self.fire(.back);   return nil   // Esc
            case 49: self.fire(.playPause); return nil // Space
            case 51: self.fire(.back);   return nil   // Delete ≈ back
            default: break
            }
            switch event.charactersIgnoringModifiers {
            case "+", "=": self.fire(.volumeUp);   return nil
            case "-", "_": self.fire(.volumeDown); return nil
            case "m":      self.fire(.mute);       return nil
            case "h":      self.fire(.home);       return nil
            default:       return event
            }
        }
    }

    func removeKeyMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
    // Inline "Rename this TV" form state.
    @State private var renaming = false
    @State private var renameInput = ""

    var body: some View {
        VStack(spacing: 14) {
            header
            if addingManually {
                addTVForm
            } else if renaming {
                renameForm
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
        .background(WindowTopPin())
        .preferredColorScheme(.dark)
        .environment(\.offlinePreview, !state.startsDiscovery)
        .onAppear {
            guard state.startsDiscovery else { return }
            state.discovery.scan()
            state.installKeyMonitors()
        }
        .onDisappear { state.removeKeyMonitors() }
        .onChange(of: typingFocused) { _, focused in state.textFieldFocused = focused }
    }

    // MARK: header — power · device picker · refresh · settings

    private var header: some View {
        // Fixed-size controls at both ends; the picker takes the flexible
        // middle and truncates, so the power button and gear are always
        // visible no matter how long the TV's name is.
        HStack(spacing: 8) {
            RemoteButton(symbol: "power", tint: .red, size: 30, key: .power) {
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
                    Label("\(state.discovery.displayName(for: device))  ·  \(device.brand.displayName)",
                          systemImage: device.brand.symbolName)
                }
            }
            Divider()
            Button("Add TV by IP…") { addingManually = true }
        } label: {
            // borderlessButton menus draw their own disclosure chevron.
            // No .fixedSize() here — it would force the label to its full
            // text width and shove the power button and gear off the popover.
            Text(state.session.map(displayName) ?? "Choose a TV")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                // FIXED width (not maxWidth) directly on the label: proposes
                // exactly this width to the Text so it always truncates,
                // regardless of how the Menu propagates layout. Leaves room
                // for the power button, refresh, and gear in the 272 pt row.
                .frame(width: 132, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    /// The name to show for a session's TV: the user's custom nickname if set,
    /// otherwise the discovered name.
    private func displayName(_ session: RemoteSession) -> String {
        state.discovery.displayName(for: session.device)
    }

    private var settingsMenu: some View {
        Menu {
            if let session = state.session {
                Button("Rename…") {
                    renameInput = displayName(session)
                    renaming = true
                }
                Button("Re-pair") { session.forgetAndRepair() }
                Button("Forget this TV") {
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
        case .idle:
            VStack(spacing: 8) {
                Text("Disconnected").font(.caption).foregroundStyle(.secondary)
                Button("Reconnect") { state.session?.connect() }.controlSize(.small)
            }
        case .connecting:
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
                Button("Reconnect") { state.session?.connect() }
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

    // MARK: rename

    private var renameForm: some View {
        VStack(spacing: 8) {
            Text("Rename this TV").font(.caption).foregroundStyle(.secondary)
            TextField("Friendly name", text: $renameInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitRename)
            HStack {
                Button("Cancel") { renaming = false }
                    .controlSize(.small)
                Button("Save", action: commitRename)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private func commitRename() {
        if let device = state.session?.device {
            // Blank clears the nickname and reverts to the discovered name.
            state.discovery.rename(device, to: renameInput)
        }
        renaming = false
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
                RemoteButton(symbol: "arrow.uturn.backward", size: 38, key: .back) { send(.back) }
                RemoteButton(symbol: "house", size: 38, key: .home) { send(.home) }
                RemoteButton(symbol: "line.3.horizontal", size: 38, key: .menu) { send(.menu) }
            }
            // ~10 s skips flank play/pause — how modern streaming UIs seek.
            HStack(spacing: 24) {
                RemoteButton(symbol: "gobackward.10", size: 38, key: .skipBackward) { send(.skipBackward) }
                RemoteButton(symbol: "playpause.fill", size: 38, key: .playPause) { send(.playPause) }
                RemoteButton(symbol: "goforward.10", size: 38, key: .skipForward) { send(.skipForward) }
            }
            HStack(spacing: 24) {
                RemoteButton(symbol: "minus", size: 38, key: .volumeDown) { send(.volumeDown) }
                RemoteButton(symbol: "speaker.slash", size: 38, key: .mute) { send(.mute) }
                RemoteButton(symbol: "plus", size: 38, key: .volumeUp) { send(.volumeUp) }
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
    /// The remote key this button represents. When a keyboard shortcut fires
    /// the same key, the button flashes as if clicked. nil = never flashes
    /// from the keyboard (it has no shortcut).
    var key: RemoteKey? = nil
    let action: () -> Void
    @EnvironmentObject private var state: AppState
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
            // Flash when the matching keyboard shortcut fires.
            .onChange(of: state.keyPulse) { _, _ in
                guard let key, state.lastKey == key else { return }
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { pressed = false }
            }
    }
}

/// The circular d-pad: one ring with four directional segments around an OK
/// hub, driven by a single mouse-down gesture (press position → region).
/// Pressing highlights the touched wedge and fires instantly.
struct DPad: View {
    let send: (RemoteKey) -> Void
    @EnvironmentObject private var state: AppState

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
        // Flash the matching wedge/hub when an arrow or Enter key fires.
        .onChange(of: state.keyPulse) { _, _ in
            let region: Region?
            switch state.lastKey {
            case .up: region = .up
            case .down: region = .down
            case .left: region = .left
            case .right: region = .right
            case .ok: region = .ok
            default: region = nil   // non-d-pad key — ignore
            }
            guard let region else { return }
            pressed = region
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if pressed == region { pressed = nil }
            }
        }
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
    @Environment(\.offlinePreview) private var offlinePreview
    let app: TVApp
    let size: CGFloat
    let showName: Bool
    let action: () -> Void
    @State private var artworkURL: URL?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if !offlinePreview, let url = artworkURL ?? app.iconURL {
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
        .task(id: app.id) {
            guard !offlinePreview else { return }
            // The TV's own art wins; the store lookup is only for catalog
            // entries that came without one.
            if app.iconArt == nil {
                artworkURL = await AppIconResolver.artworkURL(for: app.name)
            }
        }
    }

    private var letterAvatar: some View {
        Text(String(app.name.prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

/// Keeps the popover's TOP edge fixed while its height changes.
///
/// macOS windows are anchored at their bottom-left corner, and the
/// MenuBarExtra panel resizes whenever SwiftUI content height changes
/// (connect status appearing, app icons loading, the grid expanding…).
/// Bottom anchored + taller = the window grows UPWARD, sliding under the
/// menu bar and off the screen. This invisible helper grabs the hosting
/// NSWindow, remembers where its top edge belongs (clamped to the screen's
/// usable area), and re-anchors it after every resize.
struct WindowTopPin: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        var topEdge: CGFloat?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't attached until after view installation.
        DispatchQueue.main.async {
            guard let window = view.window, context.coordinator.observer == nil else { return }
            let coordinator = context.coordinator

            // Snap the top edge back to (at most) the screen's usable top and
            // hold it there. Runs once at attach — the panel is reused across
            // opens and may still carry a displaced frame from last time —
            // and again after every content resize.
            func anchor() {
                let screenTop = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? .infinity
                let top = min(coordinator.topEdge ?? window.frame.maxY, screenTop)
                coordinator.topEdge = top
                var frame = window.frame
                guard abs(frame.maxY - top) > 0.5 else { return }
                frame.origin.y = top - frame.height
                window.setFrame(frame, display: true)
            }

            anchor()
            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { _ in anchor() }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
