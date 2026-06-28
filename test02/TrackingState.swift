//
//  TrackingState.swift
//  test02
//

import Combine
import CoreGraphics
import Foundation

enum TrackingMode: String, CaseIterable, Hashable {
    case normal
    case shuffle
    case pixelStretch

    var label: String {
        switch self {
        case .normal: return "通常"
        case .shuffle: return "シャッフル"
        case .pixelStretch: return "ピクセル伸ばし"
        }
    }
}

enum FrameStyle: String, CaseIterable, Hashable {
    case corners
    case plain
    case illustrator

    var label: String {
        switch self {
        case .corners: return "コーナー"
        case .plain: return "枠のみ"
        case .illustrator: return "Illustrator風"
        }
    }
}

final class TrackingState: ObservableObject {
    @Published private(set) var tracked: [TrackedBox] = []
    @Published private(set) var swapMap: [UUID: UUID] = [:]
    @Published private(set) var mode: TrackingMode = .normal
    @Published private(set) var frameStyle: FrameStyle = .corners
    @Published private(set) var fillOpacity: Double = 0.85
    @Published private(set) var coverCompletely: Bool = false

    static let fillOpacityOptions: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    /// Effective fill opacity used by overlays / compositors.
    var effectiveFillOpacity: Double {
        coverCompletely ? 1.0 : fillOpacity
    }

    let transitionDuration: TimeInterval = 0.14
    private let iouMatchThreshold: CGFloat = 0.1
    private let lockedIouThreshold: CGFloat = 0.04
    private let centroidMatchDistance: CGFloat = 0.18
    private let lockedCentroidMatchDistance: CGFloat = 0.28

    let lockedHitThreshold = 4
    let unlockedDespawnGrace: TimeInterval = 0.3
    let lockedDespawnGrace: TimeInterval = 2.5

    private let targetSmoothing: CGFloat = 0.55

    struct TrackedBox: Identifiable {
        let id: UUID
        var previousRect: CGRect
        var targetRect: CGRect
        var confidence: Float
        var transitionStart: Date
        var firstSeen: Date
        var lastConfirmed: Date
        var hitCount: Int
        var kind: ObjectKind

        var isLocked: Bool { hitCount >= 4 }
        var isDisplayable: Bool { hitCount >= 2 }
    }

    // MARK: - Mode

    func setMode(_ new: TrackingMode) {
        guard mode != new else { return }
        mode = new
        if new == .shuffle {
            regenerateSwapMap()
        } else {
            swapMap = [:]
        }
    }

    func setFrameStyle(_ new: FrameStyle) {
        frameStyle = new
    }

    func setFillOpacity(_ new: Double) {
        fillOpacity = max(0, min(1, new))
    }

    func setCoverCompletely(_ value: Bool) {
        coverCompletely = value
    }

    // MARK: - Detection ingest

    func applyDetections(_ new: [DetectedObject]) {
        let now = Date()
        var updated = tracked
        var matched = Set<Int>()

        let sortedNew = new.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }

        for det in sortedNew {
            var bestIdx: Int? = nil
            var bestScore: CGFloat = 0
            for (idx, box) in updated.enumerated() where !matched.contains(idx) {
                let score = matchScore(existing: box, candidate: det.boundingBox)
                if score > bestScore {
                    bestScore = score
                    bestIdx = idx
                }
            }
            if let idx = bestIdx, bestScore > 0 {
                matched.insert(idx)
                var box = updated[idx]
                box.previousRect = currentNormalizedRect(box, now: now)
                box.targetRect = blendRect(box.targetRect,
                                            det.boundingBox,
                                            weight: targetSmoothing)
                box.transitionStart = now
                box.lastConfirmed = now
                box.confidence = det.confidence
                box.hitCount += 1
                updated[idx] = box
            } else {
                updated.append(TrackedBox(
                    id: UUID(),
                    previousRect: det.boundingBox,
                    targetRect: det.boundingBox,
                    confidence: det.confidence,
                    transitionStart: now,
                    firstSeen: now,
                    lastConfirmed: now,
                    hitCount: 1,
                    kind: det.kind
                ))
            }
        }

