//
//  InteractionProfile.swift
//
//  Declarative mapping from a device-neutral InputSnapshot onto ALVR button
//  paths.
//
//  This exists so that "what the device reports" and "what SteamVR is told"
//  can change independently. Today the Steam Controller rides the Quest
//  emulation table because ALVR has no binding for it; when the real SteamVR
//  binding JSON turns up it becomes a second table plus a profile ID, which is
//  the same shape PSVR2 already uses (see WorldTracker.psvrInteractionProfile).
//

import Foundation

/// An analog value pulled out of a snapshot.
enum ScalarSource {
    case leftTrigger, rightTrigger
    case leftSqueeze, rightSqueeze
    case leftStickX, leftStickY
    case rightStickX, rightStickY
    case leftPadX, leftPadY, leftPadPressure
    case rightPadX, rightPadY, rightPadPressure

    func value(in snap: InputSnapshot) -> Float {
        switch self {
        case .leftTrigger:  return snap.axes.leftTrigger
        case .rightTrigger: return snap.axes.rightTrigger
        case .leftSqueeze:  return snap.axes.leftSqueeze
        case .rightSqueeze: return snap.axes.rightSqueeze
        case .leftStickX:   return snap.axes.leftStick.x
        case .leftStickY:   return snap.axes.leftStick.y
        case .rightStickX:  return snap.axes.rightStick.x
        case .rightStickY:  return snap.axes.rightStick.y
        // Touchpad position is stored 0...1 but OpenXR trackpad axes are
        // -1...1, so recentre. A pad that isn't being touched reports 0
        // rather than its last position, matching how sticks behave at rest.
        case .leftPadX:  return snap.leftTouchpad.map { $0.isTouched ? $0.position.x * 2 - 1 : 0 } ?? 0
        case .leftPadY:  return snap.leftTouchpad.map { $0.isTouched ? $0.position.y * 2 - 1 : 0 } ?? 0
        case .rightPadX: return snap.rightTouchpad.map { $0.isTouched ? $0.position.x * 2 - 1 : 0 } ?? 0
        case .rightPadY: return snap.rightTouchpad.map { $0.isTouched ? $0.position.y * 2 - 1 : 0 } ?? 0
        case .leftPadPressure:  return snap.leftTouchpad?.pressure ?? 0
        case .rightPadPressure: return snap.rightTouchpad?.pressure ?? 0
        }
    }
}

/// Where a binding's value comes from.
enum BindingSource {
    /// Binary: true when *any* of these buttons is held.
    case buttons(ButtonSet)
    /// Scalar, straight from an axis.
    case scalar(ScalarSource)
    /// Scalar, but any of `buttons` being held forces 1.0.
    /// Mirrors the existing `max(shoulder.value, dpad.up ? 1.0 : 0.0)` idiom.
    case scalarOrButtons(ScalarSource, ButtonSet)
}

/// Bindings are tagged so callers can suppress a subset without the profile
/// needing to know why. Emulated pinch interactions currently take over the
/// triggers, which is what the scattered `leftPinchTrigger <= 0.0` guards in
/// WorldTracker are doing today.
enum BindingGroup {
    case general
    case leftTrigger
    case rightTrigger
}

struct InputBinding {
    let source: BindingSource
    /// An ALVR path ID from `alvr_path_string_to_id`.
    let target: UInt64
    var group: BindingGroup = .general

    init(_ source: BindingSource, _ target: UInt64, group: BindingGroup = .general) {
        self.source = source
        self.target = target
        self.group = group
    }
}

/// A named set of bindings, optionally announcing a real OpenXR interaction
/// profile to the server.
struct InteractionProfile {
    let name: String
    /// Path ID of the OpenXR interaction profile, or nil to leave whatever the
    /// server already assumes. Nil is correct while we emulate another
    /// controller rather than declaring our own.
    let profilePathId: UInt64?
    let bindings: [InputBinding]
}

