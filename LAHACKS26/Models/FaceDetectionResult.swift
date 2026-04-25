//
//  FaceDetectionResult.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import Foundation

struct FaceDetectionResult: Equatable {
    let hasFace: Bool
    let confidence: Double
    let boundingBox: CGRect?
    let faceProfileId: String?
    let sourceImageSize: CGSize?

    nonisolated static let none = FaceDetectionResult(
        hasFace: false,
        confidence: 0,
        boundingBox: nil,
        faceProfileId: nil,
        sourceImageSize: nil
    )

    nonisolated static func detected(
        confidence: Double,
        boundingBox: CGRect?,
        faceProfileId: String = "face-maya-001",
        sourceImageSize: CGSize? = nil
    ) -> FaceDetectionResult {
        FaceDetectionResult(
            hasFace: true,
            confidence: confidence,
            boundingBox: boundingBox,
            faceProfileId: faceProfileId,
            sourceImageSize: sourceImageSize
        )
    }

    nonisolated static let demoMaya = FaceDetectionResult.detected(
        confidence: 0.94,
        boundingBox: CGRect(x: 0.31, y: 0.19, width: 0.38, height: 0.42)
    )
}
