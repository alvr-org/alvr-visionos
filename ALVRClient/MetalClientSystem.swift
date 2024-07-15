//
//  MetalClientSystem.swift
//
// MetalClientSystem generally matches the Renderer abstraction
// that RealityKitClientSystem requires, to allow as much code
// shared for both input and rendering as possible.
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
                RealityKitClientView.handleSpatialEvent(nil, event)
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
