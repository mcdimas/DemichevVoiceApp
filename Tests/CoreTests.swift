import XCTest
import AppKit
@testable import DemichevVoice

final class CatalogTests: XCTestCase {
    private func fixture(_ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: file)
        return file
    }
    func testSHA256RejectsSameLengthCorruption() throws {
        let file = try fixture("hello\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = CatalogFile(relativePath: "weights.bin", sourceURL: URL(string: "https://example.com")!, byteCount: 6,
            digest: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03", algorithm: .sha256)
        XCTAssertTrue(try entry.verify(file))
        try Data("wrong\n".utf8).write(to: file)
        XCTAssertFalse(try entry.verify(file))
        try Data("hello".utf8).write(to: file)
        XCTAssertFalse(try entry.verify(file))
    }
    func testGitBlobHashUsesHeader() throws {
        let file = try fixture("hello\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = CatalogFile(relativePath: "tokenizer.json", sourceURL: URL(string: "https://example.com")!, byteCount: 6,
            digest: "ce013625030ba8dba906f756967f9e9ca394464a", algorithm: .gitSHA1)
        XCTAssertTrue(try entry.verify(file))
    }
    func testManifestPathsCannotEscapeStorage() throws {
        let root = URL(fileURLWithPath: "/tmp/test-model", isDirectory: true)
        for path in ["../outside", "/absolute", "a/../../outside", "a//b", "a\\b", "a/./b"] {
            let entry = CatalogFile(relativePath: path, sourceURL: URL(string: "https://example.com")!, byteCount: 1, digest: "", algorithm: .sha256)
            XCTAssertThrowsError(try entry.destination(under: root), path)
        }
    }
    func testPinnedCatalogsHaveNoMutableRevisionOrDuplicatePath() throws {
        for model in SpeechModel.allCases {
            let catalog = try ModelCatalog.bundled(model)
            XCTAssertGreaterThan(catalog.size, 600_000_000)
            XCTAssertEqual(Set(catalog.files.map(\.relativePath)).count, catalog.files.count)
            for file in catalog.files {
                XCTAssertEqual(file.sourceURL.host, "huggingface.co")
                XCTAssertNotNil(file.sourceURL.path.range(of: "/resolve/[a-f0-9]{40}/", options: .regularExpression))
                XCTAssertEqual(file.digest.count, file.algorithm == .sha256 ? 64 : 40)
                _ = try file.destination(under: ModelStore.folder(model))
            }
        }
    }
    func testDeletingModelPreservesOtherData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["parakeet", "whisper", "unrelated"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("sentinel".utf8).write(to: folder.appendingPathComponent("file"))
        }
        try await ModelStore(root: root).remove(.parakeet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parakeet").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("whisper/file"), encoding: .utf8), "sentinel")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unrelated/file"), encoding: .utf8), "sentinel")
    }
    func testMissingModelCannotDownloadInOfflineMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await ModelStore(root: root).prepare(.parakeet, allowNetwork: false) { _ in }
            XCTFail("Missing weights must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("не установлена")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.folder(.parakeet, root: root).appendingPathComponent(".installed").path))
    }
}

final class TextTests: XCTestCase {
    func testDictionaryPrefersWholeLongestPhraseAndCannotCascade() {
        let rules = [WordReplacement(original: "дом", replacement: "office"),
            WordReplacement(original: "дом света", replacement: "Demichev Voice"), WordReplacement(original: "office", replacement: "wrong")]
        XCTAssertEqual(ReplacementPipeline.apply("ДОМ света, дом и домик.", rules: rules), "Demichev Voice, office и домик.")
    }
    func testDisabledAndLiteralRulesWithUnicode() {
        let rules = [WordReplacement(original: "плюс", replacement: "C++ $1"), WordReplacement(original: "кот", replacement: "dog", enabled: false)]
        XCTAssertEqual(ReplacementPipeline.apply("😀 плюс, кот", rules: rules), "😀 C++ $1, кот")
    }
    func testPasteRejectsChangedTextSelectionProcessOrSecureField() {
        let initial = FieldState(process: 42, value: "abc", selectionStart: 1, selectionLength: 0, secure: false)
        XCTAssertTrue(initial.allowsPaste(from: initial))
        for current in [FieldState(process: 43, value: "abc", selectionStart: 1, selectionLength: 0, secure: false),
            FieldState(process: 42, value: "abd", selectionStart: 1, selectionLength: 0, secure: false),
            FieldState(process: 42, value: "abc", selectionStart: 2, selectionLength: 0, secure: false),
            FieldState(process: 42, value: "abc", selectionStart: 1, selectionLength: 0, secure: true)] {
            XCTAssertFalse(current.allowsPaste(from: initial))
        }
    }
}

