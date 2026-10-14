import Combine
import GameController

extension GCController {
    class func spatialControllers() -> [GCController] {
        if #available(visionOS 26.0, *) {
#if XCODE_BETA_26
            //print(GCController.controllers().map({ $0.productCategory}))
            return GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
#else
            return []
#endif
        }
        else {
            return []
        }
    }
}

extension GCController {
    /// Asks visionOS not to act on the controller's Home (PS) button, so the press reaches the app.
    ///
    /// This is only a request: the system honors it when the user's "in-app action" for the controller
    /// Home button is set to "Defer to app" in Settings (visionOS 27). See `ControllerHomeButtonStatus`.
    func claimHomeButtonFromSystem() {
        guard let home = physicalInputProfile.buttons[GCInputButtonHome] else {
            return
        }
        if home.preferredSystemGestureState != .disabled {
            home.preferredSystemGestureState = .disabled
        }
    }
}

/// Whether the controller Home (PS) button can reach the app, and a way to ask the user to enable it.
///
/// visionOS 27 lets the user choose what the Home button does while an app is in front: keep the system
/// behavior, or defer to the app. The app can read that choice and open the Settings page, but not change it.
final class ControllerHomeButtonStatus: ObservableObject {
    static let shared = ControllerHomeButtonStatus()

    enum State {
        /// visionOS older than 27, or the setting can't be read (no controller connected, no permission).
        case unknown
        /// The system keeps handling the Home button; the user has to switch it to "Defer to app".
        case systemHandles
        /// The app receives the Home button while it is in front.
        case deliveredToApp
    }

    @Published private(set) var state: State = .unknown

    /// True only when we know the Home button press reaches the app.
    var reachesApp: Bool { state == .deliveredToApp }

#if XCODE_BETA_27
    private var manager: AnyObject? = nil
    private var updatesTask: Task<Void, Never>? = nil
#endif

    /// Call once a controller is connected (the manager refuses to work without one). Cheap to call again.
    @MainActor func start() {
#if XCODE_BETA_27
        if #available(visionOS 27.0, *) {
            guard manager == nil else { return }
            let m = GCControllerHomeButtonSettingsManager()
            manager = m
            refresh(m)
            updatesTask = Task { @MainActor [weak self] in
                for await _ in m.settingsUpdates {
                    self?.refresh(m)
                }
            }
        }
#endif
    }

    /// Opens the Settings page where the user picks "Defer to app" for the in-app action.
    @MainActor func openSettings() {
#if XCODE_BETA_27
        if #available(visionOS 27.0, *), let m = manager as? GCControllerHomeButtonSettingsManager {
            do {
                try m.openControllerHomeButtonSettings(for: .customizeInAppAction)
            }
            catch {
                print("Could not open controller Home button settings: \(error)")
            }
        }
#endif
    }

#if XCODE_BETA_27
    @available(visionOS 27.0, *)
    @MainActor private func refresh(_ m: GCControllerHomeButtonSettingsManager) {
        do {
            let (action, _) = try m.controllerHomeButtonInAppAction
            state = (action == .defer) ? .deliveredToApp : .systemHandles
        }
        catch {
            // Reading needs a connected controller; try again on the next start() call.
            manager = nil
            updatesTask?.cancel()
            updatesTask = nil
            state = .unknown
        }
    }
#endif
}
