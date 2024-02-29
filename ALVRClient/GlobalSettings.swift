//
//  GlobalSettings.swift
//

import Foundation
import SwiftUI

struct GlobalSettings: Codable {
    var keepSteamVRCenter: Bool
    var showHandsOverlaid: Bool
    
    init(keepSteamVRCenter: Bool, showHandsOverlaid: Bool) {
        self.keepSteamVRCenter = keepSteamVRCenter
        self.showHandsOverlaid = showHandsOverlaid
    }
}

extension GlobalSettings {
    static let sampleData: GlobalSettings =
    GlobalSettings(keepSteamVRCenter: true, showHandsOverlaid: true)
}

@MainActor
class GlobalSettingsStore: ObservableObject {
    @Published var settings: GlobalSettings = GlobalSettings(keepSteamVRCenter: false, showHandsOverlaid: false)
    
    private static func fileURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        .appendingPathComponent("globalsettings.data")
    }
    
    func load() async throws {
        let task = Task<GlobalSettings, Error> {
            let fileURL = try Self.fileURL()
            guard let data = try? Data(contentsOf: fileURL) else {
                return GlobalSettings(keepSteamVRCenter: false, showHandsOverlaid: false)
            }
            let globalSettings = try JSONDecoder().decode(GlobalSettings.self, from: data)
            return globalSettings
        }
        let settings = try await task.value
        self.settings = settings
    }
    
    func save(settings: GlobalSettings) async throws {
        let task = Task {
            let data = try JSONEncoder().encode(settings)
            let outfile = try Self.fileURL()
            try data.write(to: outfile)
        }
        _ = try await task.value
    }
}
