/*
Abstract:
An entity that represents the Cube and all its moving parts.
*/

import RealityKit
import SwiftUI
import RealityKitContent

/// An entity that represents the Cube and all its moving parts.
class CubeEntity: Entity {

    /// The model that draws the Cube's surface features.
    private var cube: Entity = Entity()

    /// An entity that provides a configurable rotation
    private let rotator = Entity()

    /// Creates a new blank cube entity.
    @MainActor required init() {
        super.init()
    }

    /// Creates a new cube entity with the specified configuration.
    ///
    /// - Parameters:
    ///   - configuration: Information about how to configure the Cube.
    init(
        configuration: Configuration
    ) async {
        super.init()

        // Load the cube.
        guard let cube = await RealityKitContent.entity(named: "Cube") else { return }
        self.cube = cube

        // Attach to the Cube to an entity that enables rotation around the axis.
        self.addChild(rotator)
        rotator.addChild(cube)

        // Configure everything for the first time.
        update(
            configuration: configuration,
            animateUpdates: false)
    }

    /// Updates all the entity's configurable elements.
    ///
    /// - Parameters:
    ///   - configuration: Information about how to configure the Cube.
    ///   - animateUpdates: A Boolean that indicates whether changes to certain
    ///     configuration values should be animated.
    func update(
        configuration: Configuration,
        animateUpdates: Bool
    ) {
        // Set a static rotation of the Cube, driven from the configuration.
        rotator.orientation = configuration.rotation

        // Set the speed of the Cube's automatic rotation on its axis.
        if var rotation: RotationComponent = cube.components[RotationComponent.self] {
            rotation.speed = configuration.currentSpeed
            cube.components[RotationComponent.self] = rotation
        } else {
            cube.components.set(RotationComponent(speed: configuration.currentSpeed))
        }

        // Scale and position the entire entity.
        move(
            to: Transform(
                scale: SIMD3(repeating: configuration.scale),
                rotation: orientation,
                translation: configuration.position),
            relativeTo: parent)
    }
}
