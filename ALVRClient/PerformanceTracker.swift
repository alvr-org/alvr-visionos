//
//  PerformanceTracker.swift
//

import CompositorServices
import Dispatch
import Foundation
import os

enum PerfClock {
    static func nowNs() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }
}

final class PerformanceTracker {
    static let shared = PerformanceTracker()

    struct FrameSample {
        var timestampNs: UInt64?
        var frameIntervalMs: Double
        var decodeMs: Double?
        var renderMs: Double?
        var gpuMs: Double?
    }

    struct Snapshot {
        var frameTimes: [Double]
        var decodeTimes: [Double]
        var renderTimes: [Double]
        var gpuTimes: [Double]
        var latest: FrameSample?
        var stats: StatsBundle
    }

    struct Stats {
        var avg: Double
        var median: Double
        var max: Double
    }

    struct StatsBundle {
        var frame: Stats
        var decode: Stats
        var render: Stats
        var gpu: Stats
    }

    private struct PendingData {
        var receiveNs: UInt64?
        var decodeEndNs: UInt64?
        var compositorStartNs: UInt64?
        var renderMs: Double?
        var gpuMs: Double?
    }

    private let lock = OSAllocatedUnfairLock()
    private var pending: [UInt64: PendingData] = [:]
    private var ring: [FrameSample] = Array(repeating: FrameSample(timestampNs: nil, frameIntervalMs: 0, decodeMs: nil, renderMs: nil, gpuMs: nil), count: 60)
    private var ringValid: [Bool] = Array(repeating: false, count: 60)
    private var ringTimestamps: [UInt64?] = Array(repeating: nil, count: 60)
    private var ringIndex = 0
    private var timestampToRingIndex: [UInt64: Int] = [:]
    private var compositorStartNsByTimestamp: [UInt64: UInt64] = [:]
    private var lastPresentationTime: LayerRenderer.Clock.Instant?
    private var lastLogTimeSeconds: Double = 0

    private init() {}

    func recordReceive(timestampNs: UInt64) {
        lock.withLock {
            var data = pending[timestampNs] ?? PendingData()
            data.receiveNs = PerfClock.nowNs()
            pending[timestampNs] = data
        }
    }

    func recordDecodeEnd(timestampNs: UInt64) {
        lock.withLock {
            var data = pending[timestampNs] ?? PendingData()
            data.decodeEndNs = PerfClock.nowNs()
            pending[timestampNs] = data
        }
    }

    func recordCompositorStart(timestampNs: UInt64) {
        let startNs = PerfClock.nowNs()
        lock.withLock {
            var data = pending[timestampNs] ?? PendingData()
            data.compositorStartNs = startNs
            pending[timestampNs] = data
            compositorStartNsByTimestamp[timestampNs] = startNs
        }
    }

    func recordSubmit(timestampNs: UInt64) {
        let submitNs = PerfClock.nowNs()
        lock.withLock {
            let startNs = pending[timestampNs]?.compositorStartNs ?? compositorStartNsByTimestamp[timestampNs]
            if let startNs, submitNs >= startNs {
                let renderMs = Double(submitNs - startNs) / 1_000_000.0
                if let idx = timestampToRingIndex[timestampNs] {
                    ring[idx].renderMs = renderMs
                } else {
                    var data = pending[timestampNs] ?? PendingData()
                    data.renderMs = renderMs
                    pending[timestampNs] = data
                }
            }
            compositorStartNsByTimestamp.removeValue(forKey: timestampNs)
            if let idx = timestampToRingIndex[timestampNs] {
                _ = idx
                pending.removeValue(forKey: timestampNs)
                return
            }
        }
    }

    func recordGpu(timestampNs: UInt64, gpuStartTime: TimeInterval, gpuEndTime: TimeInterval) {
        let durationMs = (gpuEndTime - gpuStartTime) * 1000.0
        if durationMs <= 0 {
            return
        }
        lock.withLock {
            if let idx = timestampToRingIndex[timestampNs] {
                ring[idx].gpuMs = durationMs
                return
            }
            var data = pending[timestampNs] ?? PendingData()
            data.gpuMs = durationMs
            pending[timestampNs] = data
        }
    }

