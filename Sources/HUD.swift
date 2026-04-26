import SwiftUI
import AppKit
import Combine

// MARK: - HUD panel manager

final class HUDManager: ObservableObject {
    private var panel:        NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var hideWork:     DispatchWorkItem?

    func attach(to runner: ScriptRunner) {
        buildPanel(runner: runner)
        runner.$appState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.react(to: state) }
            .store(in: &cancellables)
    }

    private func buildPanel(runner: ScriptRunner) {
        let (w, h): (CGFloat, CGFloat) = (320, 84)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       true
        )
        p.level              = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.alphaValue         = 0
        p.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: HUDView(runner: runner))
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        p.contentView = hosting

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(
                x: sf.minX + (sf.width  - w) / 2,
                y: sf.minY + 110
            ))
        }

        panel = p
    }

    private func react(to state: AppState) {
        switch state {
        case .recording:
            hideWork?.cancel()
            showHUD()
        case .done:
            hideWork?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.hideHUD() }
            hideWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
        default:
            break
        }
    }

    private func showHUD() {
        guard let p = panel else { return }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    private func hideHUD() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.40
            p.animator().alphaValue = 0
        } completionHandler: {
            p.orderOut(nil)
        }
    }
}

// MARK: - HUD view

struct HUDView: View {
    @ObservedObject var runner: ScriptRunner

    // Fixed dark palette — always dark so it reads over any content
    private let bg1 = Color(red: 0.107, green: 0.118, blue: 0.145)
    private let bg2 = Color(red: 0.165, green: 0.184, blue: 0.220)
    private let ink = Color(red: 0.941, green: 0.925, blue: 0.894)
    private let dim = Color(red: 0.737, green: 0.714, blue: 0.659)
    private let rec = Color(red: 0.879, green: 0.424, blue: 0.353)
    private let ok  = Color(red: 0.498, green: 0.718, blue: 0.529)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(
                    colors: [bg1, bg2],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .shadow(color: .black.opacity(0.55), radius: 22, y: 8)

            Group {
                switch runner.appState {
                case .recording:    recordingView
                case .transcribing: transcribingView
                case .done:         doneView
                default:            EmptyView()
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(width: 320, height: 84)
        .animation(.easeInOut(duration: 0.22), value: runner.appState)
    }

    // ── Recording: pulsing dot + timer | waveform bars

    private var recordingView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    PulsingDot(color: rec)
                    Text("REC")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(rec)
                        .tracking(1.4)
                }
                Text(String(format: "%d:%02d",
                            runner.elapsedSeconds / 60,
                            runner.elapsedSeconds % 60))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                    .monospacedDigit()
            }
            WaveformBars(color: rec.opacity(0.8), height: 44, barCount: 20)
        }
    }

    // ── Transcribing: spinner + status text

    private var transcribingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(dim)
                .scaleEffect(0.72)
                .frame(width: 22, height: 22)
            Text(runner.status.isEmpty ? "Transcribing…" : runner.status)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Done: green check + "Pasted" + transcript preview

    private var doneView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ok)
                .font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text("Pasted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                if !runner.lastText.isEmpty {
                    Text(runner.lastText)
                        .font(.system(size: 11))
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Pulsing dot

struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.35 : 0.85)
            .animation(
                .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
