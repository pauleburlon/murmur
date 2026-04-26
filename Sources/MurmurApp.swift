import SwiftUI
import ApplicationServices
import CoreGraphics
import ServiceManagement

private let projectRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL.deletingLastPathComponent()

// MARK: - Config

struct Config: Codable, Equatable {
    var modelSize:      String = "base"
    var language:       String = ""
    var vadFilter:      Bool   = true
    var beamSize:       Int    = 5
    var useGroq:        Bool   = false
    var groqApiKey:     String = ""
    var streamingMode:  Bool   = false
    var useClaudeFixup: Bool   = false
    var claudeApiKey:   String = ""
    var hotkeyCode:       Int    = 61
    var hotkeyIsModifier: Bool   = true
    var hotkeyModifiers:  Int    = 0
    var hotkeyLabel:      String = "Right ⌥"

    enum CodingKeys: String, CodingKey {
        case modelSize      = "model_size"
        case language
        case vadFilter      = "vad_filter"
        case beamSize       = "beam_size"
        case useGroq        = "use_groq"
        case groqApiKey     = "groq_api_key"
        case streamingMode  = "streaming_mode"
        case useClaudeFixup = "use_claude_fixup"
        case claudeApiKey   = "claude_api_key"
        case hotkeyCode       = "hotkey_code"
        case hotkeyIsModifier = "hotkey_is_modifier"
        case hotkeyModifiers  = "hotkey_modifiers"
        case hotkeyLabel      = "hotkey_label"
    }
}

private let configURL = projectRoot.appendingPathComponent("config.json")

private func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let cfg  = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return cfg
}

private func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    guard let data = try? enc.encode(cfg) else { return }
    try? data.write(to: configURL)
}

// MARK: - App state & drawer tab

enum AppState: Equatable {
    case starting, ready, recording, transcribing, done, error
}

enum DrawerTab: String, CaseIterable {
    case engine     = "Engine"
    case output     = "Output"
    case hotkey     = "Hotkey"
    case appearance = "Appearance"
}

extension Notification.Name {
    static let runBenchmark = Notification.Name("murmur.runBenchmark")
}

// MARK: - App entry

@main
struct MurmurApp: App {
    @StateObject private var runner       = ScriptRunner()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var hudManager   = HUDManager()

    var body: some Scene {
        WindowGroup {
            ThemedRoot(tm: themeManager) {
                ContentView(runner: runner)
                    .frame(minWidth: 480, idealWidth: 520,
                           minHeight: 560, idealHeight: 620)
                    .onAppear {
                        runner.start()
                        hudManager.attach(to: runner)
                    }
                    .environmentObject(themeManager)
            }
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarMenu(runner: runner)
        } label: {
            MenuBarIcon(state: runner.appState)
        }
    }
}

// MARK: - ScriptRunner

final class ScriptRunner: ObservableObject {
    @Published var status:         String   = "Starting…"
    @Published var appState:       AppState = .starting
    @Published var lastText:       String   = ""
    @Published var elapsedSeconds: Int      = 0
    @Published var config: Config = loadConfig() {
        didSet {
            saveConfig(config)
            if config.modelSize != oldValue.modelSize ||
               config.useGroq   != oldValue.useGroq { restart() }
            let hotkeyChanged = config.hotkeyCode       != oldValue.hotkeyCode ||
                               config.hotkeyIsModifier != oldValue.hotkeyIsModifier ||
                               config.hotkeyModifiers  != oldValue.hotkeyModifiers
            if hotkeyChanged { reinstallHotkey() }
        }
    }

    private var process:        Process?
    private var stdinHandle:    FileHandle?
    private var eventMonitors:  [Any] = []
    private var isHotkeyDown    = false
    private var streamedText    = ""
    private var resetTimer:     Timer?
    private var elapsedTimer:   Timer?

