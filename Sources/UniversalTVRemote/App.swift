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
        sessionForwarder = initialSession?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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

enum RemotePanel { case remote, devices, settings }

/// Expansion changes both SwiftUI content and the AppKit panel's size.
/// Apply it as one transaction so intermediate transition layouts cannot
/// briefly shrink the entire remote before the grid is inserted.
final class AppListExpansion: ObservableObject {
    @Published private(set) var isExpanded: Bool

    init(isExpanded: Bool = false) { self.isExpanded = isExpanded }

    func toggle() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { isExpanded.toggle() }
    }
}

struct RemoteView: View {
    @EnvironmentObject private var state: AppState
    @State private var pinInput = ""
    @State private var textInput = ""
    @FocusState private var typingFocused: Bool
    @FocusState private var pairingFocused: Bool
    // Manual "Add TV by IP" form state (shown in place of the status area).
    @State private var addingManually = false
    @State private var manualBrand: TVBrand = .fireTV
    @State private var manualIP = ""
    /// Whether the app row shows the full catalog or just the top few.
    @StateObject private var appListExpansion: AppListExpansion
    // Inline "Rename this TV" form state.
    @State private var renaming = false
    @State private var renameInput = ""
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800
    private let previewHeight: CGFloat?
    @State private var panel: RemotePanel = .remote

    init(appsExpanded: Bool = false, availableHeight: CGFloat? = nil, panel: RemotePanel = .remote,
         appListExpansion: AppListExpansion? = nil) {
        _appListExpansion = .init(wrappedValue: appListExpansion ?? AppListExpansion(isExpanded: appsExpanded))
        _panel = .init(initialValue: panel)
        previewHeight = availableHeight
    }

    private var maximumBodyHeight: CGFloat {
        max(180, (previewHeight ?? screenHeight) - 100)
    }

