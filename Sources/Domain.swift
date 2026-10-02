import Foundation

enum SpeechModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeet, whisper
    var id: String { rawValue }
    var title: String { self == .parakeet ? "Parakeet v3" : "Whisper Turbo" }
    var detail: String { self == .parakeet ? "25 языков · около 632 МБ" : "Многоязычный · около 630 МБ" }
}

enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case russian, english, automatic
    var title: String { switch self { case .russian: "Русский"; case .english: "English"; case .automatic: "Авто" } }
    var code: String? { switch self { case .russian: "ru"; case .english: "en"; case .automatic: nil } }
}

enum RecordingMode: String, CaseIterable, Codable { case hold, toggle }

enum AppStorage {
    static let identifier = "ru.demichev.voice"
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identifier, isDirectory: true)
    }
    static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }
    static var audio: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}

struct VoiceError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct WordReplacement: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var original: String
    var replacement: String
    var enabled = true
}

enum ReplacementPipeline {
    static func apply(_ input: String, rules: [WordReplacement]) -> String {
        // Match all rules against the input once; replacements cannot cascade.
        let sorted = rules.filter { $0.enabled && !$0.original.isEmpty }
            .sorted { $0.original.count > $1.original.count }
        var cursor = input.startIndex
        var output = ""
        func boundary(_ index: String.Index) -> Bool {
            index == input.endIndex || (!input[index].isLetter && !input[index].isNumber && input[index] != "_")
        }
        while cursor < input.endIndex {
            let startsWord = cursor == input.startIndex || boundary(input.index(before: cursor))
            let match = startsWord ? sorted.first { rule in
                guard let end = input.index(cursor, offsetBy: rule.original.count, limitedBy: input.endIndex) else { return false }
                return boundary(end) && input[cursor..<end].compare(rule.original, options: .caseInsensitive) == .orderedSame
            } : nil
            if let match {
                output += match.replacement
                cursor = input.index(cursor, offsetBy: match.original.count)
            } else {
                output.append(input[cursor]); cursor = input.index(after: cursor)
            }
        }
        return output
    }
}

struct VoicePreferences: Codable {
    var model: SpeechModel = .parakeet
    var language: SpeechLanguage = .russian
    var recordingMode: RecordingMode = .hold
    var inputUID = ""
    var replacements: [WordReplacement] = []

    private enum CodingKeys: String, CodingKey { case model, language, recordingMode, inputUID, replacements }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Recover fields independently. An older or damaged key must not erase
        // the user's dictionary or unrelated settings.
        model = (try? values.decode(SpeechModel.self, forKey: .model)) ?? .parakeet
        language = (try? values.decode(SpeechLanguage.self, forKey: .language)) ?? .russian
        recordingMode = (try? values.decode(RecordingMode.self, forKey: .recordingMode)) ?? .hold
        inputUID = (try? values.decode(String.self, forKey: .inputUID)) ?? ""
        replacements = (try? values.decode([WordReplacement].self, forKey: .replacements)) ?? []
        var seen = Set<UUID>()
        replacements = Array(replacements.filter {
            !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.original.count <= 100 && $0.replacement.count <= 300 && seen.insert($0.id).inserted
        }.prefix(200))
    }

    static let key = "independent.preferences.v1"
    static func read(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    func save(_ defaults: UserDefaults) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}
