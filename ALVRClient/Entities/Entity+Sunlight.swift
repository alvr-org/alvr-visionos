/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Sunlight supplied through an image-based light.
*/

import SwiftUI
import RealityKit

extension Entity {
    /// Adds an image-based light that emulates sunlight.
    ///
    /// This method assumes that the project contains a folder called
    /// `Sunlight.skybox` that contains an image of a white dot on a black
    /// background. The position of the dot in the image dictates the direction
    /// from which the sunlight appears to originate. Use a small dot
    /// to maximize the point-like nature of the light source.
    ///
    /// Tune the intensity parameter to get the brightness that you need.
    /// Set the intensity to `nil` to remove the image-based light (IBL)
    /// from the entity.
    ///
    /// - Parameter intensity: The strength of the sunlight. Tune
    ///   this value to get the brightness you want. Set a value of `nil` to
    ///   remove the image based light from the entity.
    func setSunlight(intensity: Float?) {
        if let intensity {
            Task {
                guard let resource = try? await EnvironmentResource(named: "Sunlight") else { return }
                var iblComponent = ImageBasedLightComponent(
                    source: .single(resource),
                    intensityExponent: intensity)

                // Ensure that the light rotates with its entity. Omit this line
                // for a light that remains fixed relative to the surroundings.
                iblComponent.inheritsRotation = true

                components.set(iblComponent)
                components.set(ImageBasedLightReceiverComponent(imageBasedLight: self))
            }
        } else {
            components.remove(ImageBasedLightComponent.self)
            components.remove(ImageBasedLightReceiverComponent.self)
        }
    }
}
