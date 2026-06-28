//
//  TrackingOverlay.swift
//  test02
//

import SwiftUI

struct TrackingOverlay: View {
    @ObservedObject var state: TrackingState
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
                drawReticle(context: context,
                            size: size,
                            time: now.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: detections) { _, new in
            state.applyDetections(new)
        }
    }

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

    private func drawReticle(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r: CGFloat = 14
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - r, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + r, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - r))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + r))
        context.stroke(cross, with: .color(tint), lineWidth: 0.7)

        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.stroke(circle, with: .color(tint.opacity(0.85)), lineWidth: 0.6)

        let phase = sin(time * 2) * 0.5 + 0.5
        let scanR = r * (1 + CGFloat(phase) * 0.5)
        let scan = Path(ellipseIn: CGRect(
            x: center.x - scanR,
            y: center.y - scanR,
            width: scanR * 2,
            height: scanR * 2
        ))
        context.stroke(scan, with: .color(tint.opacity(0.45)), lineWidth: 0.4)
    }

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
        case .normal: hideFill = false
        case .shuffle: hideFill = state.isInvolvedInSwap(box.id)
        case .pixelStretch: hideFill = true
        }

        if !hideFill {
            let effOpacity = CGFloat(state.effectiveFillOpacity) * alpha
            context.fill(Path(rect), with: .color(tint.opacity(effOpacity)))
        }

        switch state.frameStyle {
        case .corners:
            drawCornerFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        case .plain:
            drawPlainFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        case .illustrator:
            drawIllustratorFrame(rect: rect, alpha: alpha, isLocked: box.isLocked, context: context)
        }

        // Always shown labels
        drawSizeLabel(rect: rect, context: context, alpha: alpha)
        drawKindLabel(rect: rect, kind: box.kind, context: context, alpha: alpha)

        if state.mode == .normal {
            drawCoordinateLabel(rect: rect, context: context, alpha: alpha)
            if box.isLocked {
                drawLockLabel(rect: rect, context: context, alpha: alpha)
            }
        }
    }

    private func drawKindLabel(rect: CGRect,
                               kind: ObjectKind,
                               context: GraphicsContext,
                               alpha: CGFloat) {
        let text = Text(kind.label)
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color.white.opacity(alpha))
        context.draw(text,
                     at: CGPoint(x: rect.minX + 2, y: rect.minY - 5),
                     anchor: .bottomLeading)
    }

    // MARK: - Frame styles

    private func drawCornerFrame(rect: CGRect,
                                 alpha: CGFloat,
                                 isLocked: Bool,
                                 context: GraphicsContext) {
        let corner = min(rect.width, rect.height) * 0.28
        var corners = Path()
        corners.move(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        corners.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        corners.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        corners.move(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        corners.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        corners.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
        corners.move(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        corners.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        corners.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
        corners.move(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        corners.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        corners.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
        let cornerWidth: CGFloat = isLocked ? 1.2 : 0.9
        context.stroke(corners, with: .color(tint.opacity(alpha)), lineWidth: cornerWidth)
    }

    private func drawPlainFrame(rect: CGRect,
                                alpha: CGFloat,
                                isLocked: Bool,
                                context: GraphicsContext) {
        let stroke = Path(rect)
        let lineWidth: CGFloat = isLocked ? 1.0 : 0.7
        context.stroke(stroke, with: .color(tint.opacity(alpha)), lineWidth: lineWidth)
    }

    private func drawIllustratorFrame(rect: CGRect,
                                      alpha: CGFloat,
                                      isLocked: Bool,
                                      context: GraphicsContext) {
        // Thin outline
        let outline = Path(rect)
        let outlineWidth: CGFloat = isLocked ? 0.7 : 0.5
        context.stroke(outline, with: .color(tint.opacity(alpha * 0.9)), lineWidth: outlineWidth)

        // 8 handles: 4 corners + 4 mid-edges
        let handlePoints: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY)
        ]
        let s: CGFloat = isLocked ? 6 : 5
        for p in handlePoints {
            let handle = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            context.fill(Path(handle), with: .color(Color.white.opacity(alpha)))
            context.stroke(Path(handle), with: .color(tint.opacity(alpha)), lineWidth: 0.6)
        }
    }

    // MARK: - Swap lines

    private struct UnorderedPair: Hashable {
        let a: UUID
        let b: UUID
        init(_ x: UUID, _ y: UUID) {
            if x.uuidString < y.uuidString { (a, b) = (x, y) }
            else { (a, b) = (y, x) }
        }
    }

    private func drawSwapLines(now: Date,
                               context: GraphicsContext,
                               size: CGSize) {
        guard !state.swapMap.isEmpty else { return }

        var drawn = Set<UnorderedPair>()

        for (sourceID, destID) in state.swapMap {
            let pair = UnorderedPair(sourceID, destID)
            if drawn.contains(pair) { continue }
            drawn.insert(pair)

            guard let source = state.tracked.first(where: { $0.id == sourceID }),
                  let dest = state.tracked.first(where: { $0.id == destID }),
                  source.isDisplayable, dest.isDisplayable else { continue }

            let sourceRect = viewRect(from: state.currentNormalizedRect(source, now: now), in: size)
            let destRect = viewRect(from: state.currentNormalizedRect(dest, now: now), in: size)
            let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
            let destCenter = CGPoint(x: destRect.midX, y: destRect.midY)

            var line = Path()
            line.move(to: sourceCenter)
            line.addLine(to: destCenter)
            context.stroke(line, with: .color(tint.opacity(0.9)), lineWidth: 0.8)

            let nodeR: CGFloat = 2.5
            context.fill(Path(ellipseIn: CGRect(x: sourceCenter.x - nodeR, y: sourceCenter.y - nodeR, width: nodeR * 2, height: nodeR * 2)),
                         with: .color(tint))
            context.fill(Path(ellipseIn: CGRect(x: destCenter.x - nodeR, y: destCenter.y - nodeR, width: nodeR * 2, height: nodeR * 2)),
                         with: .color(tint))
        }
    }

    // MARK: - Labels

    private func drawCoordinateLabel(rect: CGRect,
                                     context: GraphicsContext,
                                     alpha: CGFloat) {
        let label = String(format: "%.0f, %.0f", rect.minX, rect.minY)
        let text = Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(alpha))
        context.draw(text,
                     at: CGPoint(x: rect.minX + 2, y: rect.maxY + 5),
                     anchor: .topLeading)
    }

    private func drawSizeLabel(rect: CGRect,
                               context: GraphicsContext,
                               alpha: CGFloat) {
        let label = "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
        let text = Text(label)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color.white.opacity(alpha))
        context.draw(text,
                     at: CGPoint(x: rect.maxX - 2, y: rect.minY - 5),
                     anchor: .bottomTrailing)
    }

    private func drawLockLabel(rect: CGRect,
                               context: GraphicsContext,
                               alpha: CGFloat) {
        let text = Text("LOCK")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color.white.opacity(alpha))
        context.draw(text,
                     at: CGPoint(x: rect.maxX - 2, y: rect.maxY + 5),
                     anchor: .topTrailing)
    }
}
