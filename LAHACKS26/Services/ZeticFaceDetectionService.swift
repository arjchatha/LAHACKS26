//
//  ZeticFaceDetectionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import CoreImage
import UIKit

#if canImport(ZeticMLange)
import ZeticMLange
#endif

#if canImport(ext)
import ext
#endif

final class ZeticFaceDetectionService {
    private enum Constants {
        static let personalKey = "dev_9a803d0633cd4b63a00e6e4d9555b2cc"
        static let modelName = "google/MediaPipe-Face-Detection"
        static let inputShape = [1, 128, 128, 3]
    }

    private let ciContext = CIContext()

    #if canImport(ZeticMLange) && canImport(ext)
    private var model: ZeticMLangeModel?
    private let wrapper = FaceDetectionWrapper()
    #endif

    func prepare() async {
        #if canImport(ZeticMLange) && canImport(ext)
        guard model == nil else { return }

        do {
            model = try ZeticMLangeModel(
                personalKey: Constants.personalKey,
                name: Constants.modelName,
                modelMode: .RUN_AUTO,
                onDownload: { _ in }
            )
        } catch {
            model = nil
        }
        #endif
    }

    func detectFace(in pixelBuffer: CVPixelBuffer, isUsingFrontCamera: Bool) async -> FaceDetectionResult {
        #if canImport(ZeticMLange) && canImport(ext)
        guard let model, let image = makeImage(from: pixelBuffer, isUsingFrontCamera: isUsingFrontCamera) else {
            return .none
        }

        do {
            let inputData = wrapper.preprocess(image)
            let inputs = [
                Tensor(
                    data: inputData,
                    dataType: BuiltinDataType.float32,
                    shape: Constants.inputShape
                )
            ]

            _ = try model.run(inputs: inputs)
            var outputs = model.getOutputDataArray()
            let detections = wrapper.postprocess(&outputs)

            guard let best = detections.max(by: { $0.confidence < $1.confidence }) else {
                return .none
            }

            // TODO: Confirm exact MediaPipe/ZETIC output semantics and tune thresholding.
            return FaceDetectionResult.detected(
                confidence: Double(best.confidence),
                boundingBox: normalizedBoundingBox(from: best.bbox, imageSize: image.pixelSize)
            )
        } catch {
            return .none
        }
        #else
        return .none
        #endif
    }

    #if canImport(ZeticMLange) && canImport(ext)
    private func makeImage(from pixelBuffer: CVPixelBuffer, isUsingFrontCamera: Bool) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let orientation: UIImage.Orientation = isUsingFrontCamera ? .upMirrored : .up
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation).normalized()
    }

    private func normalizedBoundingBox(from box: Box, imageSize: CGSize) -> CGRect {
        let isNormalized = max(abs(box.xmin), abs(box.ymin), abs(box.xmax), abs(box.ymax)) <= 1.5

        if isNormalized {
            return CGRect(
                x: CGFloat(box.xmin),
                y: CGFloat(box.ymin),
                width: CGFloat(box.xmax - box.xmin),
                height: CGFloat(box.ymax - box.ymin)
            ).clampedToUnitRect()
        }

        return CGRect(
            x: CGFloat(box.xmin) / imageSize.width,
            y: CGFloat(box.ymin) / imageSize.height,
            width: CGFloat(box.xmax - box.xmin) / imageSize.width,
            height: CGFloat(box.ymax - box.ymin) / imageSize.height
        ).clampedToUnitRect()
    }
    #endif
}

private extension UIImage {
    var pixelSize: CGSize {
        guard let cgImage else {
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    func normalized() -> UIImage {
        guard imageOrientation != .up else {
            return self
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension CGRect {
    func clampedToUnitRect() -> CGRect {
        let minX = max(0, min(1, origin.x))
        let minY = max(0, min(1, origin.y))
        let maxX = max(0, min(1, origin.x + size.width))
        let maxY = max(0, min(1, origin.y + size.height))

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
}