/// Which binding groups to skip this frame.
struct BindingSuppression {
    var leftTrigger = false
    var rightTrigger = false

    static let none = BindingSuppression()

    func suppresses(_ group: BindingGroup) -> Bool {
        switch group {
        case .general:      return false
        case .leftTrigger:  return leftTrigger
        case .rightTrigger: return rightTrigger
        }
    }
}

// MARK: - Evaluation

enum InputRouter {
    /// Evaluates `profile` against `snapshot` and pushes the result to `sink`.
    static func route(snapshot: InputSnapshot,
                      profile: InteractionProfile,
                      suppression: BindingSuppression = .none,
                      to sink: InputSink) {
        sink.record(snapshot: snapshot)
        for binding in profile.bindings {
            guard !suppression.suppresses(binding.group) else { continue }
            switch binding.source {
            case .buttons(let set):
                sink.send(pathId: binding.target, bool: !snapshot.buttons.isDisjoint(with: set))
            case .scalar(let src):
                sink.send(pathId: binding.target, scalar: src.value(in: snapshot))
            case .scalarOrButtons(let src, let set):
                let held = !snapshot.buttons.isDisjoint(with: set)
                sink.send(pathId: binding.target, scalar: held ? 1.0 : src.value(in: snapshot))
            }
        }
    }
}

// MARK: - Valve path vocabulary

/// ALVR path IDs for inputs Valve's Roy controllers expose but WorldTracker's
/// existing constants don't cover.
///
/// `alvr_path_string_to_id` will hash any string, so these are safe to create
/// client-side — but ALVR's streamer implements no Roy bindings today, so
/// anything sent here currently lands nowhere. They exist so the mapping is
/// written down and testable, not because they work end-to-end yet.
///
/// Path list came from RE of vrlink. Note Valve's own data has
/// `/user/hand/leftinput/view/*` missing a slash; we use the corrected path,
/// which means `view` will not bind against stock SteamVR even once Roy
/// support lands. Revisit if bit-compatibility turns out to matter.
enum ValvePaths {
    // Bumpers — distinct from squeeze on Roy, unlike Quest Touch which has no
    // shoulder buttons at all.
    static let leftBumperClick  = alvr_path_string_to_id("/user/hand/left/input/bumper/click")
    static let leftBumperTouch  = alvr_path_string_to_id("/user/hand/left/input/bumper/touch")
    static let rightBumperClick = alvr_path_string_to_id("/user/hand/right/input/bumper/click")
    static let rightBumperTouch = alvr_path_string_to_id("/user/hand/right/input/bumper/touch")

    // D-pad lives on the left hand and is four discrete inputs, not an axis.
    static let dpadUpClick    = alvr_path_string_to_id("/user/hand/left/input/dpad_up/click")
    static let dpadDownClick  = alvr_path_string_to_id("/user/hand/left/input/dpad_down/click")
    static let dpadLeftClick  = alvr_path_string_to_id("/user/hand/left/input/dpad_left/click")
    static let dpadRightClick = alvr_path_string_to_id("/user/hand/left/input/dpad_right/click")

    static let leftViewClick = alvr_path_string_to_id("/user/hand/left/input/view/click")

    // Trackpads: Roy has none, so there is no Valve-blessed path for the Steam
    // Controller's pads. These follow Index/Vive vocabulary as a placeholder.
    static let leftTrackpadX     = alvr_path_string_to_id("/user/hand/left/input/trackpad/x")
    static let leftTrackpadY     = alvr_path_string_to_id("/user/hand/left/input/trackpad/y")
    static let leftTrackpadClick = alvr_path_string_to_id("/user/hand/left/input/trackpad/click")
    static let leftTrackpadTouch = alvr_path_string_to_id("/user/hand/left/input/trackpad/touch")
    static let leftTrackpadForce = alvr_path_string_to_id("/user/hand/left/input/trackpad/force")
    static let rightTrackpadX     = alvr_path_string_to_id("/user/hand/right/input/trackpad/x")
    static let rightTrackpadY     = alvr_path_string_to_id("/user/hand/right/input/trackpad/y")
    static let rightTrackpadClick = alvr_path_string_to_id("/user/hand/right/input/trackpad/click")
    static let rightTrackpadTouch = alvr_path_string_to_id("/user/hand/right/input/trackpad/touch")
    static let rightTrackpadForce = alvr_path_string_to_id("/user/hand/right/input/trackpad/force")

