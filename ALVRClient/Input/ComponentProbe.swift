//
//  ComponentProbe.swift
//
//  Measures where the Steam Controller's sticks and pads are, using the thumb.
//
//  The `ibex_ev1` rendermodel we have is the body shell only — no sticks, no
//  pads, no buttons — so their positions are simply unknown. But the device
//  reports capsense for all of them, and the headset can see the thumb that is
//  doing the touching. Put those together and the geometry falls out: while
//  `.leftStickTouch` is set, the left thumb tip *is* on the left stick, so
//  carrying it into model space and averaging gives that stick's position.
//
//  This exists to be read and then thrown away. The output is meant to be
//  transcribed into `IbexModel` as constants once the numbers settle; nothing
//  in the pose path consumes it.
//
//  # What this measurement rests on
//
//  Exactly two things: the grip anchors measured off the mesh, and the fused
//  orientation. Deliberately **not** `IbexModel.mountCorrection` — that constant
//  was tuned by eye, and one of its two terms is itself a guess about stick
//  height. Folding it in would make this circular: the probe would dutifully
//  report back the assumption it was handed. So samples are taken relative to
//  the raw anchors and the correction is added back out.
//
//  Orientation error still propagates, which is why samples are only taken with
//  both hands on the device — that is the case where yaw is measured rather
//  than integrated.
//
//  # The circularity, stated properly
//
//  The pose is solved *from* the palms: `position = palm - q.act(anchor)`. So
//  any joint J carried back through it gives
//
//      q⁻¹(J - position) = q⁻¹(J - palm) + anchor
//
//  — the grip anchor survives as an **additive constant**. An anchor that is
//  wrong by δ makes every estimate wrong by exactly δ. No amount of averaging
//  removes it, because it is not noise.
//
//  Two consequences worth being clear about:
//
//  - *Differences* between estimates are clean. `stickSeparation()` is the
//    obvious one; so is stick-to-pad offset. A global δ cancels.
//  - *Absolute* positions are only as good as the anchors, so on their own they
//    cannot be used to check the anchors. That is the same statement twice.
//
//  What breaks it is an **independent reference**, and Valve's mechanical CAD
//  is a very good one: the sticks and pads are now known to a fraction of a
//  millimetre. So a measured position is only interesting as a **residual** —
//  the vector from where the CAD says the stick is to where the solved pose
//  puts the thumb that is provably touching it. That residual *is* δ, plus the
//  fingertip-versus-finger-pad offset noted below.
//
//  Four residuals from two hands over-determine δ, so they also cross-check
//  each other: a δ that is real shows up in all four the same way, while one
//  bad estimate shows up alone.
//

import Foundation
import simd

/// A running estimate of one component's position in model space.
struct ComponentEstimate {
    /// Mean position, metres, in `IbexModel`'s frame, correction excluded.
    var mean: simd_float3
    /// Per-axis standard deviation. This is the number that says whether the
    /// mean means anything — a stick pressed from different thumb angles should
    /// land within a few mm, and a spread much larger than that says the pose
    /// was moving while sampling.
    var spread: simd_float3
    var count: Int
}

final class ComponentProbe {