@MainActor final class ControllerTests: XCTestCase {
    func testPreferencesAndDictionaryPersistOnlyInChosenSuite() {
        let name = "ru.demichev.voice.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = VoicePreferences()
        settings.model = .whisper; settings.inputUID = "synthetic-input"
        settings.replacements = [.init(original: "тест", replacement: "test")]
        settings.save(defaults)
        let restored = VoicePreferences.read(defaults)
        XCTAssertEqual(restored.model, .whisper)
        XCTAssertEqual(restored.inputUID, "synthetic-input")
        XCTAssertEqual(restored.replacements, settings.replacements)
        XCTAssertEqual(VoicePreferences.read(UserDefaults(suiteName: name + ".other")!).model, .parakeet)
    }
    func testSilenceDoesNotOverwriteClipboard() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("keep", forType: .string)
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: clipboard)
        controller.publish(" \n ")
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
        XCTAssertTrue(controller.transcript.isEmpty)
    }
    func testRecognitionCopiesDictionaryResultAndCancelRetainsIt() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: clipboard)
        controller.preferences.replacements = [.init(original: "демичев", replacement: "Demichev")]
        controller.publish("демичев voice")
        controller.cancel()
        XCTAssertEqual(controller.transcript, "Demichev voice")
        XCTAssertEqual(clipboard.string(forType: .string), controller.transcript)
        XCTAssertFalse(controller.canRecord)
    }
    func testCancelledPreparationCannotClaimReadiness() async {
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: .withUniqueName())
        controller.prepare(download: false)
        controller.cancel()
        for _ in 0..<50 where controller.phase == .cancelling { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.canRecord)
    }
    func testAppIdentityAndBundledLicenses() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "ru.demichev.voice")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Demichev Voice")
        XCTAssertEqual(Bundle(for: Self.self).bundleIdentifier, "ru.demichev.voice.tests")
        for name in ["LICENSE", "FluidAudio", "WhisperKit", "KeyboardShortcuts", "SwiftArgumentParser", "Whisper", "ModelCredits"] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: name == "LICENSE" ? nil : "txt"), name)
        }
    }
}

final class AudioTests: XCTestCase {
    func testSilenceShortBuffersAndInvalidSamplesProduceNoSpeech() {
        XCTAssertFalse(RecognitionEngine.containsSignal(Array(repeating: 0, count: 16_000)))
        XCTAssertFalse(RecognitionEngine.containsSignal(Array(repeating: 1, count: 100)))
        XCTAssertFalse(RecognitionEngine.containsSignal(Array(repeating: .nan, count: 16_000)))
        XCTAssertTrue(RecognitionEngine.containsSignal(Array(repeating: 0.1, count: 16_000)))
    }
    func testMeterHasNoSyntheticMotionAndStaysBounded() {
        XCTAssertEqual(AudioCapture.level(energy: 0), 0)
        XCTAssertEqual(AudioCapture.level(energy: .nan), 0)
        XCTAssertEqual(AudioCapture.level(energy: 0.000001), 0)
        XCTAssertEqual(AudioCapture.level(energy: 1), 1)
        XCTAssertEqual(AudioCapture.level(energy: 0.01), AudioCapture.level(energy: 0.01))
    }
}

final class IntegrationTests: XCTestCase {
    func testInstalledModelsRecognizeLocalAudioWithoutDownload() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEMICHEV_INTEGRATION_AUDIO"] else { throw XCTSkip("Opt-in local audio and installed models required") }
        let store = ModelStore(); let engine = RecognitionEngine()
        for model in SpeechModel.allCases {
            let directory = try await store.prepare(model, allowNetwork: false) { _ in }
            try await engine.load(model, directory: directory)
            let result = try await engine.recognize(URL(fileURLWithPath: path), language: .automatic)
            XCTAssertFalse(result.isEmpty)
        }
    }
}