    func start() {
        saveConfig(config)
        let backend = projectRoot.appendingPathComponent("murmur_backend").path

        guard FileManager.default.fileExists(atPath: backend) else {
            status = "murmur_backend not found"; appState = .error; return
        }

        let p = Process()
        p.executableURL      = URL(fileURLWithPath: backend)
        p.arguments          = []
        p.currentDirectoryURL = projectRoot

        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = outPipe
        p.standardInput  = inPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let raw = fh.availableData
            guard let self,
                  let chunk = String(data: raw, encoding: .utf8),
                  !chunk.isEmpty else { return }
            for line in chunk.components(separatedBy: "\n") {
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async { self.handle(line) }
            }
        }

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.status = "Script exited — restart to reconnect"
                self.appState = .error
            }
        }

        process = p
        do { try p.run() } catch {
            status = "Failed to launch: \(error.localizedDescription)"
            appState = .error; return
        }
        if eventMonitors.isEmpty { setupHotkey() }
    }

    func toggleRecording() {
        switch appState {
        case .recording:       send("STOP")
        case .ready, .done:    send("START")
        default: break
        }
    }

    private func restart() {
        status = "Loading \(config.modelSize) model…"
        appState = .starting
        process?.terminate()
        stdinHandle = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
    }

    private func setupHotkey() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            status = "Grant Accessibility in System Settings, then relaunch"
            appState = .error
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    t.invalidate()
                    DispatchQueue.main.async {
                        self.installMonitor()
                        self.status = "Hold \(self.config.hotkeyLabel) to dictate"
                        self.appState = .ready
                    }
                }
            }
            return
        }
        installMonitor()
    }

    private func installMonitor() {
        let code = UInt16(config.hotkeyCode)

        if config.hotkeyIsModifier {
            let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, event.keyCode == code else { return }
                let isDown: Bool
                switch code {
                case 58, 61: isDown = event.modifierFlags.contains(.option)
                case 55, 54: isDown = event.modifierFlags.contains(.command)
                case 59, 62: isDown = event.modifierFlags.contains(.control)
                case 56, 60: isDown = event.modifierFlags.contains(.shift)
                default:     isDown = false
                }
                guard isDown != self.isHotkeyDown else { return }
                self.isHotkeyDown = isDown
                self.send(isDown ? "START" : "STOP")
            }
            if let m { eventMonitors.append(m) }
        } else {
            let requiredMods = UInt(config.hotkeyModifiers)
            let downMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == code, !self.isHotkeyDown else { return }
                let mods = event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue
                guard mods == requiredMods else { return }
                self.isHotkeyDown = true
                self.send("START")
            }
            let upMon = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, event.keyCode == code, self.isHotkeyDown else { return }
                self.isHotkeyDown = false
                self.send("STOP")
            }
            if let m = downMon { eventMonitors.append(m) }
            if let m = upMon   { eventMonitors.append(m) }
        }
    }

    private func reinstallHotkey() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors = []
        isHotkeyDown = false
        if AXIsProcessTrusted() { installMonitor() }
    }

    func applyHotkey(code: Int, isModifier: Bool, modifiers: Int, label: String) {
        var updated              = config
        updated.hotkeyCode       = code
        updated.hotkeyIsModifier = isModifier
        updated.hotkeyModifiers  = modifiers
        updated.hotkeyLabel      = label
        config = updated   // single assignment → didSet fires once
    }

    private func send(_ cmd: String) {
        guard let data = (cmd + "\n").data(using: .utf8) else { return }
        stdinHandle?.write(data)
    }

    private func handle(_ line: String) {
        if line.hasPrefix("→ ") {
            let text = String(line.dropFirst(2))
            lastText = text
            appState = .done
            status   = "Pasted ✓"

            let delta = streamedText.isEmpty ? text : String(text.dropFirst(streamedText.count))
            streamedText = ""
            if !delta.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(delta, forType: .string)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pasteNow() }
            }

            resetTimer?.invalidate()
            resetTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.appState == .done else { return }
                    self.appState = .ready
                    self.status   = "Hold \(self.config.hotkeyLabel) to dictate"
                }
            }

        } else if line.hasPrefix("◐ ") {
            let fullText = String(line.dropFirst(2))
            let delta = String(fullText.dropFirst(streamedText.count))
            lastText = fullText; streamedText = fullText
            if !delta.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(delta, forType: .string)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pasteNow() }
            }

        } else if line.hasPrefix("● ") {
            streamedText = ""
            appState = .recording
            status   = "Recording…"
            elapsedSeconds = 0
            elapsedTimer?.invalidate()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.elapsedSeconds += 1 }
            }

        } else if line.hasPrefix("■ ") {
            elapsedTimer?.invalidate(); elapsedTimer = nil
            appState = .transcribing
            status   = "Transcribing…"

        } else if line.hasPrefix("Transcribing") || line.hasPrefix("Fixing with Claude") {
            status = line
            appState = .transcribing

        } else if line == "Model ready." {
            status = "Hold \(self.config.hotkeyLabel) to dictate"
            appState = .ready

        } else if line.hasPrefix("(no speech") {
            status = "No speech detected"
            appState = .ready
        }
    }

    private func pasteNow() {
        let src = CGEventSource(stateID: .hidSystemState)
        let v: CGKeyCode = 0x09
        let dn = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        dn?.flags = .maskCommand; up?.flags = .maskCommand
        dn?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    deinit {
        process?.terminate()
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
    }
}

