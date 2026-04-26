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
        static let modelVersion = 2
        static let sideLength = 112
    }

    private enum ChannelOrder {
        case rgb
        case bgr
    }

    private enum TensorPacking {
        case hwc
        case chw
    }

    private enum RecognitionTensorLayout {
        case rgbHwc
        case bgrHwc
        case rgbChw
        case bgrChw
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
        let inputs = recognitionTensors(from: croppedFaceImage)

        for tensor in inputs {
            do {
                let outputs = try model.run(inputs: [tensor])
                if let firstOutput = outputs.first {
                    let embedding = DataUtils.dataToFloatArray(firstOutput.data)
                    if !embedding.isEmpty, embedding.allSatisfy(\.isFinite) {
                        return embedding
                    }
                }
            } catch {
                continue
            }
        }

        throw ZeticFaceEmbeddingError.noEmbeddingOutput
        #else
        _ = croppedFaceImage
        throw ZeticFaceEmbeddingError.unsupportedPlatform
        #endif
    }

    #if canImport(ZeticMLange)
    private func recognitionTensors(from cgImage: CGImage) -> [Tensor] {
        let layouts: [(RecognitionTensorLayout, [Float])] = [
            (.rgbChw, renderAndNormalize(cgImage: cgImage, channelOrder: .rgb, packing: .chw)),
            (.bgrChw, renderAndNormalize(cgImage: cgImage, channelOrder: .bgr, packing: .chw)),
            (.rgbHwc, renderAndNormalize(cgImage: cgImage, channelOrder: .rgb, packing: .hwc)),
            (.bgrHwc, renderAndNormalize(cgImage: cgImage, channelOrder: .bgr, packing: .hwc))
        ]

        return layouts.compactMap { layout, floats in
            guard !floats.isEmpty else { return nil }
            return try? tensor(from: floats, layout: layout)
        }
    }

    private func renderAndNormalize(
        cgImage: CGImage,
        channelOrder: ChannelOrder,
        packing: TensorPacking
    ) -> [Float] {
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
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)

        for index in 0..<pixelCount {
            let base = index * bytesPerPixel
            rChannel[index] = (Float(pixels[base]) - 127.5) / 128.0
            gChannel[index] = (Float(pixels[base + 1]) - 127.5) / 128.0
            bChannel[index] = (Float(pixels[base + 2]) - 127.5) / 128.0
        }

        switch packing {
        case .hwc:
            var floats: [Float] = []
            floats.reserveCapacity(pixelCount * 3)

            for index in 0..<pixelCount {
                switch channelOrder {
                case .rgb:
                    floats.append(rChannel[index])
                    floats.append(gChannel[index])
                    floats.append(bChannel[index])
                case .bgr:
                    floats.append(bChannel[index])
                    floats.append(gChannel[index])
                    floats.append(rChannel[index])
                }
            }

            return floats
        case .chw:
            switch channelOrder {
            case .rgb:
                return rChannel + gChannel + bChannel
            case .bgr:
                return bChannel + gChannel + rChannel
            }
        }
    }

    private func tensor(from normalizedFloats: [Float], layout: RecognitionTensorLayout) throws -> Tensor {
        let data = normalizedFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let shape: [Int]

        switch layout {
        case .rgbHwc, .bgrHwc:
            shape = [1, Constants.sideLength, Constants.sideLength, 3]
        case .rgbChw, .bgrChw:
            shape = [1, 3, Constants.sideLength, Constants.sideLength]
        }

        return Tensor(
            data: data,
            dataType: BuiltinDataType.float32,
            shape: shape
        )
    }
    #endif
}
