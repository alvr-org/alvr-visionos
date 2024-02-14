/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A component and system for positioning the sun.
*/

import Foundation
import RealityKit
import SwiftUI

public struct SunPositionComponent: Component, Codable {
    var sunAngleRadians: Float = 0
    
    public init(_ sunAngle: Float) {
        sunAngleRadians = sunAngle
    }
}

public struct SunPositionSystem: System {
    static let query = EntityQuery(where: .has(SunPositionComponent.self))
    
    public init(scene: RealityKit.Scene) {}
    
    public func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let component = entity.sunPositionComponent else {
                continue
            }

            // Get the entity's rotation.
            let angle = entity.orientation.axis.y < 0
            ? entity.orientation.angle
            : 2 * .pi - entity.orientation.angle

            // Combine the entity's rotation with a constant offset that
            // changes the position of the sun relative to the entity.
            var angleAsFloat = ((angle + component.sunAngleRadians) / (Float.pi * 2))
            angleAsFloat -= floor(angleAsFloat)

            // Set the angle for use in determining where to turn on night lights.
            entity.setSunPosition(angleAsFloat)
        }
    }
}

public extension Entity {
    var sunPositionComponent: SunPositionComponent? {
        get { components[SunPositionComponent.self] }
        set { components[SunPositionComponent.self] = newValue }
    }
    
    var modelComponent: ModelComponent? {
        get { components[ModelComponent.self] }
        set { components[ModelComponent.self] = newValue }
    }
    
    /// Finds all decendant entites with a model component.
    ///
    /// - Returns: An array of decendant entities that have a model component.
    func getModelDescendents() -> [Entity] {
        var descendents = [Entity]()
        
        for child in children {
            if child.components[ModelComponent.self] != nil {
                descendents.append(child)
            }
            descendents.append(contentsOf: child.getModelDescendents())
        }
        return descendents
    }

    /// Informs materials about the position of the sun.
    ///
    /// - Parameter position: An angle expressed as a float, where 0 corresponds
    ///   to 0° and 1.0 corresponds to 360°.
    func setSunPosition(_ position: Float) {
        for modelEntity in self.getModelDescendents() {
            guard var modelComponent = modelEntity.modelComponent else {
                return
            }

            // Tell any material that has a sun angle parameter about the
            // position of the sun so that it can adjust its appearance.
            modelComponent.materials = modelComponent.materials.map {
                guard var material = $0 as? ShaderGraphMaterial else { return $0 }
                if material.parameterNames.contains(WorldAssets.sunAngleParameterName) {
                    do {
                        try material.setParameter(
                            name: WorldAssets.sunAngleParameterName,
                            value: .float(position)
                        )
                    } catch {
                        fatalError("Failed to set material parameter: \(error.localizedDescription)")
                    }
                }
                return material
            }

            modelEntity.modelComponent = modelComponent
        }
    }
}
