//
//  Module.swift
//  ALVRClient
//

import Foundation

enum Module: String, Identifiable, CaseIterable, Equatable {
    case entry, client
    var id: Self { self }
    var name: String { rawValue.capitalized }

    var callToAction: String {
        switch self {
        case .entry: "View Entry"
        case .client: "View ALVR"
        }
    }

}
