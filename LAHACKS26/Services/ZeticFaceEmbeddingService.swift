//
//  ZeticFaceEmbeddingService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import Foundation

#if canImport(ZeticMLange)
import ZeticMLange
#endif

enum ZeticFaceEmbeddingError: LocalizedError {
    case modelUnavailable(String)
    case noEmbeddingOutput
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let message):
            message
        case .noEmbeddingOutput:
            "ZETIC did not return a usable face embedding."
        case .unsupportedPlatform:
            "ZETIC face recognition requires the ZeticMLange package on a physical iPhone build."
        }
    }
}

final class ZeticFaceEmbeddingService {
    private enum Constants {
        static let personalKey = "dev_fdc9e57ff6d34bc6a590307ae5b0b101"
        static let modelName = "arjun/LAHACKS_FacialRecognition"
        static let modelVersion = 6
        static let sideLength = 112
    }

    #if canImport(ZeticMLange)
    private let model: ZeticMLangeModel
    #endif

    init() throws {
        #if canImport(ZeticMLange)
        do {
            model = try ZeticMLangeModel(
                personalKey: Constants.personalKey,
                name: Constants.modelName,
                version: Constants.modelVersion,
                modelMode: .RUN_ACCURACY,
                onDownload: { _ in }
            )
        } catch {
            throw ZeticFaceEmbeddingError.modelUnavailable(error.localizedDescription)
        }
        #else
        throw ZeticFaceEmbeddingError.unsupportedPlatform
        #endif
    }

    func embedding(for croppedFaceImage: CGImage) throws -> [Float] {
        #if canImport(ZeticMLange)
        let tensor = try recognitionTensor(from: croppedFaceImage)
        let outputs = try model.run(inputs: [tensor])
        if let firstOutput = outputs.first {
            let embedding = DataUtils.dataToFloatArray(firstOutput.data)
            if !embedding.isEmpty, embedding.allSatisfy(\.isFinite) {
                return embedding
            }
        }

        throw ZeticFaceEmbeddingError.noEmbeddingOutput
        #else
        _ = croppedFaceImage
        throw ZeticFaceEmbeddingError.unsupportedPlatform
        #endif
    }

    #if canImport(ZeticMLange)
    private func recognitionTensor(from cgImage: CGImage) throws -> Tensor {
        let floats = renderAndNormalize(cgImage: cgImage)
        return try tensor(from: floats)
    }

    private func renderAndNormalize(cgImage: CGImage) -> [Float] {
        let width = Constants.sideLength
        let height = Constants.sideLength
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            return []
        }

        let pixelCount = width * height
        var floats = [Float](repeating: 0, count: pixelCount * 3)

        for index in 0..<pixelCount {
            let base = index * bytesPerPixel
            floats[index] = (Float(pixels[base]) - 127.5) / 127.5
            floats[pixelCount + index] = (Float(pixels[base + 1]) - 127.5) / 127.5
            floats[(pixelCount * 2) + index] = (Float(pixels[base + 2]) - 127.5) / 127.5
        }

        return floats
    }

    private func tensor(from normalizedFloats: [Float]) throws -> Tensor {
        let data = normalizedFloats.withUnsafeBufferPointer { Data(buffer: $0) }

        return Tensor(
            data: data,
            dataType: BuiltinDataType.float32,
            shape: [1, 3, Constants.sideLength, Constants.sideLength]
        )
    }
    #endif
}