    func recordFramePresentation(presentationTime: LayerRenderer.Clock.Instant, timestampNs: UInt64?) {
        lock.withLock {
            let intervalMs: Double
            if let last = lastPresentationTime {
                let dt = last.duration(to: presentationTime).timeInterval
                intervalMs = dt * 1000.0
            } else {
                intervalMs = 0
            }
            lastPresentationTime = presentationTime

            if let oldTimestamp = ringTimestamps[ringIndex] {
                timestampToRingIndex.removeValue(forKey: oldTimestamp)
            }

            let sample = buildSample(timestampNs: timestampNs, frameIntervalMs: intervalMs)
            ring[ringIndex] = sample
            ringValid[ringIndex] = true
            ringTimestamps[ringIndex] = timestampNs
            if let ts = timestampNs {
                timestampToRingIndex[ts] = ringIndex
            }

            ringIndex = (ringIndex + 1) % ring.count
        }
    }

    func logIfNeeded(presentationTime: LayerRenderer.Clock.Instant) {
        let nowSeconds = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime).timeInterval
        if nowSeconds - lastLogTimeSeconds < 1.0 {
            return
        }
        lastLogTimeSeconds = nowSeconds
        let snap = snapshot()
        let frame = snap.stats.frame
        let decode = snap.stats.decode
        let render = snap.stats.render
        let gpu = snap.stats.gpu
        print("[Perf] frame avg=\(formatMs(frame.avg)) median=\(formatMs(frame.median)) max=\(formatMs(frame.max)) decode avg=\(formatMs(decode.avg)) render avg=\(formatMs(render.avg)) gpu avg=\(formatMs(gpu.avg))")
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            var ordered: [FrameSample] = []
            ordered.reserveCapacity(ring.count)

            for offset in 0..<ring.count {
                let idx = (ringIndex + offset) % ring.count
                if ringValid[idx] {
                    ordered.append(ring[idx])
                }
            }

            let frameTimes = ordered.map { $0.frameIntervalMs }
            let decodeTimes = ordered.map { $0.decodeMs ?? 0 }
            let renderTimes = ordered.map { $0.renderMs ?? 0 }
            let gpuTimes = ordered.map { $0.gpuMs ?? 0 }
            let latest = ordered.last

            let stats = StatsBundle(
                frame: computeStats(frameTimes),
                decode: computeStats(decodeTimes),
                render: computeStats(renderTimes),
                gpu: computeStats(gpuTimes)
            )

            return Snapshot(
                frameTimes: frameTimes,
                decodeTimes: decodeTimes,
                renderTimes: renderTimes,
                gpuTimes: gpuTimes,
                latest: latest,
                stats: stats
            )
        }
    }

    private func buildSample(timestampNs: UInt64?, frameIntervalMs: Double) -> FrameSample {
        guard let ts = timestampNs, let data = pending[ts] else {
            return FrameSample(timestampNs: timestampNs, frameIntervalMs: frameIntervalMs, decodeMs: nil, renderMs: nil, gpuMs: nil)
        }

        let decodeMs: Double?
        if let receive = data.receiveNs, let decodeEnd = data.decodeEndNs, decodeEnd >= receive {
            decodeMs = Double(decodeEnd - receive) / 1_000_000.0
        } else {
            decodeMs = nil
        }

        return FrameSample(
            timestampNs: timestampNs,
            frameIntervalMs: frameIntervalMs,
            decodeMs: decodeMs,
            renderMs: data.renderMs,
            gpuMs: data.gpuMs
        )
    }

    private func computeStats(_ values: [Double]) -> Stats {
        let filtered = values.filter { $0 > 0 }
        guard !filtered.isEmpty else {
            return Stats(avg: 0, median: 0, max: 0)
        }
        let sorted = filtered.sorted()
        let count = sorted.count
        let median: Double
        if count % 2 == 0 {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }
        let avg = sorted.reduce(0, +) / Double(count)
        let maxVal = sorted.last ?? 0
        return Stats(avg: avg, median: median, max: maxVal)
    }

    private func formatMs(_ value: Double) -> String {
        return String(format: "%.3fms", value)
    }
}
