#!/usr/bin/env swift
// Turns every video in SourceVideos/ into a long, seamlessly looping .m4a in WhiteNoise/Sounds/.
// The clip's end is crossfaded into its start, its loudness is levelled to `targetLoudnessDB`,
// and that loop is repeated to fill `trackMinutes`.
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
let inputDir = root.appendingPathComponent("SourceVideos")
let outputDir = root.appendingPathComponent("WhiteNoise/Sounds")
let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
let force = CommandLine.arguments.contains("--force")

struct Trim: Decodable {
    var start: Double?
    var end: Double?
}

let trimsFile = root.appendingPathComponent("scripts/trims.json")
let trims: [String: Trim] = try fileManager.fileExists(atPath: trimsFile.path)
    ? JSONDecoder().decode([String: Trim].self, from: Data(contentsOf: trimsFile))
    : [:]

guard fileManager.fileExists(atPath: inputDir.path) else {
    print("No SourceVideos/ folder found. Create it and add your videos, then run this from the repo root.")
    exit(1)
}

try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

let videos = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)
    .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

if videos.isEmpty {
    print("No .mp4/.mov/.m4v files in SourceVideos/.")
    exit(0)
}

func failure(_ message: String) -> NSError {
    NSError(domain: "extract", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func extractAudio(from video: URL, to output: URL) async throws {
    let asset = AVURLAsset(url: video)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
        throw failure("no audio track")
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw failure("cannot create export session")
    }
    try await session.export(to: output, as: .m4a)
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

let tempDir = fileManager.temporaryDirectory.appendingPathComponent("whitenoise-extract-\(UUID().uuidString)")
try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: tempDir) }

var failures = 0
for video in videos {
    let name = video.deletingPathExtension().lastPathComponent
    let output = outputDir.appendingPathComponent(name).appendingPathExtension("m4a")
    if fileManager.fileExists(atPath: output.path) {
        guard force else {
            print("skip     \(name) (already built, use --force to rebuild)")
            continue
        }
        try fileManager.removeItem(at: output)
    }
    let raw = tempDir.appendingPathComponent(name).appendingPathExtension("m4a")
    do {
        try await extractAudio(from: video, to: raw)
        try buildTrack(from: raw, to: output, trim: trims[name])
        print("done     \(name).m4a")
    } catch {
        failures += 1
        try? fileManager.removeItem(at: output)
        print("FAILED   \(name): \(error.localizedDescription)")
    }
}

try? fileManager.removeItem(at: tempDir)
exit(failures == 0 ? 0 : 1)
