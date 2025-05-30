//
//  DummyMetalRenderer.swift
//

import CompositorServices
import Metal
import Foundation

class DummyMetalRenderer {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let layerRenderer: LayerRenderer
    
    static var haveRenderInfo: Bool = false
    static var renderTangents: [simd_float4] = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
    static var renderViewTransforms: [simd_float4x4] = [simd_float4x4([[0.9999865, 0.00515201, -0.0005922073, 0.0], [-0.0051479023, 0.99996406, 0.00674105, -0.0], [0.0006269097, -0.006737909, 0.99997705, -0.0], [-0.033701643, -0.026765306, 0.011856683, 1.0]]), simd_float4x4([[0.9999876, 0.004899999, -0.0009073103, 0.0], [-0.0048943865, 0.9999694, 0.0060919393, -0.0], [0.0009371306, -0.006087418, 0.99998105, -0.0], [0.030268293, -0.024580047, 0.009440895, 1.0]])]
    static var drawableCompressedRenderWidth = 1888
    static var drawableCompressedRenderHeight = 1824
    static var drawableDecompressedRenderWidth = 4065 // not really certain on this tbh
    static var drawableDecompressedRenderHeight = 3263
    static var drawableWidth = 1920
    static var drawableHeight = 1920
    static var vrrParametersX: [[Float]] = [[0.08020063, 0.10355802, 0.12903573, 0.15763666, 0.188238, 0.2222177, 0.2601484, 0.30191043, 0.3516262, 0.4507197, 0.5333322, 0.63997656, 0.78054124, 0.8888889, 0.88886476, 0.9142857, 0.91427296, 0.9411765, 0.9411765, 0.9411224, 0.969697, 0.969697, 0.969697, 0.96974003, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9999695, 0.969697, 0.969697, 0.969697, 0.96972567, 0.9411765, 0.9411765, 0.94116974, 0.9142857, 0.9142411, 0.8888889, 0.88898534, 0.86478496, 0.84210527, 0.8421594, 0.7999414, 0.6667006, 0.5613867, 0.4776189, 0.40503827, 0.34786302, 0.27348316, 0.23357415, 0.19512194], [0.17390761, 0.20644952, 0.24244823, 0.28316885, 0.32988632, 0.43247524, 0.51609904, 0.6153651, 0.7441966, 0.8888889, 0.88894916, 0.9142857, 0.9142602, 0.9411765, 0.9411765, 0.9412035, 0.969697, 0.969697, 0.969697, 0.96966827, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.000042, 0.969697, 0.969697, 0.969697, 0.9696432, 0.9411765, 0.9411765, 0.9411799, 0.9142857, 0.91426975, 0.8888889, 0.88894314, 0.8648649, 0.86478496, 0.84213233, 0.820559, 0.6955894, 0.5818259, 0.49233174, 0.4210283, 0.3595782, 0.27349856, 0.2318697, 0.19633843, 0.16326368, 0.13389641, 0.10737648, 0.083333336]]
    static var vrrParametersY: [[Float]] = [[0.17203848, 0.20254704, 0.23702921, 0.27349564, 0.3168403, 0.36780268, 0.4383459, 0.51614785, 0.6153666, 0.727305, 0.88890696, 0.9142921, 0.9411765, 0.94113594, 0.969697, 0.969697, 0.969697, 0.96972567, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9999809, 0.969697, 0.969697, 0.969697, 0.9697149, 0.9411765, 0.9411765, 0.9411528, 0.9142857, 0.91426975, 0.8888889, 0.88897634, 0.864862, 0.86485916, 0.84203494, 0.8205025, 0.79999024, 0.7804878, 0.7804971, 0.6956559, 0.5714834, 0.48485208, 0.405027, 0.34408692, 0.28069875, 0.2370379, 0.1987641, 0.16494845], [0.17203848, 0.20254704, 0.23702921, 0.27349564, 0.3168403, 0.36780268, 0.4383459, 0.51614785, 0.6153666, 0.727305, 0.88890696, 0.9142921, 0.9411765, 0.94113594, 0.969697, 0.969697, 0.969697, 0.96972567, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9999809, 0.969697, 0.969697, 0.969697, 0.9697149, 0.9411765, 0.9411765, 0.9411528, 0.9142857, 0.91426975, 0.8888889, 0.88897634, 0.864862, 0.86485916, 0.84203494, 0.8205025, 0.79999024, 0.7804878, 0.7804971, 0.6956559, 0.5714834, 0.48485208, 0.405027, 0.34408692, 0.28069875, 0.2370379, 0.1987641, 0.16494845]]
    
