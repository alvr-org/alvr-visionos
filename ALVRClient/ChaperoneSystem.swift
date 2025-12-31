import ARKit
import Foundation
import simd

final class ChaperoneSystem {
    struct Output {
        let renderables: [(PlaneAnchor, simd_float4)]
#if CHAPERONE_PROFILE
        let profile: ProfileSnapshot
#endif
    }

    var baseColor = simd_float3(0.0, 0.8, 1.0) // Cyan
    var handRadius: Float { handRadiusValue }
    var hasActiveState: Bool { !planeStates.isEmpty }

    private struct PlaneState {
        var alpha: Float
        var targetAlpha: Float
        var holdFrames: Int
        var lastSeenFrame: Int
    }

    private struct Points {
        let bodyCenter: SIMD3<Float>
        let leftHand: SIMD3<Float>
        let rightHand: SIMD3<Float>
    }

    private var planeStates: [UUID: PlaneState] = [:]
    private var renderables: [(PlaneAnchor, simd_float4)] = []
    private var frameIndex: Int = 0
    private var frameCounter: Int = 0
    private var recomputeIntervalFrames: Int = 3

    private let smoothingFactor: Float = 0.4

    private let bodyFadeRatio: Float = 0.5
    private let handFadeRatio: Float = 0.5
    private let handRadiusValue: Float = 0.2 // 20cm detection radius for hands/controllers
    private let bodyHeight: Float = 1.7 // Approximate body height
    private let exitMargin: Float = 0.05 // 5cm
    private let handExitMargin: Float = 0.03 // 3cm
    private let holdFrames: Int = 6
    private let minPlaneArea: Float = 0.01 // 10cm x 10cm

    private let seatHeadHeightThreshold: Float = 1.2
    private let seatHeadMargin: Float = 0.2
    private let seatActivationDuration: Double = 10.0
    private let seatExitHeightThreshold: Float = 0.7
    private let seatedVerticalNormalMaxY: Float = 0.3
    private let seatPlaneStaleDuration: Double = 20.0
    private let hapticsCooldown: Double = 0.06
    private let hapticsAmplitudeScale: Float = 0.6
    private let hapticsMinAmplitude: Float = 0.08
    private let hapticsDuration: Double = 0.045

    private var seatInBoundsStartTime: Double? = nil
    private var seatedActive: Bool = false
    private var lastSeatPlane: WorldTracker.CachedPlaneData? = nil
    private var lastSeatPlaneTime: Double = 0.0
    private var leftHapticsLastTime: Double = 0.0
    private var rightHapticsLastTime: Double = 0.0
#if CHAPERONE_PROFILE
    private var profileRecomputeSamples: Int = 0
    private var profileRecomputeTrue: Int = 0
    private var profileExactProximityChecks: Int = 0
    private var profileRenderableCount: Int = 0
#endif

    func reset() {
        planeStates.removeAll()
        recomputeIntervalFrames = 3
        leftHapticsLastTime = 0.0
        rightHapticsLastTime = 0.0
#if CHAPERONE_PROFILE
        profileRecomputeSamples = 0
        profileRecomputeTrue = 0
        profileExactProximityChecks = 0
        profileRenderableCount = 0
#endif
    }

