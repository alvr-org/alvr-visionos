//
//  InputTypes.swift
//
//  Device-neutral representation of controller input.
//
//  The point of these types is to decouple *what a device reports* from *what we
//  send to ALVR*. Devices produce an InputSnapshot; an InteractionProfile decides
//  how that snapshot maps onto ALVR button paths. Adding a controller means adding
//  an InputDevice; changing bindings means changing a profile table. Neither
//  requires touching the other.
//

import Foundation
import simd

/// Which hand a device (or half of a device) represents.
///
/// `.both` covers single-unit gamepads that drive both virtual controllers,
/// which is how the existing generic-gamepad path in WorldTracker behaves.
enum Chirality: Hashable {
    case left
    case right
    case both
}

/// Semantic buttons, as a superset across every controller we support.
///
/// Members are named for what they *are* on the physical device, not for what
/// they currently map to in ALVR. A Steam Controller paddle is `.leftPaddle1`
/// even while the active profile emulates Quest Touch and drops it on the floor.
/// That keeps the binding decision in one place (the profile) instead of being
/// smeared across device drivers.
struct ButtonSet: OptionSet, Hashable {
    let rawValue: UInt64

    init(rawValue: UInt64) { self.rawValue = rawValue }

    // Face buttons
    static let a                = ButtonSet(rawValue: 1 << 0)
    static let b                = ButtonSet(rawValue: 1 << 1)
    static let x                = ButtonSet(rawValue: 1 << 2)
    static let y                = ButtonSet(rawValue: 1 << 3)

    // System / meta
    static let system           = ButtonSet(rawValue: 1 << 4)   // "Steam" button
    static let menu             = ButtonSet(rawValue: 1 << 5)
    static let view             = ButtonSet(rawValue: 1 << 6)
    static let quickAccess      = ButtonSet(rawValue: 1 << 7)   // Steam Controller QAM

    // Shoulders and stick clicks
    static let leftShoulder     = ButtonSet(rawValue: 1 << 8)
    static let rightShoulder    = ButtonSet(rawValue: 1 << 9)
    static let leftStickClick   = ButtonSet(rawValue: 1 << 10)
    static let rightStickClick  = ButtonSet(rawValue: 1 << 11)

    // D-pad
    static let dpadUp           = ButtonSet(rawValue: 1 << 12)
    static let dpadDown         = ButtonSet(rawValue: 1 << 13)
    static let dpadLeft         = ButtonSet(rawValue: 1 << 14)
    static let dpadRight        = ButtonSet(rawValue: 1 << 15)

    // Back paddles. Paddle1 is the upper/inner pair, paddle2 the lower/outer,
    // matching SDL's RIGHT_PADDLE1 = R4 / RIGHT_PADDLE2 = R5 convention.
    static let leftPaddle1      = ButtonSet(rawValue: 1 << 16)
    static let leftPaddle2      = ButtonSet(rawValue: 1 << 17)
    static let rightPaddle1     = ButtonSet(rawValue: 1 << 18)
    static let rightPaddle2     = ButtonSet(rawValue: 1 << 19)

    // Trigger full-pull click, distinct from the analog pull value
    static let leftTriggerClick  = ButtonSet(rawValue: 1 << 20)
    static let rightTriggerClick = ButtonSet(rawValue: 1 << 21)

    // Touchpad touch/click
    static let leftPadTouch     = ButtonSet(rawValue: 1 << 22)
    static let rightPadTouch    = ButtonSet(rawValue: 1 << 23)
    static let leftPadClick     = ButtonSet(rawValue: 1 << 24)
    static let rightPadClick    = ButtonSet(rawValue: 1 << 25)

    // Capacitive sense — touched but not pressed
    static let leftStickTouch   = ButtonSet(rawValue: 1 << 26)
    static let rightStickTouch  = ButtonSet(rawValue: 1 << 27)
    static let leftGripTouch    = ButtonSet(rawValue: 1 << 28)
    static let rightGripTouch   = ButtonSet(rawValue: 1 << 29)

    /// Human-readable member names, for the offline debug overlay.
    var names: [String] {
        var out: [String] = []
        for (bit, name) in ButtonSet.allNames where contains(bit) { out.append(name) }
        return out
    }

