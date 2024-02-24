//
//  GlobalSettings.swift
//  ALVRClient
//
//  Created by Max Thomas on 2/23/24.
//

import Foundation

class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    
    // TODO: configuration persistence
    var keepSteamVRCenter = true
    var showHandsOverlaid = false
}
