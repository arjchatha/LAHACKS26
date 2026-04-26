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
        static let defaultPaddingScales: [CGFloat] = [0.10, 0.20, 0.30]
    }

    private let ciContext = CIContext()

    func croppedFaceImages(
        from pixelBuffer: CVPixelBuffer,
        faceRect: CGRect,
        paddingScales: [CGFloat] = Constants.defaultPaddingScales
    ) throws -> [CGImage] {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw FaceCropperError.couldNotCreateFaceImage
        }

        return try croppedFaceImages(
            from: cgImage,
            topLeftNormalizedFaceRect: faceRect,
            paddingScales: paddingScales
        )
    }

    func croppedFaceImages(
        from cgImage: CGImage,
        topLeftNormalizedFaceRect faceRect: CGRect,
        paddingScales: [CGFloat] = Constants.defaultPaddingScales
    ) throws -> [CGImage] {
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let validScales = paddingScales.isEmpty ? Constants.defaultPaddingScales : paddingScales
        let croppedImages = validScales.compactMap { paddingScale -> CGImage? in
            let cropRect = paddedSquareRect(
                for: faceRect,
                sourceSize: sourceSize,
                paddingScale: paddingScale
            )
            guard cropRect.width > 1, cropRect.height > 1 else { return nil }
            return cgImage.cropping(to: cropRect.integral)
        }

        guard !croppedImages.isEmpty else {
            throw FaceCropperError.invalidFaceRect
        }

        return croppedImages
    }

    private func paddedSquareRect(
        for faceRect: CGRect,
        sourceSize: CGSize,
        paddingScale: CGFloat
    ) -> CGRect {
        let pixelRect = CGRect(
            x: faceRect.minX * sourceSize.width,
            y: faceRect.minY * sourceSize.height,
            width: faceRect.width * sourceSize.width,
            height: faceRect.height * sourceSize.height
        )

        let side = max(pixelRect.width, pixelRect.height) * (1 + (paddingScale * 2))
        let rect = CGRect(
            x: pixelRect.midX - side / 2,
            y: pixelRect.midY - side / 2,
            width: side,
            height: side
        )

        return rect.clamped(to: CGRect(origin: .zero, size: sourceSize))
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