    static let allNames: [(ButtonSet, String)] = [
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"),
        (.system, "System"), (.menu, "Menu"), (.view, "View"), (.quickAccess, "QAM"),
        (.leftShoulder, "L"), (.rightShoulder, "R"),
        (.leftStickClick, "L3"), (.rightStickClick, "R3"),
        (.dpadUp, "Up"), (.dpadDown, "Down"), (.dpadLeft, "Left"), (.dpadRight, "Right"),
        (.leftPaddle1, "L4"), (.leftPaddle2, "L5"),
        (.rightPaddle1, "R4"), (.rightPaddle2, "R5"),
        (.leftTriggerClick, "LTrigClick"), (.rightTriggerClick, "RTrigClick"),
        (.leftPadTouch, "LPadTouch"), (.rightPadTouch, "RPadTouch"),
        (.leftPadClick, "LPadClick"), (.rightPadClick, "RPadClick"),
        (.leftStickTouch, "LStickTouch"), (.rightStickTouch, "RStickTouch"),
        (.leftGripTouch, "LGripTouch"), (.rightGripTouch, "RGripTouch"),
    ]
}

/// Analog axes, already normalized. Sticks are -1...1 with **+Y up**
/// (OpenXR convention — note SDL negates Y because its own convention is +Y down).
/// Triggers and squeeze are 0...1.
struct AnalogAxes: Equatable {
    var leftStick  = SIMD2<Float>(0, 0)
    var rightStick = SIMD2<Float>(0, 0)
    var leftTrigger:  Float = 0
    var rightTrigger: Float = 0
    var leftSqueeze:  Float = 0
    var rightSqueeze: Float = 0
}

/// A single touchpad's state. `position` is 0...1 with the origin at bottom-left.
struct TouchpadSample: Equatable {
    var position = SIMD2<Float>(0.5, 0.5)
    var pressure: Float = 0
    var isTouched = false
    var isClicked = false
}

/// IMU sample in the **ARKit/OpenXR convention**: +X right, +Y up, +Z toward
/// the user. Drivers are responsible for rotating out of whatever frame their
/// hardware reports in, so consumers can mix sources without caring.
struct MotionSample: Equatable {
    var gyro  = SIMD3<Float>(0, 0, 0)   // radians/sec
    var accel = SIMD3<Float>(0, 0, 0)   // meters/sec^2
    /// Device-provided timestamp, monotonic in nanoseconds. Not wall-clock.
    var deviceTimestampNs: UInt64 = 0
}

/// What a device is, replacing the `controller.vendorName` string comparisons
/// that currently decide behavior in `WorldTracker.sendGamepadInputs()`.
struct DeviceIdentity: Hashable {
    enum Model: Hashable {
        case genericGamepad
        case joyCon
        case psvr2Sense
        case stylus
        case steamController
    }

    var model: Model
    var chirality: Chirality
    /// Stable per-physical-device key, used to keep device lists deduplicated.
    var instanceKey: String
    var displayName: String
}

/// One complete poll of one device.
struct InputSnapshot {
    var identity: DeviceIdentity
    var buttons = ButtonSet()
    var axes = AnalogAxes()
    var leftTouchpad:  TouchpadSample?
    var rightTouchpad: TouchpadSample?
    var motion: MotionSample?
    /// 0...1, or nil if the device does not report it.
    var battery: Float?
    /// Host time when this snapshot was taken.
    var hostTimestamp: TimeInterval = 0
}

/// Outbound haptics request, normalized.
struct HapticsCommand {
    var amplitude: Float      // 0...1
    var frequency: Float      // Hz
    var duration: TimeInterval
    var chirality: Chirality
}

/// A source of controller input.
///
/// Conformers wrap GCController, GCStylus, ARKit-tracked spatial accessories, or
/// — in the Steam Controller's case — a raw CoreBluetooth GATT connection that
/// never appears in GameController at all. That last case is precisely why this
/// protocol exists: the current code cannot represent a device that isn't a
/// `GCController`.
protocol InputDevice: AnyObject {
    var identity: DeviceIdentity { get }
    var isConnected: Bool { get }

    /// Latest state, or nil if the device has nothing new / is not ready.
    func snapshot() -> InputSnapshot?

    /// Best-effort; devices without haptics ignore this.
    func send(haptics: HapticsCommand)
}

extension InputDevice {
    func send(haptics: HapticsCommand) {}
}
