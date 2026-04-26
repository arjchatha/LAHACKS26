import AVFoundation
import Accelerate
import Combine
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import SwiftUI
import Vision

#if canImport(ZeticMLange) && !targetEnvironment(simulator)
import ZeticMLange
#endif

struct FaceTrack: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect
    let confidence: Float
    let identity: String?
    let identityConfidence: Float?
    let bestCandidate: String?
    let bestCandidateConfidence: Float?
    let embedding: [Float]?

    var label: String {
        if let identity, let identityConfidence {
            return "\(identity) \(Int(identityConfidence * 100))%"
        }
        if let identity {
            return identity
        }
        if let bestCandidate, let bestCandidateConfidence {
            return "Unknown (\(bestCandidate) \(Int(bestCandidateConfidence * 100))%)"
        }
        return "Unknown"
    }
}

struct RegisteredFaceRecord: Codable, Equatable {
    let name: String
    let embedding: [Float]
}

private struct TrainingSnapshot {
    let image: CGImage
    let faceBoundingBox: CGRect?
}

final class FaceRecognitionPipeline: NSObject, ObservableObject {
    @Published var faces: [FaceTrack] = []
    @Published var isRunning = false
    @Published var statusMessage = "Waiting to start..."
    @Published var detectorReady = false
    @Published var modelReady = false
    @Published var registeredNames: [String] = []
    @Published var enrollmentSavedName: String?
    @Published var trainingProgress: Double = 0
    @Published var trainingLabel: String = ""
    @Published var trainingCompleteName: String?
    @Published var trainingResultMessage: String?

    let session = AVCaptureSession()

    private let processingQueue = DispatchQueue(label: "com.lahacks26.processing.queue")
    private let ciContext = CIContext()
    private let inputSize = CGSize(width: 112, height: 112)
    private let frameSkipStride = 4
    private let faceMatchThreshold: Float = 0.65
    private let faceMatchMargin: Float = 0.08
    private let detectionPadding: CGFloat = 0.10
    private let trainingTargetSamples = 20
    private let minimumTrainingEmbeddings = 3
    private let melangePersonalKey = "dev_fdc9e57ff6d34bc6a590307ae5b0b101"
    private let melangeRecognitionModelName = "arjun/LAHACKS_FacialRecognition"
    private let melangeRecognitionModelVersion = 2
    private var configured = false
    private var frameCounter = 0
    private var isProcessingFrame = false
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let faceStore = FaceEmbeddingStore()
    private var trustedFaces: [String: [Float]] = [:]
    private var pendingEnrollmentName: String?
    private var trainingSnapshots: [TrainingSnapshot] = []

#if canImport(ZeticMLange) && !targetEnvironment(simulator)
    private var faceModel: ZeticMLangeModel?
#endif

    override init() {
        super.init()
        loadRegisteredFaces()
        prepareModel()
    }

    func start() async {
        guard await requestCameraAccess() else {
            await MainActor.run {
                self.statusMessage = "Camera permission is required."
            }
            return
        }

        configureSessionIfNeeded()

        if !session.isRunning {
            session.startRunning()
        }

        await MainActor.run {
            self.isRunning = self.session.isRunning
            self.statusMessage = self.modelReady
                ? "Camera running. Vision detection + Melange recognition ready."
                : "Camera running. Melange model loading..."
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        isRunning = false
    }

    func enrollCurrentFace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            guard !trimmed.isEmpty else {
                self.statusMessage = "Enter a name first."
                return
            }

            self.trainingCompleteName = nil
            self.trainingResultMessage = nil
            self.pendingEnrollmentName = trimmed
            self.trainingSnapshots.removeAll()
            self.trainingProgress = 0
            self.trainingLabel = "Training \(trimmed)"
            self.statusMessage = "Capturing 20 images for \(trimmed)..."
        }
    }

    func startTraining(named name: String) {
        enrollCurrentFace(named: name)
    }

    func cancelTraining() {
        DispatchQueue.main.async {
            self.pendingEnrollmentName = nil
            self.trainingSnapshots.removeAll()
            self.trainingProgress = 0
            self.trainingLabel = ""
            self.trainingCompleteName = nil
            self.trainingResultMessage = nil
            self.statusMessage = "Training cancelled."
        }
    }

    func enrollFace(name: String, croppedFace: CGImage) throws {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        guard let faceModel else {
            throw NSError(
                domain: "FaceRecognitionPipeline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Face model is not loaded."]
            )
        }

        let normalizedFloats = croppedFace.toNormalizedFloatArray()
        let tensors = recognitionTensors(from: croppedFace)
        guard !normalizedFloats.isEmpty, !tensors.isEmpty else {
            throw NSError(
                domain: "FaceRecognitionPipeline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No embedding output was produced."]
            )
        }

        guard let embedding = try runEmbeddingModel(with: tensors) else {
            throw NSError(
                domain: "FaceRecognitionPipeline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No embedding output was produced."]
            )
        }

        trustedFaces[name] = embedding
        try faceStore.save(embedding: embedding, for: name)
        loadRegisteredFaces()
