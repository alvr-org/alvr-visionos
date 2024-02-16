//
//  ViewModel.swift
//  ALVRClient
//

import SwiftUI

@Observable
class ViewModel {
    // Entry
    var isShowingEntry: Bool = true
    
    // Cube
    var cubeEntity: CubeEntity.Configuration = .cubeDefault
    
    // Client
    var isShowingClient: Bool = false

}
