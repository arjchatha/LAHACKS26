//
//  ProfileEnrollmentView.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ProfileEnrollmentView: View {
    @ObservedObject var memoryBridge: MockMemoryBridge

    @State private var name = ""
    @State private var isShowingVideoRecorder = false
    @State private var isProcessingEnrollment = false
    @State private var statusMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                }

                Section {
                    Button {
                        startRecording()
                    } label: {
                        Label("Record Video", systemImage: "video.badge.plus")
                    }
                    .disabled(isProcessingEnrollment)

                    if isProcessingEnrollment {
                        ProgressView("Building face profile")
                    }

                    if !VideoRecorderPicker.isVideoCameraAvailable {
                        Text("Video recording needs a physical iPhone camera.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !memoryBridge.enrolledVideoProfiles.isEmpty {
                    Section("Saved") {
                        ForEach(memoryBridge.enrolledVideoProfiles) { storedProfile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(storedProfile.profile.name)
                                    .font(.headline)
                                if !storedProfile.profile.relationship.isEmpty {
                                    Text(storedProfile.profile.relationship)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text(storedProfile.videoURL.lastPathComponent)
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
        .sheet(isPresented: $isShowingVideoRecorder) {
            VideoRecorderPicker { videoURL in
                saveRecordedVideo(videoURL)
            }
            .ignoresSafeArea()
        }
    }

    private func startRecording() {
        guard !isProcessingEnrollment else { return }

        guard !trimmedName.isEmpty else {
            statusMessage = "Add the person's name before recording."
            return
        }

        guard VideoRecorderPicker.isVideoCameraAvailable else {
            statusMessage = "Video recording is not available here. Run the app on a physical iPhone."
            return
        }

        statusMessage = nil
        isShowingVideoRecorder = true
    }

    private func saveRecordedVideo(_ videoURL: URL) {
        isProcessingEnrollment = true
        statusMessage = "Building face profile from the recording."

        Task {
            await Task.yield()

            do {
                let profile = try memoryBridge.enrollPersonFromVideo(
                    name: name,
                    relationship: "",
                    memoryCue: "",
                    detailLines: [],
                    sourceVideoURL: videoURL
                )

                statusMessage = "\(profile.name) is ready for Live mode."
                name = ""
            } catch {
                statusMessage = error.localizedDescription
            }

            isProcessingEnrollment = false
        }
    }

    private func deleteProfile(_ storedProfile: StoredPersonVideoProfile) {
        memoryBridge.deleteVideoProfile(personId: storedProfile.profile.personId)
        statusMessage = "\(storedProfile.profile.name) was deleted."
    }
}

struct VideoRecorderPicker: UIViewControllerRepresentable {
    let onVideoRecorded: (URL) -> Void

    static var isVideoCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoMaximumDuration = 12
        picker.videoQuality = .typeMedium
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onVideoRecorded: onVideoRecorded)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onVideoRecorded: (URL) -> Void

        init(onVideoRecorded: @escaping (URL) -> Void) {
            self.onVideoRecorded = onVideoRecorded
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let mediaURL = info[.mediaURL] as? URL {
                onVideoRecorded(mediaURL)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