    func update(planes: [(PlaneAnchor, WorldTracker.CachedPlaneData)],
                headPose: simd_float4x4,
                leftHandPose: AlvrPose,
                rightHandPose: AlvrPose,
                worldFromSteamVR: simd_float4x4,
                chaperoneDistanceCm: Int,
                now: Double,
                leftControllerPresent: Bool,
                rightControllerPresent: Bool,
                enqueuePulse: (Bool, Float, Double) -> Void) -> Output {
        guard chaperoneDistanceCm > 0 else {
            reset()
#if CHAPERONE_PROFILE
            return Output(renderables: [], profile: ProfileSnapshot.empty)
#else
            return Output(renderables: [])
#endif
        }

        let chaperoneRadius = Float(chaperoneDistanceCm) / 100.0 // Convert cm to meters
        renderables.removeAll(keepingCapacity: true)
        renderables.reserveCapacity(planes.count)

        frameIndex = (frameIndex + 1) % 60
        let recomputeTargets = frameIndex % recomputeIntervalFrames == 0 || planeStates.isEmpty
#if CHAPERONE_PROFILE
        profileRecomputeSamples += 1
        if recomputeTargets {
            profileRecomputeTrue += 1
        }
#endif

        frameCounter += 1
        let currentFrame = frameCounter
        var minApproxDistance = Float.greatestFiniteMagnitude
        var anyTargetActive = false
        var minLeftHandDistance: Float? = nil
        var minRightHandDistance: Float? = nil

        let points = chaperonePoints(headPose: headPose, leftHandPose: leftHandPose, rightHandPose: rightHandPose, worldFromSteamVR: worldFromSteamVR)
        let headPosition = SIMD3<Float>(headPose.columns.3.x, headPose.columns.3.y, headPose.columns.3.z)
        let isSeated = evaluateSeatedState(planes: planes, headPosition: headPosition, now: now)

        let maxHandRange = handRadiusValue + (handRadiusValue * handFadeRatio)
        let maxBodyRange = chaperoneRadius + (chaperoneRadius * bodyFadeRatio)
        let maxRange = max(maxHandRange, maxBodyRange)

        for (plane, cachedPlane) in planes {
            if shouldCullPlane(cachedPlane, points: points, maxRange: maxRange, isSeated: isSeated) {
                continue
            }

            let planeId = cachedPlane.id
            let state = planeStates[planeId] ?? PlaneState(alpha: 0.0, targetAlpha: 0.0, holdFrames: 0, lastSeenFrame: currentFrame)
            var nextState = state

            if recomputeTargets {
#if CHAPERONE_PROFILE
                profileExactProximityChecks += 1
#endif
                if let proximity = computeProximity(cachedPlane: cachedPlane, points: points, chaperoneRadius: chaperoneRadius, state: state) {
                    nextState.targetAlpha = proximity.targetAlpha
                    minApproxDistance = min(minApproxDistance, proximity.minDistance)
                    anyTargetActive = true
                    nextState.holdFrames = holdFrames
                    if let leftDistance = proximity.leftDistance {
                        minLeftHandDistance = min(minLeftHandDistance ?? leftDistance, leftDistance)
                    }
                    if let rightDistance = proximity.rightDistance {
                        minRightHandDistance = min(minRightHandDistance ?? rightDistance, rightDistance)
                    }
                } else {
                    if nextState.holdFrames > 0 {
                        nextState.holdFrames -= 1
                    } else {
                        nextState.targetAlpha = 0.0
                    }
                    if let approx = approxDistanceToPlane(points.bodyCenter, plane: cachedPlane, margin: 1.0) {
                        minApproxDistance = min(minApproxDistance, approx)
                    }
                }
            }

            nextState.lastSeenFrame = currentFrame
            let delta = nextState.targetAlpha - nextState.alpha
            nextState.alpha += delta * smoothingFactor

            if nextState.alpha < 0.001 && nextState.targetAlpha == 0.0 {
                nextState.alpha = 0.0
            }

            if nextState.targetAlpha > 0.0 || nextState.alpha > 0.0 {
                anyTargetActive = true
            }

            planeStates[planeId] = nextState

            if nextState.alpha > 0.0 {
                let planeColor = simd_float4(baseColor.x, baseColor.y, baseColor.z, nextState.alpha)
                renderables.append((plane, planeColor))
            }
        }

#if CHAPERONE_PROFILE
        profileRenderableCount += renderables.count
#endif

        if recomputeTargets {
            updateRecomputeInterval(anyTargetActive: anyTargetActive, minApproxDistance: minApproxDistance)
        }

        if !planeStates.isEmpty {
            planeStates = planeStates.filter { $0.value.lastSeenFrame == currentFrame }
        }

        emitHaptics(leftDistance: minLeftHandDistance,
                    rightDistance: minRightHandDistance,
                    leftControllerPresent: leftControllerPresent,
                    rightControllerPresent: rightControllerPresent,
                    now: now,
                    enqueuePulse: enqueuePulse)

#if CHAPERONE_PROFILE
        let profile = ProfileSnapshot(recomputeSamples: profileRecomputeSamples,
                                      recomputeTrue: profileRecomputeTrue,
                                      exactProximityChecks: profileExactProximityChecks,
                                      renderableCount: profileRenderableCount,
                                      recomputeIntervalFrames: recomputeIntervalFrames)
        profileRecomputeSamples = 0
        profileRecomputeTrue = 0
        profileExactProximityChecks = 0
        profileRenderableCount = 0
        return Output(renderables: renderables, profile: profile)
#else
        return Output(renderables: renderables)
#endif
    }

#if CHAPERONE_PROFILE
    struct ProfileSnapshot {
        let recomputeSamples: Int
        let recomputeTrue: Int
        let exactProximityChecks: Int
        let renderableCount: Int
        let recomputeIntervalFrames: Int

