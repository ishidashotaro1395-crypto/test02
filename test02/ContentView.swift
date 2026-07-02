//
//  ContentView.swift
//  test02
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var recording = RecordingManager()
    @StateObject private var trackingState = TrackingState()
    @StateObject private var audio = IkedaAudioEngine()
    @StateObject private var scanEngine = ScanEngine()

    @State private var deviceOrientation: UIDeviceOrientation = .portrait
    @State private var showSettings: Bool = false

    private let tint = Color(red: 0.0, green: 0.0, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session,
                          rotationAngle: previewRotation(for: deviceOrientation))
                .ignoresSafeArea()

            ShuffleCompositor(camera: camera, trackingState: trackingState)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TrackingOverlay(state: trackingState,
                            scanEngine: scanEngine,
                            detections: camera.detections,
                            bufferAspect: bufferAspect(for: deviceOrientation))
                .ignoresSafeArea()

            VStack {
                statusHUD
                Spacer()
                bottomBar
            }
            .opacity(recording.isRecording ? 0 : 1)

            if recording.isRecording {
                Color.black.opacity(0.0001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { recording.stop() }
            }

            if !camera.isAuthorized {
                permissionPlaceholder
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation()
            audio.start()
            camera.start()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                audio.reactivate()
                scanEngine.start(state: trackingState, audio: audio)
            }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            camera.stop()
            scanEngine.stop()
            if recording.isRecording { recording.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(state: trackingState, camera: camera)
        }
        .sheet(item: $recording.preview) { bundle in
            PreviewControllerView(controller: bundle.controller) {
                recording.preview = nil
            }
            .ignoresSafeArea()
        }
    }

    private func updateOrientation() {
        let raw = UIDevice.current.orientation
        let usable: UIDeviceOrientation
        if raw.isPortrait || raw.isLandscape {
            usable = raw
        } else {
            usable = deviceOrientation
        }
        deviceOrientation = usable
        camera.setOrientation(usable)
    }

    private var statusHUD: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(recording.isRecording ? .red : tint.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text("READY")
            }
            Spacer()
            Text("MODE: \(modeLabel)")
            Spacer()
            Text("OBJ \(String(format: "%03d", trackingState.tracked.filter { $0.isDisplayable }.count))")
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var modeLabel: String {
        switch trackingState.mode {
        case .normal:       return "NORMAL"
        case .shuffle:      return "SHUFFLE"
        case .pixelStretch: return "PIXEL STRETCH"
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(timestamp)
                Spacer()
                Text(camera.currentCamera?.label ?? "—")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)

            HStack(spacing: 28) {
                settingsButton
                recordButton
            }
            .padding(.bottom, 14)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            ZStack {
                Circle()
                    .stroke(tint, lineWidth: 1.2)
                    .frame(width: 56, height: 56)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
    }

    private var recordButton: some View {
        Button {
            recording.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(tint, lineWidth: 1.5)
                    .frame(width: 70, height: 70)
                Circle()
                    .fill(.red)
                    .frame(width: 56, height: 56)
            }
        }
        .disabled(!recording.isAvailable)
        .opacity(recording.isAvailable ? 1.0 : 0.3)
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
            Text("カメラへのアクセスを許可してください")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(24)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private func previewRotation(for orientation: UIDeviceOrientation) -> CGFloat {
    switch orientation {
    case .portrait:             return 90
    case .portraitUpsideDown:   return 270
    case .landscapeLeft:        return 0
    case .landscapeRight:       return 180
    default:                    return 90
    }
}

private func bufferAspect(for orientation: UIDeviceOrientation) -> CGFloat {
    orientation.isLandscape ? 16.0 / 9.0 : 9.0 / 16.0
}

#Preview {
    ContentView()
}