#else
        _ = name
        _ = croppedFace
        throw NSError(
            domain: "FaceRecognitionPipeline",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Enrollment is only available on a physical iPhone build."]
        )
#endif
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if #available(iOS 17.0, *) {
            layer.connection?.videoRotationAngle = 90
        } else {
            layer.connection?.videoOrientation = .portrait
        }
        if layer.connection?.isVideoMirroringSupported == true {
            layer.connection?.automaticallyAdjustsVideoMirroring = false
            layer.connection?.isVideoMirrored = true
        }
    }

    func overlayRect(for boundingBox: CGRect) -> CGRect {
        guard let previewLayer else { return .zero }
        return previewLayer.layerRectConverted(fromMetadataOutputRect: boundingBox.metadataOutputRect)
    }

    private func loadRegisteredFaces() {
        let loaded = faceStore.load()
        trustedFaces = Dictionary(uniqueKeysWithValues: loaded.map { ($0.name, $0.embedding) })
        DispatchQueue.main.async {
            self.registeredNames = Array(self.trustedFaces.keys).sorted()
        }
    }

    private func prepareModel() {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        do {
            faceModel = try ZeticMLangeModel(
                personalKey: melangePersonalKey,
                name: melangeRecognitionModelName,
                version: melangeRecognitionModelVersion,
                modelMode: .RUN_AUTO,
                onDownload: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.statusMessage = "Downloading Melange model \(Int(Double(progress) * 100))%"
                    }
                }
            )
            modelReady = true
            statusMessage = "Loaded Melange recognition: \(melangeRecognitionModelName) v\(melangeRecognitionModelVersion)"
        } catch {
            modelReady = false
            statusMessage = "Melange load failed: \(error.localizedDescription)"
        }
#else
        modelReady = false
        statusMessage = "Melange recognition runs on a physical iPhone build."
