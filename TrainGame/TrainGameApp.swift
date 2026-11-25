import SwiftUI
import SceneKit

@main
struct TrainGameApp: App {
    @State private var game = Game()

    var body: some Scene {
        WindowGroup {
            ZStack {
                SceneContainer(game: game)
                    .ignoresSafeArea()
                HUDView(model: game.model)
            }
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 540)
            #endif
        }
    }
}

// MARK: SceneKit view

final class GameSCNView: SCNView {
    #if os(macOS)
    // Take keyboard focus so key presses don't make the Mac beep; input itself is polled elsewhere.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    #else
    weak var inputController: InputController?

    override var canBecomeFocused: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    private func remoteButton(for type: UIPress.PressType) -> RemoteButton? {
        switch type {
        case .upArrow:    return .up
        case .downArrow:  return .down
        case .leftArrow:  return .left
        case .rightArrow: return .right
        case .select:     return .select
        case .playPause:  return .playPause
        default:          return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let button = remoteButton(for: press.type) {
                inputController?.setRemotePress(button, pressed: true)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let button = remoteButton(for: press.type) {
                inputController?.setRemotePress(button, pressed: false)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let button = remoteButton(for: press.type) {
                inputController?.setRemotePress(button, pressed: false)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
    #endif
}

private func makeGameView(_ game: Game) -> GameSCNView {
    let view = GameSCNView(frame: .zero, options: nil)
    view.scene = game.scene
    view.pointOfView = game.cameraNode
    view.delegate = game
    view.isPlaying = true
    view.rendersContinuously = true
    view.preferredFramesPerSecond = 60
    #if os(tvOS)
    view.antialiasingMode = .multisampling2X
    view.inputController = game.input
    #else
    view.antialiasingMode = .multisampling4X
    #endif
    view.backgroundColor = .black
    return view
}

#if os(macOS)
struct SceneContainer: NSViewRepresentable {
    let game: Game

    func makeNSView(context: Context) -> GameSCNView {
        let view = makeGameView(game)
        if let directory = UserDefaults.standard.string(forKey: "snapshot") {
            game.inputEnabled = false
            game.start(muted: true, liveWeather: false)
            SnapshotRun(view: view, game: game, directory: directory).begin()
        } else {
            game.start()
        }
        return view
    }

    func updateNSView(_ view: GameSCNView, context: Context) {}
}

/// Development aid: `TrainGame -snapshot <folder>` plays a short scripted run and saves pictures of it.
@MainActor
final class SnapshotRun {
    private let view: GameSCNView
    private let game: Game
    private let directory: String

    init(view: GameSCNView, game: Game, directory: String) {
        self.view = view
        self.game = game
        self.directory = directory
    }

    func begin() {
        var t = 1.5
        func at(_ delay: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        func shot(_ name: String, after wait: Double, _ setup: @escaping () -> Void) {
            at(t, setup)
            t += wait
            at(t) { self.save(name) }
            t += 0.2
        }
        shot("01-station-chase", after: 1.2) {
            self.game.debugSet(camera: .chase, weather: .clear, timeOfDay: .manual(.morning))
        }
        shot("02-viaduct-side", after: 1.0) {
            self.game.debugSet(camera: .side, weather: .clear, timeOfDay: .manual(.midday), notch: 3, headFraction: 0.195)
        }
        shot("03-viaduct-sunset-chase", after: 1.2) {
            self.game.debugSet(camera: .chase, weather: .clear, timeOfDay: .manual(.sunset), notch: 3, headFraction: 0.185)
        }
        shot("04-tunnel-portal-chase", after: 1.2) {
            self.game.debugSet(camera: .chase, weather: .clear, timeOfDay: .manual(.midday), notch: 3, headFraction: 0.478)
        }
        shot("05-tunnel-inside-chase", after: 1.2) {
            self.game.debugSet(camera: .chase, weather: .clear, timeOfDay: .manual(.midday), notch: 3, headFraction: 0.52)
        }
        shot("06-night-station", after: 1.2) {
            self.game.debugSet(camera: .chase, weather: .clear, timeOfDay: .manual(.night), notch: 0, headFraction: 0.36)
        }
        shot("07-night-cab", after: 1.0) {
            self.game.debugSet(camera: .cab, weather: .snow, timeOfDay: .manual(.night), notch: 2, headFraction: 0.37)
        }
        shot("08-aerial-lake", after: 1.0) {
            self.game.debugSet(camera: .aerial, weather: .clear, timeOfDay: .manual(.sunset), notch: 3, headFraction: 0.80)
        }
        at(t) {
            let renderer = ImageRenderer(content:
                HUDView(model: self.game.model)
                    .frame(width: 1280, height: 720)
                    .background(Color(red: 0.22, green: 0.32, blue: 0.42)))
            if let image = renderer.nsImage { self.write(image, "09-hud") }
        }
        at(t + 0.4) { exit(0) }
    }

    private func save(_ name: String) {
        write(view.snapshot(), name)
    }

    private func write(_ image: NSImage, _ name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
#else
/// Hosts `GameSCNView` on tvOS and guarantees the view holds focus so physical D-Pad and Center
/// presses (`UIPress`) are always delivered reliably from the Siri Remote, IR/CEC remotes, and iPhone Remote.
final class GameViewController: UIViewController {
    let game: Game
    private(set) lazy var scnView: GameSCNView = makeGameView(game)

    init(game: Game) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = scnView
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [scnView] }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Long stretches without touching the remote are normal here; don't let the screensaver start.
        UIApplication.shared.isIdleTimerDisabled = true
        game.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        scnView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        game.input.clearRemotePresses()
    }
}

struct SceneContainer: UIViewControllerRepresentable {
    let game: Game

    func makeUIViewController(context: Context) -> GameViewController {
        GameViewController(game: game)
    }

    func updateUIViewController(_ uiViewController: GameViewController, context: Context) {}
}
#endif

// MARK: HUD

struct HUDView: View {
    let model: GameModel

    #if os(tvOS)
    private let unit: CGFloat = 1.5
    private let hints = "▲ ▼ Throttle & Brake   ·   Center: Horn   ·   ◀ Camera   ·   ▶ Weather   ·   ⏯ Time of Day"
    #else
    private let unit: CGFloat = 1.0
    private let hints = "↑ ↓ Throttle & Brake   ·   Space: Horn   ·   C: Camera   ·   ← → Weather   ·   T: Time   ·   H: Hints"
    #endif

    private func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size * unit, weight: weight, design: .rounded)
    }

    var body: some View {
        let hud = model.hud
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                panel {
                    VStack(alignment: .leading, spacing: 3 * unit) {
                        Text("NEXT STATION").font(font(11, .bold)).opacity(0.7)
                        Text(hud.nextStation).font(font(24, .bold))
                        Text(hud.distance >= 1000
                             ? String(format: "%.1f km", Double(hud.distance) / 1000)
                             : "\(hud.distance) m")
                            .font(font(16)).monospacedDigit()
                        if let progress = hud.approachProgress {
                            ApproachBar(progress: progress, inStopZone: hud.inStopZone, unit: unit)
                                .padding(.top, 3 * unit)
                        }
                    }
                }
                Spacer()
                panel {
                    VStack(alignment: .trailing, spacing: 5 * unit) {
                        Label("\(hud.onboard) on board", systemImage: "person.2.fill")
                        Label("\(hud.delivered) delivered", systemImage: "checkmark.circle.fill")
                        Label(hud.weather, systemImage: hud.weatherSymbol)
                        Label(hud.timeOfDay, systemImage: hud.timeSymbol)
                        Label(hud.camera, systemImage: "video.fill")
                    }
                    .font(font(15))
                    .monospacedDigit()
                }
            }
            Spacer()
            if let banner = hud.banner {
                Text(banner)
                    .font(font(22, .bold))
                    .padding(.horizontal, 26 * unit)
                    .padding(.vertical, 12 * unit)
                    .background(.black.opacity(0.58), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Spacer()
            HStack(alignment: .bottom) {
                panel {
                    HStack(spacing: 14 * unit) {
                        ThrottleGauge(notch: hud.notch, unit: unit)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(hud.speedKmh)").font(font(44, .heavy)).monospacedDigit()
                            Text("km/h").font(font(13)).opacity(0.7)
                        }
                        .frame(minWidth: 86 * unit, alignment: .leading)
                    }
                }
                Spacer()
                if hud.showHints {
                    panel { Text(hints).font(font(13)) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24 * unit)
        .animation(.easeInOut(duration: 0.2), value: hud.banner)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16 * unit)
            .padding(.vertical, 11 * unit)
            .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 14 * unit))
    }
}

/// Visual braking guide shown in the final 320m before a station platform.
struct ApproachBar: View {
    let progress: Float
    let inStopZone: Bool
    let unit: CGFloat

    var body: some View {
        let width: CGFloat = 170 * unit
        let height: CGFloat = 7 * unit
        let clamped = CGFloat(min(max(progress, 0), 1))
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: width, height: height)
            // Green platform stop zone covering the final ~20m of the 320m approach
            Capsule()
                .fill(inStopZone ? Color.green : Color.green.opacity(0.55))
                .frame(width: width * 0.14, height: height)
                .offset(x: width * 0.86)
            Circle()
                .fill(inStopZone ? Color.green : Color.white)
                .frame(width: 11 * unit, height: 11 * unit)
                .offset(x: clamped * (width - 11 * unit))
        }
    }
}

/// The throttle lever: green segments for power, red for brake.
struct ThrottleGauge: View {
    let notch: Int
    let unit: CGFloat

    var body: some View {
        VStack(spacing: 3 * unit) {
            ForEach(Array(stride(from: Game.maxNotch, through: Game.minNotch, by: -1)), id: \.self) { level in
                RoundedRectangle(cornerRadius: 2 * unit)
                    .fill(color(for: level))
                    .frame(width: (level == 0 ? 30 : 22) * unit, height: (level == 0 ? 3 : 7) * unit)
            }
        }
    }

    private func color(for level: Int) -> Color {
        if level == 0 { return .white.opacity(notch == 0 ? 1 : 0.4) }
        if level > 0 { return level <= notch ? .green : .white.opacity(0.18) }
        return level >= notch ? .red : .white.opacity(0.18)
    }
}
