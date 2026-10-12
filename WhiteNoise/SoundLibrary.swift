import Foundation

struct Sound: Identifiable, Hashable {
    let name: String
    let url: URL

    var id: URL { url }

    var symbol: String {
        if let symbol = Self.customSymbols[name] {
            return symbol
        }
        let lower = name.lowercased()
        for (keywords, symbol) in Self.symbolTable where keywords.contains(where: lower.contains) {
            return symbol
        }
        return "waveform"
    }

    /// Icons for sounds whose names don't describe them (place names, etc.).
    private static let customSymbols: [String: String] = [
        "Inari": "leaf.fill",
        "Kerala": "cloud.rain.fill",
        "Rainier": "waveform",
        "Sentosa": "beach.umbrella.fill",
        "Serengeti": "moon.stars.fill",
        "Tasmania": "cloud.bolt.rain.fill",
        "Yellowstone": "wind",
    ]

    private static let symbolTable: [([String], String)] = [
        (["thunder", "storm"], "cloud.bolt.rain.fill"),
        (["rain", "drizzle"], "cloud.rain.fill"),
        (["ocean", "wave", "sea", "beach", "surf"], "water.waves"),
        (["river", "stream", "creek", "water", "brook"], "drop.fill"),
        (["fire", "camp", "crackl"], "flame.fill"),
        (["plane", "flight", "cabin"], "airplane"),
        (["fan", "air condition"], "fan.fill"),
        (["wind", "breeze"], "wind"),
        (["forest", "bird", "nature", "jungle"], "leaf.fill"),
        (["night", "cricket"], "moon.stars.fill"),
        (["train", "rail"], "tram.fill"),
        (["car", "drive", "road"], "car.fill"),
        (["heart", "womb"], "heart.fill"),
        (["brown", "pink", "white", "noise", "static"], "waveform.path"),
        (["snow", "blizzard"], "snowflake"),
        (["cafe", "coffee"], "cup.and.saucer.fill"),
    ]
}

enum SoundLibrary {
    static let audioExtensions = ["m4a", "mp3", "wav", "caf", "aac"]

    static func load(bundle: Bundle = .main) -> [Sound] {
        audioExtensions
            .flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            .map { Sound(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
