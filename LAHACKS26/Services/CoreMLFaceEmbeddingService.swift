//
//  CoreMLFaceEmbeddingService.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import CoreML
import Foundation

enum CoreMLFaceEmbeddingError: LocalizedError {
    case modelNotFound
    case invalidInputCount(expected: Int, actual: Int)
    case missingEmbeddingOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            "VGGFaceEmbedding.mlpackage is not bundled with the app target."
        case .invalidInputCount(let expected, let actual):
            "Expected \(expected) face tensor values, received \(actual)."
        case .missingEmbeddingOutput:
            "The Core ML model did not return an embedding output."
        }
    }
}

final class CoreMLFaceEmbeddingService {
    private enum Constants {
        static let modelName = "VGGFaceEmbedding"
        static let compiledModelExtension = "mlmodelc"
        static let packageExtension = "mlpackage"
        static let inputName = "face_image"
        static let outputName = "embedding"
        static let inputCount = 1 * 3 * 224 * 224
    }

    private let model: MLModel

    init(bundle: Bundle = .main) throws {
        self.model = try Self.loadModel(from: bundle)
    }

    func embedding(forPreprocessedFaceTensor tensor: [Float]) throws -> [Float] {
        guard tensor.count == Constants.inputCount else {
            throw CoreMLFaceEmbeddingError.invalidInputCount(
                expected: Constants.inputCount,
                actual: tensor.count
            )
        }

        let inputArray = try MLMultiArray(
            shape: [1, 3, 224, 224],
            dataType: .float32
        )

        for (index, value) in tensor.enumerated() {
            inputArray[index] = NSNumber(value: value)
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: [Constants.inputName: inputArray]
        )
        let prediction = try model.prediction(from: input)

        guard let outputArray = prediction.featureValue(for: Constants.outputName)?.multiArrayValue else {
            throw CoreMLFaceEmbeddingError.missingEmbeddingOutput
        }

        return (0..<outputArray.count).map { index in
            outputArray[index].floatValue
        }
    }

    private static func loadModel(from bundle: Bundle) throws -> MLModel {
        if let compiledURL = bundle.url(
            forResource: Constants.modelName,
            withExtension: Constants.compiledModelExtension
        ) {
            return try MLModel(contentsOf: compiledURL)
        }

        if let packageURL = bundle.url(
            forResource: Constants.modelName,
            withExtension: Constants.packageExtension
        ) {
            let compiledURL = try MLModel.compileModel(at: packageURL)
            return try MLModel(contentsOf: compiledURL)
        }

        throw CoreMLFaceEmbeddingError.modelNotFound
    }
}