// MARK: - Waveform bars

struct WaveformBars: View {
    let color:    Color
    let height:   CGFloat
    var barCount: Int = 38

    @State private var amps:   [CGFloat] = []
    @State private var ticker: Timer?

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: max(4, (i < amps.count ? amps[i] : 0.1) * height))
            }
        }
        .frame(height: height)
        .onAppear {
            amps = (0..<barCount).map { _ in CGFloat.random(in: 0.1...0.4) }
            ticker = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.08)) {
                    amps = amps.map { cur in cur * 0.6 + CGFloat.random(in: 0.05...1.0) * 0.4 }
                }
            }
        }
        .onDisappear { ticker?.invalidate(); ticker = nil }
    }
}

// MARK: - Recording surface

struct RecordingSurface: View {
    @Environment(\.theme) private var theme
    @ObservedObject var runner: ScriptRunner

    @State private var micPulse = false

    private var engineLabel: String {
        runner.config.useGroq ? "groq · large-v3" : "local · \(runner.config.modelSize)"
    }

    private var pillColor: Color {
        switch runner.appState {
        case .ready:        return theme.ok
        case .recording:    return theme.rec
        case .transcribing: return Color(red: 1, green: 0.55, blue: 0)
        case .done:         return theme.ok
        case .error:        return theme.rec
        case .starting:     return theme.ink4
        }
    }

    private var pillLabel: String {
        switch runner.appState {
        case .starting:     return "Starting"
        case .ready:        return "Ready"
        case .recording:    return "Recording"
        case .transcribing: return "Processing"
        case .done:         return "Done"
        case .error:        return "Error"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.paper2)
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.hair, lineWidth: 0.5)

            VStack(spacing: 0) {
                // Top row
                HStack {
                    // Status pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(pillColor)
                            .frame(width: 6, height: 6)
                        Text(pillLabel.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.ink3)
                            .tracking(0.6)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(theme.paper)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.hair, lineWidth: 0.5))

                    Spacer()

