import simd
import Foundation

final class OneEuroFilter3 {
    private var prevValue: simd_float3?
    private var prevDeriv: simd_float3?
    private var prevTime: TimeInterval?

    private let minCutoff: Float      // minimum cutoff frequency
    private let beta: Float           // speed coefficient
    private let derivCutoff: Float    // derivative cutoff

    init(minCutoff: Float = 1.0, beta: Float = 0.0, derivCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivCutoff = derivCutoff
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private func lowpass(previous: simd_float3, current: simd_float3, alpha: Float) -> simd_float3 {
        return alpha * current + (1 - alpha) * previous
    }

    /// Filter a new simd_float3 sample at a given timestamp (seconds)
    func filter(_ x: simd_float3, timestamp: TimeInterval) -> simd_float3 {
        guard let t0 = prevTime,
              let xPrev = prevValue else {
            prevTime = timestamp
            prevValue = x
            prevDeriv = simd_float3.zero
            return x
        }

        let dt = Float(timestamp - t0)
        prevTime = timestamp

        // Derivative estimation
        let dx = (x - xPrev) / dt

        // Low-pass derivative
        let alphaDeriv = alpha(cutoff: derivCutoff, dt: dt)
        let dFiltered: simd_float3
        if let dPrev = prevDeriv {
            dFiltered = lowpass(previous: dPrev, current: dx, alpha: alphaDeriv)
        } else {
            dFiltered = dx
        }
        prevDeriv = dFiltered

        // Adaptive cutoff based on derivative magnitude
        let cutoff = minCutoff + beta * simd_length(dFiltered)

        // Low-pass signal
        let alphaSignal = alpha(cutoff: cutoff, dt: dt)
        let filtered = lowpass(previous: xPrev, current: x, alpha: alphaSignal)
        prevValue = filtered
        return filtered
    }
}
