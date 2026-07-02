//
//  SettingsView.swift
//  test02
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("MODE") {
                    ForEach(TrackingMode.allCases, id: \.self) { m in
                        selectionRow(label: m.label, isSelected: state.mode == m) {
                            state.setMode(m)
                        }
                    }
                }

                Section("FRAME") {
                    ForEach(FrameStyle.allCases, id: \.self) { s in
                        selectionRow(label: s.label, isSelected: state.frameStyle == s) {
                            state.setFrameStyle(s)
                        }
                    }
                }

                Section("FILL OPACITY") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("OPACITY")
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Text("\(Int((state.fillOpacity * 100).rounded()))%")
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        }
                        Slider(value: opacityBinding, in: 0...1)
                            .disabled(state.coverCompletely)
                    }
                    .padding(.vertical, 4)
                }

                Section("OVERLAY") {
                    Toggle(isOn: coverBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("COVER COMPLETELY")
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                            Text("不透明度を無視して完全に被せる")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: binaryBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BINARY OVERLAY")
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                            Text("ボックス内にバイナリコードを表示")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("SCAN") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("LINE SPEED")
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Text(String(format: "%.2f×", state.scanLineSpeed))
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        }
                        Slider(value: scanSpeedBinding, in: 0.25...4.0)
                    }
                    .padding(.vertical, 4)
                }

                Section("CAMERA") {
                    ForEach(camera.availableCameras) { option in
                        selectionRow(label: option.label,
                                     isSelected: camera.currentCamera == option) {
                            camera.switchCamera(to: option)
                        }
                    }
                }
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { dismiss() }
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                }
            }
        }
    }

    private func selectionRow(label: String, isSelected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { state.fillOpacity }, set: { state.setFillOpacity($0) })
    }

    private var coverBinding: Binding<Bool> {
        Binding(get: { state.coverCompletely }, set: { state.setCoverCompletely($0) })
    }

    private var binaryBinding: Binding<Bool> {
        Binding(get: { state.showBinaryOverlay }, set: { state.setShowBinaryOverlay($0) })
    }

    private var scanSpeedBinding: Binding<Double> {
        Binding(get: { state.scanLineSpeed }, set: { state.setScanLineSpeed($0) })
    }
}
