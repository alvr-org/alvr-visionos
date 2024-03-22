//
//  GlobalSettings.swift
//

import Foundation
import SwiftUI

struct GlobalSettings: Codable {
    var keepSteamVRCenter: Bool = true
    var showHandsOverlaid: Bool = false
    var setDisplayTo96Hz: Bool = false
    var upscalingFactor: Float32 = 1.0
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.keepSteamVRCenter = try container.decodeIfPresent(Bool.self, forKey: .keepSteamVRCenter) ?? self.keepSteamVRCenter
        self.showHandsOverlaid = try container.decodeIfPresent(Bool.self, forKey: .showHandsOverlaid) ?? self.showHandsOverlaid
        self.setDisplayTo96Hz = try container.decodeIfPresent(Bool.self, forKey: .setDisplayTo96Hz) ?? self.setDisplayTo96Hz
        self.upscalingFactor = try container.decodeIfPresent(Float32.self, forKey: .upscalingFactor) ?? self.upscalingFactor
    }
}

extension GlobalSettings {
    static let sampleData: GlobalSettings =
    GlobalSettings()
}

@MainActor
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
