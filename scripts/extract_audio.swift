#!/usr/bin/env swift
// Turns every recording into a long, seamlessly looping .m4a in WhiteNoise/Sounds/.
// 1. Each video in SourceVideos/ (git-ignored) has its audio track copied, untouched, to SourceAudio/<name>.m4a.
// 2. Each file in SourceAudio/ (committed) is trimmed, its end crossfaded into its start, its loudness
//    levelled to `targetLoudnessDB`, and that loop repeated to fill `trackMinutes`.
// Audio-only recordings (.m4a/.mp3/.wav/...) can be dropped straight into SourceAudio/.
// scripts/trims.json can keep only part of a clip, e.g. { "Annapurna": { "start": 1.3, "end": 4.0 } } (seconds).
// Usage (from the repo root): swift scripts/extract_audio.swift [--force]
//   --force  rebuild sounds that already exist

import AVFoundation
import Foundation

let trackMinutes = 10.0
let crossfadeSeconds = 1.0
let bitRate = 96_000
let targetLoudnessDB = -20.0
let peakCeiling: Float = 0.89  // about -1 dBFS, leaves headroom for AAC encoding

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let videoDir = root.appendingPathComponent("SourceVideos")
let sourceDir = root.appendingPathComponent("SourceAudio")
let outputDir = root.appendingPathComponent("WhiteNoise/Sounds")
let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]
let force = CommandLine.arguments.contains("--force")

struct Trim: Decodable {
    var start: Double?
    var end: Double?
}

let trimsFile = root.appendingPathComponent("scripts/trims.json")
let trims: [String: Trim] = try fileManager.fileExists(atPath: trimsFile.path)
    ? JSONDecoder().decode([String: Trim].self, from: Data(contentsOf: trimsFile))
    : [:]

func files(in dir: URL, withExtensions extensions: Set<String>) throws -> [URL] {
    guard fileManager.fileExists(atPath: dir.path) else { return [] }
    return try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "extract", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Copies the video's audio track into an .m4a without re-encoding when possible.
func extractAudio(from video: URL, to output: URL) async throws {
    let asset = AVURLAsset(url: video)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
        throw failure("no audio track")
    }
    for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
        do {
            try await session.export(to: output, as: .m4a)
            return
        } catch {
            try? fileManager.removeItem(at: output)
        }
    }
    throw failure("cannot export audio")
}

/// Returns one loop of the clip whose last `fade` frames blend into its first `fade` frames,
/// so playing it back-to-back has no audible seam.
func seamlessLoop(from clip: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    let format = clip.format
    let n = Int(clip.frameLength)
    let fade = min(Int(crossfadeSeconds * format.sampleRate), n / 4)
    let length = n - fade
    guard fade > 0, let loop = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else {
        throw failure("clip is too short")
    }
    loop.frameLength = AVAudioFrameCount(length)

    for channel in 0..<Int(format.channelCount) {
        let src = clip.floatChannelData![channel]
        let dst = loop.floatChannelData![channel]
        for i in 0..<length {
            dst[i] = src[fade + i]
        }
        for j in 0..<fade {
            let t = Float(j) / Float(fade)
            dst[length - fade + j] = src[n - fade + j] * (1 - t).squareRoot() + src[j] * t.squareRoot()
        }
    }
    return loop
}

/// Scales the buffer so its RMS level hits `targetLoudnessDB`, without letting peaks pass `peakCeiling`.
/// Returns the applied gain in dB.
@discardableResult
func levelLoudness(_ buffer: AVAudioPCMBuffer) -> Double {
    let channels = Int(buffer.format.channelCount)
    let n = Int(buffer.frameLength)
    var sumSquares = 0.0
    var peak: Float = 0
    for channel in 0..<channels {
        let data = buffer.floatChannelData![channel]
        for i in 0..<n {
            sumSquares += Double(data[i] * data[i])
            peak = max(peak, abs(data[i]))
        }
    }
    let rms = (sumSquares / Double(channels * n)).squareRoot()
    guard rms > 0, peak > 0 else { return 0 }
    let wanted = Float(pow(10, targetLoudnessDB / 20) / rms)
    let gain = min(wanted, peakCeiling / peak)
    for channel in 0..<channels {
        let data = buffer.floatChannelData![channel]
        for i in 0..<n { data[i] *= gain }
    }
    return 20 * log10(Double(gain))
}

func buildTrack(from audio: URL, to output: URL, trim: Trim?) throws {
    let input = try AVAudioFile(forReading: audio)
    let format = input.processingFormat
    let total = input.length
    let first = min(total, AVAudioFramePosition((trim?.start ?? 0) * format.sampleRate))
    let last = min(total, trim?.end.map { AVAudioFramePosition($0 * format.sampleRate) } ?? total)
    guard last > first,
          let clip = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else {
        throw failure("trim leaves no audio")
    }
    input.framePosition = first
    try input.read(into: clip, frameCount: AVAudioFrameCount(last - first))
    let loop = try seamlessLoop(from: clip)
    levelLoudness(loop)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVEncoderBitRateKey: bitRate,
    ]
    let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let targetFrames = trackMinutes * 60 * format.sampleRate
    let repeats = max(1, Int((targetFrames / Double(loop.frameLength)).rounded()))
    for _ in 0..<repeats {
        try file.write(from: loop)
    }
}

try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

var failures = 0

let existingSources = Set(try files(in: sourceDir, withExtensions: audioExtensions).map {
    $0.deletingPathExtension().lastPathComponent
})
for video in try files(in: videoDir, withExtensions: videoExtensions) {
    let name = video.deletingPathExtension().lastPathComponent
    guard !existingSources.contains(name) else { continue }
    let audio = sourceDir.appendingPathComponent(name).appendingPathExtension("m4a")
    do {
        try await extractAudio(from: video, to: audio)
        print("audio    SourceAudio/\(name).m4a")
    } catch {
        failures += 1
        print("FAILED   \(name): \(error.localizedDescription)")
    }
}

let sources = try files(in: sourceDir, withExtensions: audioExtensions)
if sources.isEmpty {
    print("No recordings found. Add videos to SourceVideos/ or audio files to SourceAudio/, then run this from the repo root.")
    exit(failures == 0 ? 0 : 1)
}

for source in sources {
    let name = source.deletingPathExtension().lastPathComponent
    let output = outputDir.appendingPathComponent(name).appendingPathExtension("m4a")
    if fileManager.fileExists(atPath: output.path) {
        guard force else {
            print("skip     \(name) (already built, use --force to rebuild)")
            continue
        }
        try fileManager.removeItem(at: output)
    }
    do {
        try buildTrack(from: source, to: output, trim: trims[name])
        print("done     \(name).m4a")
    } catch {
        failures += 1
        try? fileManager.removeItem(at: output)
        print("FAILED   \(name): \(error.localizedDescription)")
    }
}

exit(failures == 0 ? 0 : 1)
