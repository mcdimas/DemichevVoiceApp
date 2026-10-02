import Foundation
import CoreML
import AVFoundation
@preconcurrency import WhisperKit
@preconcurrency import FluidAudio

protocol SpeechRecognizing: Sendable {
    func load(_ model: SpeechModel, directory: URL) async throws
    func recognize(_ file: URL, language: SpeechLanguage) async throws -> String
    func unload() async throws
}

actor RecognitionEngine: SpeechRecognizing {
    private var whisper: WhisperKit?
    private var parakeet: AsrManager?
    private var active: SpeechModel?
    private var occupied = false

    func load(_ model: SpeechModel, directory: URL) async throws {
        guard !occupied else { throw VoiceError("Распознавание ещё завершается.") }
        occupied = true
        defer { occupied = false }
        try Task.checkCancellation()
        await releaseModels()
        try Task.checkCancellation()
        do {
        switch model {
        case .whisper:
            let options = WhisperKitConfig(modelFolder: directory.path, tokenizerFolder: directory,
                verbose: false, logLevel: .none, prewarm: true, load: true, download: false)
            whisper = try await WhisperKit(options)
        case .parakeet:
            func compiled(_ name: String, cpu: Bool = false) throws -> MLModel {
                try Task.checkCancellation()
                let options = MLModelConfiguration()
                options.computeUnits = cpu ? .cpuOnly : .cpuAndNeuralEngine
                return try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: options)
            }
            let words = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("parakeet_v3_vocab.json")))
            var vocabulary: [Int: String] = [:]
            for (key, word) in words { if let number = Int(key) { vocabulary[number] = word } }
            guard vocabulary.count >= 8192 else { throw VoiceError("Неполный словарь модели.") }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try AsrModels(encoder: compiled("Encoder_v2"), preprocessor: compiled("Preprocessor", cpu: true),
                decoder: compiled("Decoder"), joint: compiled("JointDecisionv3"), configuration: configuration, vocabulary: vocabulary, version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            parakeet = manager
        }
        try Task.checkCancellation()
        active = model
        } catch { await releaseModels(); throw error }
    }

    func recognize(_ file: URL, language: SpeechLanguage) async throws -> String {
        guard !occupied, active != nil else { throw VoiceError("Модель ещё не готова.") }
        occupied = true
        defer { occupied = false }
        try Task.checkCancellation()
        try Self.validateAudio(file)
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(file)
        try Task.checkCancellation()
        guard samples.count <= 16_000 * 600 else { throw VoiceError("Максимальная длина записи — 10 минут.") }
        guard Self.containsSignal(samples) else { return "" }
        let text: String
        if let parakeet {
            var decoder = try TdtDecoderState()
            let hint: Language? = language == .russian ? .russian : language == .english ? .english : nil
            text = try await parakeet.transcribe(samples, decoderState: &decoder, language: hint).text
        } else if let whisper {
            let options = DecodingOptions(language: language.code, detectLanguage: language == .automatic,
                skipSpecialTokens: true, suppressBlank: true, concurrentWorkerCount: 1, chunkingStrategy: .vad)
            text = try await whisper.transcribe(audioArray: samples, decodeOptions: options).map(\.text).joined(separator: " ")
        } else { throw VoiceError("Модель не загружена.") }
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func containsSignal(_ samples: [Float]) -> Bool {
        guard samples.count >= 4_000 else { return false }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return energy.isFinite && energy > 0.00000001
    }

    nonisolated static func validateAudio(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0, file.processingFormat.sampleRate <= 192_000,
              file.length >= 0, Double(file.length) / file.processingFormat.sampleRate <= 600,
              file.processingFormat.channelCount > 0, file.processingFormat.channelCount <= 32 else {
            throw VoiceError("Неподдерживаемая запись или длительность больше 10 минут.")
        }
    }

    func unload() async throws {
        guard !occupied else { throw VoiceError("Дождитесь завершения распознавания.") }
        occupied = true
        defer { occupied = false }
        await releaseModels()
    }
    private func releaseModels() async {
        active = nil
        if let whisper { await whisper.unloadModels() }
        if let parakeet { await parakeet.cleanup() }
        whisper = nil; parakeet = nil; active = nil
    }
}
