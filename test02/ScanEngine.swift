//
//  ScanEngine.swift
//  test02
//
//  H+V スキャンラインを 2 秒間隔でペア生成。
//  ランダムな方向で移動し、TrackedBox を横断したら pip 音をトリガー。
//  速度は TrackingState.scanLineSpeed 倍率で調整。
//

import Combine
import CoreGraphics
import Foundation

struct ScanLine: Identifiable {
    enum Direction { case horizontal, vertical }
    let id: UUID
    var position: Double      // screen-normalized 0=top/left … 1=bottom/right
    var velocity: Double      // 正=下/右、負=上/左
    var thickness: Double
    let direction: Direction
    var trail: [Double]
    var crossedKeys: Set<String>

    init(position: Double, velocity: Double, thickness: Double, direction: Direction) {
        id = UUID()
        self.position = position
        self.velocity = velocity
        self.thickness = thickness
        self.direction = direction
        trail = []
        crossedKeys = []
    }
}

final class ScanEngine: ObservableObject {
    // Canvas が TimelineView 経由で 30fps 読み取るため @Published 不要
    nonisolated(unsafe) var lines: [ScanLine] = []

    private nonisolated(unsafe) weak var trackingState: TrackingState?
    private nonisolated(unsafe) weak var audio: IkedaAudioEngine?
    private nonisolated(unsafe) var updateTask: Task<Void, Never>?
    private nonisolated(unsafe) var timeSinceLastSpawn: Double = 1.9

    private let spawnInterval: Double = 2.0

    func start(state: TrackingState, audio: IkedaAudioEngine) {
        trackingState = state
        self.audio = audio
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        Task { @MainActor [weak self] in self?.lines = [] }
    }

    @MainActor
    private func loop() async {
        var last = Date.now
        while !Task.isCancelled {
            let now = Date.now
            let dt = min(0.05, now.timeIntervalSince(last))
            last = now
            update(dt: dt)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    @MainActor
    private func update(dt: Double) {
        timeSinceLastSpawn += dt
        if timeSinceLastSpawn >= spawnInterval {
            spawnLines()
            timeSinceLastSpawn = 0
        }

        let boxes = trackingState?.tracked.filter { $0.isDisplayable } ?? []
        var didPip = false

        for i in lines.indices {
            let old = lines[i].position
            lines[i].trail.append(old)
            if lines[i].trail.count > 14 { lines[i].trail.removeFirst() }
            lines[i].position += lines[i].velocity * dt

            let sweptLo = min(old, lines[i].position)
            let sweptHi = max(old, lines[i].position)

            for box in boxes {
                let key = box.id.uuidString
                guard !lines[i].crossedKeys.contains(key) else { continue }
                let (lo, hi): (Double, Double)
                switch lines[i].direction {
                case .horizontal:
                    lo = Double(1.0 - box.targetRect.maxY)
                    hi = Double(1.0 - box.targetRect.minY)
                case .vertical:
                    lo = Double(box.targetRect.minX)
                    hi = Double(box.targetRect.maxX)
                }
                if sweptLo <= hi && sweptHi >= lo {
                    lines[i].crossedKeys.insert(key)
                    didPip = true
                }
            }
        }

        if didPip { audio?.triggerPips() }
        lines.removeAll { $0.position < -0.08 || $0.position > 1.08 }
    }

    @MainActor
    private func spawnLines() {
        let speedMult = trackingState?.scanLineSpeed ?? 1.0
        let baseH = Double.random(in: 0.10...0.28) * speedMult
        let baseV = Double.random(in: 0.10...0.28) * speedMult

        let fromTop = Bool.random()
        lines.append(ScanLine(
            position: fromTop ? -0.02 : 1.02,
            velocity: fromTop ? baseH : -baseH,
            thickness: Double.random(in: 0.8...1.8),
            direction: .horizontal
        ))

        let fromLeft = Bool.random()
        lines.append(ScanLine(
            position: fromLeft ? -0.02 : 1.02,
            velocity: fromLeft ? baseV : -baseV,
            thickness: Double.random(in: 0.8...1.8),
            direction: .vertical
        ))

        audio?.triggerBeep(frequency: 5000.0)
    }
}
