//
//  ShuffleCompositor.swift
//  test02
//
//  Renders mode-specific image effects on top of the camera preview:
//   - .shuffle: cuts each locked box and pastes the source pixels onto the
//     destination box (with rescaling).
//   - .pixelStretch: takes a single-pixel-wide column at the box's center and
//     stretches it horizontally to fill the box (slit-scan effect).
//

import CoreImage
import SwiftUI
import UIKit

struct ShuffleCompositor: UIViewRepresentable {
    let camera: CameraManager
    let trackingState: TrackingState

    func makeUIView(context: Context) -> ShuffleCompositorView {
        let view = ShuffleCompositorView()
        view.camera = camera
        view.trackingState = trackingState
        view.start()
        return view
    }

    func updateUIView(_ uiView: ShuffleCompositorView, context: Context) {
        uiView.camera = camera
        uiView.trackingState = trackingState
    }

    static func dismantleUIView(_ uiView: ShuffleCompositorView, coordinator: ()) {
        uiView.stop()
    }
}

final class ShuffleCompositorView: UIView {
    weak var camera: CameraManager?
    weak var trackingState: TrackingState?

    private var displayLink: CADisplayLink?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let imageLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let state = trackingState,
              let baseImage = camera?.currentImage() else {
            clearLayer()
            return
        }

        imageLayer.opacity = Float(state.effectiveFillOpacity)

        let extent = baseImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let now = Date()
        let tracks = state.tracked
        var composite: CIImage? = nil

        switch state.mode {
        case .normal:
            clearLayer()
            return

        case .shuffle:
            guard !state.swapMap.isEmpty else { clearLayer(); return }
            for (sourceID, destID) in state.swapMap {
                guard let source = tracks.first(where: { $0.id == sourceID }),
                      let dest = tracks.first(where: { $0.id == destID }) else { continue }

                let sourceRect = imageRect(for: state.currentNormalizedRect(source, now: now), extent: extent)
                let destRect = imageRect(for: state.currentNormalizedRect(dest, now: now), extent: extent)

                guard sourceRect.width > 1, sourceRect.height > 1,
                      destRect.width > 1, destRect.height > 1 else { continue }

                let scaleX = destRect.width / sourceRect.width
                let scaleY = destRect.height / sourceRect.height
                let tx = destRect.minX - sourceRect.minX * scaleX
                let ty = destRect.minY - sourceRect.minY * scaleY
                let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: tx, ty: ty)

                let warped = baseImage.transformed(by: transform).cropped(to: destRect)
                composite = composite.map { warped.composited(over: $0) } ?? warped
            }

        case .pixelStretch:
            for box in tracks where box.isDisplayable {
                let rect = imageRect(for: state.currentNormalizedRect(box, now: now), extent: extent)
                guard rect.width > 2, rect.height > 2 else { continue }

                let centerX = (rect.midX).rounded()
                let columnRect = CGRect(x: centerX, y: rect.minY, width: 1, height: rect.height)
                                    .intersection(extent)
                guard !columnRect.isNull, columnRect.height > 1 else { continue }

                // Stretch horizontally: scale x by rect.width, then place at rect.minX
                let scaleX = rect.width
                let tx = rect.minX - columnRect.minX * scaleX
                let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: 1, tx: tx, ty: 0)

                let stretched = baseImage
                    .cropped(to: columnRect)
                    .transformed(by: transform)
                    .cropped(to: rect)

                composite = composite.map { stretched.composited(over: $0) } ?? stretched
            }
        }

        guard let final = composite else {
            clearLayer()
            return
        }

        if let cg = ciContext.createCGImage(final, from: extent) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = cg
            CATransaction.commit()
        }
    }

    private func clearLayer() {
        if imageLayer.contents != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func imageRect(for normalized: CGRect, extent: CGRect) -> CGRect {
        CGRect(
            x: normalized.minX * extent.width,
            y: normalized.minY * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        )
    }
}
