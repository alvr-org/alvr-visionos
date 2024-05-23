//
//  GlobalSettings.swift
//

import Foundation
import SwiftUI

struct GlobalSettings: Codable {
    var keepSteamVRCenter: Bool = true
    var showHandsOverlaid: Bool = false
    var setDisplayTo96Hz: Bool = false
    var experimental40ppd: Bool = false
    var chromaKeyEnabled: Bool = false
    var chromaKeyDistRangeMin: Float = 0.35
    var chromaKeyDistRangeMax: Float = 0.7
    var chromaKeyColorR: Float = 16.0 / 255.0
    var chromaKeyColorG: Float = 124.0 / 255.0
    var chromaKeyColorB: Float = 16.0 / 255.0
    var dismissWindowOnEnter: Bool = true
    var realityKitRenderScale: Float = 1.75
    var metalFxEnabled: Bool = false
    var emulatedPinchInteractions: Bool = false
    var dontShowAWDLAlertAgain: Bool = false
    var fovRenderScale: Float = 1.0
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.keepSteamVRCenter = try container.decodeIfPresent(Bool.self, forKey: .keepSteamVRCenter) ?? self.keepSteamVRCenter
        self.showHandsOverlaid = try container.decodeIfPresent(Bool.self, forKey: .showHandsOverlaid) ?? self.showHandsOverlaid
        self.setDisplayTo96Hz = try container.decodeIfPresent(Bool.self, forKey: .setDisplayTo96Hz) ?? self.setDisplayTo96Hz
        self.experimental40ppd = try container.decodeIfPresent(Bool.self, forKey: .experimental40ppd) ?? self.experimental40ppd
        self.chromaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyEnabled) ?? self.chromaKeyEnabled
        self.chromaKeyDistRangeMin = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMin) ?? self.chromaKeyDistRangeMin
        self.chromaKeyDistRangeMax = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMax) ?? self.chromaKeyDistRangeMax
        self.chromaKeyColorR = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorR) ?? self.chromaKeyColorR
        self.chromaKeyColorG = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorG) ?? self.chromaKeyColorG
        self.chromaKeyColorB = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorB) ?? self.chromaKeyColorB
        self.dismissWindowOnEnter = try container.decodeIfPresent(Bool.self, forKey: .dismissWindowOnEnter) ?? self.dismissWindowOnEnter
        self.realityKitRenderScale = try container.decodeIfPresent(Float.self, forKey: .realityKitRenderScale) ?? self.realityKitRenderScale
        self.metalFxEnabled = try container.decodeIfPresent(Bool.self, forKey: .metalFxEnabled) ?? self.metalFxEnabled
        self.emulatedPinchInteractions = try container.decodeIfPresent(Bool.self, forKey: .emulatedPinchInteractions) ?? self.emulatedPinchInteractions
        self.dontShowAWDLAlertAgain = try container.decodeIfPresent(Bool.self, forKey: .dontShowAWDLAlertAgain) ?? self.dontShowAWDLAlertAgain
        self.fovRenderScale = try container.decodeIfPresent(Float.self, forKey: .fovRenderScale) ?? self.fovRenderScale
    }
}

extension GlobalSettingsStore {
    static let sampleData: GlobalSettingsStore =
    GlobalSettingsStore()
}

class GlobalSettingsStore: ObservableObject {
    @Published var settings: GlobalSettings = GlobalSettings()
    
    private static func fileURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        .appendingPathComponent("globalsettings.data")
    }
    
    func load() throws {
        let fileURL = try Self.fileURL()
        guard let data = try? Data(contentsOf: fileURL) else {
            return self.settings = GlobalSettings()
        }
        let globalSettings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        self.settings = globalSettings
    }
    
    func save(settings: GlobalSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let outfile = try Self.fileURL()
        try data.write(to: outfile)
    }
}
