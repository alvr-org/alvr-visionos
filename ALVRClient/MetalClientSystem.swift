//
//  MetalClientSystem.swift
//

import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class MetalClientSystem {

    var renderer: Renderer;
    let layerRenderer: LayerRenderer
    
    init(_ layerRenderer: LayerRenderer) {
        self.renderer = Renderer(layerRenderer)
        self.layerRenderer = layerRenderer
    }
    
    func startRenderLoop() {
        Task {
            renderer.rebuildRenderPipelines()
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
                // For eyes: inputDevicePose is the pinch connect location, and the selection ray is
                // the eye center plus the gaze
                // For AssistiveTouch mouse: inputDevicePose is locked to the last plane the device was on, and
                // the selection ray is some random pose?
                // For keyboard accessibility touch: inputDevicePose is some random place, selectionRay is 0,0,0
                
                // Only selectionRay origin, not projected to direction
                /*if let ray = event.selectionRay {
                    let pos = simd_float3(ray.origin)
                    WorldTracker.shared.testPosition = pos
                }*/
                
                // selectionRay origin + direction
                if let ray = event.selectionRay {
                    let pos = simd_float3(ray.origin + ray.direction)
                    WorldTracker.shared.testPosition = pos
                }
                
                // inputDevicePose
                /*if let inputPose = event.inputDevicePose {
                    let pos = simd_float3(inputPose.pose3D.position)
                    WorldTracker.shared.testPosition = pos
                }*/
                
                // location3D, basically always 0,0,0?
                /*if true {
                    let pos = simd_float3(event.location3D)
                    WorldTracker.shared.testPosition = pos
                }*/
            }
        }
        
        EventHandler.shared.handleHeadsetRemovedOrReentry()
        let timeSinceLastLoop = CACurrentMediaTime()
        while EventHandler.shared.renderStarted {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                //EventHandler.shared.stop()
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetRemoved()
                WorldTracker.shared.resetPlayspace()
                alvr_pause()

                // visionOS sometimes sends these invalidated things really fkn late...
                // But generally, we want to exit fully when the user exits.
                if CACurrentMediaTime() - timeSinceLastLoop < 1.0 {
                    exit(0)
                }
                break
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                //EventHandler.shared.handleHeadsetRemovedOrReentry()
                continue
            } else {
                autoreleasepool {
                    renderer.renderFrame()
                }
            }
        }
    }
}
