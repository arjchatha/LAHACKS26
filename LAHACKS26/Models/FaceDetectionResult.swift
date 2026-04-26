//
//  FaceDetectionResult.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import Foundation

struct FaceDetectionResult: Identifiable, Equatable {
    let id: UUID
    let confidence: Double
    let boundingBox: CGRect
    let sourceImageSize: CGSize?
    let faceProfileId: String?

    var hasFace: Bool {
        confidence > 0 && !boundingBox.isNull && !boundingBox.isEmpty
    }

    nonisolated static let none = FaceDetectionResult(
        id: UUID(),
        confidence: 0,
        boundingBox: .null,
        sourceImageSize: nil,
        faceProfileId: nil
    )

    nonisolated static func detected(
        id: UUID = UUID(),
        confidence: Double,
        boundingBox: CGRect,
        sourceImageSize: CGSize? = nil,
        faceProfileId: String? = nil
    ) -> FaceDetectionResult {
        FaceDetectionResult(
            id: id,
            confidence: confidence,
            boundingBox: boundingBox,
            sourceImageSize: sourceImageSize,
            faceProfileId: faceProfileId
        )
    }

    nonisolated static let demoMaya = FaceDetectionResult.detected(
        confidence: 0.94,
        boundingBox: CGRect(x: 0.31, y: 0.19, width: 0.38, height: 0.42)
    )
}