        static let empty = ProfileSnapshot(recomputeSamples: 0,
                                           recomputeTrue: 0,
                                           exactProximityChecks: 0,
                                           renderableCount: 0,
                                           recomputeIntervalFrames: 0)
    }
#endif
    private struct ProximityResult {
        let targetAlpha: Float
        let minDistance: Float
        let leftDistance: Float?
        let rightDistance: Float?
    }

    // Determines seated mode using seat planes; caches a last-seen seat plane to survive classification dropouts.
    private func evaluateSeatedState(planes: [(PlaneAnchor, WorldTracker.CachedPlaneData)], headPosition: SIMD3<Float>, now: Double) -> Bool {
        var isWithinSeat = false
        var seatPlaneForState: WorldTracker.CachedPlaneData? = nil

        for (_, cachedPlane) in planes {
            guard cachedPlane.classification == .seat else { continue }
            let toHead = headPosition - cachedPlane.position
            let localX = dot(toHead, cachedPlane.right)
            let localZ = dot(toHead, cachedPlane.forward)
            if abs(localX) > (cachedPlane.halfWidth + seatHeadMargin)
                || abs(localZ) > (cachedPlane.halfHeight + seatHeadMargin) {
                continue
            }
            let signedDistance = dot(toHead, cachedPlane.normal)
            if signedDistance > 0.0 && signedDistance < seatHeadHeightThreshold {
                isWithinSeat = true
                seatPlaneForState = cachedPlane
                break
            }
        }

        if !isWithinSeat, let lastSeat = lastSeatPlane,
           now - lastSeatPlaneTime < seatPlaneStaleDuration {
            let toHead = headPosition - lastSeat.position
            let localX = dot(toHead, lastSeat.right)
            let localZ = dot(toHead, lastSeat.forward)
            if abs(localX) <= (lastSeat.halfWidth + seatHeadMargin)
                && abs(localZ) <= (lastSeat.halfHeight + seatHeadMargin) {
                let signedDistance = dot(toHead, lastSeat.normal)
                if signedDistance > 0.0 && signedDistance < seatHeadHeightThreshold {
                    isWithinSeat = true
                }
            }
        }

        if isWithinSeat {
            if seatInBoundsStartTime == nil {
                seatInBoundsStartTime = now
            }
            if let plane = seatPlaneForState {
                lastSeatPlane = plane
                lastSeatPlaneTime = now
            }
            if !seatedActive,
               let start = seatInBoundsStartTime,
               now - start >= seatActivationDuration {
                seatedActive = true
            }
        } else {
            seatInBoundsStartTime = nil
            if seatedActive,
               let lastSeat = lastSeatPlane {
                let toHead = headPosition - lastSeat.position
                let signedDistance = dot(toHead, lastSeat.normal)
                if signedDistance > seatExitHeightThreshold {
                    seatedActive = false
                }
            }
        }

        return seatedActive
    }

    // Broad-phase cull: filters seated horizontal planes, tiny planes, and anything beyond padded range.
    private func shouldCullPlane(_ cachedPlane: WorldTracker.CachedPlaneData, points: Points, maxRange: Float, isSeated: Bool) -> Bool {
        if isSeated, abs(cachedPlane.normal.y) > seatedVerticalNormalMaxY {
            return true
        }
        let planeArea = (cachedPlane.halfWidth * 2.0) * (cachedPlane.halfHeight * 2.0)
        if planeArea < minPlaneArea {
            return true
        }

        let planePosition = cachedPlane.position
        let bodyDistanceSq = simd_length_squared(points.bodyCenter - planePosition)
        let leftDistanceSq = simd_length_squared(points.leftHand - planePosition)
        let rightDistanceSq = simd_length_squared(points.rightHand - planePosition)
        let minDistanceSq = min(bodyDistanceSq, min(leftDistanceSq, rightDistanceSq))
        let paddedRange = cachedPlane.boundingRadius + maxRange
        let paddedRangeSq = paddedRange * paddedRange
        return minDistanceSq > paddedRangeSq
    }

