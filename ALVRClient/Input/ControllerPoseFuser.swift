//
//  ControllerPoseFuser.swift
//
//  6DoF pose for a device that has no 6DoF tracking.
//
//  The Steam Controller (2026) reports gyro and accel and nothing else: no
//  constellation, no ARKit AccessoryAnchor, no magnetometer. On its own that is
//  3DoF at best, and yaw walks away within seconds. What makes it tractable is
//  that the device has **capsense on both grips** and the headset can already
//  see the hands holding it. So the hands supply position and an absolute yaw
//  reference, and the IMU supplies the responsiveness the hands lack.
//
//  Division of labour:
//
//  | Quantity     | Source                        | Why not the other one |
//  |--------------|-------------------------------|-----------------------|
//  | position     | hand anchors, exclusively     | double-integrating accel diverges in seconds |
//  | fast rotation| gyro, integrated at ~68Hz     | hand anchors are slower and jitter under occlusion |
//  | pitch/roll   | gravity from accel, low gain  | gyro alone drifts |
//  | yaw          | hand geometry, low gain       | there is no magnetometer; nothing else observes it |
//
//  The two-handed case is the good one: both grip anchors are known in model
//  space, so the vector between the two palms *is* the device's X axis, and yaw
//  is measured rather than integrated. One hand is weaker — position is still
//  solid, but yaw leans on the palm's own orientation. No hands at all is dead
//  reckoning, and the pose is marked unconfident so callers can ignore it.
//
//  Deliberately free of ARKit and CoreBluetooth so it compiles under the macOS
//  harness in `tools/steam-controller-harness/` alongside the driver.
//

import Foundation
import simd

/// One hand as observed by the headset, in **ARKit world space**.
///
/// The fuser works in Apple's frame throughout and leaves the conversion to
/// SteamVR space to the caller, exactly as `controllerToAlvrDeviceMotion` does.
/// Mixing the two inside a filter is how sign errors get buried.
struct HandObservation {
    /// OpenXR palm point — midpoint of middle metacarpal and knuckle.
    var palmPosition: simd_float3
    /// Wrist orientation, uncorrected.
    var palmOrientation: simd_quatf
    var isTracked: Bool
    /// Thumb tip, when the skeleton provides one. Not used by the filter —
    /// `ComponentProbe` uses it to work out where the sticks and pads are,
    /// since the rendermodel we have does not say.
    var thumbTip: simd_float3?
    /// Index fingertip. The other half of the same measurement: the thumb
    /// reaches the controls on the top face, the index finger reaches the
    /// trigger on the front of the handle.
    var indexTip: simd_float3?
}

/// Fused controller pose, in ARKit world space.
struct FusedControllerPose {
    var orientation: simd_quatf
    /// Model origin, i.e. where `IbexModel`'s frame is planted.
    var position: simd_float3
    var linearVelocity: simd_float3
    var angularVelocity: simd_float3
    /// How much of the pose is actually observed rather than dead-reckoned.
    /// 1.0 = both hands on the device, 0.0 = nothing has been seen for a while.
    var confidence: Float
    /// Which grips capsense reports as held, for the debug overlay.
    var heldLeft: Bool
    var heldRight: Bool
}

final class ControllerPoseFuser {

    // MARK: - Tuning
    //
    // Gains are per-second and scaled by dt at use, so they do not silently
    // change meaning when the report rate does — and it does change here, from
    // ~68Hz nominal down to ~51Hz whenever rumble is running.

    /// How hard gravity pulls pitch/roll back. Low: gravity is only clean when
    /// the device is not being accelerated, and it is usually being accelerated.
    private static let gravityGain: Float = 1.2

    /// How hard a two-handed grip pulls the whole orientation back. Higher than
    /// the single-handed case because the measurement is genuinely good.
    private static let twoHandGain: Float = 6.0

    /// How hard a single palm pulls yaw back. Deliberately feeble — a wrist
    /// rolls freely around a handle, so this is a bias correction, not a fix.
    private static let oneHandYawGain: Float = 0.8

