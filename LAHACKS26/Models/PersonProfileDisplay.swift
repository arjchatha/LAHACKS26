//
//  PersonProfileDisplay.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Foundation

struct PersonProfileDisplay: Equatable {
    let personId: String
    let faceProfileId: String
    let name: String
    let relationship: String
    let memoryCue: String
    let detailLines: [String]
    let caregiverApproved: Bool

    var title: String {
        "\(name) • \(relationship)"
    }

    var spokenSafeSummary: String {
        memoryCue
    }
}

struct StoredPersonVideoProfile: Identifiable, Equatable {
    let profile: PersonProfileDisplay
    let videoURL: URL
    let createdAt: Date

    var id: String {
        profile.personId
    }
}

enum PersonProfileDisplayResult: Equatable {
    case approved(PersonProfileDisplay)
    case unknown(String)

    var title: String {
        switch self {
        case .approved(let profile):
            return profile.title
        case .unknown:
            return "Person nearby"
        }
    }

    var description: String {
        switch self {
        case .approved(let profile):
            return profile.spokenSafeSummary
        case .unknown(let message):
            return message
        }
    }

    var detailLines: [String] {
        switch self {
        case .approved(let profile):
            return profile.detailLines
        case .unknown:
            return []
        }
    }
}
