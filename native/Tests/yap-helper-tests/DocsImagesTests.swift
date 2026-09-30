import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import yap_helper

/// Regenerates the images in docs/images from the real HUD and menu bar code.
/// Skipped unless YAP_DOCS_DIR is set:
///
///     YAP_DOCS_DIR="$PWD/docs/images" swift test --package-path native --filter DocsImagesTests
final class DocsImagesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["YAP_DOCS_DIR"] else {
            throw XCTSkip("Set YAP_DOCS_DIR to regenerate the docs images")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Transparent, so the pill's shadow sits on whatever page shows it.
    private let themes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

    /// An animated PNG rather than a GIF: GIF's 256 colours turn the soft shadow into a grey box.
    @MainActor
    func testPillAnimation() throws {
        let fps = 25.0
        for (name, scheme) in themes {
            var frames: [CGImage] = []
            for index in 0..<Int(fps * 3.4) {
                let time = Double(index) / fps
                let model = HUDModel()
                model.frozenTime = time
                model.content = time < 2.6 ? .listening(handsFree: false) : .transcribing
                // Syllable-like bursts with a pause in the middle.
                let speech = abs(sin(time * 5.3)) * (0.55 + 0.45 * sin(time * 1.7 + 1)) * (time > 1.1 && time < 1.4 ? 0.1 : 1)
                model.levelProvider = { Float(0.08 + 0.6 * speech) }
                frames.append(try render(HUDView(model: model), scheme: scheme, size: CGSize(width: 240, height: 70)))
            }
            try writeAnimatedPNG(frames, delay: 1 / fps, to: directory.appendingPathComponent("pill-\(name).png"))
        }
    }

    @MainActor
    func testPillStates() throws {
        let states: [HUD.Content] = [
            .listening(handsFree: false),
            .listening(handsFree: true),
            .transcribing,
            .message(symbol: "doc.on.clipboard.fill", title: "Copied", detail: "⌘V to paste"),
        ]
        for (name, scheme) in themes {
            let view = VStack(spacing: -34) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, content in
                    let model = HUDModel()
                    let _ = (model.content = content, model.levelProvider = { 0.5 }, model.frozenTime = 1.3)
                    HUDView(model: model).frame(width: 300, height: 70)
                }
            }
            try png(render(view, scheme: scheme, size: CGSize(width: 300, height: 190)),
                    to: directory.appendingPathComponent("pill-states-\(name).png"))
        }
    }

    func testMenuBarGlyphs() throws {
        let states: [MenuBarIcon.State] = [.idle, .recording, .transcribing, .attention]
        let scale: CGFloat = 4
        let cell: CGFloat = 30
        for (name, background, ink) in [("light", NSColor(white: 0.96, alpha: 1), NSColor.black),
                                        ("dark", NSColor(white: 0.12, alpha: 1), NSColor.white)] {
            let size = CGSize(width: cell * CGFloat(states.count) * scale, height: cell * scale)
            let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(background.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            for (index, state) in states.enumerated() {
                let layer = CGLayer(context, size: CGSize(width: 18 * scale, height: 18 * scale), auxiliaryInfo: nil)!
                let glyph = layer.context!
                glyph.scaleBy(x: scale, y: scale)
                MenuBarIcon.draw(state, in: glyph)
                // Tint the template the way the menu bar does.
                glyph.setBlendMode(.sourceIn)
                glyph.setFillColor(ink.cgColor)
                glyph.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
                let origin = CGPoint(x: (CGFloat(index) * cell + 6) * scale, y: 6 * scale)
                context.draw(layer, in: CGRect(origin: origin, size: CGSize(width: 18 * scale, height: 18 * scale)))
            }
            try png(context.makeImage()!, to: directory.appendingPathComponent("menubar-\(name).png"))
        }
    }

    // MARK: - README artwork

    @MainActor
    func testArtwork() throws {
        let scenes: [(String, AnyView)] = [
            ("hero", AnyView(HeroScene())),
            ("formatting", AnyView(FormattingScene())),
            ("hands-free", AnyView(HandsFreeScene())),
            ("auto-send", AnyView(AutoSendScene())),
        ]
        for (name, scene) in scenes {
            let renderer = ImageRenderer(content: Artboard { scene }.environment(\.colorScheme, .light))
            renderer.scale = 2
            try png(XCTUnwrap(renderer.cgImage, name), to: directory.appendingPathComponent("art-\(name).png"))
        }
    }

    // MARK: - Helpers

    @MainActor
    private func render(_ view: some View, scheme: ColorScheme, size: CGSize) throws -> CGImage {
        let content = view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeAnimatedPNG(_ frames: [CGImage], delay: Double, to url: URL) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frames.count, nil))
        let loop = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        let frameProperties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

// MARK: - Artwork pieces

private enum Art {
    static let ink = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let paper = Color(red: 0.969, green: 0.953, blue: 0.918)
    static let muted = Color(red: 0.45, green: 0.43, blue: 0.40)
    static let serif = Font.system(size: 17, weight: .regular, design: .serif).italic()
}