    /// Per-frame blend for the learned per-hand rotation and anchor. Slow:
    /// these describe how someone is holding the thing, which changes over
    /// seconds, while ARKit's per-frame view of an occluded hand does not.
    private static let learnRate: Float = 0.02

    /// Accel magnitudes further than this from g are treated as manoeuvring and
    /// contribute nothing to attitude.
    private static let gravityToleranceMS2: Float = 1.5
    private static let gravityMS2: Float = 9.81

    /// Position smoothing, per second. The hands are the only position source
    /// and they jitter; this is the same trade the existing hand path makes with
    /// its EWMA, just expressed in a rate rather than a per-frame constant.
    private static let positionGain: Float = 22.0

    /// How long a pose survives with no hand observation before confidence
    /// bottoms out. Long enough to ride out a hand leaving the camera frustum,
    /// short enough that a put-down controller stops being believed.
    private static let deadReckonHorizon: TimeInterval = 0.75

    // MARK: - State

    private var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var position = simd_float3(0, 0, 0)
    private var linearVelocity = simd_float3(0, 0, 0)
    private var angularVelocity = simd_float3(0, 0, 0)

    private var lastMotionStamp: TimeInterval = 0
    private var lastObservationStamp: TimeInterval = 0
    private var hasOrientation = false
    private var hasPosition = false

    // Learned while both hands are on the device, which is the only state where
    // the pose is fully observed. Both are nil until that has happened once.
    //
    // These exist because the nominal model describes an idealised hand on an
    // idealised handle, and neither the hand nor the grasp is idealised. Rather
    // than tune constants for one person's hands, the filter watches what the
    // hands actually do while it can see the answer.

    /// Rotation from each wrist frame to the device frame.
    private var leftHandRotationOffset: simd_quatf?
    private var rightHandRotationOffset: simd_quatf?

    /// Where each palm actually sits in model space, as opposed to where the
    /// nominal grip anchor says it should.
    private var leftHandAnchor: simd_float3?
    private var rightHandAnchor: simd_float3?

    /// Set during the orientation stage, consumed by the learning stage after
    /// position has been solved — the anchor cannot be learned until there is a
    /// position to measure it against.
    private var twoHandedThisFrame = false

    /// Reset to the state a fresh connection should have.
    func reset() {
        orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        position = .zero
        linearVelocity = .zero
        angularVelocity = .zero
        lastMotionStamp = 0
        lastObservationStamp = 0
        hasOrientation = false
        hasPosition = false
        leftHandRotationOffset = nil
        rightHandRotationOffset = nil
        leftHandAnchor = nil
        rightHandAnchor = nil
        twoHandedThisFrame = false
    }

    // MARK: - Update

