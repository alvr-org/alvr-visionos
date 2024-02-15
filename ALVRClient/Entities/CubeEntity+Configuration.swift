/*
Abstract:
Configuration information for Cube entities.
*/

import SwiftUI

extension CubeEntity {
    /// Configuration information for Cube entities.
    struct Configuration {
        var scale: Float = 0.6
        var rotation: simd_quatf = .init(angle: 0, axis: [0, 1, 0])
        var speed: Float = 0.9
        var position: SIMD3<Float> = .zero

        var axDescribeTilt: Bool = false

        var currentSpeed: Float {
            speed
        }
        static var cubeDefault: Configuration = .init()
    }
}