#endif
    }

    private func configureSessionIfNeeded() {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
            configured = true
        }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            statusMessage = "No front camera found."
            return
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        guard session.canAddOutput(output) else {
            statusMessage = "Could not attach camera output."
            return
        }

        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: processingQueue)

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 90
            } else {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func analyze(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        autoreleasepool {
            do {
                let detections = try detectFaces(in: pixelBuffer)
                let recognition = try recognizeFaces(from: pixelBuffer, detections: detections)

                DispatchQueue.main.async {
                    self.faces = recognition
                    self.detectorReady = true
                    self.modelReady = self.faceModel != nil || self.modelReady
                    if recognition.isEmpty {
                        self.statusMessage = "No faces detected."
                    } else {
                        let names = recognition.map(\.label).joined(separator: ", ")
                        self.statusMessage = "Detected \(recognition.count) face(s): \(names)"
                    }
                }

                if let pendingName = pendingEnrollmentName {
                    if let snapshot = fullFrameImage(from: pixelBuffer) {
                        let faceBoundingBox = largestFace(in: detections)?.boundingBox
                        handleTrainingSnapshot(
                            TrainingSnapshot(image: snapshot, faceBoundingBox: faceBoundingBox),
                            name: pendingName
                        )
                    } else {
                        DispatchQueue.main.async { self.statusMessage = "Training capturing image..." }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Pipeline error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func detectFaces(in pixelBuffer: CVPixelBuffer) throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )
        try handler.perform([request])
        return request.results ?? []
    }

    private func detectFaces(in cgImage: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])
        return request.results ?? []
    }

    private func largestFace(in detections: [VNFaceObservation]) -> VNFaceObservation? {
        detections.max {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }
    }

    private func recognizeFaces(from pixelBuffer: CVPixelBuffer, detections: [VNFaceObservation]) throws -> [FaceTrack] {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        guard let faceModel else {
            return detections.map {
                FaceTrack(
                    boundingBox: $0.boundingBox,
                    confidence: Float($0.confidence),
                    identity: nil,
                    identityConfidence: nil,
                    bestCandidate: nil,
                    bestCandidateConfidence: nil,
                    embedding: nil
                )
            }
        }

        var results: [FaceTrack] = []

        for detection in detections {
            guard let embedding = try embedding(for: detection, pixelBuffer: pixelBuffer) else {
                continue
            }

            let candidate = bestCandidate(for: embedding)
            let match = candidate.flatMap { candidate in
                isAcceptedMatch(candidate) ? (name: candidate.name, confidence: candidate.confidence) : nil
            }
            results.append(
                FaceTrack(
                    boundingBox: detection.boundingBox,
                    confidence: Float(detection.confidence),
                    identity: match?.name,
                    identityConfidence: match?.confidence,
                    bestCandidate: match == nil ? candidate?.name : nil,
                    bestCandidateConfidence: match == nil ? candidate?.confidence : nil,
                    embedding: embedding
                )
            )
        }

        return results
#else
        return detections.map {
            FaceTrack(
                boundingBox: $0.boundingBox,
                confidence: Float($0.confidence),
                identity: nil,
                identityConfidence: nil,
                bestCandidate: nil,
                bestCandidateConfidence: nil,
                embedding: nil
            )
        }
#endif
    }

    private func embedding(for detection: VNFaceObservation, pixelBuffer: CVPixelBuffer) throws -> [Float]? {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        guard let faceModel else {
            return nil
        }

        guard let inputs = makeRecognitionInputs(from: pixelBuffer, detection: detection) else {
            return nil
        }

        return try runEmbeddingModel(with: inputs)
#else
        _ = detection
        _ = pixelBuffer
        return nil
#endif
    }

    private func handleTrainingSnapshot(_ snapshot: TrainingSnapshot, name: String) {
        trainingSnapshots.append(snapshot)
        let count = trainingSnapshots.count
        let faceBoxCount = trainingSnapshots.filter { $0.faceBoundingBox != nil }.count
        let progress = Double(count) / Double(trainingTargetSamples)
        let label = "Training \(name) \(count)/\(trainingTargetSamples)"

        DispatchQueue.main.async {
            self.trainingProgress = progress
            self.trainingLabel = label
            if count < self.trainingTargetSamples {
                self.statusMessage = "Capturing images for \(name)... face boxes \(faceBoxCount)/\(count)"
            }
        }

        guard count >= trainingTargetSamples else {
            return
        }

        let snapshots = trainingSnapshots
        trainingSnapshots.removeAll()
        pendingEnrollmentName = nil

        DispatchQueue.main.async {
            self.statusMessage = "Captured \(self.trainingTargetSamples) images. Creating embeddings..."
        }

        let embeddings = snapshots.compactMap { embeddingFromTrainingSnapshot($0) }
        guard embeddings.count >= minimumTrainingEmbeddings else {
            let boxed = snapshots.filter { $0.faceBoundingBox != nil }.count
            let message = "Training failed: \(boxed)/\(snapshots.count) face boxes, \(embeddings.count) usable embeddings."
            DispatchQueue.main.async {
                self.trainingLabel = "Ready"
                self.trainingProgress = 0
                self.trainingResultMessage = message
                self.statusMessage = message
            }
            return
        }

        let averaged = averageEmbeddings(embeddings)
        do {
            try faceStore.save(embedding: averaged, for: name)
            trustedFaces[name] = averaged
            loadRegisteredFaces()
            let boxed = snapshots.filter { $0.faceBoundingBox != nil }.count
            let message = "Saved \(name) from \(embeddings.count)/\(snapshots.count) embeddings, \(boxed) face boxes."
            DispatchQueue.main.async {
                self.enrollmentSavedName = name
                self.trainingCompleteName = name
                self.trainingProgress = 1
                self.trainingLabel = "Complete"
                self.trainingResultMessage = message
                self.statusMessage = message
            }
        } catch {
            let message = "Training save failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.trainingResultMessage = message
                self.statusMessage = message
            }
        }
    }

    private func embeddingFromTrainingSnapshot(_ snapshot: TrainingSnapshot) -> [Float]? {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        if let faceBoundingBox = snapshot.faceBoundingBox,
           let inputs = makeRecognitionInputs(from: snapshot.image, boundingBox: faceBoundingBox) {
            return try? runEmbeddingModel(with: inputs)
        }

        if let detection = largestFace(in: ((try? detectFaces(in: snapshot.image)) ?? [])),
           let inputs = makeRecognitionInputs(from: snapshot.image, boundingBox: detection.boundingBox) {
            return try? runEmbeddingModel(with: inputs)
        }

        return nil
#else
        _ = snapshot
        return nil
#endif
    }

    private func makeRecognitionInputs(from pixelBuffer: CVPixelBuffer, detection: VNFaceObservation) -> [Tensor]? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        let orientedExtent = oriented.extent

        let candidates: [CGRect] = [
            cropRect(for: detection.boundingBox, in: orientedExtent, insetFactor: 0.10),
            cropRect(for: detection.boundingBox, in: orientedExtent, insetFactor: 0.20),
            cropRect(for: detection.boundingBox, in: orientedExtent, insetFactor: 0.30)
        ]

        for candidate in candidates {
            let crop = oriented.cropped(to: candidate.integral)
            if let cgImage = ciContext.createCGImage(crop, from: crop.extent) {
                let tensors = recognitionTensors(from: cgImage)
                if !tensors.isEmpty {
                    return tensors
                }
            }
        }
        return nil
    }

    private func makeRecognitionInputs(from cgImage: CGImage, detection: VNFaceObservation) -> [Tensor]? {
        makeRecognitionInputs(from: cgImage, boundingBox: detection.boundingBox)
    }

    private func makeRecognitionInputs(from cgImage: CGImage, boundingBox: CGRect) -> [Tensor]? {
        let image = CIImage(cgImage: cgImage)
        let candidates: [CGRect] = [
            cropRect(for: boundingBox, in: image.extent, insetFactor: 0.10),
            cropRect(for: boundingBox, in: image.extent, insetFactor: 0.20),
            cropRect(for: boundingBox, in: image.extent, insetFactor: 0.30)
        ]

        for candidate in candidates {
            let crop = image.cropped(to: candidate.integral)
            if let croppedImage = ciContext.createCGImage(crop, from: crop.extent) {
                let tensors = recognitionTensors(from: croppedImage)
                if !tensors.isEmpty {
                    return tensors
                }
            }
        }

        return nil
    }

    private func recognitionTensors(from cgImage: CGImage) -> [Tensor] {
        let layouts: [(RecognitionTensorLayout, [Float])] = [
            (.rgbHwc, renderAndNormalize(cgImage: cgImage, channelOrder: .rgb, packing: .hwc)),
            (.bgrHwc, renderAndNormalize(cgImage: cgImage, channelOrder: .bgr, packing: .hwc)),
            (.rgbChw, renderAndNormalize(cgImage: cgImage, channelOrder: .rgb, packing: .chw)),
            (.bgrChw, renderAndNormalize(cgImage: cgImage, channelOrder: .bgr, packing: .chw))
        ]

        return layouts.compactMap { entry in
            let (layout, floats) = entry
            guard !floats.isEmpty else { return nil }
            return try? tensor(from: floats, layout: layout)
        }
    }

    private func renderAndNormalize(
        cgImage: CGImage,
        channelOrder: ChannelOrder,
        packing: TensorPacking
    ) -> [Float] {
        let width = Int(inputSize.width)
        let height = Int(inputSize.height)
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
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
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
            shape = [1, Int(inputSize.height), Int(inputSize.width), 3]
        case .rgbChw, .bgrChw:
            shape = [1, 3, Int(inputSize.height), Int(inputSize.width)]
        }
        return Tensor(
            data: data,
            dataType: BuiltinDataType.float32,
            shape: shape
        )
    }

    private func runEmbeddingModel(with inputs: [Tensor]) throws -> [Float]? {
#if canImport(ZeticMLange) && !targetEnvironment(simulator)
        guard let faceModel else { return nil }

        for tensor in inputs {
            do {
                let outputs = try faceModel.run(inputs: [tensor])
                if let firstOutput = outputs.first {
                    let embedding = DataUtils.dataToFloatArray(firstOutput.data)
                    if !embedding.isEmpty {
                        return embedding
                    }
                }
            } catch {
                continue
            }
        }

        return nil
#else
        _ = inputs
        return nil
#endif
    }

    private func fullFrameImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        return ciContext.createCGImage(oriented, from: oriented.extent)
    }

    private func bestCandidate(for embedding: [Float]) -> (name: String, confidence: Float, margin: Float?)? {
        guard !trustedFaces.isEmpty else {
            return nil
        }

        var bestName: String?
        var bestScore: Float = -Float.greatestFiniteMagnitude
        var secondBestScore: Float = -Float.greatestFiniteMagnitude

        for (name, storedEmbedding) in trustedFaces {
            let score = cosineSimilarity(embedding, storedEmbedding)
            if score > bestScore {
                secondBestScore = bestScore
                bestScore = score
                bestName = name
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        guard let bestName else {
            return nil
        }

        let margin = secondBestScore == -Float.greatestFiniteMagnitude ? nil : bestScore - secondBestScore
        return (bestName, bestScore, margin)
    }

    private func isAcceptedMatch(_ candidate: (name: String, confidence: Float, margin: Float?)) -> Bool {
        guard candidate.confidence >= faceMatchThreshold else {
            return false
        }

        if let margin = candidate.margin {
            return margin >= faceMatchMargin
        }

        return true
    }

    private func weightedAverage(old: [Float], live: [Float]) -> [Float] {
        let count = min(old.count, live.count)
        guard count > 0 else { return old }

        var oldScaled = [Float](repeating: 0, count: count)
        var liveScaled = [Float](repeating: 0, count: count)
        var blended = [Float](repeating: 0, count: count)

        old.withUnsafeBufferPointer { oldPtr in
            live.withUnsafeBufferPointer { livePtr in
                oldScaled.withUnsafeMutableBufferPointer { oldScaledPtr in
                    liveScaled.withUnsafeMutableBufferPointer { liveScaledPtr in
                        blended.withUnsafeMutableBufferPointer { blendedPtr in
                            let oldWeight: Float = 0.9
                            let liveWeight: Float = 0.1
                            withUnsafePointer(to: oldWeight) { oldWeightPtr in
                                vDSP_vsmul(oldPtr.baseAddress!, 1, oldWeightPtr, oldScaledPtr.baseAddress!, 1, vDSP_Length(count))
                            }
                            withUnsafePointer(to: liveWeight) { liveWeightPtr in
                                vDSP_vsmul(livePtr.baseAddress!, 1, liveWeightPtr, liveScaledPtr.baseAddress!, 1, vDSP_Length(count))
                            }
                            vDSP_vadd(oldScaledPtr.baseAddress!, 1, liveScaledPtr.baseAddress!, 1, blendedPtr.baseAddress!, 1, vDSP_Length(count))
                        }
                    }
                }
            }
        }

        return normalizedEmbedding(blended)
    }

    private func averageEmbeddings(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first, !first.isEmpty else { return [] }
        let count = first.count
        var sum = [Float](repeating: 0, count: count)

        for embedding in embeddings {
            let length = min(count, embedding.count)
            for index in 0..<length {
                sum[index] += embedding[index]
            }
        }

        let scale = 1.0 / Float(max(embeddings.count, 1))
        return normalizedEmbedding(sum.map { $0 * scale })
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }

        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0

        for index in 0..<count {
            let l = lhs[index]
            let r = rhs[index]
            dot += l * r
            lhsNorm += l * l
            rhsNorm += r * r
        }

        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private func normalizedEmbedding(_ embedding: [Float]) -> [Float] {
        let norm = sqrt(embedding.reduce(0) { $0 + ($1 * $1) })
        guard norm > 0 else { return embedding }
        return embedding.map { $0 / norm }
    }

    private func cropRect(for boundingBox: CGRect, in extent: CGRect, insetFactor: CGFloat) -> CGRect {
        let width = extent.width
        let height = extent.height

        let rect = CGRect(
            x: extent.minX + boundingBox.origin.x * width,
            y: extent.minY + boundingBox.origin.y * height,
            width: boundingBox.width * width,
            height: boundingBox.height * height
        )

        let side = max(rect.width, rect.height) * (1 + insetFactor * 2)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        return square.clamped(to: extent)
    }

    private func rectForVisionBoundingBox(_ bbox: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(
            x: bbox.origin.x * CGFloat(imageWidth),
            y: (1 - bbox.origin.y - bbox.height) * CGFloat(imageHeight),
            width: bbox.width * CGFloat(imageWidth),
            height: bbox.height * CGFloat(imageHeight)
        )
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
}

private final class FaceEmbeddingStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.lahacks26.face-store")

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = baseURL
            .appendingPathComponent("LAHACKS26", isDirectory: true)
            .appendingPathComponent("face_embeddings.json")
    }

    func load() -> [RegisteredFaceRecord] {
        queue.sync { loadLocked() }
    }

    func save(embedding: [Float], for name: String) throws {
        try queue.sync {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw NSError(
                    domain: "FaceEmbeddingStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."]
                )
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var records = loadLocked()
            let newEmbedding = normalizedEmbedding(embedding)

            if let index = records.firstIndex(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
                records[index] = RegisteredFaceRecord(name: normalizedName, embedding: newEmbedding)
            } else {
                records.append(RegisteredFaceRecord(name: normalizedName, embedding: newEmbedding))
            }

            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    private func loadLocked() -> [RegisteredFaceRecord] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([RegisteredFaceRecord].self, from: data)) ?? []
    }

    private func normalizedEmbedding(_ embedding: [Float]) -> [Float] {
        let norm = sqrt(embedding.reduce(0) { $0 + ($1 * $1) })
        guard norm > 0 else { return embedding }
        return embedding.map { $0 / norm }
    }

    private func average(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return lhs }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            result[index] = (lhs[index] + rhs[index]) / 2
        }
        return normalizedEmbedding(result)
    }
}