    /// Folds one controller report and the current hand anchors into the pose.
    ///
    /// Returns nil until there is enough to place the device at all, which means
    /// at least one hand has been seen holding it once. Orientation alone is not
    /// enough — a pose at the world origin would draw the controller inside the
    /// floor and look like a tracking bug rather than a missing observation.
    @discardableResult
    func update(snapshot: InputSnapshot,
                left: HandObservation?,
                right: HandObservation?,
                now: TimeInterval) -> FusedControllerPose? {

        // Host time, not `motion.deviceTimestampNs`. The device clock is
        // monotonic but unrelated to the clock the hand anchors are stamped
        // with, and this filter mixes the two sources every step.
        var dt = Float(now - lastMotionStamp)
        if lastMotionStamp == 0 || dt <= 0 || dt > 0.25 {
            dt = 1.0 / 68.0     // nominal report interval
        }
        lastMotionStamp = now

        // Snapshots are pulled, not pushed, and this runs at the 90Hz display
        // rate against a ~68Hz device — so the same report is routinely seen
        // more than once. That is fine and even wanted: gyro is a *rate*, so
        // re-integrating the last known rate over the new interval is a correct
        // zero-order hold.
        //
        // What is not fine is a controller that has stopped reporting entirely.
        // `snapshot()` keeps handing back the last value forever, so a frozen
        // gyro would spin the pose away and a frozen capsense bit would keep
        // claiming a grip that was released — both with no indication anything
        // is wrong. Past this age the whole report is treated as absent.
        let isFresh = snapshot.hostTimestamp > 0 && (now - snapshot.hostTimestamp) < 0.2

        // Capsense decides which hands to believe. This is the only source for
        // that decision: both hands are on one rigid body, and a hand resting
        // near the controller looks identical to a hand holding it.
        let heldLeft = isFresh && snapshot.buttons.contains(.leftGripTouch)
        let heldRight = isFresh && snapshot.buttons.contains(.rightGripTouch)
        let leftHand = (heldLeft && (left?.isTracked ?? false)) ? left : nil
        let rightHand = (heldRight && (right?.isTracked ?? false)) ? right : nil

        // MARK: Orientation

        if !isFresh {
            angularVelocity = .zero
        }
        if isFresh, let motion = snapshot.motion {
            // Gyro is body-frame and already rotated into these axes by the
            // driver's `deviceToOpenXR`. Right-multiply: a body-frame delta.
            let omega = motion.gyro
            let angle = simd_length(omega) * dt
            if angle > 1e-7 {
                let axis = omega / simd_length(omega)
                orientation = simd_normalize(orientation * simd_quatf(angle: angle, axis: axis))
                hasOrientation = true
            }
            angularVelocity = orientation.act(omega)

            // Gravity fixes pitch and roll, and only those: it says nothing
            // about rotation *around* the gravity vector.
            let accel = motion.accel
            let mag = simd_length(accel)
            if abs(mag - Self.gravityMS2) < Self.gravityToleranceMS2 {
                // Specific force points *up* at rest, so the measured body-frame
                // direction is where world up currently lies in the body frame.
                //
                // `orientation` maps body to world, so the correction that makes
                // q.act(measured) land on world up is a body-frame rotation
                // taking `measured` onto `expected` — hence right-multiplication
                // and no inverse. Getting either wrong drives the filter away
                // from gravity instead of toward it, and it looks like drift.
                let measuredUpBody = accel / mag
                if hasOrientation {
                    let expectedUpBody = orientation.inverse.act(simd_float3(0, 1, 0))
                    orientation = simd_normalize(
                        orientation * partialRotation(from: measuredUpBody,
                                                      to: expectedUpBody,
                                                      fraction: min(1, Self.gravityGain * dt)))
                } else {
                    // No integration history: adopt gravity outright rather than
                    // starting at identity and swinging into place.
                    orientation = simd_quatf(from: measuredUpBody, to: simd_float3(0, 1, 0))
                    hasOrientation = true
                }
            }
        }

        // MARK: Hand-derived correction

        if let l = leftHand, let r = rightHand {
            // Both palms known: the line between them is the device's X axis.
            // Yaw is now measured, which is the entire reason this path exists.
            let span = r.palmPosition - l.palmPosition
            if simd_length(span) > 0.04 {
                let xAxis = simd_normalize(span)
                // Keep the IMU's roll about that axis — the hands do not
                // observe it, so overriding it would throw away good data.
                let faceRef = hasOrientation ? orientation.act(simd_float3(0, 1, 0)) : simd_float3(0, 1, 0)
                var zAxis = simd_cross(xAxis, faceRef)
                if simd_length(zAxis) < 1e-4 { zAxis = simd_cross(xAxis, simd_float3(0, 0, 1)) }
                zAxis = simd_normalize(zAxis)
                let yAxis = simd_cross(zAxis, xAxis)
                let target = simd_quatf(simd_float3x3(columns: (xAxis, yAxis, zAxis)))

                if hasOrientation {
                    orientation = simd_normalize(simd_slerp(orientation, alignedTo(target, orientation),
                                                            min(1, Self.twoHandGain * dt)))
                } else {
                    orientation = target
                    hasOrientation = true
                }

                twoHandedThisFrame = true
            }
        } else if hasOrientation, let single = leftHand ?? rightHand {
            // One palm. Yaw is not observable from a single point, so the only
            // honest reference is the rotation learned during a two-handed grip.
            //
            // With no calibration yet, yaw is simply *held*: it keeps
            // integrating gyro and accepts the drift. That is deliberately
            // better than pulling it toward the raw wrist orientation, which
            // would look like a fix while quietly steering the device to a
            // wrong constant heading.
            let isLeft = leftHand != nil
            if let offset = isLeft ? leftHandRotationOffset : rightHandRotationOffset {
                // Twist decomposition about world up, rather than the heading of
                // some chosen palm axis.
                //
                // The old version took `atan2` of a wrist axis projected onto
                // the floor. Hold a gamepad naturally and that axis is close to
                // vertical, where its horizontal projection is nearly zero and
                // its heading is numerically meaningless — it can swing by half
                // a turn between frames from noise alone. That is where the
                // 180° flips came from.
                let target = simd_normalize(single.palmOrientation * offset)
                let step = yawTwist(from: orientation, to: target) * min(1, Self.oneHandYawGain * dt)
                orientation = simd_normalize(simd_quatf(angle: step, axis: simd_float3(0, 1, 0)) * orientation)
            }
        }

        // MARK: Position
        //
        // Always from the hands. Nothing here integrates acceleration: over the
        // ~0.75s this filter has to survive an occlusion, double integration of
        // a 2g-range accel accumulates metres of error.

        // `mounted*` rather than the raw anchors: the measured centroids sit
        // inside the handle, and the CAD centre is not where ARKit puts a palm
        // joint on a grasped handle. See `IbexModel.mountCorrection`.
        var observed: simd_float3?
        if let l = leftHand, let r = rightHand {
            let midpoint = (l.palmPosition + r.palmPosition) * 0.5
            observed = midpoint - orientation.act(IbexModel.mountedGripCentre)
        } else if let single = leftHand ?? rightHand {
            // Use the anchor *learned for this hand* if there is one.
            //
            // The nominal anchors are where a palm should be. Real palms are
            // not there — hands differ, and people hold a controller how they
            // like. Two-handed, the solve averages the two errors and the body
            // lands between them. Drop to one hand and that hand's whole error
            // applies at once, so the controller visibly jumps at the moment of
            // release even though nothing about it moved. That is exactly the
            // symptom, and learning the per-hand anchor removes it by
            // construction: the one-handed solve reproduces what the two-handed
            // solve was already reporting.
            let isLeft = leftHand != nil
            let anchor = (isLeft ? leftHandAnchor : rightHandAnchor)
                ?? IbexModel.mountedGripAnchor(isLeft: isLeft)
            observed = single.palmPosition - orientation.act(anchor)
        }

        if let target = observed {
            lastObservationStamp = now
            if hasPosition {
                let blend = min(1, Self.positionGain * dt)
                let next = simd_mix(position, target, simd_float3(repeating: blend))
                linearVelocity = (next - position) / dt
                position = next
            } else {
                position = target
                linearVelocity = .zero
                hasPosition = true
            }
        } else if hasPosition {
            // Coast. Velocity is kept but decayed, so a hand that reappears does
            // not have to fight a stale extrapolation.
            position += linearVelocity * dt
            linearVelocity *= max(0, 1 - 4 * dt)
        }

        // MARK: Learn, while the answer is visible
        //
        // Only two-handed, and only once there is a position to measure
        // against. Slow blends on purpose: this is calibration, and a fast one
        // would just track the noise in whichever hand ARKit is currently least
        // sure about.
        if twoHandedThisFrame, hasPosition, let l = leftHand, let r = rightHand {
            learn(hand: l, isLeft: true)
            learn(hand: r, isLeft: false)
        }
        twoHandedThisFrame = false

        guard hasPosition, hasOrientation else { return nil }

        let staleness = lastObservationStamp == 0 ? Self.deadReckonHorizon : (now - lastObservationStamp)
        var confidence: Float = Float(max(0, 1 - staleness / Self.deadReckonHorizon))
        if !(heldLeft && heldRight) { confidence *= 0.6 }

        return FusedControllerPose(orientation: orientation,
                                   position: position,
                                   linearVelocity: linearVelocity,
                                   angularVelocity: angularVelocity,
                                   confidence: confidence,
                                   heldLeft: heldLeft,
                                   heldRight: heldRight)
    }

