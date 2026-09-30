import AppKit
import SwiftUI

/// The pill near the bottom of the screen that shows what Yap is doing. It follows the system
/// appearance: ink on paper in light mode, paper on ink in dark mode, with Yap's orange caret.
final class HUD {
    enum Content: Equatable {
        /// Recording. Hands-free recording shows a stop button.
        case listening(handsFree: Bool)
        case transcribing
        case message(symbol: String, title: String, detail: String? = nil)
    }

    /// Supplies the live input level (0...1) while recording.
    var levelProvider: (() -> Float)? {
        get { model.levelProvider }
        set { model.levelProvider = newValue }
    }

    /// Called when the stop button is clicked.
    var onStop: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    private let model = HUDModel()
    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = FirstClickHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show(_ content: Content) {
        hideWorkItem?.cancel()
        if !panel.isVisible {
            // Follow the pointer to whichever display the user is working on.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 6))
            panel.orderFrontRegardless()
        }
        // Clicks pass through the pill except when it has a stop button.
        panel.ignoresMouseEvents = content != .listening(handsFree: true)
        model.content = content
    }

    /// Shows a short message, then fades out.
    func flash(symbol: String, _ title: String, detail: String? = nil, for duration: TimeInterval = 1.6) {
        show(.message(symbol: symbol, title: title, detail: detail))
        hide(after: duration)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.ignoresMouseEvents = true
            self.model.content = nil
            // Let the exit animation finish before taking the window off screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.model.content == nil { self.panel.orderOut(nil) }
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Never takes keyboard focus, so clicking the stop button leaves your cursor where it was
/// and the text still pastes into the right place.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the stop button work on the first click, without the panel being key first.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDModel: ObservableObject {
    @Published var content: HUD.Content?
    var levelProvider: (() -> Float)?
    var onStop: (() -> Void)?
    /// Pins the animation clock, for rendering frames of the docs GIF.
    var frozenTime: TimeInterval?
}

enum Palette {
    /// The caret orange from the app icon.
    static let accent = Color(red: 1, green: 0.353, blue: 0.122)

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.96) : Color(red: 0.071, green: 0.071, blue: 0.071)
    }

    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.082) : Color(red: 0.969, green: 0.953, blue: 0.918)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let content = model.content {
                Pill(content: content, model: model)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.4, anchor: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 18)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.content)
    }
}

private struct Pill: View {
    let content: HUD.Content
    let model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Palette.ink(scheme)
        HStack(spacing: 8) {
            switch content {
            case .listening, .transcribing:
                Waveform(model: model, busy: content == .transcribing, ink: ink)
                    .frame(width: Waveform.width, height: 18)
                    .transition(.opacity)
                if content == .listening(handsFree: true) {
                    StopButton(ink: ink) { model.onStop?() }
                        .padding(.leading, 2)
                        .padding(.trailing, -8)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            case .message(let symbol, let title, let detail):
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    if let detail { Text(detail).foregroundStyle(ink.opacity(0.5)) }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(ink)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Palette.paper(scheme), in: Capsule())
        .overlay(
            Capsule().strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.16), radius: 12, y: 5)
    }
}

/// Ends a hands-free take: an orange stop square in a soft ring.
private struct StopButton: View {
    let ink: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(ink.opacity(hovering ? 0.16 : 0.08))
                RoundedRectangle(cornerRadius: 2.5).fill(Palette.accent).frame(width: 9, height: 9)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Stop and paste")
    }
}

/// Your voice flowing into a text cursor: bars that follow the microphone and brighten toward a
/// blinking orange caret. While transcribing they settle into dots that run toward the caret.
private struct Waveform: View {
    static let barCount = 9
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2.5
    static let caretGap: CGFloat = 5
    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing + caretGap + barWidth
    }

    let model: HUDModel
    let busy: Bool
    let ink: Color
    @State private var motion = Motion()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = model.frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
                let input = CGFloat(model.levelProvider?() ?? 0)
                motion.advance(to: time, level: busy ? 0 : input, busy: busy)
                draw(in: &context, size: size, time: time)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let count = Waveform.barCount
        let dot = Waveform.barWidth
        // Perceptual curve: quiet speech still moves the bars.
        let level = pow(motion.level, 0.65)
        var x: CGFloat = 0
        for index in 0..<count {
            let position = CGFloat(index) / CGFloat(count - 1)
            let envelope = 0.55 + 0.45 * sin(.pi * position)
            let phase = time * (7.5 + Double(index % 3) * 1.9) + Double(index) * 1.7
            let wobble = 0.62 + 0.38 * CGFloat(sin(phase))
            // A little motion even in silence, so it is obvious the microphone is live.
            let speaking = max(level, 0.07) * envelope * wobble
            let wave = CGFloat(max(0, sin(time * 8 - Double(index) * 0.8)))

            let height = dot + (size.height - dot) * min(1, speaking * (1 - motion.busy))
            let opacity = (0.3 + 0.7 * position) * (1 - motion.busy) + (0.2 + 0.8 * wave) * motion.busy
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: dot, height: height)
            context.fill(Capsule().path(in: rect), with: .color(ink.opacity(opacity)))
            x += dot + Waveform.spacing
        }

        // The caret blinks like a real one while listening, and holds steady while transcribing.
        let blink = 0.5 + 0.5 * CGFloat(cos(time * 2 * .pi / 1.1))
        let caretOpacity = (0.3 + 0.7 * blink) * (1 - motion.busy) + motion.busy
        let caret = CGRect(x: x - Waveform.spacing + Waveform.caretGap, y: 0, width: dot, height: size.height)
        context.fill(Capsule().path(in: caret), with: .color(Palette.accent.opacity(caretOpacity)))
    }

    /// Eases the raw input level and the recording → transcribing change over time, so the
    /// bars glide instead of stepping at the microphone's ~10 Hz update rate.
    private final class Motion {
        private(set) var level: CGFloat = 0
        private(set) var busy: CGFloat = 0
        private var last: TimeInterval?

        func advance(to time: TimeInterval, level target: CGFloat, busy isBusy: Bool) {
            guard let last else {
                // The first frame starts where things are rather than easing in from zero.
                level = target
                busy = isBusy ? 1 : 0
                self.last = time
                return
            }
            let delta = min(0.1, max(0, time - last))
            self.last = time
            let tau = target > level ? 0.05 : 0.16
            level += (target - level) * (1 - exp(-delta / tau))
            busy += ((isBusy ? 1 : 0) - busy) * (1 - exp(-delta / 0.12))
        }
    }
}
