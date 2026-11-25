import GameController
import os

struct InputCommands {
    var throttleUp = false
    var throttleDown = false
    var nextCamera = false
    var weatherNext = false
    var weatherPrevious = false
    var nextTimeOfDay = false
    var toggleMenu = false
    var selectTap = false
    var toggleHints = false
    var switchWorld = false
    var switchTrain: TrainKind?
    var horn = false
}

/// Discrete remote / directional press events forwarded from UIKit (`UIPress`) on tvOS.
enum RemoteButton: UInt32 {
    case up        = 1
    case down      = 2
    case left      = 4
    case right     = 8
    case select    = 16
    case playPause = 32
}

/// Polls the Apple TV Siri Remote (direction pad + center button), game controllers,
/// UIKit `UIPress` events (IR/CEC/Siri clickpad), and (on Mac) the keyboard once per frame.
final class InputController {
    private struct Repeater {
        var held = false
        var timer: Float = 0
        var releaseCooldown: Float = 0

        mutating func update(_ pressed: Bool, dt: Float, repeats: Bool) -> Bool {
            if releaseCooldown > 0 { releaseCooldown = max(0, releaseCooldown - dt) }
            guard pressed else {
                if held {
                    held = false
                    releaseCooldown = 0.07
                }
                return false
            }
            if !held {
                held = true
                timer = 0.42
                guard releaseCooldown <= 0 else { return false }
                return true
            }
            guard repeats else { return false }
            timer -= dt
            if timer <= 0 {
                timer = 0.22
                return true
            }
            return false
        }
    }

    private var up = Repeater()
    private var down = Repeater()
    private var camera = Repeater()
    private var weatherPrev = Repeater()
    private var weatherNext = Repeater()
    private var timeOfDay = Repeater()
    private var menu = Repeater()
    private var selectEdge = Repeater()
    private var hints = Repeater()
    private var worldKey = Repeater()
    private var train1 = Repeater(), train2 = Repeater(), train3 = Repeater()
    private var hornPulseTimer: Float = 0

    private struct PressState {
        var heldMask: UInt32 = 0
        var tapMask: UInt32 = 0
    }
    private let pressState = OSAllocatedUnfairLock(initialState: PressState())

    func setRemotePress(_ button: RemoteButton, pressed: Bool) {
        pressState.withLock { state in
            if pressed {
                state.heldMask |= button.rawValue
                state.tapMask |= button.rawValue
            } else {
                state.heldMask &= ~button.rawValue
            }
        }
    }

    func clearRemotePresses() {
        pressState.withLock { state in
            state.heldMask = 0
        }
    }

