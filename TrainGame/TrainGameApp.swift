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
                ConfettiOverlay(trigger: game.model.hud.confettiTrigger)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
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

/// Development aid: `TrainGame -snapshot <folder>` captures scripted showcase shots.
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
        NSApp.activate(ignoringOtherApps: true)
        var t = 1.6
        func at(_ delay: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        func shot(_ name: String, after wait: Double, _ setup: @escaping () -> Void) {
            at(t, setup)
            t += wait
            at(t) { self.save(name) }
            t += 0.25
        }
        shot("cab-view", after: 1.5) {
            self.game.debugSet(world: .alps, train: .steam, camera: .cab,
                               weather: .rain, timeOfDay: .manual(.morning), notch: 3, headFraction: 0.075)
        }
        shot("cargo-freight", after: 1.4) {
            self.game.debugSet(world: .alps, train: .freight, camera: .chase,
                               weather: .clear, timeOfDay: .manual(.morning), notch: 3, headFraction: 0.832)
        }
        shot("tokyo-bullet", after: 1.6) {
            self.game.debugSet(world: .tokyo, train: .bullet, camera: .chase,
                               weather: .clear, timeOfDay: .manual(.midday), notch: 4, headFraction: 0.19)
        }
        shot("tokyo-night", after: 1.4) {
            self.game.debugSet(world: .tokyo, train: .bullet, camera: .chase,
                               weather: .clear, timeOfDay: .manual(.night), notch: 3, headFraction: 0.04)
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
final class GameViewController: UIViewController {
    let game: Game
    private(set) lazy var scnView: GameSCNView = makeGameView(game)

    init(game: Game) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = scnView }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [scnView] }

    override func viewDidLoad() {
        super.viewDidLoad()
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

    func makeUIViewController(context: Context) -> GameViewController { GameViewController(game: game) }
    func updateUIViewController(_ uiViewController: GameViewController, context: Context) {}
}
#endif

// MARK: HUD

struct HUDView: View {
    let model: GameModel

    #if os(tvOS)
    private let unit: CGFloat = 1.5
    private let hints = "RT / LT (or ▲ ▼): Throttle   ·   L3 / Center: Horn   ·   D-Pad: Views & Weather   ·   ☰ / ⏯: Menu"
    #else
    private let unit: CGFloat = 1.0
    private let hints = "↑ ↓ Throttle   ·   Space: Horn   ·   C: Camera   ·   L: World   ·   1-3: Train   ·   M: Menu"
    #endif

    private func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size * unit, weight: weight, design: .rounded)
    }

    var body: some View {
        let hud = model.hud
        ZStack {
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
                            if let mission = hud.activeMission {
                                Label(mission, systemImage: "shippingbox.fill")
                                    .font(font(13, .bold))
                                    .foregroundStyle(.yellow)
                                    .padding(.top, 2 * unit)
                            }
                            if let progress = hud.approachProgress {
                                ApproachBar(progress: progress, inStopZone: hud.inStopZone, unit: unit)
                                    .padding(.top, 3 * unit)
                            }
                        }
                    }
                    Spacer()
                    panel {
                        VStack(alignment: .trailing, spacing: 5 * unit) {
                            Label(hud.worldTitle, systemImage: hud.worldSymbol)
                            Label(hud.trainTitle, systemImage: hud.trainSymbol)
                            if hud.activeMission != nil || hud.cargoDelivered > 0 {
                                Label("\(hud.cargoDelivered) cargo delivered", systemImage: "shippingbox.fill")
                            } else {
                                Label("\(hud.onboard) on board · \(hud.delivered) delivered", systemImage: "person.2.fill")
                            }
                            Label(hud.weather, systemImage: hud.weatherSymbol)
                            Label(hud.timeOfDay, systemImage: hud.timeSymbol)
                            Label(hud.camera, systemImage: "video.fill")
                        }
                        .font(font(14))
                        .monospacedDigit()
                    }
                }
                Spacer()
                if let banner = hud.banner, !hud.menuOpen {
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
                            if hud.hornCooldownSeconds > 0 {
                                Label("\(hud.hornCooldownSeconds)s", systemImage: "speaker.slash.fill")
                                    .font(font(13, .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 10 * unit)
                                    .padding(.vertical, 5 * unit)
                                    .background(.white.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                    Spacer()
                    if hud.showHints && !hud.menuOpen {
                        panel { Text(hints).font(font(13)) }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(24 * unit)
            .animation(.easeInOut(duration: 0.2), value: hud.banner)

            if hud.menuOpen {
                QuickMenuView(hud: hud, unit: unit)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: hud.menuOpen)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16 * unit)
            .padding(.vertical, 11 * unit)
            .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 14 * unit))
    }
}

/// Sleek Apple TV & macOS Quick Switcher toggled via Play/Pause (or M / Tab).
struct QuickMenuView: View {
    let hud: HUDState
    let unit: CGFloat