        updated.removeAll { box in
            let grace = box.isLocked ? lockedDespawnGrace : unlockedDespawnGrace
            return now.timeIntervalSince(box.lastConfirmed) > grace
        }
        tracked = updated
        cleanupSwapMap()

        if mode == .shuffle && swapMap.isEmpty {
            regenerateSwapMap()
        }
    }

    // MARK: - Shuffle

    private func regenerateSwapMap() {
        // Use any displayable boxes so we can swap whenever 2+ exist
        let pool = tracked.filter { $0.isDisplayable }.map { $0.id }
        guard pool.count >= 2 else {
            swapMap = [:]
            return
        }
        var shuffled = pool.shuffled()
        var attempts = 0
        while attempts < 8, zip(pool, shuffled).contains(where: { $0 == $1 }) {
            shuffled.shuffle()
            attempts += 1
        }
        if zip(pool, shuffled).contains(where: { $0 == $1 }),
           let first = pool.first {
            shuffled = Array(pool.dropFirst()) + [first]
        }
        swapMap = Dictionary(uniqueKeysWithValues: zip(pool, shuffled))
    }

    private func cleanupSwapMap() {
        let validIDs = Set(tracked.filter { $0.isDisplayable }.map { $0.id })
        swapMap = swapMap.filter { validIDs.contains($0.key) && validIDs.contains($0.value) }
    }

    func isInvolvedInSwap(_ id: UUID) -> Bool {
        guard mode == .shuffle else { return false }
        if swapMap[id] != nil { return true }
        if swapMap.values.contains(id) { return true }
        return false
    }

    // MARK: - Interpolation

    func currentNormalizedRect(_ box: TrackedBox, now: Date) -> CGRect {
        let elapsed = now.timeIntervalSince(box.transitionStart)
        let t = CGFloat(min(1.0, max(0, elapsed / transitionDuration)))
        return interpolateRect(from: box.previousRect, to: box.targetRect, t: t)
    }

    // MARK: - Matching

    private func matchScore(existing: TrackedBox, candidate: CGRect) -> CGFloat {
        let lockBonus: CGFloat = existing.isLocked ? 0.5 : 0
        let iouThresh = existing.isLocked ? lockedIouThreshold : iouMatchThreshold
        let centroidThresh = existing.isLocked ? lockedCentroidMatchDistance : centroidMatchDistance

        let iouScore = iou(existing.targetRect, candidate)
        if iouScore >= iouThresh {
            return iouScore + 1.0 + lockBonus
        }

        let dx = existing.targetRect.midX - candidate.midX
        let dy = existing.targetRect.midY - candidate.midY
        let dist = sqrt(dx * dx + dy * dy)
        guard dist < centroidThresh else { return 0 }

        let aArea = existing.targetRect.width * existing.targetRect.height
        let bArea = candidate.width * candidate.height
        guard aArea > 0, bArea > 0 else { return 0 }
        let sizeRatio = min(aArea, bArea) / max(aArea, bArea)
        guard sizeRatio > 0.4 else { return 0 }

        let proximity = 1 - dist / centroidThresh
        return proximity * sizeRatio + lockBonus
    }
}

// MARK: - Helpers

private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull else { return 0 }
    let interArea = inter.width * inter.height
    let union = a.width * a.height + b.width * b.height - interArea
    return union > 0 ? interArea / union : 0
}

func interpolateRect(from a: CGRect, to b: CGRect, t: CGFloat) -> CGRect {
    CGRect(
        x: a.minX + (b.minX - a.minX) * t,
        y: a.minY + (b.minY - a.minY) * t,
        width: a.width + (b.width - a.width) * t,
        height: a.height + (b.height - a.height) * t
    )
}

func blendRect(_ a: CGRect, _ b: CGRect, weight w: CGFloat) -> CGRect {
    let inv = 1 - w
    return CGRect(
        x: a.minX * inv + b.minX * w,
        y: a.minY * inv + b.minY * w,
        width: a.width * inv + b.width * w,
        height: a.height * inv + b.height * w
    )
}