                    Text(engineLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.ink4)
                }
                .padding(.horizontal, 16).padding(.top, 14)

                Spacer()

                centerContent
                    .padding(.horizontal, 24)

                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: runner.appState)
    }

    @ViewBuilder
    private var centerContent: some View {
        switch runner.appState {

        case .starting:
            VStack(spacing: 12) {
                ProgressView().scaleEffect(0.9)
                Text("Loading model…")
                    .font(.callout).foregroundStyle(theme.ink3)
            }

        case .ready:
            VStack(spacing: 20) {
                micButton
                Text("Press Space or click to record")
                    .font(.system(size: 12)).foregroundStyle(theme.ink4)
            }

        case .recording:
            VStack(spacing: 16) {
                WaveformBars(color: theme.rec, height: 100)
                HStack(spacing: 6) {
                    Circle().fill(theme.rec).frame(width: 7, height: 7)
                    Text(String(format: "%d:%02d",
                                runner.elapsedSeconds / 60,
                                runner.elapsedSeconds % 60))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.rec)
                }
            }

        case .transcribing:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(theme.accent)
                Text(runner.status)
                    .font(.callout).foregroundStyle(theme.ink3)
                if !runner.lastText.isEmpty {
                    Text(runner.lastText)
                        .font(.body).foregroundStyle(theme.ink2)
                        .multilineTextAlignment(.center)
                        .lineLimit(4).frame(maxWidth: .infinity)
                }
            }

        case .done:
            VStack(spacing: 16) {
                Text(runner.lastText)
                    .font(.body).foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(6).frame(maxWidth: .infinity)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.ok).font(.system(size: 13))
                    Text("Pasted ✓")
                        .font(.system(size: 12)).foregroundStyle(theme.ink4)
                }
            }

        case .error:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.rec).font(.system(size: 24))
                Text(runner.status)
                    .font(.callout).foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var micButton: some View {
        Button { runner.toggleRecording() } label: {
            ZStack {
                Circle()
                    .stroke(theme.accent.opacity(0.3), lineWidth: 2)
                    .frame(width: 110, height: 110)
                    .scaleEffect(micPulse ? 1.22 : 1.0)
                    .opacity(micPulse ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                        value: micPulse
                    )

                Circle()
                    .fill(LinearGradient(
                        colors: [theme.accent, theme.accentDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 88, height: 88)
                    .shadow(color: theme.accent.opacity(0.4), radius: 18, y: 8)

                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .onAppear { micPulse = true }
    }
}

// MARK: - Tile row

struct TileRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject var runner: ScriptRunner
    @Binding var drawerTab: DrawerTab?

    var body: some View {
        HStack(spacing: 8) {
            tile(icon: "cpu",
                 label: runner.config.useGroq ? "Cloud" : "On-device",
                 value: runner.config.useGroq ? "Groq" : runner.config.modelSize,
                 tab: .engine)
            tile(icon: "globe",
                 label: "Language",
                 value: languageName(runner.config.language),
                 tab: .engine)
            tile(icon: "sparkles",
                 label: "Polish",
                 value: runner.config.useClaudeFixup ? "Claude" : "Off",
                 active: runner.config.useClaudeFixup,
                 tab: .output)
        }
    }

    private func tile(icon: String, label: String, value: String,
                      active: Bool = false, tab: DrawerTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                drawerTab = drawerTab == tab ? nil : tab
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(active ? theme.accent : theme.ink3)

                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(active ? theme.accentSoft : theme.paper2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? theme.accent.opacity(0.35) : theme.hair, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "de": return "German"
        case "nl": return "Dutch"
        default:   return "Auto"
        }
    }
}

// MARK: - Settings drawer

struct SettingsDrawer: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var themeManager: ThemeManager
    @Binding var drawerTab: DrawerTab?
    @ObservedObject var runner: ScriptRunner

    private let models    = ["tiny", "base", "small", "medium", "large-v3"]
    private let languages = ["", "en", "de", "nl"]

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.hair2)
                .frame(width: 36, height: 4)
                .padding(.top, 10).padding(.bottom, 2)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(DrawerTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { drawerTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12,
                                          weight: drawerTab == tab ? .semibold : .regular))
                            .foregroundStyle(drawerTab == tab ? theme.accent : theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 10) {
                    switch drawerTab {
                    case .engine:     engineTab
                    case .output:     outputTab
                    case .hotkey:     hotkeyTab
                    case .appearance: appearanceTab
                    case nil:         EmptyView()
                    }
                }
                .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.paper)
                .shadow(color: .black.opacity(0.14), radius: 24, y: -6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.hair, lineWidth: 0.5)
        )
    }

    // ── Engine

    @ViewBuilder private var engineTab: some View {
        row("Language") {
            Picker("", selection: $runner.config.language) {
                ForEach(languages, id: \.self) { lang in
                    Text(lang.isEmpty ? "Auto"
                         : lang == "en" ? "English"
                         : lang == "de" ? "German"
                         : lang == "nl" ? "Dutch" : lang).tag(lang)
                }
            }.pickerStyle(.menu).labelsHidden()
        }
        Divider()
        row("Use Groq") {
            Toggle("", isOn: $runner.config.useGroq).labelsHidden()
        }
        if runner.config.useGroq {
            Divider()
            row("Groq key") {
                SecureField("gsk_…", text: $runner.config.groqApiKey)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            }
        } else {
            Divider()
            row("Model", hint: "restarts on change") {
                Picker("", selection: $runner.config.modelSize) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            Divider()
            row("Beam size", hint: "higher = slower but more accurate") {
                Stepper("\(runner.config.beamSize)",
                        value: $runner.config.beamSize, in: 1...10)
            }
            Divider()
            row("VAD filter", hint: "skip silent segments") {
                Toggle("", isOn: $runner.config.vadFilter).labelsHidden()
            }
            Divider()
            row("Benchmark", hint: "time all models on your Mac") {
                Button("Run") {
                    NotificationCenter.default.post(name: .runBenchmark, object: nil)
                }.buttonStyle(.bordered)
            }
        }
    }

    // ── Output

    @ViewBuilder private var outputTab: some View {
        row("Streaming", hint: "paste text as you pause") {
            Toggle("", isOn: $runner.config.streamingMode).labelsHidden()
        }
        Divider()
        row("Fix with Claude", hint: "clean up punctuation & errors") {
            Toggle("", isOn: $runner.config.useClaudeFixup).labelsHidden()
        }
        if runner.config.useClaudeFixup {
            Divider()
            row("Anthropic key") {
                SecureField("sk-ant-…", text: $runner.config.claudeApiKey)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            }
        }
    }

    // ── Hotkey

    private var hotkeyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HotkeyRecorder(currentLabel: runner.config.hotkeyLabel) { code, isModifier, mods, label in
                runner.applyHotkey(code: code, isModifier: isModifier, modifiers: mods, label: label)
            }
            Text("Hold a modifier key (⌥ ⌘ ⌃ ⇧) for press-and-hold mode, or press any other key for toggle mode. Esc cancels.")
                .font(.caption2).foregroundStyle(theme.ink4)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            row("Launch at Login", hint: "start Murmur automatically on login") {
                Toggle("", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.isEnabled = $0 }
                )).labelsHidden()
            }
        }
    }

    // ── Appearance

    private var appearanceTab: some View {
        VStack(spacing: 4) {
            ForEach(themePresets) { preset in
                PresetRow(
                    preset: preset,
                    isSelected: themeManager.accentHex.lowercased() == preset.accent.lowercased(),
                    onSelect: { themeManager.accentHex = preset.accent }
                )
            }
            Divider().padding(.top, 4)
            row("Custom color") {
                ColorPicker("", selection: Binding(
                    get: { themeManager.accentColor },
                    set: { themeManager.accentColor = $0 }
                )).labelsHidden()
            }
        }
    }

    // ── Helper

    private func row<C: View>(_ label: String, hint: String = "",
                               @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout).foregroundStyle(theme.ink)
                if !hint.isEmpty {
                    Text(hint).font(.caption2).foregroundStyle(theme.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 118, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Benchmark

struct BenchmarkResultRow: Identifiable {
    let id = UUID()
    let model: String; let seconds: Double; let text: String
}

struct BenchmarkSheet: View {
    @Environment(\.theme) private var theme
    @Binding var isPresented: Bool

    @State private var phase        = "ready"
    @State private var countdown    = 0
    @State private var currentModel = ""
    @State private var currentIndex = 0
    @State private var errorMsg     = ""
    @State private var results: [BenchmarkResultRow] = []
    @State private var process: Process?

    private let example = "The deadline is next Friday at three pm — please send the final report to the whole team."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Model Benchmark").font(.title3.bold()).foregroundStyle(theme.ink)
                Spacer()
                Button("Close") { process?.terminate(); isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(theme.ink3)
            }

            if phase == "ready" {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Records 6 seconds, then tests all 5 models.")
                        .font(.callout).foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Say this:").font(.caption.bold()).foregroundStyle(theme.ink3)
                        Text("\"\(example)\"").font(.body.italic())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button("Start Recording") { runBenchmark() }
                        .buttonStyle(.borderedProminent).tint(theme.accent)
                        .frame(maxWidth: .infinity)
                }

            } else if phase == "countdown" {
                VStack(spacing: 16) {
                    Text("\"\(example)\"").font(.body.italic())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(countdown)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.rec).frame(maxWidth: .infinity)
                    Text("Recording…").font(.caption).foregroundStyle(theme.ink3)
                }

            } else if phase == "testing" {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Testing \(currentIndex) of 5…").font(.callout).foregroundStyle(theme.ink3)
                    Text(currentModel).font(.title3.bold().monospaced()).foregroundStyle(theme.ink)
                    ProgressView(value: Double(currentIndex - 1), total: 5).tint(theme.accent)
                    if !results.isEmpty { Divider(); resultsTable }
                }

            } else if phase == "done" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Results — lower is faster")
                        .font(.caption.bold()).foregroundStyle(theme.ink3)
                    resultsTable
                }

            } else if phase == "error" {
                Text(errorMsg).font(.callout).foregroundStyle(theme.rec)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 420).fixedSize(horizontal: false, vertical: true)
        .onDisappear { process?.terminate() }
    }

    private var resultsTable: some View {
        VStack(spacing: 0) {
            ForEach(results) { r in
                HStack(spacing: 10) {
                    Text(r.model).font(.caption.monospaced()).foregroundStyle(theme.ink)
                        .frame(width: 72, alignment: .leading)
                    Text(String(format: "%.1fs", r.seconds))
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(r.seconds < 2 ? theme.ok
                                         : r.seconds < 5 ? Color(red: 1, green: 0.5, blue: 0)
                                         : theme.rec)
                        .frame(width: 38, alignment: .trailing)
                    Text(r.text.isEmpty ? "(no speech)" : r.text)
                        .font(.caption)
                        .foregroundStyle(r.text.isEmpty ? theme.ink4 : theme.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                if r.id != results.last?.id { Divider() }
            }
        }
    }

    private func runBenchmark() {
        phase = "countdown"; countdown = 6; results = []; currentIndex = 0
        let benchmark = projectRoot.appendingPathComponent("murmur_benchmark").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: benchmark)
        p.arguments = []; p.currentDirectoryURL = projectRoot
        let outPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = outPipe; process = p

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let raw = fh.availableData
            guard let chunk = String(data: raw, encoding: .utf8), !chunk.isEmpty else { return }
            for line in chunk.components(separatedBy: "\n") {
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async { handleLine(line) }
            }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                if phase != "done" { phase = "error"; errorMsg = "Benchmark exited unexpectedly." }
            }
        }
        do { try p.run() } catch { phase = "error"; errorMsg = error.localizedDescription }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("COUNTDOWN "), let n = Int(line.dropFirst(10)) { countdown = n }
        else if line.hasPrefix("BENCHMARK_MODEL ") { currentModel = String(line.dropFirst(16)); currentIndex += 1; phase = "testing" }
        else if line.hasPrefix("BENCHMARK_RESULT "),
                let data = String(line.dropFirst(17)).data(using: .utf8),
                let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let m = obj["model"] as? String, let s = obj["seconds"] as? Double, let t = obj["text"] as? String {
            results.append(BenchmarkResultRow(model: m, seconds: s, text: t))
        } else if line == "BENCHMARK_DONE" { phase = "done" }
        else if line.hasPrefix("ERROR") { phase = "error"; errorMsg = line }
    }
}

