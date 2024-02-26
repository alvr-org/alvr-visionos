//
//  GlobalSettings.swift
//

import Foundation

class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    
    // TODO: configuration persistence
    var keepSteamVRCenter = true
    var showHandsOverlaid = false
}