    private var capturesTextInput: Bool {
        panel != .remote || addingManually || renaming || typingFocused || pairingFocused
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            ViewThatFits(in: .vertical) {
                bodyContent.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    bodyContent
                }
                .scrollIndicators(.never)
                .frame(height: maximumBodyHeight)
            }
            .frame(maxHeight: maximumBodyHeight)
        }
        .padding(16)
        .frame(width: 272)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .background(GeometryReader { geometry in
            WindowTopPin(contentSize: geometry.size) {
                if abs(screenHeight - $0) > 0.5 { screenHeight = $0 }
            }
        })
        .preferredColorScheme(.dark)
        .environment(\.offlinePreview, !state.startsDiscovery)
        .onAppear {
            if case .awaitingPairing(.pin) = state.session?.state { pairingFocused = true }
            state.textFieldFocused = capturesTextInput
            guard state.startsDiscovery else { return }
            state.discovery.scan()
            state.installKeyMonitors()
        }
        .onDisappear { state.removeKeyMonitors(); state.textFieldFocused = false }
        .onChange(of: capturesTextInput) { _, focused in state.textFieldFocused = focused }
        .onChange(of: state.session?.state) { _, newState in
            pinInput = ""
            if case .awaitingPairing(.pin) = newState { pairingFocused = true }
            else { pairingFocused = false }
        }
    }

    private var bodyContent: some View {
        VStack(spacing: 14) {
            if addingManually {
                addTVForm
            } else if renaming {
                renameForm
            } else if panel == .devices {
                deviceList
            } else if panel == .settings {
                settingsPanel
            } else {
                statusSection
                if case .connected = state.session?.state {
                    dpad
                    controlRows
                    keyboardField
                    appShortcuts
                } else if state.session == nil {
                    emptyState
                }
            }
        }
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

            Button {
                addingManually = false
                renaming = false
                panel = panel == .settings ? .remote : .settings
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(panel == .settings ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var devicePicker: some View {
        Button {
            addingManually = false
            renaming = false
            panel = panel == .devices ? .remote : .devices
        } label: {
            HStack(spacing: 4) {
                Text(state.session.map(displayName) ?? "Choose a TV")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: panel == .devices ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func panelHeading(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button { panel = .remote } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back to remote")
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeading("Your TVs")
            if state.discovery.devices.isEmpty {
                Text("No TVs found yet").font(.caption).foregroundStyle(.secondary)
            }
            if !state.discovery.availableDevices.isEmpty {
                Text("Discovered on this network").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.discovery.availableDevices) { device in
                        deviceMenuItem(device)
                    }
            }
            if !state.discovery.savedDevices.isEmpty {
                Text("Saved · not currently discovered").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.discovery.savedDevices) { device in
                        deviceMenuItem(device)
                    }
            }
            Divider()
            Button("Add TV by IP…") { addingManually = true }
                .buttonStyle(.bordered)
        }
    }

    private func deviceMenuItem(_ device: DiscoveredTV) -> some View {
        Button {
            state.select(device)
            panel = .remote
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.brand.symbolName).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.discovery.displayName(for: device))
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(device.brand.displayName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if state.session?.device.id == device.id {
                    Image(systemName: "checkmark").foregroundStyle(.blue)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    /// The name to show for a session's TV: the user's custom nickname if set,
    /// otherwise the discovered name.
    private func displayName(_ session: RemoteSession) -> String {
        state.discovery.displayName(for: session.device)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeading("Settings")
            if let session = state.session {
                settingsRow("Rename", symbol: "pencil") {
                    renameInput = displayName(session)
                    renaming = true
                }
                settingsRow("Re-pair", symbol: "key") { session.forgetAndRepair(); panel = .remote }
                settingsRow("Forget this TV", symbol: "trash", tint: .red) {
                    session.disconnect()
                    state.discovery.forget(session.device)
                    state.session = nil
                    panel = .devices
                }
                Divider()
            }
            LaunchAtLoginToggle()
                .toggleStyle(.switch)
                .controlSize(.small)
            Divider()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption).foregroundStyle(.secondary)
            settingsRow("Quit Universal TV Remote", symbol: "rectangle.portrait.and.arrow.right") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func settingsRow(_ title: String, symbol: String, tint: Color = .primary,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
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
            VStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.blue)
                VStack(spacing: 5) {
                    Text("Pair your TV")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Enter the \(digits)-\(digits == 4 ? "digit PIN" : "character code") shown on your TV.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                }
                TextField(digits == 4 ? "0000" : "000000", text: $pinInput)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(pairingFocused ? Color.blue : Color.white.opacity(0.12), lineWidth: pairingFocused ? 2 : 1))
                        .focused($pairingFocused)
                        .onSubmit(submitPIN)
                        .onChange(of: pinInput) { _, value in
                            pinInput = String(value.uppercased().filter {
                                digits == 4 ? $0.isASCII && $0.isNumber : $0.isHexDigit
                            }.prefix(digits))
                        }
                    Button(action: submitPIN) {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(pinInput.count != digits)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
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
            .pickerStyle(.radioGroup)
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
        panel = .settings
    }

    private func addManualTV() {
        let host = manualIP.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let device = state.discovery.addManual(brand: manualBrand, host: host)
        addingManually = false
        manualIP = ""
        state.select(device)
        panel = .remote
    }

    private func submitPIN() {
        guard case .awaitingPairing(.pin(let digits)) = state.session?.state,
              pinInput.count == digits else { return }
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
                if !appListExpansion.isExpanded {
                    // Collapsed: just the top few, icon-only.
                    HStack(spacing: 8) {
                        ForEach(session.apps.prefix(5)) { app in
                            AppIconButton(app: app, size: 32, showName: false) {
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
            appListExpansion.toggle()
        } label: {
            Image(systemName: appListExpansion.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(appListExpansion.isExpanded ? "Show fewer apps" : "Show all apps")
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
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(height: 28, alignment: .top)
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

/// Resize to the measured SwiftUI content, then keep the top under the menu bar.
/// Coalescing updates avoids changing the frame inside AppKit's resize notification.
struct WindowTopPin: NSViewRepresentable {
    let contentSize: CGSize
    var onScreenHeight: ((CGFloat) -> Void)? = nil

    final class AnchorView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }

    final class Coordinator {
        var desiredSize: CGSize = .zero
        var topEdge: CGFloat?
        var pending = false
        var onScreenHeight: ((CGFloat) -> Void)?

        func synchronize(_ window: NSWindow) {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.pending = false
                guard let window, self.desiredSize.width > 0, self.desiredSize.height > 0 else { return }
                let screenTop = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? window.frame.maxY
                if let height = (window.screen ?? NSScreen.main)?.visibleFrame.height {
                    self.onScreenHeight?(height)
                }
                let top = min(self.topEdge ?? window.frame.maxY, screenTop)
                self.topEdge = top
                let size = window.contentView?.bounds.size ?? .zero
                if abs(size.width - self.desiredSize.width) > 0.5 || abs(size.height - self.desiredSize.height) > 0.5 {
                    window.setContentSize(self.desiredSize)
                }
                if abs(window.frame.maxY - top) > 0.5 {
                    window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        let coordinator = context.coordinator
        coordinator.desiredSize = contentSize
        coordinator.onScreenHeight = onScreenHeight
        view.attached = { [weak coordinator] window in coordinator?.synchronize(window) }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.desiredSize = contentSize
        context.coordinator.onScreenHeight = onScreenHeight
        if let window = view.window { context.coordinator.synchronize(window) }
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
