//
//  IkedaAudioEngine.swift
//  test02
//
//  スキャンライン出現: 5000Hz「ピッ」(largeHall リバーブ)
//  ボックス横断: 10000Hz「ピッピッ」ゲートバースト
//

import AVFoundation
import Combine

final class AudioParams: @unchecked Sendable {
    var sineFreq: Double = 5000.0
    var sineEnv: Double = 0.0
    var pipBurstRemaining: Double = 0.0
}

final class IkedaAudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let params = AudioParams()

    func start() {
        configureSession()
        buildGraph()
        tryStart()
    }

    func reactivate() {
        configureSession()
        if !engine.isRunning { tryStart() }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    private func tryStart() {
        try? engine.start()
    }

    private func buildGraph() {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        var beepPhase = 0.0
        var pipPhase  = 0.0
        var lfoPhase  = 0.0
        let twoPi = 2.0 * Double.pi

        let node = AVAudioSourceNode { [params] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {

                // 5000Hz ビープ（指数減衰）
                params.sineEnv *= 0.9992
                beepPhase += twoPi * params.sineFreq / sampleRate
                if beepPhase > twoPi { beepPhase -= twoPi }
                let beep = sin(beepPhase) * params.sineEnv * 0.30

                // 10000Hz ピップ（12Hz LFO ゲート）
                var pip = 0.0
                if params.pipBurstRemaining > 0 {
                    params.pipBurstRemaining -= 1.0 / sampleRate
                    lfoPhase += twoPi * 12.0 / sampleRate
                    if lfoPhase > twoPi { lfoPhase -= twoPi }
                    let gate = sin(lfoPhase) > 0.2 ? 1.0 : 0.0
                    pipPhase += twoPi * 10000.0 / sampleRate
                    if pipPhase > twoPi { pipPhase -= twoPi }
                    pip = sin(pipPhase) * gate * 0.30
                } else {
                    lfoPhase = 0
                }

                let value = Float(beep + pip)
                for buffer in abl {
                    buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }

        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 65

        engine.attach(node)
        engine.attach(reverb)
        engine.connect(node, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
    }

    func triggerBeep(frequency: Double = 5000.0) {
        params.sineFreq = frequency
        params.sineEnv = 1.0
    }

    func triggerPips() {
        guard params.pipBurstRemaining <= 0 else { return }
        params.pipBurstRemaining = 2.0 / 12.0
    }
}