    //vOS 2.2 MTLSize(width: 1888, height: 1824, depth: 1) MTLSize(width: 1888, height: 1824, depth: 1) 4065 3263 ::: 0.22857909 0.5052083 ::: 0.72151554 0.5052083
    
    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
    }
    
    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }
        
        frame.startUpdate()
        frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        
        guard let drawable = frame.queryDrawable() else {
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }
        
        var averageViewTransformPositionalComponent = simd_float4()
        
        DummyMetalRenderer.renderTangents.removeAll()
        DummyMetalRenderer.renderViewTransforms.removeAll()
        for view in drawable.views {
            let tangents = view.tangents
            DummyMetalRenderer.renderTangents.append(tangents)
            var transform = matrix_identity_float4x4
            transform.columns.3 = view.transform.columns.3
            //let transform = view.transform
            DummyMetalRenderer.renderViewTransforms.append(transform)
            
            averageViewTransformPositionalComponent += view.transform.columns.3
        DummyMetalRenderer.renderTangents.removeAll()
        DummyMetalRenderer.renderViewTransforms.removeAll()
        var averageViewTransform = simd_float4()
        for view in drawable.views {
            let tangents = view.tangents
            DummyMetalRenderer.renderTangents.append(tangents)
            averageViewTransform += view.transform.columns.3
        }
        
        averageViewTransform /= Float(drawable.views.count)
        averageViewTransform.w = 0.0
        
        for view in drawable.views {
            var transform = matrix_identity_float4x4
            transform.columns.3 = view.transform.columns.3 //- averageViewTransform
            //let transform = view.transform
            DummyMetalRenderer.renderViewTransforms.append(transform)
        }
        
        let vrr = drawable.rasterizationRateMaps[0]
        DummyMetalRenderer.drawableDecompressedRenderWidth = vrr.screenSize.width
        DummyMetalRenderer.drawableDecompressedRenderHeight = vrr.screenSize.height
        DummyMetalRenderer.drawableCompressedRenderWidth = vrr.physicalSize(layer: 0).width // not really certain on this tbh
        DummyMetalRenderer.drawableCompressedRenderHeight = vrr.physicalSize(layer: 0).height
        DummyMetalRenderer.drawableWidth = drawable.colorTextures[0].width
        DummyMetalRenderer.drawableHeight = drawable.colorTextures[0].width
        print("Drawable compressed dims:", DummyMetalRenderer.drawableCompressedRenderWidth, "x", DummyMetalRenderer.drawableCompressedRenderHeight)
        print("Drawable decompressed dims:", DummyMetalRenderer.drawableDecompressedRenderWidth, "x", DummyMetalRenderer.drawableDecompressedRenderHeight)
        print("Drawable texture dims:", DummyMetalRenderer.drawableWidth, "x", DummyMetalRenderer.drawableHeight)
        print("VRR granularity:", vrr.physicalGranularity)
        
        // TODO: not sure if I want to pull the rate maps on the off chance that eye tracking gets added.
        for i in 0..<2 {
            let physSize = vrr.physicalSize(layer: i)
            let granularity = vrr.physicalGranularity
            let xCells = Int(physSize.width / granularity.width)
            let yCells = Int(physSize.height / granularity.height)
            print(i, "Cell amt:", xCells, "x", yCells)
            //print(i, "Cell amt:", xCells, "x", yCells)
            
            for j in 0..<xCells {
                let screenX1 = vrr.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: Float(j*granularity.width), y: 0), layer: i).x
                let screenX2 = vrr.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: Float((j+1)*granularity.width), y: 0), layer: i).x
                let rate = Float(granularity.width)/(screenX2-screenX1)
                //print("x", j, rate)
            }
            
            for j in 0..<yCells {
                let screenY1 = vrr.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: 0, y: Float(j*granularity.height)), layer: i).y
                let screenY2 = vrr.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: 0, y: Float((j+1)*granularity.height)), layer: i).y
                let rate = Float(granularity.height)/(screenY2-screenY1)
                //print("y", j, rate)
            }
        }
        
        // HACK: for some reason Apple's view transforms' positional component has this really weird drift downwards at the start.
        // Initially, it's off by like 26cm, super weird.
        averageViewTransformPositionalComponent /= Float(DummyMetalRenderer.renderViewTransforms.count)
        averageViewTransformPositionalComponent.w = 0.0
        
        /*for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
            DummyMetalRenderer.renderViewTransforms[i].columns.3 -= averageViewTransformPositionalComponent
        }*/
        WorldTracker.shared.averageViewTransformPositionalComponent = averageViewTransformPositionalComponent.asFloat3()
        
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        LayerRenderer.Clock().wait(until: drawable.frameTiming.renderingDeadline)
        frame.endSubmission()
        
        DummyMetalRenderer.haveRenderInfo = true
        print("Got view info!")
    }
    
    func startRenderLoop() {
        Task {
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }
    
    func renderLoop() {
        layerRenderer.waitUntilRunning()
        
        layerRenderer.onSpatialEvent = { eventCollection in
            for event in eventCollection {
                print(event)
            }
        }
        
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                break
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
            
            if DummyMetalRenderer.haveRenderInfo {
                break
            }
        }
    }
}
