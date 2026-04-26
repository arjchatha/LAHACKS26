//
//  ArcFaceAligner.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import CoreGraphics
import UIKit
import Vision

final class ArcFaceAligner {
    private enum Constants {
        static let outputSize = CGSize(width: 112, height: 112)
        static let template: [CGPoint] = [
            CGPoint(x: 38.2946, y: 51.6963),
            CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366),
            CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041)
        ]
    }

    func alignedFaceImage(from image: CGImage, observation: VNFaceObservation) -> CGImage? {
        guard
            let sourcePoints = landmarkPoints(from: observation, imageSize: CGSize(width: image.width, height: image.height)),
            let transform = similarityTransform(from: sourcePoints, to: Constants.template)
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: Constants.outputSize, format: format)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: Constants.outputSize))

            let cgContext = context.cgContext
            cgContext.interpolationQuality = .high
            cgContext.concatenate(transform)
            UIImage(cgImage: image).draw(
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }

        return rendered.cgImage
    }

    private func landmarkPoints(from observation: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let landmarks = observation.landmarks else { return nil }

        let leftEye = center(of: landmarks.leftPupil ?? landmarks.leftEye, in: observation, imageSize: imageSize)
        let rightEye = center(of: landmarks.rightPupil ?? landmarks.rightEye, in: observation, imageSize: imageSize)
        let nose = noseTip(from: landmarks, in: observation, imageSize: imageSize)
        let mouth = mouthCorners(from: landmarks.outerLips, in: observation, imageSize: imageSize)

        guard
            let firstEye = leftEye,
            let secondEye = rightEye,
            let nose,
            let mouth
        else {
            return nil
        }

        let eyes = [firstEye, secondEye].sorted { $0.x < $1.x }
        return [eyes[0], eyes[1], nose, mouth.left, mouth.right]
    }

    private func center(
        of region: VNFaceLandmarkRegion2D?,
        in observation: VNFaceObservation,
        imageSize: CGSize
    ) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }

        let converted = points.map {
            imagePoint(from: $0, in: observation, imageSize: imageSize)
        }
        let sum = converted.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = CGFloat(converted.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private func noseTip(
        from landmarks: VNFaceLandmarks2D,
        in observation: VNFaceObservation,
        imageSize: CGSize
    ) -> CGPoint? {
        if let noseCrest = landmarks.noseCrest?.normalizedPoints, !noseCrest.isEmpty {
            return noseCrest
                .map { imagePoint(from: $0, in: observation, imageSize: imageSize) }
                .max { $0.y < $1.y }
        }

        return center(of: landmarks.nose, in: observation, imageSize: imageSize)
    }

    private func mouthCorners(
        from region: VNFaceLandmarkRegion2D?,
        in observation: VNFaceObservation,
        imageSize: CGSize
    ) -> (left: CGPoint, right: CGPoint)? {
        guard let points = region?.normalizedPoints, points.count >= 2 else { return nil }

        let converted = points.map {
            imagePoint(from: $0, in: observation, imageSize: imageSize)
        }
        guard
            let left = converted.min(by: { $0.x < $1.x }),
            let right = converted.max(by: { $0.x < $1.x })
        else {
            return nil
        }

        return (left, right)
    }

    private func imagePoint(
        from landmarkPoint: CGPoint,
        in observation: VNFaceObservation,
        imageSize: CGSize
    ) -> CGPoint {
        let box = observation.boundingBox
        let normalizedX = box.minX + (landmarkPoint.x * box.width)
        let normalizedY = box.minY + (landmarkPoint.y * box.height)

        return CGPoint(
            x: normalizedX * imageSize.width,
            y: (1 - normalizedY) * imageSize.height
        )
    }

    private func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 2 else { return nil }

        let sourceMean = mean(source)
        let destinationMean = mean(destination)
        var denominator: CGFloat = 0
        var aNumerator: CGFloat = 0
        var bNumerator: CGFloat = 0

        for index in source.indices {
            let sourceX = source[index].x - sourceMean.x
            let sourceY = source[index].y - sourceMean.y
            let destinationX = destination[index].x - destinationMean.x
            let destinationY = destination[index].y - destinationMean.y

            denominator += (sourceX * sourceX) + (sourceY * sourceY)
            aNumerator += (destinationX * sourceX) + (destinationY * sourceY)
            bNumerator += (destinationY * sourceX) - (destinationX * sourceY)
        }

        guard denominator > 0 else { return nil }

        let a = aNumerator / denominator
        let b = bNumerator / denominator
        let tx = destinationMean.x - (a * sourceMean.x) + (b * sourceMean.y)
        let ty = destinationMean.y - (b * sourceMean.x) - (a * sourceMean.y)

        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    private func mean(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = CGFloat(points.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }
}
