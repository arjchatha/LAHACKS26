//
//  FaceCropper.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

enum FaceCropperError: LocalizedError {
    case couldNotCreateFaceImage
    case invalidFaceRect

    var errorDescription: String? {
        switch self {
        case .couldNotCreateFaceImage:
            "The app could not crop the detected face."
        case .invalidFaceRect:
            "The detected face was too small or outside the image."
        }
    }
}

final class FaceCropper {
    private enum Constants {
        static let sideLength = 224
        static let paddingScale: CGFloat = 0.24
        static let channelMeans: [Float] = [
            129.186279296875,
            104.76238250732422,
            93.59396362304688
        ]
    }

    private let ciContext = CIContext()

    func preprocessedTensor(from pixelBuffer: CVPixelBuffer, faceRect: CGRect) throws -> [Float] {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw FaceCropperError.couldNotCreateFaceImage
        }

        return try preprocessedTensor(from: cgImage, topLeftNormalizedFaceRect: faceRect)
    }

    func preprocessedTensor(from cgImage: CGImage, topLeftNormalizedFaceRect faceRect: CGRect) throws -> [Float] {
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let cropRect = paddedSquareRect(for: faceRect, sourceSize: sourceSize)

        guard
            cropRect.width > 1,
            cropRect.height > 1,
            let croppedImage = cgImage.cropping(to: cropRect)
        else {
            throw FaceCropperError.invalidFaceRect
        }

        return try rgbTensor(from: croppedImage)
    }

    private func paddedSquareRect(for faceRect: CGRect, sourceSize: CGSize) -> CGRect {
        let pixelRect = CGRect(
            x: faceRect.minX * sourceSize.width,
            y: faceRect.minY * sourceSize.height,
            width: faceRect.width * sourceSize.width,
            height: faceRect.height * sourceSize.height
        )

        let side = max(pixelRect.width, pixelRect.height) * (1 + Constants.paddingScale)
        let rect = CGRect(
            x: pixelRect.midX - side / 2,
            y: pixelRect.midY - side / 2,
            width: side,
            height: side
        )

        return rect.clamped(to: CGRect(origin: .zero, size: sourceSize))
    }

    private func rgbTensor(from image: CGImage) throws -> [Float] {
        let sideLength = Constants.sideLength
        let pixelCount = sideLength * sideLength
        let bytesPerPixel = 4
        let bytesPerRow = sideLength * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: pixelCount * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: sideLength,
            height: sideLength,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw FaceCropperError.couldNotCreateFaceImage
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: sideLength, height: sideLength))

        var tensor = [Float](repeating: 0, count: 3 * pixelCount)

        for pixelIndex in 0..<pixelCount {
            let byteIndex = pixelIndex * bytesPerPixel
            tensor[pixelIndex] = Float(pixels[byteIndex]) - Constants.channelMeans[0]
            tensor[pixelCount + pixelIndex] = Float(pixels[byteIndex + 1]) - Constants.channelMeans[1]
            tensor[(2 * pixelCount) + pixelIndex] = Float(pixels[byteIndex + 2]) - Constants.channelMeans[2]
        }

        return tensor
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let clampedMinX = max(bounds.minX, min(bounds.maxX, minX))
        let clampedMinY = max(bounds.minY, min(bounds.maxY, minY))
        let clampedMaxX = max(bounds.minX, min(bounds.maxX, maxX))
        let clampedMaxY = max(bounds.minY, min(bounds.maxY, maxY))

        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: max(0, clampedMaxX - clampedMinX),
            height: max(0, clampedMaxY - clampedMinY)
        )
    }
}