// MARK: - HotkeyRecorder

struct HotkeyRecorder: View {
    let currentLabel: String
    let onSelect: (Int, Bool, Int, String) -> Void

    @Environment(\.theme) private var theme
    @State private var isRecording    = false
    @State private var recordMonitors: [Any] = []

    var body: some View {
        HStack(spacing: 8) {
            Text(isRecording ? "Press a key…" : currentLabel)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isRecording ? theme.accent : theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isRecording ? theme.accentSoft : theme.paper2)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isRecording ? theme.accent.opacity(0.6) : theme.hair,
                                lineWidth: isRecording ? 1.5 : 0.5)
                )
                .animation(.easeInOut(duration: 0.15), value: isRecording)
            Spacer()
            Button(isRecording ? "Cancel" : "Change") {
                isRecording ? stopRecording() : startRecording()
            }
            .buttonStyle(.bordered)
        }
    }

    private func startRecording() {
        isRecording = true

        let handleFlags: (NSEvent) -> Void = { event in
            guard Self.modifierKeyCodes.contains(event.keyCode) else { return }
            guard Self.isModifierGoingDown(event) else { return }
            let code = Int(event.keyCode)
            let lbl  = Self.modifierLabel(event.keyCode)
            DispatchQueue.main.async {
                onSelect(code, true, 0, lbl)
                stopRecording()
            }
        }

        let handleKey: (NSEvent) -> Void = { event in
            if event.keyCode == 53 { DispatchQueue.main.async { stopRecording() }; return }
            let code = Int(event.keyCode)
            let mods = Int(event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue)
            let lbl  = Self.regularKeyLabel(event)
            DispatchQueue.main.async {
                onSelect(code, false, mods, lbl)
                stopRecording()
            }
        }

        // Global: fires when another app is frontmost
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags) { recordMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown,      handler: handleKey)   { recordMonitors.append(m) }

        // Local: fires when Murmur itself is frontmost
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handleFlags($0); return $0 }) { recordMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown,      handler: { handleKey($0);   return $0 }) { recordMonitors.append(m) }
    }

    private func stopRecording() {
        isRecording = false
        recordMonitors.forEach { NSEvent.removeMonitor($0) }
        recordMonitors = []
    }

    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func isModifierGoingDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 58, 61: return event.modifierFlags.contains(.option)
        case 55, 54: return event.modifierFlags.contains(.command)
        case 59, 62: return event.modifierFlags.contains(.control)
        case 56, 60: return event.modifierFlags.contains(.shift)
        case 57:     return event.modifierFlags.contains(.capsLock)
        default:     return false
        }
    }

    static func modifierLabel(_ code: UInt16) -> String {
        switch code {
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        case 63: return "Fn"
        case 57: return "Caps Lock"
        default: return "Key \(code)"
        }
    }

    static func regularKeyLabel(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if let ch = event.charactersIgnoringModifiers?.uppercased(), !ch.isEmpty {
            parts.append(ch)
        } else {
            parts.append("[\(event.keyCode)]")
        }
        return parts.joined()
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var runner: ScriptRunner
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme

    @State private var drawerTab:    DrawerTab? = nil
    @State private var showBenchmark = false
    @State private var copyFlash     = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Main column
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 16)

                RecordingSurface(runner: runner)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 280)

                // Last transcript strip — fades in when there's text and we're back to ready
                if !runner.lastText.isEmpty && runner.appState == .ready {
                    lastTranscriptStrip
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                TileRow(runner: runner, drawerTab: $drawerTab)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }

            // ── Drawer overlay
            if drawerTab != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            drawerTab = nil
                        }
                    }

                SettingsDrawer(drawerTab: $drawerTab, runner: runner)
                    .frame(height: 320)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(theme.canvas)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: runner.appState)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: drawerTab)
        .onReceive(NotificationCenter.default.publisher(for: .runBenchmark)) { _ in
            drawerTab = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showBenchmark = true }
        }
        .sheet(isPresented: $showBenchmark) {
            BenchmarkSheet(isPresented: $showBenchmark)
        }
    }

    // ── Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [theme.accent, theme.accentDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Murmur")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text("Hold \(runner.config.hotkeyLabel) to dictate")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink3)
            }

            Spacer()

            // Appearance shortcut
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    drawerTab = drawerTab == .appearance ? nil : .appearance
                }
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 13))
                    .foregroundStyle(drawerTab == .appearance ? theme.accent : theme.ink4)
            }
            .buttonStyle(.plain)
        }
    }

    // ── Last transcript strip

    private var lastTranscriptStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(runner.lastText)
                .font(.callout)
                .foregroundStyle(theme.ink2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runner.lastText, forType: .string)
                withAnimation { copyFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation { copyFlash = false }
                }
            } label: {
                Image(systemName: copyFlash ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copyFlash ? theme.ok : theme.accent)
        }
        .padding(12)
        .background(theme.paper2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.hair, lineWidth: 0.5))
    }
}

