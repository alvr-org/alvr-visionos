//
//  ViewModel.swift
//  ALVRClient
//
//  Created by Chris Metrailer on 2/10/24.
//

import SwiftUI

@Observable
class ViewModel {
    // MARK: - Navigation
    var navigationPath: [Module] = []
    var titleText: String = ""
    var isTitleFinished: Bool = true
    var finalTitle: String = "Hello World"

    // MARK: - Globe
    var isShowingGlobe: Bool = true
    var globeEarth: EarthEntity.Configuration = .globeEarthDefault
    var isGlobeRotating: Bool = true
    var globeTilt: GlobeTilt = .none
    var requestClient: Bool = false
    
    // Client
    var isShowingClient: Bool = false
    
}