    // MARK: - Derived poses

    /// Where each virtual controller goes, given a fused pose.
    ///
    /// Both hands get a pose even when only one is holding the device, and the
    /// two move rigidly together — because they physically do. Sending the same
    /// pose to both (the obvious shortcut) puts two virtual controllers inside
    /// each other and looks wrong the instant a game draws them.
    static func handPose(_ pose: FusedControllerPose, isLeft: Bool) -> (simd_quatf, simd_float3) {
        // The same anchor that solved position, so this lands back exactly on
        // the palm. Using the raw anchor here would reintroduce the mount
        // correction as an error between the body and the virtual controllers.
        let anchor = IbexModel.mountedGripAnchor(isLeft: isLeft)
        return (pose.orientation, pose.position + pose.orientation.act(anchor))
    }

    /// Model-to-world matrix, for drawing the body wireframe.
    static func modelMatrix(_ pose: FusedControllerPose) -> simd_float4x4 {
        var m = simd_float4x4(pose.orientation)
        m.columns.3 = simd_float4(pose.position, 1)
        return m
    }

    // MARK: - Helpers

    /// A fraction of the rotation carrying `a` onto `b`.
    private func partialRotation(from a: simd_float3, to b: simd_float3, fraction: Float) -> simd_quatf {
        let full = simd_quatf(from: a, to: b)
        return simd_normalize(simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), full, fraction))
    }

    /// Rotation about world up needed to carry `a` onto `b`, in radians.
    ///
    /// Twist decomposition: take the relative rotation, keep only its component
    /// about the up axis, discard the swing. This replaced projecting a chosen
    /// axis onto the floor and taking `atan2` of it, which is degenerate exactly
    /// when that axis is vertical — the normal way to hold a gamepad — and gave
    /// meaningless headings that could flip by half a turn frame to frame.
    private func yawTwist(from a: simd_quatf, to b: simd_quatf) -> Float {
        var err = b * a.inverse
        // Both signs name the same rotation; pick the one that twists the short
        // way, or the correction happily takes the 358° route.
        if err.real < 0 { err = simd_quatf(vector: -err.vector) }
        return 2 * atan2(err.imag.y, err.real)
    }

    /// Folds one observation into a hand's learned rotation offset and anchor.
    ///
    /// Both are slewed slowly rather than snapped. They are properties of how
    /// this person holds this controller, which changes over seconds, while
    /// ARKit's per-frame estimate of an occluded hand is far noisier than that.
    private func learn(hand: HandObservation, isLeft: Bool) {
        let rotation = simd_normalize(hand.palmOrientation.inverse * orientation)
        let anchor = orientation.inverse.act(hand.palmPosition - position)

        if isLeft {
            leftHandRotationOffset = leftHandRotationOffset
                .map { simd_normalize(simd_slerp($0, alignedTo(rotation, $0), Self.learnRate)) } ?? rotation
            leftHandAnchor = leftHandAnchor
                .map { simd_mix($0, anchor, simd_float3(repeating: Self.learnRate)) } ?? anchor
        } else {
            rightHandRotationOffset = rightHandRotationOffset
                .map { simd_normalize(simd_slerp($0, alignedTo(rotation, $0), Self.learnRate)) } ?? rotation
            rightHandAnchor = rightHandAnchor
                .map { simd_mix($0, anchor, simd_float3(repeating: Self.learnRate)) } ?? anchor
        }
    }

    /// Picks the sign of `q` closest to `reference`, so slerp takes the short
    /// way round. Quaternions double-cover rotations and a basis-built one has
    /// no memory of which cover it came from; without this the correction
    /// occasionally spins the controller the long way.
    private func alignedTo(_ q: simd_quatf, _ reference: simd_quatf) -> simd_quatf {
        simd_dot(q.vector, reference.vector) < 0 ? simd_quatf(vector: -q.vector) : q
    }
}
