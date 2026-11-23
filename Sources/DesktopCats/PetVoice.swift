import AVFoundation

@MainActor
final class PetVoice {
    enum Cue: Hashable {
        case murmur, purr
    }

    static let shared = PetVoice()
    private var sounds: [Cue: Data] = [:]
    private var player: AVAudioPlayer?

    func play(_ cue: Cue) {
        guard player?.isPlaying != true else { return }
        let sound = sounds[cue] ?? Self.waveform(cue)
        sounds[cue] = sound
        guard let next = try? AVAudioPlayer(data: sound, fileTypeHint: AVFileType.wav.rawValue),
              next.play() else { return }
        player = next
    }

    func stop() {
        player?.stop()
        player = nil
    }

    static func waveform(_ cue: Cue) -> Data {
        let rate = 22_050
        let frames = Int(Double(rate) * (cue == .purr ? 2.65 : 0.46))
        let tau = 2 * Double.pi
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        var phase = 0.0, air = 0.0
        var seed: UInt32 = 0x43b1
        for frame in 0..<frames {
            let t = Double(frame) / Double(rate)
            let remaining = Double(frames - 1 - frame) / Double(rate)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            air += 0.15 * (Double(seed) / Double(UInt32.max) * 2 - 1 - air)
            let voice: Double, attack: Double, release: Double
            switch cue {
            case .murmur:
                let pitch = 187 + 66 * sin(.pi * min(1, t / 0.36)) - 43 * t / 0.46
                phase += tau * pitch / Double(rate)
                let hum = 0.50 * sin(phase) + 0.25 * sin(2 * phase) + 0.12 * sin(3 * phase)
                voice = 0.22 * (hum + 0.06 * air) * exp(-2.6 * t)
                attack = 0.055; release = 0.13
            case .purr:
                // A purr keeps pulsing through both halves of the breath, with a soft dip at the turn.
                let breath = sin(tau * t / 2.1 + 0.25)
                let pitch = 25.8 + 1.6 * breath + 0.35 * sin(tau * 3.2 * t)
                phase += tau * pitch / Double(rate)
                let low = 0.19 * sin(phase) + 0.27 * sin(2 * phase) + 0.24 * sin(3 * phase)
                let rasp = 0.15 * sin(4 * phase) + 0.10 * sin(5 * phase) + 0.05 * sin(7 * phase)
                let flow = 0.31 + 0.69 * abs(breath)
                voice = 0.21 * flow * (low + rasp + 0.15 * air * (0.5 + 0.5 * cos(phase)))
                attack = 0.23; release = 0.34
            }
            let edge = min(1, t / attack, remaining / release)
            let gain = edge * edge * (3 - 2 * edge)
            samples.append(Int16((voice * gain * Double(Int16.max)).rounded()).littleEndian)
        }

        var wave = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) }
        }
        let bytes = UInt32(frames * MemoryLayout<Int16>.size)
        wave.append(contentsOf: "RIFF".utf8); append(UInt32(36) + bytes)
        wave.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate))
        append(UInt32(2 * rate)); append(UInt16(2)); append(UInt16(16))
        wave.append(contentsOf: "data".utf8); append(bytes)
        samples.withUnsafeBytes { wave.append(contentsOf: $0) }
        return wave
    }
}
