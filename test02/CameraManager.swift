//
//  CameraManager.swift
//  test02
//
//  検出ソース:
//   1. VNDetectRectanglesRequest      — 矩形サインボード・ポスター・ビジョン
//   2. VNDetectHumanRectanglesRequest — 歩行中の人間
//   3. VNRecognizeTextRequest (fast)  — 文字が書かれたサインを追加検出
//   4. VNGenerateObjectnessBasedSaliencyImageRequest — 車両・その他の顕著物体
//  Neural Engine を最大活用するため全リクエストを 1 回の perform でバッチ処理。
//

@preconcurrency import AVFoundation
import Combine
import CoreImage
import SwiftUI
import UIKit
import Vision

enum ObjectKind: String, CaseIterable, Hashable {
    case poster, sign, vision, person, vehicle, unknown

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
    private let sessionQueue  = DispatchQueue(label: "camera.session")
    private let bufferQueue   = DispatchQueue(label: "camera.buffer")
    private var isConfigured  = false
    private nonisolated(unsafe) var lastProcessedTime: CFAbsoluteTime = 0
    private let minProcessInterval: CFAbsoluteTime = 1.0 / 20.0   // 20fps
    private nonisolated(unsafe) var currentVisionOrientation: CGImagePropertyOrientation = .right

    private let imageLock = NSLock()
    private nonisolated(unsafe) var _latestImage: CIImage?

    func currentImage() -> CIImage? {
        imageLock.lock(); defer { imageLock.unlock() }
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
            if let conn = self.videoOutput.connection(with: .video) {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
            Task { @MainActor in self.currentCamera = option }
        }
    }

    private func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:     return true
        case .notDetermined:  return await AVCaptureDevice.requestAccess(for: .video)
        default:              return false
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        let cameras = discoverCameras()
        let defaultOption = cameras.first(where: {
            $0.deviceType == .builtInWideAngleCamera && $0.position == .back
        }) ?? cameras.first
        if let opt = defaultOption,
           let dev = AVCaptureDevice.default(opt.deviceType, for: .video, position: opt.position),
           let inp = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(inp) {
            session.addInput(inp)
            if let conn = videoOutput.connection(with: .video) {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
            Task { @MainActor in self.availableCameras = cameras; self.currentCamera = opt }
        }
        session.commitConfiguration()
    }

    private func discoverCameras() -> [CameraOption] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera,
            .builtInTelephotoCamera, .builtInTrueDepthCamera
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                position: .unspecified).devices
            .map { CameraOption(id: "\($0.deviceType.rawValue)|\($0.position.rawValue)",
                                deviceType: $0.deviceType, position: $0.position,
                                label: cameraLabel(for: $0)) }
            .sorted { cameraOrder($0) < cameraOrder($1) }
    }
}

// MARK: - Sample buffer delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let orientation = currentVisionOrientation
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        imageLock.lock(); _latestImage = oriented; imageLock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessedTime >= minProcessInterval else { return }
        lastProcessedTime = now

        // ── リクエスト構築 ──────────────────────────────────────
        // 1. 矩形検出
        let rectReq = VNDetectRectanglesRequest()
        rectReq.maximumObservations   = 12
        rectReq.minimumAspectRatio    = VNAspectRatio(0.2)   // 5:1 横長まで対応
        rectReq.maximumAspectRatio    = VNAspectRatio(1.0)
        rectReq.minimumSize           = Float(0.04)
        rectReq.minimumConfidence     = VNConfidence(0.40)
        rectReq.quadratureTolerance   = VNDegrees(22)        // 歪み・傾き許容

        // 2. 人物検出
        let humanReq = VNDetectHumanRectanglesRequest()
        humanReq.upperBodyOnly = false

        // 3. テキスト領域検出（文字のあるサインを追加検出、Neural Engine 活用）
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel        = .fast
        textReq.usesLanguageCorrection  = false
        textReq.minimumTextHeight       = 0.008   // 画像高の 0.8% 以上の文字

        // 4. 顕著物体検出（車両など）
        let saliencyReq = VNGenerateObjectnessBasedSaliencyImageRequest()

        // ── バッチ実行（Neural Engine が全リクエストを最適化）──
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation, options: [:])
        try? handler.perform([rectReq, humanReq, textReq, saliencyReq])

        var combined: [DetectedObject] = []

        // 矩形結果
        if let results = rectReq.results {
            for obs in results {
                let aspect = obs.boundingBox.width / max(obs.boundingBox.height, 0.001)
                combined.append(DetectedObject(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence,
                    kind: kindForAspect(aspect)
                ))
            }
        }

        // 人物結果
        if let results = humanReq.results {
            for obs in results {
                combined.append(DetectedObject(boundingBox: obs.boundingBox,
                                               confidence: obs.confidence,
                                               kind: .person))
            }
        }

        // テキスト結果 → 隣接ボックスをマージして 1 サイン = 1 ボックス
        if let results = textReq.results, !results.isEmpty {
            let textBoxes = results.map { $0.boundingBox }
            let merged = mergeAdjacentBoxes(textBoxes, padding: 0.025)
            for box in merged {
                guard box.width * box.height >= 0.002 else { continue }
                let aspect = box.width / max(box.height, 0.001)
                combined.append(DetectedObject(
                    boundingBox: box,
                    confidence: 0.72,
                    kind: kindForAspect(aspect)
                ))
            }
        }

        // 顕著物体結果 → 車両ヒューリスティック
        if let results = saliencyReq.results {
            for obs in results {
                guard let objects = obs.salientObjects else { continue }
                for s in objects {
                    let area   = s.boundingBox.width * s.boundingBox.height
                    let aspect = s.boundingBox.width / max(s.boundingBox.height, 0.001)
                    guard area >= 0.012 else { continue }
                    // 画面下半分 (Vision Y < 0.6) かつ横長 → 車両と判定
                    let isLowerHalf = s.boundingBox.midY < 0.6
                    let kind: ObjectKind = (aspect >= 1.2 && isLowerHalf) ? .vehicle : .unknown
                    combined.append(DetectedObject(boundingBox: s.boundingBox,
                                                   confidence: s.confidence, kind: kind))
                }
            }
        }

        let deduped = dedupeBoxes(combined, iouThreshold: 0.45)
        Task { @MainActor [weak self] in self?.detections = deduped }
    }
}

// MARK: - Helpers

private func kindForAspect(_ aspect: CGFloat) -> ObjectKind {
    if aspect >= 1.7 { return .vision }
    if aspect <= 0.65 { return .poster }
    return .sign
}

private func mergeAdjacentBoxes(_ boxes: [CGRect], padding: CGFloat) -> [CGRect] {
    var merged: [CGRect] = []
    for box in boxes {
        let expanded = box.insetBy(dx: -padding, dy: -padding)
        if let idx = merged.indices.first(where: { merged[$0].intersects(expanded) }) {
            merged[idx] = merged[idx].union(box)
        } else {
            merged.append(box)
        }
    }
    return merged
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
