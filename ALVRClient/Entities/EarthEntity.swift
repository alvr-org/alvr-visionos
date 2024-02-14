/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An entity that represents the Earth and all its moving parts.
*/

import RealityKit
import SwiftUI
import RealityKitContent

/// An entity that represents the Earth and all its moving parts.
class EarthEntity: Entity {

    // MARK: - Sub-entities

    /// The model that draws the Earth's surface features.
    private var earth: Entity = Entity()

    /// An entity that rotates 23.5° to create axial tilt.
    private let equatorialPlane = Entity()

    /// An entity that provides a configurable rotation,
    /// separate from the day/night cycle.
    private let rotator = Entity()

    /// A physical representation of the Earth's north and south poles.
    private var pole: Entity = Entity()

    /// The Earth's one natural satellite.
 //   private var moon: SatelliteEntity = SatelliteEntity()

    /// A container for artificial satellites.
    private let satellites = Entity()

    // MARK: - Internal state

    /// Keep track of solar intensity and only update when it changes.
    private var currentSunIntensity: Float? = nil

    // MARK: - Initializers

    /// Creates a new blank earth entity.
    @MainActor required init() {
        super.init()
    }

    /// Creates a new earth entity with the specified configuration.
    ///
    /// - Parameters:
    ///   - configuration: Information about how to configure the Earth.
    ///   - satelliteConfiguration: An array of configuration structures, one
    ///     for each artificial satellite. The initializer creates one
    ///     satellite model for each element of the array. Pass an empty
    ///     array to avoid creating any artificial satellites.
    ///   - moonConfiguration: A satellite configuration structure that's
    ///     specifically for the Moon. Set to `nil` to avoid creating a
    ///     Moon entity.
    init(
        configuration: Configuration
      //  satelliteConfiguration: [SatelliteEntity.Configuration],
       // moonConfiguration: SatelliteEntity.Configuration?
    ) async {
        super.init()

        // Load the earth and pole models.
        guard let earth = await RealityKitContent.entity(named: configuration.isCloudy ? "Earth" : "Globe") else { return }
        self.earth = earth


        // Attach to the Earth to a set of entities that enable axial
        // tilt and a configured amount of rotation around the axis.
        self.addChild(equatorialPlane)
        equatorialPlane.addChild(rotator)
        rotator.addChild(earth)

        // Attach the pole to the Earth to ensure that it
        // moves, tilts, rotates, and scales with the Earth.
      //  earth.addChild(pole)


        // The inclination of artificial satellite orbits is measured relative
        // to the Earth's equator, so attach the satellite container to the
        // equatorial plane entity.
        equatorialPlane.addChild(satellites)

        // Configure everything for the first time.
        update(
            configuration: configuration,
            animateUpdates: false)
    }

    // MARK: - Updates

    /// Updates all the entity's configurable elements.
    ///
    /// - Parameters:
    ///   - configuration: Information about how to configure the Earth.
    ///   - satelliteConfiguration: An array of configuration structures, one
    ///     for each artificial satellite.
    ///   - moonConfiguration: A satellite configuration structure that's
    ///     specifically for the Moon.
    ///   - animateUpdates: A Boolean that indicates whether changes to certain
    ///     configuration values should be animated.
    func update(
        configuration: Configuration,
        animateUpdates: Bool
    ) {
        // Indicate the position of the sun for use in turning the ground
        // lights on and off.
        earth.sunPositionComponent = SunPositionComponent(Float(configuration.sunAngle.radians))
        
        // Set a static rotation of the tilted Earth, driven from the configuration.
        rotator.orientation = configuration.rotation

        // Set the speed of the Earth's automatic rotation on it's axis.
        if var rotation: RotationComponent = earth.components[RotationComponent.self] {
            rotation.speed = configuration.currentSpeed
            earth.components[RotationComponent.self] = rotation
        } else {
            earth.components.set(RotationComponent(speed: configuration.currentSpeed))
        }


        // Set the sunlight, if corresponding controls have changed.
        if configuration.currentSunIntensity != currentSunIntensity {
            setSunlight(intensity: configuration.currentSunIntensity)
            currentSunIntensity = configuration.currentSunIntensity
        }

        // Tilt the axis according to a date. For this to be meaningful,
        // locate the sun along the positive x-axis. Animate this move for
        // changes that the user makes when the globe appears in the volume.
        var planeTransform = equatorialPlane.transform
        planeTransform.rotation = tilt(date: configuration.date)
        if animateUpdates {
            equatorialPlane.move(to: planeTransform, relativeTo: self, duration: 0.25)
        } else {
            equatorialPlane.move(to: planeTransform, relativeTo: self)
        }

        // Scale and position the entire entity.
        move(
            to: Transform(
                scale: SIMD3(repeating: configuration.scale),
                rotation: orientation,
                translation: configuration.position),
            relativeTo: parent)

        // Set an accessibility component on the entity.
        components.set(makeAxComponent(
            configuration: configuration))
    }

    /// Create an accessibility component suitable for the Earth entity.
    ///
    /// - Parameters:
    ///   - configuration: Information about how to configure the Earth.
    ///   - satelliteConfiguration: An array of configuration structures, one
    ///     for each artificial satellite.
    ///   - moonConfiguration: A satellite configuration structure that's
    ///     specifically for the Moon.
    /// - Returns: A new accessibility component.
    private func makeAxComponent(
        configuration: Configuration
    ) -> AccessibilityComponent {
        // Create an accessibility component.
        var axComponent = AccessibilityComponent()
        axComponent.isAccessibilityElement = true

        // Add a label.
        axComponent.label = "Earth model"

        // Add a value that describes the model's current state.
        var axValue = configuration.currentSpeed != 0 ? "Rotating, " : "Not rotating, "
        axValue.append(configuration.showSun ? "with the sun shining, " : "with the sun not shining, ")
        if configuration.axDescribeTilt {
            if let dateString = configuration.date?.formatted(.dateTime.day().month(.wide)) {
                axValue.append("and tilted for the date \(dateString)")
            } else {
                axValue.append("and no tilt")
            }
        }
        if configuration.showPoles {
            axValue.append("with the poles indicated, ")
        }
        axComponent.value = LocalizedStringResource(stringLiteral: axValue)

        // Add custom accessibility actions, if applicable.
        if !configuration.axActions.isEmpty {
            axComponent.customActions.append(contentsOf: configuration.axActions)
        }

        return axComponent
    }

    /// Calculates the orientation of the Earth's tilt on a specified date.
    ///
    /// This method assumes the sun appears at some distance from the Earth
    /// along the negative x-axis.
    ///
    /// - Parameter date: The date that the Earth's tilt represents.
    ///
    /// - Returns: A representation of tilt that you apply to an Earth model.
    private func tilt(date: Date?) -> simd_quatf {
        // Assume a constant magnitude for the Earth's tilt angle.
        let tiltAngle: Angle = .degrees(date == nil ? 0 : 23.5)

        // Find the day in the year corresponding to the date.
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.ordinality(of: .day, in: .year, for: date ?? Date()) ?? 1

        // Get an axis angle corresponding to the day of the year, assuming
        // the sun appears in the negative x direction.
        let axisAngle: Float = (Float(day) / 365.0) * 2.0 * .pi

        // Create an axis that points the northern hemisphere toward the
        // sun along the positive x-axis when axisAngle is zero.
        let tiltAxis: SIMD3<Float> = [
            sin(axisAngle),
            0,
            -cos(axisAngle)
        ]

        // Create and return a tilt orientation from the angle and axis.
        return simd_quatf(angle: Float(tiltAngle.radians), axis: tiltAxis)
    }
}