    func poll(dt: Float, menuOpen: Bool = false) -> InputCommands {
        var wantUp = false
        var wantDown = false
        var wantLeft = false
        var wantRight = false
        var wantCamera = false
        var wantWeatherPrev = false
        var wantWeatherNext = false
        var wantTime = false
        var wantMenu = false
        var wantHints = false
        var wantWorld = false
        var wantT1 = false, wantT2 = false, wantT3 = false
        var wantSelect = false
        var selectTapped = false

        // 1. UIKit UIPress state (tvOS Siri Remote clickpad ring, Click-Only mode, IR/CEC & iPhone TV Remote).
        let (held, taps): (UInt32, UInt32) = pressState.withLock { state in
            let result = (state.heldMask, state.tapMask)
            state.tapMask = 0
            return result
        }

        let combined = held | taps
        if combined != 0 {
            if (combined & RemoteButton.up.rawValue) != 0        { wantUp = true }
            if (combined & RemoteButton.down.rawValue) != 0      { wantDown = true }
            if (combined & RemoteButton.left.rawValue) != 0      { wantLeft = true }
            if (combined & RemoteButton.right.rawValue) != 0     { wantRight = true }
            if (combined & RemoteButton.playPause.rawValue) != 0 { wantMenu = true }
            if (held & RemoteButton.select.rawValue) != 0        { wantSelect = true }
            if (taps & RemoteButton.select.rawValue) != 0        { selectTapped = true }
        }

        // 2. GameController framework (Extended gamepads & Siri Remote directional/micro gamepads).
        for controller in GCController.controllers() {
            if let pad = controller.extendedGamepad {
                let stickY = pad.leftThumbstick.yAxis.value
                let dpadY = pad.dpad.yAxis.value
                let y = abs(stickY) > abs(dpadY) ? stickY : dpadY
                let x = pad.dpad.xAxis.value
                wantUp = wantUp || y > 0.5
                wantDown = wantDown || y < -0.5
                wantLeft = wantLeft || x < -0.5
                wantRight = wantRight || x > 0.5
                wantCamera = wantCamera || pad.buttonX.isPressed
                wantWeatherNext = wantWeatherNext || pad.rightShoulder.isPressed
                wantWeatherPrev = wantWeatherPrev || pad.leftShoulder.isPressed
                wantTime = wantTime || pad.buttonY.isPressed
                wantMenu = wantMenu || pad.buttonMenu.isPressed
                wantSelect = wantSelect || pad.buttonA.isPressed
            } else if let remote = controller.microGamepad {
                if let cardinal = remote.dpads[GCInputDirectionalCardinalDpad] {
                    wantUp = wantUp || cardinal.up.isPressed
                    wantDown = wantDown || cardinal.down.isPressed
                    wantLeft = wantLeft || cardinal.left.isPressed
                    wantRight = wantRight || cardinal.right.isPressed
                    if let center = remote.buttons[GCInputDirectionalCenterButton] {
                        wantSelect = wantSelect || center.isPressed
                    }
                } else {
                    if !remote.reportsAbsoluteDpadValues {
                        remote.reportsAbsoluteDpadValues = true
                    }
                    if remote.buttonA.isPressed {
                        let x = remote.dpad.xAxis.value
                        let y = remote.dpad.yAxis.value
                        if x * x + y * y < 0.42 * 0.42 {
                            wantSelect = true
                        } else if abs(y) >= abs(x) {
                            if y > 0 { wantUp = true } else { wantDown = true }
                        } else {
                            if x < 0 { wantLeft = true } else { wantRight = true }
                        }
                    }
                }
                wantMenu = wantMenu || remote.buttonX.isPressed
            }
        }

        // 3. Hardware keyboard (macOS & tvOS with paired keyboard).
        if let keys = GCKeyboard.coalesced?.keyboardInput {
            func pressed(_ code: GCKeyCode) -> Bool { keys.button(forKeyCode: code)?.isPressed ?? false }
            wantUp = wantUp || pressed(.upArrow) || pressed(.keyW)
            wantDown = wantDown || pressed(.downArrow) || pressed(.keyS)
            if menuOpen {
                wantLeft = wantLeft || pressed(.leftArrow)
                wantRight = wantRight || pressed(.rightArrow)
                wantSelect = wantSelect || pressed(.returnOrEnter) || pressed(.spacebar)
            } else {
                wantWeatherPrev = wantWeatherPrev || pressed(.leftArrow)
                wantWeatherNext = wantWeatherNext || pressed(.rightArrow)
                wantSelect = wantSelect || pressed(.spacebar)
            }
            wantCamera = wantCamera || pressed(.keyC)
            wantTime = wantTime || pressed(.keyT)
            wantMenu = wantMenu || pressed(.keyM) || pressed(.tab)
            wantHints = wantHints || pressed(.keyH)
            wantWorld = wantWorld || pressed(.keyL)
            wantT1 = wantT1 || pressed(.one)
            wantT2 = wantT2 || pressed(.two)
            wantT3 = wantT3 || pressed(.three)
        }

        // When driving normally, D-pad Left = Camera and D-pad Right = Weather on Apple TV / Gamepad.
        if !menuOpen {
            wantCamera = wantCamera || wantLeft
            wantWeatherNext = wantWeatherNext || wantRight
        } else {
            wantWeatherPrev = wantWeatherPrev || wantLeft
            wantWeatherNext = wantWeatherNext || wantRight
        }

        if !menuOpen {
            if selectTapped || wantSelect {
                hornPulseTimer = max(hornPulseTimer, selectTapped ? 0.24 : 0)
            }
            if hornPulseTimer > 0 {
                hornPulseTimer = max(0, hornPulseTimer - dt)
            }
        } else {
            hornPulseTimer = 0
        }

        var commands = InputCommands()
        commands.throttleUp = up.update(wantUp, dt: dt, repeats: !menuOpen)
        commands.throttleDown = down.update(wantDown, dt: dt, repeats: !menuOpen)
        commands.nextCamera = camera.update(wantCamera, dt: dt, repeats: false)
        commands.weatherPrevious = weatherPrev.update(wantWeatherPrev, dt: dt, repeats: false)
        commands.weatherNext = weatherNext.update(wantWeatherNext, dt: dt, repeats: false)
        commands.nextTimeOfDay = timeOfDay.update(wantTime, dt: dt, repeats: false)
        commands.toggleMenu = menu.update(wantMenu, dt: dt, repeats: false)
        commands.selectTap = selectEdge.update(wantSelect || selectTapped, dt: dt, repeats: false)
        commands.toggleHints = hints.update(wantHints, dt: dt, repeats: false)
        commands.switchWorld = worldKey.update(wantWorld, dt: dt, repeats: false)
        if train1.update(wantT1, dt: dt, repeats: false) { commands.switchTrain = .steam }
        if train2.update(wantT2, dt: dt, repeats: false) { commands.switchTrain = .bullet }
        if train3.update(wantT3, dt: dt, repeats: false) { commands.switchTrain = .freight }
        commands.horn = !menuOpen && (wantSelect || hornPulseTimer > 0)
        return commands
    }
}