private extension CGImage {
    func toNormalizedFloatArray(size: CGSize = CGSize(width: 112, height: 112)) -> [Float] {
        let width = Int(size.width)
        let height = Int(size.height)
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
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            return []
        }

        var floats: [Float] = []
        floats.reserveCapacity(width * height * 3)

        for index in 0..<(width * height) {
            let base = index * bytesPerPixel
            let r = Float(pixels[base])
            let g = Float(pixels[base + 1])
            let b = Float(pixels[base + 2])
            floats.append((r - 127.5) / 128.0)
            floats.append((g - 127.5) / 128.0)
            floats.append((b - 127.5) / 128.0)
        }

        return floats
    }
}

extension FaceRecognitionPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCounter += 1
        guard frameCounter % frameSkipStride == 0 else { return }
        guard !isProcessingFrame else { return }

        isProcessingFrame = true
        defer { isProcessingFrame = false }
        analyze(sampleBuffer: sampleBuffer)
    }
}

private extension CGRect {
    var metadataOutputRect: CGRect {
        CGRect(x: origin.x, y: 1 - origin.y - height, width: width, height: height)
    }

    func clamped(to bounds: CGRect) -> CGRect {
        let x1 = max(bounds.minX, min(minX, bounds.maxX))
        let y1 = max(bounds.minY, min(minY, bounds.maxY))
        let x2 = max(x1 + 1, min(maxX, bounds.maxX))
        let y2 = max(y1 + 1, min(maxY, bounds.maxY))
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