    // Back paddles: no precedent anywhere in Valve's data. Invented, and the
    // most likely of these to change once a real profile exists.
    static let leftPaddle1Click  = alvr_path_string_to_id("/user/hand/left/input/paddle1/click")
    static let leftPaddle2Click  = alvr_path_string_to_id("/user/hand/left/input/paddle2/click")
    static let rightPaddle1Click = alvr_path_string_to_id("/user/hand/right/input/paddle1/click")
    static let rightPaddle2Click = alvr_path_string_to_id("/user/hand/right/input/paddle2/click")
}

// MARK: - Profiles

extension InteractionProfile {
    /// Steam Controller mapped onto Quest Touch bindings.
    ///
    /// ALVR has no Steam Controller interaction profile yet, so this emulates
    /// Touch the same way the existing generic-gamepad path does (see the
    /// "we're emulating Quest controllers bc we don't have a real input
    /// profile" comment in WorldTracker.sendGamepadInputs).
    ///
    /// Deliberately unmapped: L4/L5/R4/R5 paddles, QAM, both touchpads, and
    /// grip capsense. There is nothing meaningful to bind them to under Touch,
    /// and inventing aliases would have to be un-learned once real bindings
    /// exist. They remain visible in the snapshot, so the debug overlay still
    /// proves the BLE layer sees them.
    static func steamControllerQuestEmulation() -> InteractionProfile {
        InteractionProfile(
            name: "Steam Controller (Quest Touch emulation)",
            profilePathId: nil,
            bindings: [
                // Face buttons. A single unit drives both virtual hands, so the
                // face cluster goes to the right hand and the d-pad stands in
                // for the left hand's cluster — matching the existing gamepad path.
                InputBinding(.buttons(.a), WorldTracker.rightButtonA),
                InputBinding(.buttons(.b), WorldTracker.rightButtonB),
                InputBinding(.buttons(.y), WorldTracker.rightButtonY),
                InputBinding(.buttons(.dpadRight), WorldTracker.leftButtonY),
                InputBinding(.buttons([.dpadDown, .dpadLeft]), WorldTracker.leftButtonX),

                // Triggers. Click comes from the controller's own full-pull
                // detent rather than a threshold on the analog value.
                InputBinding(.buttons(.leftTriggerClick), WorldTracker.leftTriggerClick, group: .leftTrigger),
                InputBinding(.scalar(.leftTrigger), WorldTracker.leftTriggerValue, group: .leftTrigger),
                InputBinding(.buttons(.rightTriggerClick), WorldTracker.rightTriggerClick, group: .rightTrigger),
                InputBinding(.scalar(.rightTrigger), WorldTracker.rightTriggerValue, group: .rightTrigger),

                // Shoulders act as squeeze. Unlike the generic gamepad path we
                // have real L/R separate from the triggers, so nothing needs to
                // be folded in from the d-pad.
                InputBinding(.buttons(.leftShoulder), WorldTracker.leftSqueezeClick),
                InputBinding(.scalarOrButtons(.leftSqueeze, .leftShoulder), WorldTracker.leftSqueezeValue),
                InputBinding(.scalarOrButtons(.leftSqueeze, .leftShoulder), WorldTracker.leftSqueezeForce),
                InputBinding(.buttons(.rightShoulder), WorldTracker.rightSqueezeClick),
                InputBinding(.scalarOrButtons(.rightSqueeze, .rightShoulder), WorldTracker.rightSqueezeValue),
                InputBinding(.scalarOrButtons(.rightSqueeze, .rightShoulder), WorldTracker.rightSqueezeForce),

                // Thumbsticks
                InputBinding(.scalar(.leftStickX), WorldTracker.leftThumbstickX),
                InputBinding(.scalar(.leftStickY), WorldTracker.leftThumbstickY),
                InputBinding(.scalar(.rightStickX), WorldTracker.rightThumbstickX),
                InputBinding(.scalar(.rightStickY), WorldTracker.rightThumbstickY),
                InputBinding(.buttons(.leftStickClick), WorldTracker.leftThumbstickClick),
                InputBinding(.buttons(.rightStickClick), WorldTracker.rightThumbstickClick),
                InputBinding(.buttons(.leftStickTouch), WorldTracker.leftThumbstickTouched),
                InputBinding(.buttons(.rightStickTouch), WorldTracker.rightThumbstickTouched),

                // System / menu. The existing path sends the same value to both
                // system and menu because it is unclear which one lands.
                InputBinding(.buttons(.system), WorldTracker.leftSystemClick),
                InputBinding(.buttons(.system), WorldTracker.leftMenuClick),
                InputBinding(.buttons([.menu, .view]), WorldTracker.rightSystemClick),
                InputBinding(.buttons([.menu, .view]), WorldTracker.rightMenuClick),
            ]
        )
    }

