//
//  RecordingManager.swift
//  test02
//

import Combine
import ReplayKit
import SwiftUI

@MainActor
final class RecordingManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var preview: PreviewBundle?
    @Published var errorMessage: String?

    private let recorder = RPScreenRecorder.shared()

    struct PreviewBundle: Identifiable {
        let id = UUID()
        let controller: RPPreviewViewController
    }

    var isAvailable: Bool { recorder.isAvailable }

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard recorder.isAvailable, !recorder.isRecording else { return }
        errorMessage = nil
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.isRecording = false
                } else {
                    self.isRecording = true
                }
            }
        }
    }

    func stop() {
        recorder.stopRecording { [weak self] previewController, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                if let previewController {
                    self.preview = PreviewBundle(controller: previewController)
                }
            }
        }
    }
}

struct PreviewControllerView: UIViewControllerRepresentable {
    let controller: RPPreviewViewController
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        controller.previewControllerDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}

    final class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
            previewController.dismiss(animated: true) { [onFinish] in
                onFinish()
            }
        }
    }
}