    private func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size * unit, weight: weight, design: .rounded)
    }

    var body: some View {
        let rows: [(title: String, value: String, symbol: String)] = [
            ("Landscape", hud.worldTitle, hud.worldSymbol),
            ("Train", hud.trainTitle, hud.trainSymbol),
            ("Time of Day", hud.timeOfDay, hud.timeSymbol),
            ("Weather", hud.weather, hud.weatherSymbol),
        ]
        VStack(spacing: 10 * unit) {
            Text("EXPRESS MENU")
                .font(font(13, .bold))
                .tracking(1.5)
                .opacity(0.75)
            ForEach(0..<rows.count, id: \.self) { i in
                let active = hud.menuRow == i
                HStack {
                    Label(rows[i].title, systemImage: rows[i].symbol)
                        .font(font(17, active ? .bold : .medium))
                    Spacer()
                    HStack(spacing: 8 * unit) {
                        Text("◀").opacity(active ? 0.9 : 0.25)
                        Text(rows[i].value).font(font(17, .bold))
                        Text("▶").opacity(active ? 0.9 : 0.25)
                    }
                }
                .padding(.horizontal, 18 * unit)
                .padding(.vertical, 10 * unit)
                .background(
                    RoundedRectangle(cornerRadius: 12 * unit)
                        .fill(active ? Color.white.opacity(0.24) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * unit)
                        .stroke(active ? Color.white.opacity(0.85) : Color.clear, lineWidth: 2 * unit)
                )
            }
            #if os(tvOS)
            Text("▲ ▼ Select   ·   ◀ ▶ or Center: Change   ·   ⏯ Close")
                .font(font(12)).opacity(0.72).padding(.top, 4 * unit)
            #else
            Text("↑ ↓ Select   ·   ← → or Space: Change   ·   M / Tab: Close")
                .font(font(12)).opacity(0.72).padding(.top, 4 * unit)
            #endif
        }
        .foregroundStyle(.white)
        .padding(22 * unit)
        .frame(width: 440 * unit)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20 * unit))
        .overlay(
            RoundedRectangle(cornerRadius: 20 * unit)
                .stroke(.white.opacity(0.22), lineWidth: 1.5)
        )
    }
}

/// Lightweight 60fps SwiftUI confetti burst triggered on deliveries, perfect stops, and train washes!
struct ConfettiOverlay: View {
    let trigger: Int

    private struct Piece {
        let startX: CGFloat
        let startY: CGFloat
        let vx: CGFloat
        let vy: CGFloat
        let size: CGFloat
        let spin: Double
        let phase: Double
        let color: Color
    }

    @State private var burstStart: Date?
    @State private var pieces: [Piece] = []

    var body: some View {
        TimelineView(.animation(paused: burstStart == nil)) { timeline in
            Canvas { context, size in
                guard let start = burstStart else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed < 2.8 else { return }
                let t = CGFloat(elapsed)
                let fade = max(0, 1 - max(0, (elapsed - 1.7) / 1.1))

                for p in pieces {
                    let x = p.startX * size.width + p.vx * size.width * t + sin(elapsed * 5 + p.phase) * 18
                    let y = p.startY * size.height + p.vy * size.height * t + 0.42 * size.height * t * t
                    let angle = Angle.radians(p.phase + p.spin * elapsed)
                    let wobble = CGFloat(0.45 + 0.55 * abs(cos(elapsed * 6.5 + p.phase)))

                    var ctx = context
                    ctx.opacity = fade
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: angle)
                    let rect = CGRect(x: -p.size * 0.5, y: -p.size * 0.3 * wobble,
                                      width: p.size, height: p.size * 0.6 * wobble)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(p.color))
                }
            }
        }
        .onChange(of: trigger) { _, newValue in
            guard newValue > 0 else { return }
            spawnBurst()
        }
    }

    private func spawnBurst() {
        let palette: [Color] = [.red, .yellow, .green, .cyan, .orange, .pink, .purple, .mint]
        var next: [Piece] = []
        next.reserveCapacity(72)
        for i in 0..<72 {
            let fromLeft = i % 2 == 0
            let startX: CGFloat = fromLeft ? 0.08 : 0.92
            let vx: CGFloat = (fromLeft ? 1 : -1) * CGFloat.random(in: 0.12...0.52)
            let vy: CGFloat = -CGFloat.random(in: 0.52...0.95)
            next.append(Piece(
                startX: startX,
                startY: 0.88,
                vx: vx,
                vy: vy,
                size: CGFloat.random(in: 10...18),
                spin: Double.random(in: -8...8),
                phase: Double.random(in: 0...(2 * .pi)),
                color: palette[i % palette.count]
            ))
        }
        pieces = next
        burstStart = Date()
        let captured = burstStart
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
            if burstStart == captured { burstStart = nil }
        }
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
