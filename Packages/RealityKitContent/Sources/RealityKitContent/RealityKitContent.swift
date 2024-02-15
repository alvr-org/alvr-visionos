import Foundation
import RealityKit

/// Bundle for the RealityKitContent project
public let realityKitContentBundle = Bundle.module
public let sceneName = "Cube.usda"
public let rootNodeName = "Cube"


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
        return try await Entity(named: name, in: realityKitContentBundle)

    } catch is CancellationError {
        // The entity initializer can throw this error if an enclosing
        // RealityView disappears before the model loads. Exit gracefully.
        return nil

    } catch let error {
        // Other errors indicate unrecoverable problems.
        fatalError("Failed to load \(name): \(error)")
    }
}