    enum Site: String, CaseIterable, Identifiable {
        // Thumb reaches the controls on the top face.
        case leftStick, rightStick, leftPad, rightPad
        // Index finger reaches the front of the handle. Two states, because
        // they are different points: where the finger rests on an unpulled
        // trigger, and where it ends up at full travel.
        case leftIndexRest, rightIndexRest
        case leftTriggerPull, rightTriggerPull

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .leftStick:       return "L stick"
            case .rightStick:      return "R stick"
            case .leftPad:         return "L pad"
            case .rightPad:        return "R pad"
            case .leftIndexRest:   return "L index rest"
            case .rightIndexRest:  return "R index rest"
            case .leftTriggerPull: return "L trigger pull"
            case .rightTriggerPull:return "R trigger pull"
            }
        }

        /// Which hand the joint belongs to.
        var isLeft: Bool {
            switch self {
            case .leftStick, .leftPad, .leftIndexRest, .leftTriggerPull: return true
            default: return false
            }
        }

        /// Which fingertip lands on this component.
        var usesIndexFinger: Bool {
            switch self {
            case .leftIndexRest, .rightIndexRest, .leftTriggerPull, .rightTriggerPull: return true
            default: return false
            }
        }

        /// Where the CAD says this component is, when it says anything.
        ///
        /// This is what turned the probe from a measuring tool into a checking
        /// one. The sticks and pads are now known to a fraction of a millimetre,
        /// so a measured position is only interesting as a *residual* — how far
        /// the solved pose puts the thumb from where the thumb demonstrably is.
        ///
        /// nil for the index-finger sites: the trigger is a moving part and the
        /// CAD captures one position of it, so there is no single right answer
        /// to compare against.
        var expected: simd_float3? {
            switch self {
            case .leftStick:  return IbexModel.leftStickCentre
            case .rightStick: return IbexModel.rightStickCentre
            case .leftPad:    return IbexModel.leftPadCentre
            case .rightPad:   return IbexModel.rightPadCentre
            default:          return nil
            }
        }

        /// Whether this frame's report says the component is being touched.
        ///
        /// The trigger has no capsense, but its **analog pull is itself a
        /// contact signal** — past half travel the fingertip is unambiguously
        /// on it. The resting case is gated on the trigger being all the way
        /// out, so the two sites stay cleanly separated instead of smearing
        /// across the trigger's travel.
        func isTouched(in snapshot: InputSnapshot) -> Bool {
            let trigger = isLeft ? snapshot.axes.leftTrigger : snapshot.axes.rightTrigger
            switch self {
            case .leftStick:        return snapshot.buttons.contains(.leftStickTouch)
            case .rightStick:       return snapshot.buttons.contains(.rightStickTouch)
            case .leftPad:          return snapshot.buttons.contains(.leftPadTouch)
            case .rightPad:         return snapshot.buttons.contains(.rightPadTouch)
            case .leftIndexRest, .rightIndexRest:     return trigger < 0.05
            case .leftTriggerPull, .rightTriggerPull: return trigger > 0.5
            }
        }
    }

    /// Minimum confidence before a sample counts. Effectively "both grips held
    /// and nothing stale", which is the only state where the pose is measured
    /// rather than dead-reckoned.
    private static let minimumConfidence: Float = 0.9

    /// Welford accumulator. Streaming rather than keeping every sample: this
    /// runs at the tracking rate and could otherwise collect tens of thousands
    /// of points in a sitting.
    private struct Accumulator {
        var count = 0
        var mean = simd_float3()
        var m2 = simd_float3()

        mutating func add(_ v: simd_float3) {
            count += 1
            let delta = v - mean
            mean += delta / Float(count)
            m2 += delta * (v - mean)
        }

        var estimate: ComponentEstimate? {
            guard count > 0 else { return nil }
            let variance = count > 1 ? m2 / Float(count - 1) : simd_float3()
            return ComponentEstimate(mean: mean,
                                     spread: simd_float3(sqrt(variance.x), sqrt(variance.y), sqrt(variance.z)),
                                     count: count)
        }
    }

    /// Why samples are being thrown away.
    ///
    /// Exists because "the probe measures nothing" is indistinguishable from
    /// the outside across six different guards, and guessing which one is
    /// firing costs a hardware round-trip each time. Each counter is a
    /// different diagnosis: `gatedByGrip` means capsense is not reporting a
    /// two-handed hold, `gatedByTouch` means the control's own capsense never
    /// fires, `gatedByJoint` means ARKit is not giving up fingertip joints for
    /// a hand wrapped around a controller, and `gatedByBounds` means the pose
    /// is wrong rather than the plumbing.
    struct Diagnostics {
        var calls = 0
        var gatedByConfidence = 0
        var gatedByGrip = 0
        var gatedByTouch = 0
        var gatedByTracking = 0
        var gatedByJoint = 0
        var gatedByBounds = 0
        var accepted = 0
    }

    private let lock = NSLock()
    private var accumulators: [Site: Accumulator] = [:]
    private var diag = Diagnostics()

    func diagnostics() -> Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return diag
    }

    /// Folds one frame's worth of touches into the estimates.
    func observe(pose: FusedControllerPose,
                 snapshot: InputSnapshot,
                 left: HandObservation?,
                 right: HandObservation?) {
        lock.lock(); diag.calls += 1; lock.unlock()
        guard pose.confidence >= Self.minimumConfidence else {
            lock.lock(); diag.gatedByConfidence += 1; lock.unlock(); return
        }
        guard pose.heldLeft, pose.heldRight else {
            lock.lock(); diag.gatedByGrip += 1; lock.unlock(); return
        }

        for site in Site.allCases {
            guard site.isTouched(in: snapshot) else {
                lock.lock(); diag.gatedByTouch += 1; lock.unlock(); continue
            }
            guard let hand = site.isLeft ? left : right, hand.isTracked else {
                lock.lock(); diag.gatedByTracking += 1; lock.unlock(); continue
            }
            guard let joint = site.usesIndexFinger ? hand.indexTip : hand.thumbTip else {
                lock.lock(); diag.gatedByJoint += 1; lock.unlock(); continue
            }

            // Into model space, then add the mount correction back out so the
            // result is relative to the mesh-measured anchors rather than to the
            // tuned placement. See the note at the top of the file.
            let modelPoint = pose.orientation.inverse.act(joint - pose.position) + IbexModel.mountCorrection

            // Reject anything outside the shell by a wide margin. A thumb that
            // is touching a stick is on the device by definition, so a wild
            // sample means the pose was wrong, not that the stick moved.
            let slack: Float = 0.05
            let lo = IbexModel.boundsMin - simd_float3(repeating: slack)
            let hi = IbexModel.boundsMax + simd_float3(repeating: slack)
            guard modelPoint.x >= lo.x, modelPoint.y >= lo.y, modelPoint.z >= lo.z,
                  modelPoint.x <= hi.x, modelPoint.y <= hi.y, modelPoint.z <= hi.z else {
                lock.lock(); diag.gatedByBounds += 1; lock.unlock(); continue
            }

            lock.lock()
            accumulators[site, default: Accumulator()].add(modelPoint)
            diag.accepted += 1
            lock.unlock()
        }
    }

    func estimate(_ site: Site) -> ComponentEstimate? {
        lock.lock(); defer { lock.unlock() }
        return accumulators[site]?.estimate
    }

    /// Distance between the two sticks, once both have samples. Worth reading
    /// separately because it is the one figure a global placement error cannot
    /// touch — shifting the whole body moves both estimates equally.
    func stickSeparation() -> Float? {
        guard let l = estimate(.leftStick), let r = estimate(.rightStick) else { return nil }
        return simd_distance(l.mean, r.mean)
    }

    func reset() {
        lock.lock()
        accumulators.removeAll()
        diag = Diagnostics()
        lock.unlock()
    }
}
