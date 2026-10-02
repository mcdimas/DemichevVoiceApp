import XCTest
import AppKit
import AVFoundation
import SwiftUI
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
    func testFailedVerificationInvalidatesInstalledMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("parakeet".utf8).write(to: directory.appendingPathComponent(".installed"))
        XCTAssertTrue(ModelStore.isPresent(.parakeet, root: root))
        do { _ = try await ModelStore(root: root).prepare(.parakeet, allowNetwork: false) { _ in }; XCTFail("Missing model") }
        catch {}
        XCTAssertFalse(ModelStore.isPresent(.parakeet, root: root))
    }
    func testSymlinkCannotReadOrDeleteOutsideModelStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("parakeet"), withDestinationURL: outside)
        do { try await ModelStore(root: root).remove(.parakeet); XCTFail("Link must be rejected") } catch {}
        let entry = CatalogFile(relativePath: "parakeet/file", sourceURL: URL(string: "https://example.com")!, byteCount: 8, digest: "", algorithm: .sha256)
        XCTAssertThrowsError(try entry.destination(under: root))
        XCTAssertFalse(try entry.verify(root.appendingPathComponent("parakeet")))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("file"), encoding: .utf8), "sentinel")
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
}

@MainActor final class ControllerTests: XCTestCase {
    func testAllTabsRenderWithSyntheticDataWithoutPermissions() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            microphoneAuthorized: { false }, availableDevices: { [] })
        controller.preferences.replacements = [.init(original: "демичев", replacement: "Demichev")]
        controller.publish("Синтетический текст для проверки интерфейса.")
        for tab in ["dictation", "settings", "dictionary"] {
            let host = NSHostingView(rootView: VoiceWindow(controller: controller, initialTab: tab))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 850, height: 720)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1_000)
            if let directory = ProcessInfo.processInfo.environment["DEMICHEV_UI_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent(tab + ".png"))
            }
            window.contentView = nil
        }
        XCTAssertFalse(controller.shortcutsActive)
        XCTAssertFalse(controller.microphoneAllowed)
    }
    private func waitForOperation(_ controller: VoiceController) async {
        for _ in 0..<100 where controller.busy && controller.phase != .recording { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private func session(recognizer: FakeRecognizer = FakeRecognizer(), capture: FakeCapture = FakeCapture()) async -> (VoiceController, NSPasteboard) {
        let board = NSPasteboard.withUniqueName()
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            modelRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            store: FakeStore(), recognizer: recognizer, capture: capture, microphoneAuthorized: { true }, availableDevices: { [] })
        controller.prepare(download: false)
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .ready)
        return (controller, board)
    }
    func testReleaseOfUnrelatedShortcutCannotStopButtonRecording() async {
        let capture = FakeCapture()
        let (controller, board) = await session(capture: capture)
        defer { controller.cancel(); board.releaseGlobally() }
        controller.beginRecording()
        controller.shortcutDown(); controller.shortcutUp()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(capture.finished, 0)
    }
    func testHoldShortcutStopsOnlyItsOwnRecording() async {
        let capture = FakeCapture()
        let (controller, board) = await session(capture: capture)
        defer { controller.cancel(); board.releaseGlobally() }
        controller.shortcutDown(); controller.shortcutUp()
        await waitForOperation(controller)
        XCTAssertEqual(capture.finished, 1)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(board.string(forType: .string), "synthetic result")
    }
    func testCancelledRecognitionCannotPublishLateResultOrLeaveFile() async {
        let recognizer = FakeRecognizer(delayed: true)
        let capture = FakeCapture()
        let (controller, board) = await session(recognizer: recognizer, capture: capture)
        defer { board.releaseGlobally() }
        controller.publish("keep")
        controller.beginRecording(); controller.endRecording()
        for _ in 0..<100 { if await recognizer.recognizing { break }; try? await Task.sleep(for: .milliseconds(1)) }
        controller.cancel()
        XCTAssertEqual(controller.phase, .cancelling)
        XCTAssertFalse(controller.canRecord)
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.transcript, "keep")
        XCTAssertEqual(board.string(forType: .string), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.file.path))
    }
    func testCaptureFailurePreservesPreviousResultAndCanRetry() async {
        let capture = FakeCapture(); capture.failBegin = true
        let (controller, board) = await session(capture: capture)
        defer { controller.cancel(); board.releaseGlobally() }
        controller.publish("keep")
        controller.beginRecording()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertEqual(controller.transcript, "keep")
        capture.failBegin = false; controller.beginRecording()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(controller.error.isEmpty)
    }
    func testFailedLoadUnloadsEngineAndCannotRecord() async {
        let recognizer = FakeRecognizer(failLoad: true)
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, store: FakeStore(), recognizer: recognizer,
            microphoneAuthorized: { true }, availableDevices: { [] })
        controller.prepare(download: false)
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.canRecord)
        XCTAssertFalse(controller.error.isEmpty)
        let unloads = await recognizer.unloads
        XCTAssertEqual(unloads, 2)
    }
    func testPartialPreferencesPreserveValidFields() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let dictionary = [WordReplacement(original: "тест", replacement: "test")]
        let rules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dictionary))
        let fields: [String: Any] = ["model": "future-model", "language": "english", "inputUID": "chosen-input", "replacements": rules]
        defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: VoicePreferences.key)
        let restored = VoicePreferences.read(defaults)
        XCTAssertEqual(restored.model, .parakeet)
        XCTAssertEqual(restored.recordingMode, .hold)
        XCTAssertEqual(restored.language, .english)
        XCTAssertEqual(restored.inputUID, "chosen-input")
        XCTAssertEqual(restored.replacements, dictionary)
    }
    func testPreferencesAndDictionaryPersistOnlyInChosenSuite() {
        let name = "ru.demichev.voice.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = VoicePreferences()
        settings.model = .whisper; settings.inputUID = "synthetic-input"
        settings.replacements = [.init(original: "тест", replacement: "test")]
        settings.save(defaults)
        // An existing installation may have enabled automatic paste. Ignore that
        // legacy setting while preserving its model, input and dictionary.
        var legacy = try! JSONSerialization.jsonObject(with: defaults.data(forKey: VoicePreferences.key)!) as! [String: Any]
        legacy["pasteAutomatically"] = true
        defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: VoicePreferences.key)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let clipboard = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.removeItem(at: root); clipboard.releaseGlobally() }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: clipboard, modelRoot: root)
        controller.prepare(download: false)
        controller.cancel()
        for _ in 0..<50 where controller.phase == .cancelling { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.canRecord)
    }
    func testRemovalCannotClaimToBeCancellable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, modelRoot: root)
        controller.removeModel()
        XCTAssertEqual(controller.phase, .removing)
        XCTAssertFalse(controller.canCancel)
        controller.cancel()
        XCTAssertEqual(controller.phase, .removing)
        for _ in 0..<50 where controller.phase == .removing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
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
    func testDiagnosticArgumentsRejectMissingPathAndConflictingActions() {
        XCTAssertEqual(LaunchCommand.parse(["app"]), .normal)
        XCTAssertEqual(LaunchCommand.parse(["app", "--install-models"]), .installModels)
        XCTAssertEqual(LaunchCommand.parse(["app", "--check-audio"]), .invalid)
        XCTAssertEqual(LaunchCommand.parse(["app", "--check-audio", "--install-models"]), .invalid)
        XCTAssertEqual(LaunchCommand.parse(["app", "--install-models", "--install-models"]), .invalid)
        XCTAssertEqual(LaunchCommand.parse(["app", "--check-audio", "/tmp/synthetic.aiff"]), .checkAudio(URL(fileURLWithPath: "/tmp/synthetic.aiff")))
    }
    func testExpiredRecordingCleanupPreservesRecentAndUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent(UUID().uuidString + ".caf")
        let recent = root.appendingPathComponent(UUID().uuidString + ".caf")
        let other = root.appendingPathComponent("user.caf")
        for file in [old, recent, other] { try Data("synthetic".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: other.path)
        try RecordingFiles.purgeExpired(under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
    func testInvalidAudioIsRejectedBeforeModelInference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not audio".utf8).write(to: file)
        XCTAssertThrowsError(try RecognitionEngine.validateAudio(file))
    }
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

private actor FakeStore: ModelPreparing {
    func prepare(_ model: SpeechModel, allowNetwork: Bool, publish: @escaping @Sendable (ModelProgress) -> Void) async throws -> URL {
        URL(fileURLWithPath: "/tmp/synthetic-model")
    }
    func remove(_ model: SpeechModel) async throws {}
}

private actor FakeRecognizer: SpeechRecognizing {
    let delayed: Bool
    let failLoad: Bool
    private(set) var recognizing = false
    private(set) var unloads = 0
    init(delayed: Bool = false, failLoad: Bool = false) { self.delayed = delayed; self.failLoad = failLoad }
    func load(_ model: SpeechModel, directory: URL) async throws {
        if failLoad { throw VoiceError("Synthetic load error") }
    }
    func recognize(_ file: URL, language: SpeechLanguage) async throws -> String {
        recognizing = true
        // Deliberately return a late result despite cancellation: the controller
        // must discard it even when a dependency fails to cooperate.
        if delayed { try? await Task.sleep(for: .seconds(10)) }
        return "synthetic result"
    }
    func unload() async throws { unloads += 1 }
}

@MainActor private final class FakeCapture: AudioRecording {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    var amplitude: Double { 0 }
    var failure: Error? { nil }
    var failBegin = false
    var finished = 0
    func begin(inputUID: String) throws {
        if failBegin { throw VoiceError("Synthetic capture error") }
        try Data("synthetic fixture".utf8).write(to: file)
    }
    func finish() throws -> URL? { finished += 1; return file }
    func discard() { try? FileManager.default.removeItem(at: file) }
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
