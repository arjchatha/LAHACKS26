//
//  FaceEmbeddingMath.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import Accelerate
import Foundation

enum FaceEmbeddingMath {
    static func l2Normalized(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }

        let sumOfSquares = vDSP.sumOfSquares(values)
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return values }

        return values.map { $0 / norm }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }

        let dotProduct = vDSP.dot(lhs, rhs)
        let lhsNorm = sqrt(vDSP.sumOfSquares(lhs))
        let rhsNorm = sqrt(vDSP.sumOfSquares(rhs))
        let denominator = lhsNorm * rhsNorm

        guard denominator > 0 else { return nil }
        return dotProduct / denominator
    }
}
