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
            DummyMetalRenderer.renderTangents.append(view.tangents)
            DummyMetalRenderer.renderViewTransforms.append(view.transform)
            
            averageViewTransformPositionalComponent += view.transform.columns.3
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
