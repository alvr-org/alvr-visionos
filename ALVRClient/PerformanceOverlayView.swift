//
//  PerformanceOverlayView.swift
//

import SwiftUI
import Metal
import os

private struct GraphView: View {
    let samples: [Double]
    let lineColor: Color
    let referenceLines: [Double]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let maxSample = max(samples.max() ?? 0, referenceLines.max() ?? 0, 1)

                for ref in referenceLines {
                    let y = height - (CGFloat(ref) / CGFloat(maxSample)) * height
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
                }

                guard samples.count > 1 else { return }
                let step = width / CGFloat(max(samples.count - 1, 1))
                var path = Path()
                for (i, value) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = height - (CGFloat(value) / CGFloat(maxSample)) * height
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(lineColor), lineWidth: 2)
            }
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }
}

private func streamFpsCap(from value: String) -> Double {
    return value == "Default" ? 90.0 : (Double(value) ?? 90.0)
}

private struct PerformanceOverlayContent: View {
    let snapshot: PerformanceTracker.Snapshot
    let streamFpsCap: Double

    var body: some View {
        let latest = snapshot.latest
        let frameStats = snapshot.stats.frame
        let decodeStats = snapshot.stats.decode
        let renderStats = snapshot.stats.render
        let gpuStats = snapshot.stats.gpu
        let latestFrameMs = latest?.frameIntervalMs ?? 0
        let fps = latestFrameMs > 0 ? 1000.0 / latestFrameMs : 0
        let cappedFps = min(fps, streamFpsCap)
        let fpsRatio = streamFpsCap > 0 ? (cappedFps / streamFpsCap) : 0
        let fpsColor: Color = fpsRatio >= 0.95 ? .green : (fpsRatio >= 0.8 ? .yellow : .red)
        let frameTargetMs = streamFpsCap > 0 ? (1000.0 / streamFpsCap) : 11.11
        let frameRatio = frameTargetMs > 0 ? (frameTargetMs / max(latestFrameMs, 0.001)) : 0
        let frameColor: Color = frameRatio >= 0.95 ? .green : (frameRatio >= 0.8 ? .yellow : .red)
        let primaryText = Color.white
        let secondaryText = Color.white.opacity(0.7)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text("FPS")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text(latest != nil ? String(format: "%3.0f", min(cappedFps, 300)) : "--")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(fpsColor)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                
                Divider()
                    .frame(height: 30)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("FRAME")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                    HStack(spacing: 4) {
                        Text(latest != nil ? String(format: "%.1f", latestFrameMs) : "--")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(frameColor)
                        Text("ms")
                            .font(.system(size: 8, weight: .regular, design: .rounded))
                            .foregroundStyle(secondaryText)
                    }
                }
                
                Spacer()
            }
            .foregroundStyle(primaryText)
            
            VStack(alignment: .leading, spacing: 6) {
                GraphView(samples: snapshot.frameTimes, lineColor: .green, referenceLines: [11.11])
                    .frame(height: 32)
                MetricRow(label: "frame avg", value: String(format: "%.2fms", frameStats.avg))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(secondaryText)

                GraphView(samples: snapshot.decodeTimes, lineColor: .yellow, referenceLines: [11.11])
                    .frame(height: 32)
                MetricRow(label: "decode", value: String(format: "%.2fms", decodeStats.avg))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(secondaryText)

                GraphView(samples: snapshot.renderTimes, lineColor: .orange, referenceLines: [11.11])
                    .frame(height: 32)
                MetricRow(label: "render", value: String(format: "%.2fms", renderStats.avg))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(secondaryText)

                GraphView(samples: snapshot.gpuTimes, lineColor: .pink, referenceLines: [11.11])
                    .frame(height: 32)
                MetricRow(label: "gpu", value: String(format: "%.2fms", gpuStats.avg))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(8)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PerformanceOverlayPanel: View {
    @EnvironmentObject private var gStore: GlobalSettingsStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let snapshot = PerformanceTracker.shared.snapshot()
            PerformanceOverlayContent(
                snapshot: snapshot,
                streamFpsCap: streamFpsCap(from: gStore.settings.streamFPS)
            )
        }
    }
}

struct PerformanceOverlaySnapshotView: View {
    let snapshot: PerformanceTracker.Snapshot
    let streamFpsCap: Double

    var body: some View {
        PerformanceOverlayContent(
            snapshot: snapshot,
            streamFpsCap: streamFpsCap
        )
    }
}

final class PerformanceHudRenderer {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "PerfHUD.Render")
    private let lock = OSAllocatedUnfairLock()
    private var texture: MTLTexture?
    private var lastUpdateNs: UInt64 = 0
    private var isUpdating = false
    private let updateIntervalNs: UInt64 = 33_000_000

    init(device: MTLDevice) {
        self.device = device
    }

    private func makeTexture(cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let dataSize = bytesPerRow * height

        var data = Data(count: dataSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let created = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }
            guard let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0,
                                withBytes: baseAddress,
                                bytesPerRow: bytesPerRow)
            }
        }
        return texture
    }

    func updateIfNeeded() -> MTLTexture? {
        let now = PerfClock.nowNs()
        var shouldUpdate = false
        lock.withLock {
            if !isUpdating && now &- lastUpdateNs >= updateIntervalNs {
                isUpdating = true
                lastUpdateNs = now
                shouldUpdate = true
            }
        }
        if shouldUpdate {
            let snapshot = PerformanceTracker.shared.snapshot()
            let fpsCap = streamFpsCap(from: ALVRClientApp.gStore.settings.streamFPS)
            queue.async { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    let view = PerformanceOverlaySnapshotView(snapshot: snapshot, streamFpsCap: fpsCap)
                    let renderer = ImageRenderer(content: view)
                    renderer.proposedSize = ProposedViewSize(width: 240, height: 250)
                    renderer.scale = 2
                    renderer.isOpaque = false
                    guard let cgImage = renderer.cgImage else {
                        self.lock.withLock { self.isUpdating = false }
                        return
                    }
                    let newTexture = self.makeTexture(cgImage: cgImage)
                    self.lock.withLock {
                        self.texture = newTexture
                        self.isUpdating = false
                    }
                }
            }
        }
        return lock.withLock { texture }
    }
}
