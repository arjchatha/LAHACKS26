//
//  ProfileEnrollmentView.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import AVFoundation
import CoreImage
import PhotosUI
import QuartzCore
import SwiftUI
import UIKit

struct ProfileEnrollmentView: View {
    private enum Constants {
        static let requiredPhotoCount = 20
        static let thumbnailSize: CGFloat = 72
    }

    @ObservedObject var memoryBridge: MockMemoryBridge

    @State private var name = ""
    @State private var selectedImages: [UIImage] = []
    @State private var isShowingCamera = false
    @State private var isShowingPhotoLibrary = false
    @State private var isProcessingEnrollment = false
    @State private var statusMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remainingPhotoCount: Int {
        max(0, Constants.requiredPhotoCount - selectedImages.count)
    }

    private var hasRequiredPhotos: Bool {
        selectedImages.count == Constants.requiredPhotoCount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                }

                Section("Photos") {
                    Button {
                        startCameraCapture()
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .disabled(isProcessingEnrollment || remainingPhotoCount == 0)

                    Button {
                        startPhotoLibrary()
                    } label: {
                        Label("Add From Library", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(isProcessingEnrollment || remainingPhotoCount == 0)

                    Button {
                        saveSelectedPhotos()
                    } label: {
                        Label("Build Face Profile", systemImage: "person.crop.rectangle.stack.badge.plus")
                    }
                    .disabled(isProcessingEnrollment || trimmedName.isEmpty || !hasRequiredPhotos)

                    if !selectedImages.isEmpty {
                        Button(role: .destructive) {
                            clearSelectedPhotos()
                        } label: {
                            Label("Clear Photos", systemImage: "trash")
                        }
                        .disabled(isProcessingEnrollment)
                    }

                    if isProcessingEnrollment {
                        ProgressView("Building face profile")
                    }

                    if !PhotoCameraPicker.isCameraAvailable {
                        Text("Photo capture needs a physical iPhone camera.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !PhotoLibraryPicker.isPhotoLibraryAvailable {
                        Text("Photo library access is not available here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if selectedImages.isEmpty {
                        Text("Take 20 clear photos with one face centered in frame.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(progressText)
                            .font(.footnote.weight(.semibold))
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: Constants.thumbnailSize, height: Constants.thumbnailSize)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !memoryBridge.enrolledPhotoProfiles.isEmpty {
                    Section("Saved") {
                        ForEach(memoryBridge.enrolledPhotoProfiles) { storedProfile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(storedProfile.profile.name)
                                    .font(.headline)
                                if !storedProfile.profile.relationship.isEmpty {
                                    Text(storedProfile.profile.relationship)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text(savedProfileSummary(storedProfile))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteProfile(storedProfile)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Profiles")
        }
        .sheet(isPresented: $isShowingCamera) {
            PhotoCameraPicker(
                photoCount: remainingPhotoCount,
                captureInterval: 0.1,
                onPhotosCaptured: { images in
                    appendSelectedImages(images, sourceDescription: "camera")
                    isShowingCamera = false
                },
                onCancelled: {
                    isShowingCamera = false
                },
                onFailure: { message in
                    statusMessage = message
                    isShowingCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingPhotoLibrary) {
            PhotoLibraryPicker { images in
                guard !images.isEmpty else { return }
                appendSelectedImages(images, sourceDescription: "library")
            }
            .ignoresSafeArea()
        }
    }

    private func startCameraCapture() {
        guard !isProcessingEnrollment else { return }

        guard PhotoCameraPicker.isCameraAvailable else {
            statusMessage = "Photo capture is not available here. Run the app on a physical iPhone."
            return
        }

        statusMessage = "Opening back camera..."
        isShowingCamera = true
    }

    private func startPhotoLibrary() {
        guard !isProcessingEnrollment else { return }

        guard PhotoLibraryPicker.isPhotoLibraryAvailable else {
            statusMessage = "Photo library access is not available here."
            return
        }

        statusMessage = "Opening photo library..."
        isShowingPhotoLibrary = true
    }

    private func saveSelectedPhotos() {
        guard hasRequiredPhotos else {
            statusMessage = "Capture all \(Constants.requiredPhotoCount) photos before building the face profile."
            return
        }

        isProcessingEnrollment = true
        statusMessage = "Building face profile."

        Task {
            await Task.yield()

            do {
                let profile = try memoryBridge.enrollPersonFromPhotos(
                    name: name,
                    relationship: "",
                    memoryCue: "",
                    detailLines: [],
                    sourceImages: selectedImages
                )

                statusMessage = "\(profile.name) is ready for Live mode."
                name = ""
                selectedImages = []
            } catch {
                statusMessage = error.localizedDescription
            }

            isProcessingEnrollment = false
        }
    }

    private func deleteProfile(_ storedProfile: StoredPersonPhotoProfile) {
        memoryBridge.deletePhotoProfile(personId: storedProfile.profile.personId)
        statusMessage = "\(storedProfile.profile.name) was deleted."
    }

    private func appendSelectedImages(_ images: [UIImage], sourceDescription: String) {
        let remainingSlots = remainingPhotoCount

        guard remainingSlots > 0 else {
            statusMessage = "All \(Constants.requiredPhotoCount) photos are already captured."
            return
        }

        let acceptedImages = Array(images.prefix(remainingSlots))
        selectedImages.append(contentsOf: acceptedImages)

        if acceptedImages.count < images.count {
            statusMessage = "Kept the first \(Constants.requiredPhotoCount) photos from the \(sourceDescription) selection."
        } else if remainingSlots == acceptedImages.count {
            statusMessage = "All \(Constants.requiredPhotoCount) photos are ready. Build the face profile when you’re set."
        } else {
            statusMessage = "\(progressText)."
        }
    }

    private func clearSelectedPhotos() {
        selectedImages = []
        statusMessage = "Cleared the photo set. Capture \(Constants.requiredPhotoCount) new photos."
    }

    private var progressText: String {
        "\(selectedImages.count)/\(Constants.requiredPhotoCount) photos ready"
    }

    private func savedProfileSummary(_ storedProfile: StoredPersonPhotoProfile) -> String {
        "\(storedProfile.photoURLs.count) photo(s)"
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    private enum Constants {
        static let maximumSelectionCount = 20
    }

    let onPhotosSelected: ([UIImage]) -> Void

    static var isPhotoLibraryAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.photoLibrary)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = Constants.maximumSelectionCount

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPhotosSelected: onPhotosSelected)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPhotosSelected: ([UIImage]) -> Void

        init(onPhotosSelected: @escaping ([UIImage]) -> Void) {
            self.onPhotosSelected = onPhotosSelected
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onPhotosSelected([])
                return
            }

            Task {
                var images: [UIImage] = []

                for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    if let image = try? await result.itemProvider.loadUIImage() {
                        images.append(image)
                    }
                }

                await MainActor.run {
                    onPhotosSelected(images)
                }
            }
        }
    }
}

struct PhotoCameraPicker: UIViewControllerRepresentable {
    let photoCount: Int
    let captureInterval: TimeInterval
    let onPhotosCaptured: ([UIImage]) -> Void
    let onCancelled: () -> Void
    let onFailure: (String) -> Void

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> AutoPhotoCaptureViewController {
        AutoPhotoCaptureViewController(
            photoCount: photoCount,
            captureInterval: captureInterval,
            onPhotosCaptured: onPhotosCaptured,
            onCancelled: onCancelled,
            onFailure: onFailure
        )
    }

    func updateUIViewController(_ uiViewController: AutoPhotoCaptureViewController, context: Context) {}
}

private extension NSItemProvider {
    func loadUIImage() async throws -> UIImage? {
        try await withCheckedThrowingContinuation { continuation in
            loadObject(ofClass: UIImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}

final class AutoPhotoCaptureViewController: UIViewController {
    private enum Constants {
        static let warmupDuration: CFTimeInterval = 1.5
        static let startupFramesToSkip = 6
    }

    private let photoCount: Int
    private let captureInterval: TimeInterval
    private let onPhotosCaptured: ([UIImage]) -> Void
    private let onCancelled: () -> Void
    private let onFailure: (String) -> Void

    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.lahacks26.enrollment.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.lahacks26.enrollment.camera.frames", qos: .userInitiated)
    private let ciContext = CIContext()
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    private var capturedImages: [UIImage] = []
    private var lastCaptureTime: CFTimeInterval?
    private var captureStartTime: CFTimeInterval?
    private var skippedStartupFrameCount = 0
    private var didStartBurst = false
    private var didFinishCapture = false
    private var isSessionConfigured = false

    init(
        photoCount: Int,
        captureInterval: TimeInterval,
        onPhotosCaptured: @escaping ([UIImage]) -> Void,
        onCancelled: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.photoCount = photoCount
        self.captureInterval = captureInterval
        self.onPhotosCaptured = onPhotosCaptured
        self.onCancelled = onCancelled
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configurePreview()
        configureOverlay()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCaptureIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configurePreview() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    private func configureOverlay() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.text = "Preparing camera..."
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statusLabel.layer.cornerRadius = 16
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 0

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.tintColor = .white
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelButton.layer.cornerRadius = 16
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        cancelButton.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)

        view.addSubview(statusLabel)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    private func startCaptureIfNeeded() {
        guard !didStartBurst, !didFinishCapture else { return }

        Task { [weak self] in
            guard let self else { return }

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                do {
                    try await configureAndStartSession()
                    await MainActor.run {
                        self.captureStartTime = CACurrentMediaTime() + Constants.warmupDuration
                        self.statusLabel.text = "Stabilizing exposure..."
                    }
                } catch {
                    await MainActor.run {
                        self.finishWithFailure(error.localizedDescription)
                    }
                }

            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard granted else {
                    await MainActor.run {
                        self.finishWithFailure("Camera access is required to capture the training photos.")
                    }
                    return
                }

                do {
                    try await configureAndStartSession()
                    await MainActor.run {
                        self.captureStartTime = CACurrentMediaTime() + Constants.warmupDuration
                        self.statusLabel.text = "Stabilizing exposure..."
                    }
                } catch {
                    await MainActor.run {
                        self.finishWithFailure(error.localizedDescription)
                    }
                }

            case .denied, .restricted:
                await MainActor.run {
                    self.finishWithFailure("Camera access is off. Enable it in Settings to capture training photos.")
                }

            @unknown default:
                await MainActor.run {
                    self.finishWithFailure("This device does not support camera capture.")
                }
            }
        }
    }

    private func configureAndStartSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }

                do {
                    try self.configureSessionIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSessionIfNeeded() throws {
        guard !isSessionConfigured else { return }

        guard
            let camera = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .back
            ).devices.first
        else {
            throw AutoPhotoCaptureError.noCamera
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        defer {
            session.commitConfiguration()
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw AutoPhotoCaptureError.cannotAddInput
        }
        session.addInput(input)

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        camera.isSubjectAreaChangeMonitoringEnabled = true

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            throw AutoPhotoCaptureError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                let portraitRotationAngle: CGFloat = 90
                if connection.isVideoRotationAngleSupported(portraitRotationAngle) {
                    connection.videoRotationAngle = portraitRotationAngle
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }

            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        isSessionConfigured = true
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    @objc
    private func cancelCapture() {
        guard !didFinishCapture else { return }
        didFinishCapture = true
        stopSession()
        onCancelled()
    }

    private func finishWithFailure(_ message: String) {
        guard !didFinishCapture else { return }
        didFinishCapture = true
        stopSession()
        onFailure(message)
    }

    private func finishWithImages(_ images: [UIImage]) {
        guard !didFinishCapture else { return }
        didFinishCapture = true
        stopSession()
        onPhotosCaptured(images)
    }
}

extension AutoPhotoCaptureViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !didFinishCapture else { return }
        let now = CACurrentMediaTime()

        if let captureStartTime, now < captureStartTime {
            return
        }

        if skippedStartupFrameCount < Constants.startupFramesToSkip {
            skippedStartupFrameCount += 1
            Task { @MainActor [weak self] in
                self?.statusLabel.text = "Stabilizing exposure..."
            }
            return
        }

        if let lastCaptureTime, now - lastCaptureTime < captureInterval {
            return
        }

        guard let image = makeUIImage(from: sampleBuffer) else {
            return
        }

        lastCaptureTime = now
        didStartBurst = true
        capturedImages.append(image)

        let currentCount = capturedImages.count
        Task { @MainActor [weak self] in
            self?.statusLabel.text = "Capturing \(currentCount)/\(self?.photoCount ?? currentCount)"
        }

        if currentCount >= photoCount {
            let images = capturedImages
            Task { @MainActor [weak self] in
                self?.finishWithImages(images)
            }
        }
    }

    private func makeUIImage(from sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private enum AutoPhotoCaptureError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            #if targetEnvironment(simulator)
            "The iPhone Simulator is not exposing a back camera. Run on a physical iPhone for automatic capture."
            #else
            "The back camera is not available on this device."
            #endif
        case .cannotAddInput:
            "The app could not connect to the back camera."
        case .cannotAddOutput:
            "The app could not read camera frames for automatic capture."
        }
    }
}