    /// Steam Controller mapped onto Valve's Roy vocabulary.
    ///
    /// Best-effort and **not currently consumable** — ALVR's streamer has no
    /// Roy bindings, so most of this lands nowhere until that changes. It is
    /// written now because the mapping is far more faithful than Quest
    /// emulation and the Roy path list is known; swapping to it later should be
    /// a profile selection, not a redesign.
    ///
    /// The layout split follows Roy's own asymmetry, which happens to match the
    /// Steam Controller's physical arrangement: d-pad and View on the left,
    /// ABXY and Menu on the right, bumpers and sticks on both.
    ///
    /// Caveats, worst first:
    ///   - Paddle paths are invented; nothing in Valve's data names them.
    ///   - Trackpad paths borrow Index/Vive vocabulary; Roy has no pads.
    ///   - `view` uses the corrected path, not Valve's missing-slash variant.
    ///   - QAM is folded onto right `system`, which is a guess.
    ///   - Roy exposes no `trigger/click`; we send it anyway because the Steam
    ///     Controller has a real hardware detent and the data is better than
    ///     a threshold.
    ///   - The left/right split assumes the physical layout; unverified against
    ///     hardware.
    static func steamControllerRoyEmulation() -> InteractionProfile {
        InteractionProfile(
            name: "Steam Controller (Roy vocabulary, provisional)",
            profilePathId: nil,   // XR_VALVE_roy_interaction, once ALVR knows it
            bindings: [
                // Right hand: full ABXY cluster plus Menu.
                InputBinding(.buttons(.a), WorldTracker.rightButtonA),
                InputBinding(.buttons(.b), WorldTracker.rightButtonB),
                InputBinding(.buttons(.x), WorldTracker.rightButtonX),
                InputBinding(.buttons(.y), WorldTracker.rightButtonY),
                InputBinding(.buttons(.menu), WorldTracker.rightMenuClick),

                // Left hand: d-pad as four discrete inputs, plus View.
                InputBinding(.buttons(.dpadUp), ValvePaths.dpadUpClick),
                InputBinding(.buttons(.dpadDown), ValvePaths.dpadDownClick),
                InputBinding(.buttons(.dpadLeft), ValvePaths.dpadLeftClick),
                InputBinding(.buttons(.dpadRight), ValvePaths.dpadRightClick),
                InputBinding(.buttons(.view), ValvePaths.leftViewClick),

                // System. Steam button on the left, QAM folded onto right system.
                InputBinding(.buttons(.system), WorldTracker.leftSystemClick),
                InputBinding(.buttons(.quickAccess), WorldTracker.rightSystemClick),

                // Bumpers, kept distinct from squeeze the way Roy does.
                InputBinding(.buttons(.leftShoulder), ValvePaths.leftBumperClick),
                InputBinding(.buttons(.leftShoulder), ValvePaths.leftBumperTouch),
                InputBinding(.buttons(.rightShoulder), ValvePaths.rightBumperClick),
                InputBinding(.buttons(.rightShoulder), ValvePaths.rightBumperTouch),

                // Triggers.
                InputBinding(.scalar(.leftTrigger), WorldTracker.leftTriggerValue, group: .leftTrigger),
                InputBinding(.buttons(.leftTriggerClick), WorldTracker.leftTriggerClick, group: .leftTrigger),
                InputBinding(.buttons(.leftTriggerClick), WorldTracker.leftTriggerTouched, group: .leftTrigger),
                InputBinding(.scalar(.rightTrigger), WorldTracker.rightTriggerValue, group: .rightTrigger),
                InputBinding(.buttons(.rightTriggerClick), WorldTracker.rightTriggerClick, group: .rightTrigger),
                InputBinding(.buttons(.rightTriggerClick), WorldTracker.rightTriggerTouched, group: .rightTrigger),

                // Squeeze. The Steam Controller has grip capsense but no analog
                // grip, so only the touch path carries real information.
                InputBinding(.buttons(.leftGripTouch), WorldTracker.leftSqueezeTouched),
                InputBinding(.buttons(.rightGripTouch), WorldTracker.rightSqueezeTouched),

                // Thumbsticks, including genuine capsense touch.
                InputBinding(.scalar(.leftStickX), WorldTracker.leftThumbstickX),
                InputBinding(.scalar(.leftStickY), WorldTracker.leftThumbstickY),
                InputBinding(.buttons(.leftStickClick), WorldTracker.leftThumbstickClick),
                InputBinding(.buttons(.leftStickTouch), WorldTracker.leftThumbstickTouched),
                InputBinding(.scalar(.rightStickX), WorldTracker.rightThumbstickX),
                InputBinding(.scalar(.rightStickY), WorldTracker.rightThumbstickY),
                InputBinding(.buttons(.rightStickClick), WorldTracker.rightThumbstickClick),
                InputBinding(.buttons(.rightStickTouch), WorldTracker.rightThumbstickTouched),

                // Trackpads and paddles — provisional vocabulary, see caveats.
                InputBinding(.buttons(.leftPadTouch), ValvePaths.leftTrackpadTouch),
                InputBinding(.buttons(.leftPadClick), ValvePaths.leftTrackpadClick),
                InputBinding(.scalar(.leftPadX), ValvePaths.leftTrackpadX),
                InputBinding(.scalar(.leftPadY), ValvePaths.leftTrackpadY),
                InputBinding(.scalar(.leftPadPressure), ValvePaths.leftTrackpadForce),
                InputBinding(.buttons(.rightPadTouch), ValvePaths.rightTrackpadTouch),
                InputBinding(.buttons(.rightPadClick), ValvePaths.rightTrackpadClick),
                InputBinding(.scalar(.rightPadX), ValvePaths.rightTrackpadX),
                InputBinding(.scalar(.rightPadY), ValvePaths.rightTrackpadY),
                InputBinding(.scalar(.rightPadPressure), ValvePaths.rightTrackpadForce),
                InputBinding(.buttons(.leftPaddle1), ValvePaths.leftPaddle1Click),
                InputBinding(.buttons(.leftPaddle2), ValvePaths.leftPaddle2Click),
                InputBinding(.buttons(.rightPaddle1), ValvePaths.rightPaddle1Click),
                InputBinding(.buttons(.rightPaddle2), ValvePaths.rightPaddle2Click),
            ]
        )
    }
}
