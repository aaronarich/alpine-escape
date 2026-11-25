import GameController
import os

struct InputCommands {
    var throttleUp = false
    var throttleDown = false
    var nextCamera = false
    var weatherNext = false
    var weatherPrevious = false
    var nextTimeOfDay = false
    var toggleHints = false
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
    private var hints = Repeater()
    private var hornPulseTimer: Float = 0

    // Thread-safe bridge for main-thread UIPress events (Apple TV remote clickpad, IR/CEC remotes, Simulator).
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

    func poll(dt: Float) -> InputCommands {
        var wantUp = false
        var wantDown = false
        var wantCamera = false
        var wantWeatherPrev = false
        var wantWeatherNext = false
        var wantTime = false
        var wantHints = false
        var wantHorn = false
        var hornTapped = false

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
            if (combined & RemoteButton.left.rawValue) != 0      { wantCamera = true }
            if (combined & RemoteButton.right.rawValue) != 0     { wantWeatherNext = true }
            if (combined & RemoteButton.playPause.rawValue) != 0 { wantTime = true }
            if (held & RemoteButton.select.rawValue) != 0        { wantHorn = true }
            if (taps & RemoteButton.select.rawValue) != 0        { hornTapped = true }
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
                wantCamera = wantCamera || x < -0.5 || pad.buttonX.isPressed
                wantWeatherNext = wantWeatherNext || x > 0.5 || pad.rightShoulder.isPressed
                wantWeatherPrev = wantWeatherPrev || pad.leftShoulder.isPressed
                wantTime = wantTime || pad.buttonY.isPressed
                wantHorn = wantHorn || pad.buttonA.isPressed
            } else if let remote = controller.microGamepad {
                // 2nd/3rd gen Siri Remote exposes a dedicated digital cardinal D-pad ring and center button.
                // Using those directly fixes swipe-only behaviour and avoids outer-ring clicks triggering buttonA.
                if let cardinal = remote.dpads[GCInputDirectionalCardinalDpad] {
                    wantUp = wantUp || cardinal.up.isPressed
                    wantDown = wantDown || cardinal.down.isPressed
                    wantCamera = wantCamera || cardinal.left.isPressed
                    wantWeatherNext = wantWeatherNext || cardinal.right.isPressed
                    if let center = remote.buttons[GCInputDirectionalCenterButton] {
                        wantHorn = wantHorn || center.isPressed
                    }
                } else {
                    // 1st gen Siri Remote fallback (glass touchpad with no outer ring):
                    // Use absolute click coordinates so clicking edges/center works like a D-pad without swiping.
                    if !remote.reportsAbsoluteDpadValues {
                        remote.reportsAbsoluteDpadValues = true
                    }
                    if remote.buttonA.isPressed {
                        let x = remote.dpad.xAxis.value
                        let y = remote.dpad.yAxis.value
                        if x * x + y * y < 0.42 * 0.42 {
                            wantHorn = true
                        } else if abs(y) >= abs(x) {
                            if y > 0 { wantUp = true } else { wantDown = true }
                        } else {
                            if x < 0 { wantCamera = true } else { wantWeatherNext = true }
                        }
                    }
                }
                wantTime = wantTime || remote.buttonX.isPressed
            }
        }

        // 3. Hardware keyboard (macOS & tvOS with paired keyboard).
        if let keys = GCKeyboard.coalesced?.keyboardInput {
            func pressed(_ code: GCKeyCode) -> Bool { keys.button(forKeyCode: code)?.isPressed ?? false }
            wantUp = wantUp || pressed(.upArrow) || pressed(.keyW)
            wantDown = wantDown || pressed(.downArrow) || pressed(.keyS)
            wantWeatherPrev = wantWeatherPrev || pressed(.leftArrow)
            wantWeatherNext = wantWeatherNext || pressed(.rightArrow)
            wantHorn = wantHorn || pressed(.spacebar)
            wantCamera = wantCamera || pressed(.keyC)
            wantTime = wantTime || pressed(.keyT)
            wantHints = wantHints || pressed(.keyH)
        }

        // Give quick Center clicks on the Apple TV remote a short minimum whistle blast
        // so taps always sound crisp, while holding Center sustains the whistle indefinitely.
        if hornTapped || wantHorn {
            hornPulseTimer = max(hornPulseTimer, hornTapped ? 0.24 : 0)
        }
        if hornPulseTimer > 0 {
            hornPulseTimer = max(0, hornPulseTimer - dt)
        }

        var commands = InputCommands()
        commands.throttleUp = up.update(wantUp, dt: dt, repeats: true)
        commands.throttleDown = down.update(wantDown, dt: dt, repeats: true)
        commands.nextCamera = camera.update(wantCamera, dt: dt, repeats: false)
        commands.weatherPrevious = weatherPrev.update(wantWeatherPrev, dt: dt, repeats: false)
        commands.weatherNext = weatherNext.update(wantWeatherNext, dt: dt, repeats: false)
        commands.nextTimeOfDay = timeOfDay.update(wantTime, dt: dt, repeats: false)
        commands.toggleHints = hints.update(wantHints, dt: dt, repeats: false)
        commands.horn = wantHorn || hornPulseTimer > 0
        return commands
    }
}