/// A paper card with its own background, so the art reads on light and dark GitHub themes.
private struct Artboard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
            .frame(width: 880)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.975, green: 0.962, blue: 0.93), Color(red: 0.93, green: 0.905, blue: 0.85)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.black.opacity(0.06)))
    }
}

private struct Caption: View {
    let step: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text(step)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Palette.accent, in: Circle())
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Art.ink)
        }
    }
}

private struct Keycap: View {
    let label: String
    var symbol: String?
    var width: CGFloat = 76

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.94)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 2)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Art.ink.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
            Text(label)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Art.ink)
                .padding(11)
        }
        .frame(width: width, height: 76)
    }
}

private struct Arrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Art.ink.opacity(0.28))
    }
}

/// The real pill, from the app's own HUD code.
private struct LivePill: View {
    let content: HUD.Content
    var level: Float = 0.5

    var body: some View {
        let model = HUDModel()
        let _ = (model.content = content, model.levelProvider = { level }, model.frozenTime = 1.3)
        return HUDView(model: model).frame(width: 220, height: 80)
    }
}

/// A plain macOS-style window.
private struct Window<Content: View>: View {
    let title: String
    var width: CGFloat = 360
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 11, height: 11) }
                Spacer()
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Art.ink.opacity(0.55))
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            Divider().opacity(0.5)
            content.padding(16)
        }
        .frame(width: width, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.black.opacity(0.08)))
    }
}

/// Text ending in Yap's orange caret.
private struct Typed: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        (Text(text).foregroundStyle(Art.ink) + Text(" |").foregroundStyle(Palette.accent).fontWeight(.heavy))
            .font(.system(size: size))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Scenes put each step's picture in a row of equal height, so the captions line up beneath.
private struct Step<Picture: View>: View {
    let number: String
    let caption: String
    let height: CGFloat
    @ViewBuilder var picture: Picture

    var body: some View {
        VStack(spacing: 16) {
            picture.frame(height: height)
            Caption(step: number, text: caption).fixedSize()
        }
    }
}

private struct HeroScene: View {
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Step(number: "1", caption: "Hold fn", height: 150) { Keycap(label: "fn", symbol: "globe") }
            Arrow().frame(height: 150)
            Step(number: "2", caption: "Talk", height: 150) {
                LivePill(content: .listening(handsFree: false)).frame(width: 150, height: 76)
            }
            Arrow().frame(height: 150)
            Step(number: "3", caption: "Let go. It’s typed.", height: 150) {
                Window(title: "Messages", width: 340) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("To: Sam").font(.system(size: 12)).foregroundStyle(Art.muted)
                        Typed(text: "Can you send me the updated deck before the 3 o'clock meeting?")
                    }
                }
            }
        }
    }
}

private struct FormattingScene: View {
    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                Text("YOU SAY").font(.system(size: 11, weight: .bold)).kerning(1.2).foregroundStyle(Art.muted)
                Text("“Um, so I need three things from the store: milk, eggs and a loaf of bread.”")
                    .font(Art.serif)
                    .foregroundStyle(Art.ink.opacity(0.75))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300, alignment: .leading)
            Arrow()
            Window(title: "Notes", width: 330) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("So I need three things from the store:").font(.system(size: 15)).foregroundStyle(Art.ink)
                    Text("- Milk").font(.system(size: 15)).foregroundStyle(Art.ink)
                    Text("- Eggs").font(.system(size: 15)).foregroundStyle(Art.ink)
                    Typed(text: "- A loaf of bread")
                }
            }
        }
    }
}

private struct HandsFreeScene: View {
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Step(number: "1", caption: "Hold fn, tap Space", height: 90) {
                HStack(spacing: 10) {
                    Keycap(label: "fn", symbol: "globe")
                    Text("+").font(.system(size: 20, weight: .medium)).foregroundStyle(Art.ink.opacity(0.4))
                    Keycap(label: "space", width: 170)
                }
            }
            Arrow().frame(height: 90)
            Step(number: "2", caption: "Let go and keep talking. Stop when you’re done.", height: 90) {
                LivePill(content: .listening(handsFree: true)).frame(width: 200, height: 76)
            }
        }
    }
}

private struct AutoSendScene: View {
    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill").foregroundStyle(Palette.accent)
                    Text("Auto-Send").font(.system(size: 17, weight: .semibold)).foregroundStyle(Art.ink)
                }
                Text("Yap presses Return after pasting, in the apps you choose: dictate straight into Slack, Messages or Claude Code.")
                    .font(.system(size: 14))
                    .foregroundStyle(Art.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 290, alignment: .leading)
            Window(title: "#launch", width: 390) {
                VStack(alignment: .leading, spacing: 12) {
                    bubble("Sam", "Is the deploy done?", mine: false)
                    bubble("You", "Yes, it shipped ten minutes ago. Dashboards look clean.", mine: true)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text("Sent")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Art.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func bubble(_ name: String, _ text: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Art.muted)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(mine ? .white : Art.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Art.ink : Color(white: 0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}