    // Computes per-plane proximity, returning max alpha and the min distance; no alpha smoothing here.
    private func computeProximity(cachedPlane: WorldTracker.CachedPlaneData, points: Points, chaperoneRadius: Float, state: PlaneState) -> ProximityResult? {
        let effectiveBodyRadius = chaperoneRadius + (state.targetAlpha > 0.0 ? exitMargin : 0.0)
        let effectiveHandRadius = handRadiusValue + (state.targetAlpha > 0.0 ? handExitMargin : 0.0)
        guard let proximity = proximityToPlane(plane: cachedPlane, points: points, bodyRadius: effectiveBodyRadius, handRadius: effectiveHandRadius) else {
            return nil
        }

        var maxAlpha: Float = 0.0
        var minDistance = Float.greatestFiniteMagnitude
        if let bodyDistance = proximity.bodyDistance {
            maxAlpha = max(maxAlpha, chaperoneAlpha(distance: bodyDistance, chaperoneRadius: effectiveBodyRadius, isHandProximity: false))
            minDistance = min(minDistance, bodyDistance)
        }
        if let leftDistance = proximity.leftDistance {
            maxAlpha = max(maxAlpha, chaperoneAlpha(distance: leftDistance, chaperoneRadius: effectiveHandRadius, isHandProximity: true))
            minDistance = min(minDistance, leftDistance)
        }
        if let rightDistance = proximity.rightDistance {
            maxAlpha = max(maxAlpha, chaperoneAlpha(distance: rightDistance, chaperoneRadius: effectiveHandRadius, isHandProximity: true))
            minDistance = min(minDistance, rightDistance)
        }

        return ProximityResult(targetAlpha: maxAlpha, minDistance: minDistance, leftDistance: proximity.leftDistance, rightDistance: proximity.rightDistance)
    }

    // Adapts recompute cadence based on distance, keeping full rate when anything is active.
    private func updateRecomputeInterval(anyTargetActive: Bool, minApproxDistance: Float) {
        if anyTargetActive {
            recomputeIntervalFrames = 1
        } else if minApproxDistance.isFinite {
            if minApproxDistance > 1.5 {
                recomputeIntervalFrames = 6
            } else if minApproxDistance > 0.75 {
                recomputeIntervalFrames = 4
            } else {
                recomputeIntervalFrames = 3
            }
        } else {
            recomputeIntervalFrames = 6
        }
    }

    // Emits controller pulses with cooldown; skips if no controller or below amplitude threshold.
    private func emitHaptics(leftDistance: Float?, rightDistance: Float?, leftControllerPresent: Bool, rightControllerPresent: Bool, now: Double, enqueuePulse: (Bool, Float, Double) -> Void) {
        if let distance = leftDistance, leftControllerPresent {
            let normalized = max(0.0, min(1.0, (handRadiusValue - distance) / handRadiusValue))
            let amplitude = hapticsAmplitudeScale * normalized
            if amplitude >= hapticsMinAmplitude && now - leftHapticsLastTime >= hapticsCooldown {
                leftHapticsLastTime = now
                enqueuePulse(true, amplitude, hapticsDuration)
            }
        }

        if let distance = rightDistance, rightControllerPresent {
            let normalized = max(0.0, min(1.0, (handRadiusValue - distance) / handRadiusValue))
            let amplitude = hapticsAmplitudeScale * normalized
            if amplitude >= hapticsMinAmplitude && now - rightHapticsLastTime >= hapticsCooldown {
                rightHapticsLastTime = now
                enqueuePulse(false, amplitude, hapticsDuration)
            }
        }
    }

