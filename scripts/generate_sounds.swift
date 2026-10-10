#!/usr/bin/env swift
// Synthesizes sounds that aren't recordings into WhiteNoise/Sounds/:
//   Big Sur        - pink noise: classic 1/f noise, independent per channel for a wide stereo image
//   Niagara        - brown noise: deeper 1/f² noise (integrated white noise), subsonic drift filtered out
//   Inari          - Nordic forest: gusty leaf rustle, low wind, sparse songbirds, a distant cuckoo
//   Serengeti      - savanna night: warm grass wind, a cricket chorus that comes and goes, distant frogs
//   Tasmania       - island rain: pink-noise rain hiss with slow intensity drift, droplets, valley rumble, distant thunder
// Each track is `trackMinutes` long, levelled to `targetLoudnessDB`, and its end is crossfaded into its start.
// Output is deterministic (fixed seeds), so rebuilding gives the same audio.
// Usage (from the repo root): swift -O scripts/generate_sounds.swift [--force]

import AVFoundation
import Foundation

let sampleRate = 44_100.0
let trackMinutes = 10.0
let crossfadeSeconds = 2.0
let targetLoudnessDB = -20.0
let peakCeiling: Float = 0.89
let bitRate = 96_000

// MARK: - Building blocks

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in -1..<1.
    mutating func white() -> Float { Float(unit() * 2 - 1) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
}

/// Paul Kellet's refined pink-noise filter.
struct PinkFilter {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

    mutating func process(_ white: Float) -> Float {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.11
    }
}

struct OnePoleLowPass {
    let a: Float
    var y: Float = 0
    init(cutoff: Double) { a = Float(exp(-2 * Double.pi * cutoff / sampleRate)) }
    mutating func process(_ x: Float) -> Float { y = (1 - a) * x + a * y; return y }
}

struct OnePoleHighPass {
    var lowPass: OnePoleLowPass
    init(cutoff: Double) { lowPass = OnePoleLowPass(cutoff: cutoff) }
    mutating func process(_ x: Float) -> Float { x - lowPass.process(x) }
}

protocol StereoSynth {
    mutating func next() -> (Float, Float)
}

/// A short pitched sound (bird chirp, cuckoo note, frog croak) scheduled at a fixed frame.
struct Tone {
    var start: Int
    var length: Int
    var f0: Double
    var f1: Double
    var amp: Float
    var pan: Float
    /// Amplitude pulses per second inside the tone (frog croaks); 0 for a smooth tone.
    var pulseHz: Double = 0
    var vibratoHz: Double = 0
    var vibratoDepth: Double = 0
    /// Mix of 2nd and 3rd harmonics, for buzzier tones.
    var harmonics: Float = 0
}

/// Plays a pre-scheduled list of tones, mixing whichever are sounding at each frame.
struct ToneVoices {
    private let tones: [Tone]
    private var nextIndex = 0
    private var active: [(tone: Tone, phase: Double)] = []

    init(_ tones: [Tone]) { self.tones = tones.sorted { $0.start < $1.start } }

    mutating func render(frame: Int) -> (Float, Float) {
        while nextIndex < tones.count, tones[nextIndex].start <= frame {
            active.append((tones[nextIndex], 0))
            nextIndex += 1
        }
        var left: Float = 0, right: Float = 0
        var i = 0
        while i < active.count {
            let tone = active[i].tone
            let k = frame - tone.start
            if k >= tone.length {
                active.swapAt(i, active.count - 1)
                active.removeLast()
                continue
            }
            let x = Double(k) / Double(tone.length)
            let t = Double(k) / sampleRate
            var f = tone.f0 + (tone.f1 - tone.f0) * x
            if tone.vibratoDepth > 0 { f *= 1 + tone.vibratoDepth * sin(2 * .pi * tone.vibratoHz * t) }
            active[i].phase += 2 * .pi * f / sampleRate
            let p = active[i].phase
            var s = Float(sin(p))
            if tone.harmonics > 0 { s += tone.harmonics * Float(sin(2 * p)) + tone.harmonics * 0.6 * Float(sin(3 * p)) }
            var envelope = Float(sin(.pi * x))
            envelope *= envelope
            if tone.pulseHz > 0 {
                let pulse = Float(sin(.pi * tone.pulseHz * t))
                envelope *= pulse * pulse
            }
            let v = s * envelope * tone.amp
            left += v * (1 - tone.pan)
            right += v * tone.pan
            i += 1
        }
        return (left, right)
    }
}