// MARK: - Setting row (used by BenchmarkSheet and PresetRow)

struct SettingRow<Control: View>: View {
    let label: String
    let hint:  String
    var info:  String? = nil
    @ViewBuilder let control: () -> Control

    @Environment(\.theme) private var theme
    @State private var showInfo = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(label).font(.callout).foregroundStyle(theme.ink)
                    if let info {
                        Button { showInfo.toggle() } label: {
                            Image(systemName: "info.circle")
                                .font(.caption).foregroundStyle(theme.ink4)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            Text(info).font(.caption).foregroundStyle(theme.ink)
                                .padding(12).frame(maxWidth: 220)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !hint.isEmpty {
                    Text(hint).font(.caption2).foregroundStyle(theme.ink4)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 130, alignment: .leading)
            control()
        }
    }
}

// MARK: - Menu Bar

struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(state == .recording ? .multicolor : .monochrome)
    }

    private var iconName: String {
        switch state {
        case .recording:    return "waveform.circle.fill"
        case .transcribing: return "ellipsis.circle"
        case .error:        return "exclamationmark.circle"
        default:            return "waveform"
        }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var runner: ScriptRunner

    var body: some View {
        Text(statusLabel)
            .foregroundStyle(.secondary)

        Divider()

        Button(runner.appState == .recording ? "Stop Recording" : "Start Recording") {
            runner.toggleRecording()
        }
        .disabled(![.ready, .recording, .done].contains(runner.appState))

        Divider()

        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { !($0 is NSPanel) }?
                .makeKeyAndOrderFront(nil)
        }

        Divider()

        Button("Quit Murmur") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusLabel: String {
        switch runner.appState {
        case .starting:     return "Starting…"
        case .ready:        return "Ready"
        case .recording:    return "Recording…"
        case .transcribing: return "Transcribing…"
        case .done:         return "Done"
        case .error:        return "Error"
        }
    }
}

// MARK: - Launch at Login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                print("LaunchAtLogin error: \(error)", to: &standardError)
            }
        }
    }
}

private var standardError = StandardErrorStream()
private struct StandardErrorStream: TextOutputStream {
    mutating func write(_ string: String) {
        fputs(string, stderr)
    }
}
