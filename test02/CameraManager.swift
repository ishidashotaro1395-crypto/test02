//
//  CameraManager.swift
//  test02
//

@preconcurrency import AVFoundation
import Combine
import CoreImage
import SwiftUI
import UIKit
import Vision

enum ObjectKind: String, CaseIterable, Hashable {
    case poster
    case sign
    case vision
    case person
    case vehicle
    case unknown

    var label: String {
        switch self {
        case .poster:  return "POSTER"
        case .sign:    return "SIGN"
        case .vision:  return "VISION"
        case .person:  return "PERSON"
        case .vehicle: return "VEHICLE"
        case .unknown: return "UNKNOWN"
        }
    }
}

struct DetectedObject: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect
    let confidence: Float
    let kind: ObjectKind
}

struct CameraOption: Identifiable, Hashable {
    let id: String
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    let label: String
}

final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [DetectedObject] = []
    @Published var isAuthorized = false
    @Published var availableCameras: [CameraOption] = []
    @Published private(set) var currentCamera: CameraOption?

    let session = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let bufferQueue = DispatchQueue(label: "camera.buffer")
    private var isConfigured = false
    private nonisolated(unsafe) var lastProcessedTime: CFAbsoluteTime = 0
    private let minProcessInterval: CFAbsoluteTime = 1.0 / 20.0  // 20fps 検出
    private nonisolated(unsafe) var currentVisionOrientation: CGImagePropertyOrientation = .right

    private let imageLock = NSLock()
    private nonisolated(unsafe) var _latestImage: CIImage?

    func currentImage() -> CIImage? {
        imageLock.lock()
        defer { imageLock.unlock() }
        return _latestImage
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.ensureAuthorized()
            await MainActor.run { self.isAuthorized = granted }
            guard granted else { return }
            self.configureIfNeeded()
            self.sessionQueue.async { [session = self.session] in
                if !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func setOrientation(_ orientation: UIDeviceOrientation) {
        currentVisionOrientation = visionOrientation(for: orientation)
    }

    func switchCamera(to option: CameraOption) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            for input in self.session.inputs { self.session.removeInput(input) }
            guard let device = AVCaptureDevice.default(option.deviceType,
                                                        for: .video,
                                                        position: option.position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else { return }
            self.session.addInput(input)
            if let connection = self.videoOutput.connection(with: .video) {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            Task { @MainActor in self.currentCamera = option }
        }
    }

    private func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)

        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        let cameras = discoverCameras()
        let defaultOption = cameras.first(where: {
            $0.deviceType == .builtInWideAngleCamera && $0.position == .back
        }) ?? cameras.first

        if let option = defaultOption,
           let device = AVCaptureDevice.default(option.deviceType,
                                                 for: .video,
                                                 position: option.position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            if let connection = videoOutput.connection(with: .video) {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            Task { @MainActor in
                self.availableCameras = cameras
                self.currentCamera = option
            }
        }

        session.commitConfiguration()
    }

    private func discoverCameras() -> [CameraOption] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInTrueDepthCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.map { device in
            CameraOption(id: "\(device.deviceType.rawValue)|\(device.position.rawValue)",
                         deviceType: device.deviceType,
                         position: device.position,
                         label: cameraLabel(for: device))
        }
        .sorted { cameraOrder($0) < cameraOrder($1) }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let orientation = currentVisionOrientation
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        imageLock.lock()
        _latestImage = oriented
        imageLock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessedTime >= minProcessInterval else { return }
        lastProcessedTime = now

        // 矩形検出 — 感度向上
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.maximumObservations = 12
        rectRequest.minimumAspectRatio = 0.2    // 5:1 程度の横長も対象
        rectRequest.maximumAspectRatio = 1.0
        rectRequest.minimumSize = 0.04           // より小さいオブジェクトも
        rectRequest.minimumConfidence = 0.45     // 感度を上げる
        rectRequest.quadratureTolerance = 20     // 歪み許容を広げる

        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false

        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        try? handler.perform([rectRequest, humanRequest, saliencyRequest])

        var combined: [DetectedObject] = []

        if let results = rectRequest.results {
            for obs in results {
                let aspect = obs.boundingBox.width / max(obs.boundingBox.height, 0.001)
                let kind: ObjectKind
                if aspect >= 1.7     { kind = .vision }
                else if aspect <= 0.65 { kind = .poster }
                else                 { kind = .sign }
                combined.append(DetectedObject(boundingBox: obs.boundingBox,
                                               confidence: obs.confidence,
                                               kind: kind))
            }
        }
        if let results = humanRequest.results {
            for obs in results {
                combined.append(DetectedObject(boundingBox: obs.boundingBox,
                                               confidence: obs.confidence,
                                               kind: .person))
            }
        }
        if let results = saliencyRequest.results {
            for obs in results {
                guard let objects = obs.salientObjects else { continue }
                for s in objects {
                    let area = s.boundingBox.width * s.boundingBox.height
                    guard area >= 0.015 else { continue }  // より小さいオブジェクトも
                    let aspect = s.boundingBox.width / max(s.boundingBox.height, 0.001)
                    let kind: ObjectKind = aspect >= 1.4 ? .vehicle : .unknown
                    combined.append(DetectedObject(boundingBox: s.boundingBox,
                                                   confidence: s.confidence,
                                                   kind: kind))
                }
            }
        }

        let deduped = dedupeBoxes(combined, iouThreshold: 0.5)
        Task { @MainActor [weak self] in self?.detections = deduped }
    }
}

private func dedupeBoxes(_ items: [DetectedObject], iouThreshold: CGFloat) -> [DetectedObject] {
    var kept: [DetectedObject] = []
    for item in items.sorted(by: { $0.confidence > $1.confidence }) {
        if !kept.contains(where: { iouRect($0.boundingBox, item.boundingBox) > iouThreshold }) {
            kept.append(item)
        }
    }
    return kept
}

private func iouRect(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull else { return 0 }
    let interArea = inter.width * inter.height
    let union = a.width * a.height + b.width * b.height - interArea
    return union > 0 ? interArea / union : 0
}

private func visionOrientation(for orientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .portrait:             return .right
    case .portraitUpsideDown:   return .left
    case .landscapeLeft:        return .up
    case .landscapeRight:       return .down
    default:                    return .right
    }
}

private func cameraLabel(for device: AVCaptureDevice) -> String {
    switch (device.deviceType, device.position) {
    case (.builtInUltraWideCamera, .back):  return "0.5×"
    case (.builtInWideAngleCamera, .back):  return "1×"
    case (.builtInTelephotoCamera, .back):  return "TELE"
    case (.builtInWideAngleCamera, .front): return "FRONT"
    case (.builtInTrueDepthCamera, .front): return "FRONT"
    default:                                return device.localizedName
    }
}

private func cameraOrder(_ option: CameraOption) -> Int {
    switch (option.deviceType, option.position) {
    case (.builtInUltraWideCamera, .back):  return 0
    case (.builtInWideAngleCamera, .back):  return 1
    case (.builtInTelephotoCamera, .back):  return 2
    case (.builtInWideAngleCamera, .front): return 3
    case (.builtInTrueDepthCamera, .front): return 4
    default:                                return 99
    }
}