/// Slow, smooth swell between roughly 0.2 and 1 built from a few unrelated sine periods.
struct Gusts {
    let parts: [(period: Double, depth: Double, phase: Double)]

    init(_ rng: inout SplitMix64, periods: [Double]) {
        let depths = [0.25, 0.15, 0.1, 0.08]
        parts = periods.enumerated().map { ($1, depths[min($0, depths.count - 1)], rng.range(0...6.28)) }
    }

    func level(at t: Double) -> Double {
        var v = 0.55
        for p in parts { v += p.depth * sin(2 * .pi * t / p.period + p.phase) }
        return max(0.15, v)
    }
}

func scheduleFrame(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

// MARK: - Sounds

struct PinkNoise: StereoSynth {
    var rng = SplitMix64(state: 0x5EED_0001)
    var left = PinkFilter(), right = PinkFilter()

    mutating func next() -> (Float, Float) {
        (left.process(rng.white()), right.process(rng.white()))
    }
}

struct BrownNoise: StereoSynth {
    var rng = SplitMix64(state: 0x5EED_0004)
    var left: Float = 0, right: Float = 0
    var highPassL = OnePoleHighPass(cutoff: 20), highPassR = OnePoleHighPass(cutoff: 20)

    mutating func next() -> (Float, Float) {
        left = 0.998 * left + rng.white() * 0.04
        right = 0.998 * right + rng.white() * 0.04
        return (highPassL.process(left), highPassR.process(right))
    }
}

struct Forest: StereoSynth {
    var rng = SplitMix64(state: 0x5EED_0005)
    var frame = 0
    var pinkL = PinkFilter(), pinkR = PinkFilter()
    var leafHighPassL = OnePoleHighPass(cutoff: 600), leafHighPassR = OnePoleHighPass(cutoff: 600)
    var leafLowPassL = OnePoleLowPass(cutoff: 7000), leafLowPassR = OnePoleLowPass(cutoff: 7000)
    var flutterL = OnePoleLowPass(cutoff: 4), flutterR = OnePoleLowPass(cutoff: 4)
    var brownL: Float = 0, brownR: Float = 0
    var windLowPassL = OnePoleLowPass(cutoff: 200), windLowPassR = OnePoleLowPass(cutoff: 200)
    let gusts: Gusts
    var calls: ToneVoices

    init(totalSeconds: Double) {
        var setup = SplitMix64(state: 0x5EED_0006)
        gusts = Gusts(&setup, periods: [11, 29, 53])
        var tones: [Tone] = []

        // Songbirds: short phrases of 2-6 chirps from a random spot in the trees.
        var t = setup.range(2...6)
        while t < totalSeconds - 4 {
            let pan = Float(setup.range(0.1...0.9))
            let amp = Float(setup.range(0.08...0.24))
            let base = setup.range(2500...4500)
            var c = t
            for _ in 0..<Int(setup.range(2...6.99)) {
                let length = setup.range(0.06...0.16)
                let f0 = base * setup.range(0.9...1.15)
                tones.append(Tone(start: scheduleFrame(c), length: scheduleFrame(length), f0: f0, f1: f0 * setup.range(0.7...1.35),
                                  amp: amp, pan: pan, vibratoHz: setup.range(30...60), vibratoDepth: 0.02))
                c += length + setup.range(0.04...0.14)
            }
            t += setup.range(3...10)
        }

        // A distant cuckoo: a few "cu-ckoo" calls, a falling minor third.
        t = setup.range(25...50)
        while t < totalSeconds - 8 {
            let pan = Float(setup.range(0.15...0.85))
            let amp = Float(setup.range(0.13...0.24))
            var c = t
            for _ in 0..<Int(setup.range(2...5.99)) {
                tones.append(Tone(start: scheduleFrame(c), length: scheduleFrame(0.22), f0: 690, f1: 672, amp: amp, pan: pan))
                tones.append(Tone(start: scheduleFrame(c + 0.3), length: scheduleFrame(0.32), f0: 578, f1: 560, amp: amp * 0.9, pan: pan))
                c += setup.range(0.85...1.0)
            }
            t += setup.range(45...90)
        }
        calls = ToneVoices(tones)
    }

    mutating func next() -> (Float, Float) {
        let t = Double(frame) / sampleRate
        let gust = Float(gusts.level(at: t))
        let rustleL = 1 + 0.5 * max(-1, min(1, flutterL.process(rng.white()) * 60))
        let rustleR = 1 + 0.5 * max(-1, min(1, flutterR.process(rng.white()) * 60))
        let leavesL = leafLowPassL.process(leafHighPassL.process(pinkL.process(rng.white()))) * gust * rustleL
        let leavesR = leafLowPassR.process(leafHighPassR.process(pinkR.process(rng.white()))) * gust * rustleR

        brownL = 0.998 * brownL + rng.white() * 0.04
        brownR = 0.998 * brownR + rng.white() * 0.04
        let windL = windLowPassL.process(brownL) * 0.3 * (0.6 + 0.4 * gust)
        let windR = windLowPassR.process(brownR) * 0.3 * (0.6 + 0.4 * gust)

        let (birdL, birdR) = calls.render(frame: frame)
        frame += 1
        return (leavesL + windL + birdL, leavesR + windR + birdR)
    }
}

struct SavannaNight: StereoSynth {
    struct Cricket {
        let step: Double
        var phase: Double = 0
        let chirpPeriod: Double
        let pulses: Double
        let pulseRate: Double
        let offset: Double
        let amp: Float
        let pan: Float
        let activityPeriod: Double
        let activityPhase: Double
    }

    var rng = SplitMix64(state: 0x5EED_0007)
    var frame = 0
    var pinkL = PinkFilter(), pinkR = PinkFilter()
    var grassLowPassL = OnePoleLowPass(cutoff: 1800), grassLowPassR = OnePoleLowPass(cutoff: 1800)
    var grassHighPassL = OnePoleHighPass(cutoff: 150), grassHighPassR = OnePoleHighPass(cutoff: 150)
    let gusts: Gusts
    var crickets: [Cricket]
    var frogs: ToneVoices

    init(totalSeconds: Double) {
        var setup = SplitMix64(state: 0x5EED_0008)
        gusts = Gusts(&setup, periods: [13, 31, 61])
        crickets = (0..<7).map { _ in
            Cricket(step: 2 * .pi * setup.range(3800...5200) / sampleRate,
                    chirpPeriod: setup.range(0.35...0.7),
                    pulses: Double(Int(setup.range(3...5.99))),
                    pulseRate: setup.range(25...40),
                    offset: setup.range(0...1),
                    amp: Float(setup.range(0.007...0.019)),
                    pan: Float(setup.range(0.05...0.95)),
                    activityPeriod: setup.range(20...60),
                    activityPhase: setup.range(0...6.28))
        }

        // Frogs: buzzy, pulsed croaks a little way off.
        var tones: [Tone] = []
        var t = setup.range(1...3)
        while t < totalSeconds - 3 {
            let pan = Float(setup.range(0.1...0.9))
            let amp = Float(setup.range(0.08...0.18))
            let f = setup.range(350...650)
            var c = t
            for _ in 0..<Int(setup.range(1...3.99)) {
                let length = setup.range(0.12...0.25)
                tones.append(Tone(start: scheduleFrame(c), length: scheduleFrame(length), f0: f, f1: f * 0.92,
                                  amp: amp, pan: pan, pulseHz: setup.range(35...60), harmonics: 0.6))
                c += length + setup.range(0.08...0.2)
            }
            t += setup.range(1.5...5)
        }
        frogs = ToneVoices(tones)
    }

    mutating func next() -> (Float, Float) {
        let t = Double(frame) / sampleRate
        let gust = Float(gusts.level(at: t))
        let grassL = grassHighPassL.process(grassLowPassL.process(pinkL.process(rng.white()))) * gust * 0.45
        let grassR = grassHighPassR.process(grassLowPassR.process(pinkR.process(rng.white()))) * gust * 0.45

        var chorusL: Float = 0, chorusR: Float = 0
        for i in crickets.indices {
            crickets[i].phase += crickets[i].step
            let c = crickets[i]
            // Each cricket fades in and out over tens of seconds so the chorus breathes.
            let activity = max(0, min(1, (sin(2 * .pi * t / c.activityPeriod + c.activityPhase) + 0.3) / 0.6))
            guard activity > 0 else { continue }
            let inChirp = (t + c.offset).truncatingRemainder(dividingBy: c.chirpPeriod)
            guard inChirp < c.pulses / c.pulseRate else { continue }
            let pulse = sin(.pi * (inChirp * c.pulseRate).truncatingRemainder(dividingBy: 1))
            let v = Float(sin(c.phase) * pulse * pulse * activity) * c.amp
            chorusL += v * (1 - c.pan)
            chorusR += v * c.pan
        }

        let (frogL, frogR) = frogs.render(frame: frame)
        frame += 1
        return (grassL + chorusL + frogL, grassR + chorusR + frogR)
    }
}

struct MountainRain: StereoSynth {
    struct Drop {
        var phase: Float
        let step: Float
        var amp: Float
        let decay: Float
        let pan: Float
    }

    var rng = SplitMix64(state: 0x5EED_0002)
    var frame = 0

    // Rain hiss: pink noise with the lows taken out, gently brightened.
    var pinkL = PinkFilter(), pinkR = PinkFilter()
    var hissHighPassL = OnePoleHighPass(cutoff: 350), hissHighPassR = OnePoleHighPass(cutoff: 350)
    let drift: [(period: Double, depth: Double, phase: Double)]

    // Droplets hitting rocks and leaves.
    let dropsPerSecond = 28.0
    var drops: [Drop] = []

    // Low valley rumble and distant thunder share a brown-noise source.
    var brownL: Float = 0, brownR: Float = 0
    var rumbleLowPassL = OnePoleLowPass(cutoff: 140), rumbleLowPassR = OnePoleLowPass(cutoff: 140)
    let thunder: [(start: Double, attack: Double, decay: Double, level: Double)]

    init(totalSeconds: Double) {
        var setup = SplitMix64(state: 0x5EED_0003)
        drift = [(17, 0.22, setup.range(0...6.28)), (7.3, 0.12, setup.range(0...6.28)), (41, 0.15, setup.range(0...6.28))]
        var events: [(Double, Double, Double, Double)] = []
        var t = setup.range(20...45)
        while t < totalSeconds - 25 {
            events.append((t, setup.range(1.2...2.5), setup.range(3.5...7), setup.range(0.6...1.0)))
            t += setup.range(55...110)
        }
        thunder = events
    }

    func thunderEnvelope(at t: Double) -> Double {
        var level = 0.0
        for event in thunder where t >= event.start && t < event.start + event.attack + event.decay * 6 {
            let x = t - event.start
            let shape = x < event.attack
                ? pow(sin(x / event.attack * .pi / 2), 2)
                : exp(-(x - event.attack) / event.decay)
            // Rolling: thunder rumbles in a few uneven swells rather than one smooth hump.
            let roll = 0.65 + 0.35 * sin(x * 2.1 + event.start) * sin(x * 0.9 + event.start * 0.37)
            level += shape * roll * event.level
        }
        return level
    }

    mutating func next() -> (Float, Float) {
        let t = Double(frame) / sampleRate
        frame += 1

        var intensity = 1.0
        for d in drift { intensity += d.depth * sin(2 * .pi * t / d.period + d.phase) }
        let hissL = hissHighPassL.process(pinkL.process(rng.white())) * Float(intensity)
        let hissR = hissHighPassR.process(pinkR.process(rng.white())) * Float(intensity)

        if rng.unit() < dropsPerSecond * intensity / sampleRate {
            let size = Float(pow(rng.unit(), 2.5))
            drops.append(Drop(
                phase: 0,
                step: Float(2 * .pi * rng.range(1800...5200) / sampleRate),
                amp: 0.004 + 0.03 * size,
                decay: Float(exp(-1 / (rng.range(0.002...0.009) * sampleRate))),
                pan: Float(rng.unit())
            ))
        }
        var dropL: Float = 0, dropR: Float = 0
        var i = 0
        while i < drops.count {
            let s = sin(drops[i].phase) * drops[i].amp
            dropL += s * (1 - drops[i].pan)
            dropR += s * drops[i].pan
            drops[i].phase += drops[i].step
            drops[i].amp *= drops[i].decay
            if drops[i].amp < 0.00005 { drops.swapAt(i, drops.count - 1); drops.removeLast() } else { i += 1 }
        }

        brownL = 0.998 * brownL + rng.white() * 0.04
        brownR = 0.998 * brownR + rng.white() * 0.04
        let rumbleL = rumbleLowPassL.process(brownL), rumbleR = rumbleLowPassR.process(brownR)
        let rumbleLevel = Float(0.35 + 2.2 * thunderEnvelope(at: t))

        return (hissL + dropL + rumbleL * rumbleLevel, hissR + dropR + rumbleR * rumbleLevel)
    }
}

// MARK: - Rendering

func failure(_ message: String) -> NSError {
    NSError(domain: "generate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Renders `make()` twice: once to measure loudness, once to write the levelled, loop-crossfaded track.
func render<S: StereoSynth>(_ make: () -> S, to output: URL) throws {
    let total = Int(trackMinutes * 60 * sampleRate)
    let fade = Int(crossfadeSeconds * sampleRate)

    var synth = make()
    var sumSquares = 0.0
    var peak: Float = 0
    for _ in 0..<(total + fade) {
        let (l, r) = synth.next()
        sumSquares += Double(l * l + r * r)
        peak = max(peak, abs(l), abs(r))
    }
    let rms = (sumSquares / Double(2 * (total + fade))).squareRoot()
    let gain = min(Float(pow(10, targetLoudnessDB / 20) / rms), peakCeiling / peak)

    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw failure("cannot create format")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: bitRate,
    ]
    let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunkSize = AVAudioFrameCount(sampleRate)
    guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
        throw failure("cannot allocate buffer")
    }
    func append(_ l: Float, _ r: Float) throws {
        let i = Int(chunk.frameLength)
        chunk.floatChannelData![0][i] = l
        chunk.floatChannelData![1][i] = r
        chunk.frameLength += 1
        if chunk.frameLength == chunkSize {
            try file.write(from: chunk)
            chunk.frameLength = 0
        }
    }

    // The first `fade` frames are held back and blended into the last `fade` frames,
    // so the track's end flows straight into its start.
    synth = make()
    var head: [(Float, Float)] = []
    head.reserveCapacity(fade)
    for _ in 0..<fade { head.append(synth.next()) }
    for _ in fade..<total {
        let (l, r) = synth.next()
        try append(l * gain, r * gain)
    }
    for j in 0..<fade {
        let (l, r) = synth.next()
        let t = Float(j) / Float(fade)
        let out = (1 - t).squareRoot(), into = t.squareRoot()
        try append((l * out + head[j].0 * into) * gain, (r * out + head[j].1 * into) * gain)
    }
    if chunk.frameLength > 0 { try file.write(from: chunk) }
}

let fileManager = FileManager.default
let outputDir = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("WhiteNoise/Sounds")
try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
let force = CommandLine.arguments.contains("--force")
let totalSeconds = trackMinutes * 60 + crossfadeSeconds

let sounds: [(String, (URL) throws -> Void)] = [
    ("Big Sur", { try render({ PinkNoise() }, to: $0) }),
    ("Niagara", { try render({ BrownNoise() }, to: $0) }),
    ("Tasmania", { try render({ MountainRain(totalSeconds: totalSeconds) }, to: $0) }),
    ("Inari", { try render({ Forest(totalSeconds: totalSeconds) }, to: $0) }),
    ("Serengeti", { try render({ SavannaNight(totalSeconds: totalSeconds) }, to: $0) }),
]

var failures = 0
for (name, build) in sounds {
    let output = outputDir.appendingPathComponent(name).appendingPathExtension("m4a")
    if fileManager.fileExists(atPath: output.path) {
        guard force else {
            print("skip     \(name) (already built, use --force to rebuild)")
            continue
        }
        try fileManager.removeItem(at: output)
    }
    do {
        try build(output)
        print("done     \(name).m4a")
    } catch {
        failures += 1
        try? fileManager.removeItem(at: output)
        print("FAILED   \(name): \(error.localizedDescription)")
    }
}
exit(failures == 0 ? 0 : 1)
