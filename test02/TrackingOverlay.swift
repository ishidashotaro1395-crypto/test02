//
//  TrackingOverlay.swift
//  test02
//

import SwiftUI

struct TrackingOverlay: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var scanEngine: ScanEngine
    let detections: [DetectedObject]
    let bufferAspect: CGFloat

    private let tint = Color(red: 0.0, green: 0.0, blue: 1.0)
    private let fadeInDuration: TimeInterval = 0.12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                for box in state.tracked where box.isDisplayable {
                    drawTrackingBox(box, now: now, context: context, size: size)
                }
                if state.mode == .shuffle {
                    drawSwapLines(now: now, context: context, size: size)
                }
                drawScanLines(scanEngine.lines, context: context, size: size)
                drawReticle(context: context, size: size,
                            time: now.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: detections) { _, new in
            state.applyDetections(new)
        }
    }

    // MARK: - Coordinate helpers

    private func viewRect(from box: CGRect, in size: CGSize) -> CGRect {
        let viewAspect = size.width / size.height
        let renderedW: CGFloat
        let renderedH: CGFloat
        if bufferAspect > viewAspect {
            renderedH = size.height
            renderedW = renderedH * bufferAspect
        } else {
            renderedW = size.width
            renderedH = renderedW / bufferAspect
        }
        let offsetX = (renderedW - size.width) / 2
        let offsetY = (renderedH - size.height) / 2
        return CGRect(
            x: box.minX * renderedW - offsetX,
            y: (1 - box.maxY) * renderedH - offsetY,
            width: box.width * renderedW,
            height: box.height * renderedH
        )
    }

    // MARK: - Scan lines (白)

    private func drawScanLines(_ lines: [ScanLine], context: GraphicsContext, size: CGSize) {
        for line in lines {
            let tc = line.trail.count
            for (ti, tp) in line.trail.enumerated() {
                let t = Double(ti + 1) / Double(tc + 1)
                let trailAlpha = t * t * 0.50
                let w = max(0.3, line.thickness * t * 0.8)
                switch line.direction {
                case .horizontal:
                    context.fill(
                        Path(CGRect(x: 0, y: tp * Double(size.height) - w / 2,
                                    width: Double(size.width), height: w)),
                        with: .color(Color.white.opacity(trailAlpha))
                    )
                case .vertical:
                    context.fill(
                        Path(CGRect(x: tp * Double(size.width) - w / 2, y: 0,
                                    width: w, height: Double(size.height))),
                        with: .color(Color.white.opacity(trailAlpha))
                    )
                }
            }
            switch line.direction {
            case .horizontal:
                context.fill(
                    Path(CGRect(x: 0, y: line.position * Double(size.height),
                                width: Double(size.width), height: line.thickness)),
                    with: .color(Color.white)
                )
            case .vertical:
                context.fill(
                    Path(CGRect(x: line.position * Double(size.width), y: 0,
                                width: line.thickness, height: Double(size.height))),
                    with: .color(Color.white)
                )
            }
        }
    }

    // MARK: - Reticle

    private func drawReticle(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r: CGFloat = 14
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - r, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + r, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - r))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + r))
        context.stroke(cross, with: .color(tint), lineWidth: 0.7)

        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                            width: r * 2, height: r * 2))
        context.stroke(circle, with: .color(tint.opacity(0.85)), lineWidth: 0.6)

        let phase = sin(time * 2) * 0.5 + 0.5
        let scanR = r * (1 + CGFloat(phase) * 0.5)
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - scanR, y: center.y - scanR,
                                   width: scanR * 2, height: scanR * 2)),
            with: .color(tint.opacity(0.45)), lineWidth: 0.4)
    }

    // MARK: - Tracking box

    private func drawTrackingBox(_ box: TrackingState.TrackedBox,
                                 now: Date,
                                 context: GraphicsContext,
                                 size: CGSize) {
        let rect = viewRect(from: state.currentNormalizedRect(box, now: now), in: size)
        guard rect.width > 4, rect.height > 4 else { return }

        let inAlpha = min(1.0, now.timeIntervalSince(box.firstSeen) / fadeInDuration)
        let grace = box.isLocked ? state.lockedDespawnGrace : state.unlockedDespawnGrace
        let timeSinceConfirmed = now.timeIntervalSince(box.lastConfirmed)
        let fadeStart = grace * 0.5
        let outAlpha: Double
        if timeSinceConfirmed < fadeStart {
            outAlpha = 1.0
        } else if timeSinceConfirmed < grace {
            outAlpha = max(0, 1.0 - (timeSinceConfirmed - fadeStart) / (grace - fadeStart))
        } else {
            outAlpha = 0
        }
        let alpha = CGFloat(inAlpha * outAlpha)
        guard alpha > 0.01 else { return }

        let hideFill: Bool
        switch state.mode {
        case .normal:       hideFill = false
        case .shuffle:      hideFill = state.isInvolvedInSwap(box.id)
        case .pixelStretch: hideFill = true
        }

        if !hideFill {
            context.fill(Path(rect),
                         with: .color(tint.opacity(CGFloat(state.effectiveFillOpacity) * alpha)))
        }

        // バイナリコードオーバーレイ（設定でON/OFF）
        if state.showBinaryOverlay {
            drawBinaryOverlay(rect: rect, id: box.id, alpha: alpha, context: context)
        }

        switch state.frameStyle {
        case .corners:      drawCornerFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        case .plain:        drawPlainFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        case .illustrator:  drawIllustratorFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        }

        drawSizeLabel(rect: rect, context: context, alpha: alpha)
        drawKindLabel(rect: rect, kind: box.kind, context: context, alpha: alpha)

        if state.mode == .normal {
            drawCoordinateLabel(rect: rect, context: context, alpha: alpha)
            if box.isLocked { drawLockLabel(rect: rect, context: context, alpha: alpha) }
        }
    }

    // MARK: - Binary overlay

    private func drawBinaryOverlay(rect: CGRect, id: UUID, alpha: CGFloat,
                                   context: GraphicsContext) {
        guard rect.width > 24, rect.height > 14 else { return }
        let bytes: [UInt8] = withUnsafeBytes(of: id.uuid) { Array($0) }
        let line = bytes.map { String($0, radix: 2).zeroPadded(to: 8) }.joined(separator: " ")
        let rowCount = max(2, Int(rect.height / 8))
        let text = Array(repeating: line, count: rowCount).joined(separator: "\n")

        context.drawLayer { inner in
            inner.clip(to: Path(rect))
            let t = Text(text)
                .font(.system(size: 6, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(Double(alpha) * 0.40))
            inner.draw(t, in: rect.insetBy(dx: 2, dy: 2))
        }
    }

    // MARK: - Frame styles

    private func drawCornerFrame(rect: CGRect, alpha: CGFloat, isLocked: Bool,
                                 context: GraphicsContext) {
        let corner = min(rect.width, rect.height) * 0.28
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
        context.stroke(p, with: .color(tint.opacity(alpha)),
                       lineWidth: isLocked ? 1.2 : 0.9)
    }

    private func drawPlainFrame(rect: CGRect, alpha: CGFloat, isLocked: Bool,
                                context: GraphicsContext) {
        context.stroke(Path(rect), with: .color(tint.opacity(alpha)),
                       lineWidth: isLocked ? 1.0 : 0.7)
    }

    private func drawIllustratorFrame(rect: CGRect, alpha: CGFloat, isLocked: Bool,
                                      context: GraphicsContext) {
        context.stroke(Path(rect), with: .color(tint.opacity(alpha * 0.9)),
                       lineWidth: isLocked ? 0.7 : 0.5)
        let handlePoints: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
        ]
        let s: CGFloat = isLocked ? 6 : 5
        for point in handlePoints {
            let h = CGRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s)
            context.fill(Path(h), with: .color(Color.white.opacity(alpha)))
            context.stroke(Path(h), with: .color(tint.opacity(alpha)), lineWidth: 0.6)
        }
    }

    // MARK: - Swap lines

    private struct UnorderedPair: Hashable {
        let a: UUID; let b: UUID
        init(_ x: UUID, _ y: UUID) {
            if x.uuidString < y.uuidString { (a, b) = (x, y) } else { (a, b) = (y, x) }
        }
    }

    private func drawSwapLines(now: Date, context: GraphicsContext, size: CGSize) {
        guard !state.swapMap.isEmpty else { return }
        var drawn = Set<UnorderedPair>()
        for (srcID, dstID) in state.swapMap {
            let pair = UnorderedPair(srcID, dstID)
            guard !drawn.contains(pair) else { continue }
            drawn.insert(pair)
            guard let src = state.tracked.first(where: { $0.id == srcID }),
                  let dst = state.tracked.first(where: { $0.id == dstID }),
                  src.isDisplayable, dst.isDisplayable else { continue }

            let srcR = viewRect(from: state.currentNormalizedRect(src, now: now), in: size)
            let dstR = viewRect(from: state.currentNormalizedRect(dst, now: now), in: size)
            let sc = CGPoint(x: srcR.midX, y: srcR.midY)
            let dc = CGPoint(x: dstR.midX, y: dstR.midY)

            var line = Path()
            line.move(to: sc); line.addLine(to: dc)
            context.stroke(line, with: .color(tint.opacity(0.9)), lineWidth: 0.8)

            let r: CGFloat = 2.5
            for c in [sc, dc] {
                context.fill(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(tint))
            }
        }
    }

    // MARK: - Labels

    private func drawKindLabel(rect: CGRect, kind: ObjectKind, context: GraphicsContext,
                               alpha: CGFloat) {
        context.draw(
            Text(kind.label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.white.opacity(alpha)),
            at: CGPoint(x: rect.minX + 2, y: rect.minY - 5), anchor: .bottomLeading)
    }

    private func drawSizeLabel(rect: CGRect, context: GraphicsContext, alpha: CGFloat) {
        context.draw(
            Text("\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.white.opacity(alpha)),
            at: CGPoint(x: rect.maxX - 2, y: rect.minY - 5), anchor: .bottomTrailing)
    }

    private func drawCoordinateLabel(rect: CGRect, context: GraphicsContext, alpha: CGFloat) {
        context.draw(
            Text(String(format: "%.0f, %.0f", rect.minX, rect.minY))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(alpha)),
            at: CGPoint(x: rect.minX + 2, y: rect.maxY + 5), anchor: .topLeading)
    }

    private func drawLockLabel(rect: CGRect, context: GraphicsContext, alpha: CGFloat) {
        context.draw(
            Text("LOCK")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.white.opacity(alpha)),
            at: CGPoint(x: rect.maxX - 2, y: rect.maxY + 5), anchor: .topTrailing)
    }
}

private extension String {
    func zeroPadded(to length: Int) -> String {
        guard count < length else { return self }
        return String(repeating: "0", count: length - count) + self
    }
}