    // Converts head/hand poses into world-space points; body center is head minus a fixed height.
    private func chaperonePoints(headPose: simd_float4x4, leftHandPose: AlvrPose, rightHandPose: AlvrPose, worldFromSteamVR: simd_float4x4) -> Points {
        let headPosition = SIMD3<Float>(headPose.columns.3.x, headPose.columns.3.y, headPose.columns.3.z)
        let bodyCenter = SIMD3<Float>(headPosition.x, headPosition.y - bodyHeight / 2.0, headPosition.z)

        let leftHandPoseSteamVR = simd_float4(leftHandPose.position.0, leftHandPose.position.1, leftHandPose.position.2, 1.0)
        let leftHandPoseWorld = worldFromSteamVR * leftHandPoseSteamVR
        let leftHandPosition = SIMD3<Float>(leftHandPoseWorld.x, leftHandPoseWorld.y, leftHandPoseWorld.z)

        let rightHandPoseSteamVR = simd_float4(rightHandPose.position.0, rightHandPose.position.1, rightHandPose.position.2, 1.0)
        let rightHandPoseWorld = worldFromSteamVR * rightHandPoseSteamVR
        let rightHandPosition = SIMD3<Float>(rightHandPoseWorld.x, rightHandPoseWorld.y, rightHandPoseWorld.z)

        return Points(bodyCenter: bodyCenter, leftHand: leftHandPosition, rightHand: rightHandPosition)
    }

    // Fast distance to plane if the point is inside plane bounds + margin; used to set recompute cadence.
    private func approxDistanceToPlane(_ point: SIMD3<Float>, plane: WorldTracker.CachedPlaneData, margin: Float) -> Float? {
        let planePosition = plane.position
        let planeRight = plane.right
        let planeForward = plane.forward
        let planeNormal = plane.normal

        let toPoint = point - planePosition
        let localX = dot(toPoint, planeRight)
        let localZ = dot(toPoint, planeForward)

        if abs(localX) <= (plane.halfWidth + margin) && abs(localZ) <= (plane.halfHeight + margin) {
            return abs(dot(toPoint, planeNormal))
        }
        return nil
    }

    // Exact distance to a bounded rectangle; ignores floor/ceiling to prevent constant hits.
    private func distanceToPlane(_ point: SIMD3<Float>, plane: WorldTracker.CachedPlaneData) -> Float? {
        // Skip floors and ceilings entirely
        if plane.classification == .floor || plane.classification == .ceiling {
            return nil
        }

        let planePosition = plane.position
        let planeNormal = plane.normal
        let planeRight = plane.right
        let planeForward = plane.forward
        let halfWidth = plane.halfWidth
        let halfHeight = plane.halfHeight

        // Compute distance to the bounded plane rectangle in its local basis.
        let toPoint = point - planePosition
        let localX = dot(toPoint, planeRight)
        let localY = dot(toPoint, planeNormal)
        let localZ = dot(toPoint, planeForward)

        let dx = max(abs(localX) - halfWidth, 0.0)
        let dz = max(abs(localZ) - halfHeight, 0.0)
        let dy = abs(localY)

        return sqrt((dx * dx) + (dy * dy) + (dz * dz))
    }

    // Gathers body/hand distances within their radii; returns nil only if all are out of range.
    private func proximityToPlane(plane: WorldTracker.CachedPlaneData, points: Points, bodyRadius: Float, handRadius: Float) -> (bodyDistance: Float?, leftDistance: Float?, rightDistance: Float?)? {
        var bodyDistance: Float? = nil
        var leftDistance: Float? = nil
        var rightDistance: Float? = nil

        if let distance = distanceToPlane(points.bodyCenter, plane: plane), distance <= bodyRadius {
            bodyDistance = distance
        }
        if let distance = distanceToPlane(points.leftHand, plane: plane), distance <= handRadius {
            leftDistance = distance
        }
        if let distance = distanceToPlane(points.rightHand, plane: plane), distance <= handRadius {
            rightDistance = distance
        }

        if bodyDistance != nil || leftDistance != nil || rightDistance != nil {
            return (bodyDistance, leftDistance, rightDistance)
        }
        return nil
    }

    // Linear fade from max to zero using a radius-based fade ratio.
    private func chaperoneAlpha(distance: Float, chaperoneRadius: Float, isHandProximity: Bool) -> Float {
        let actualRadius = isHandProximity ? handRadiusValue : chaperoneRadius
        let fadeDistance = actualRadius * (isHandProximity ? handFadeRatio : bodyFadeRatio)

        let maxAlpha: Float = 0.7
        let fadeStart = actualRadius - fadeDistance

        if distance <= fadeStart {
            return maxAlpha
        } else if distance >= actualRadius {
            return 0.0
        }

        let fadeProgress = (distance - fadeStart) / fadeDistance
        return maxAlpha * (1.0 - fadeProgress)
    }
}
