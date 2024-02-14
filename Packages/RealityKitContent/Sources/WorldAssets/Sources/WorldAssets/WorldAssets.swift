/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Assets for the World app.
*/

import Foundation
import RealityKit

/// Bundle for the WorldAssets project
public let worldAssetsBundle = Bundle.module
public let sceneName = "Earth.usda"
public let rootNodeName = "Earth"
public let panSpeedParameterName = "pan_speed"
public let minimumCloudOpacityParameterName = "cloud_min_opacity"
public let maximumCloudOpacityParameterName = "cloud_max_opacity"
public let lightsMaximuIntensityParameterName = "light_max_intensity"

/// The name of the material parameter that indicates the sun's angle.
///
/// This is a clamped float where a value of 0.0 (or 1.0) refers to light
/// coming from directly in front of the object and 0.5 refers to light
/// coming from directly behind the model. The model can use this information
/// to adjust any material effects accordingly, like whether the nighttime
/// lights should be visible on the Earth's surface.
public let sunAngleParameterName = "sun_angle"

/// Loads the specified model from the app's asset bundle, or aborts the app
/// if the load fails.
///
/// This method assumes that callers have specified a valid asset name.
/// Failure to find the asset in the bundle indicates that something is
/// fundamentally wrong with the app's assets, and therefore with the app.
/// In that case, the method aborts the app.
///
/// The method does allow for the entity initializer to throw a
/// `CancellationError`. That can happen if an enclosing RealityView gets
/// removed from the SwiftUI view hierarchy while the initializer's load
/// operation is in progress. In that case, the method returns `nil`.
/// Upon receiving a `nil` return value, callers typically bypass any
/// further entity configuration, because the system discards the entity.
///
/// - Parameter name: The name of the entity to load from the bundle.
/// - Returns: The entity from the bundle, or `nil` if the system cancels
///   the load operation before it completes. The method aborts the app
///   for any other kind of load failure.
public func entity(named name: String) async -> Entity? {
    do {
        return try await Entity(named: name, in: worldAssetsBundle)

    } catch is CancellationError {
        // The entity initializer can throw this error if an enclosing
        // RealityView disappears before the model loads. Exit gracefully.
        return nil

    } catch let error {
        // Other errors indicate unrecoverable problems.
        fatalError("Failed to load \(name): \(error)")
    }
}
