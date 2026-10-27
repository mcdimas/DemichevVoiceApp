import XCTest
import AppKit
import AVFoundation
import SwiftUI
@preconcurrency import FluidAudio
@testable import DemichevVoice

final class CatalogTests: XCTestCase {
    private func smallCatalog() -> ModelCatalog {
        ModelCatalog(name: "parakeet", files: [.init(relativePath: "weights.bin",
            sourceURL: URL(string: "https://huggingface.co/test/model/resolve/0000000000000000000000000000000000000000/weights.bin")!, byteCount: 6,
            digest: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03", algorithm: .sha256)])
    }
    func testVerifiedTransferRepairsCorruptionAndResumesWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("wrong\n".utf8).write(to: folder.appendingPathComponent("weights.bin"))
        let transfer = FakeTransfer(text: "hello\n")
        let catalog = smallCatalog()
        let store = ModelStore(root: root, catalog: catalog, transfer: { request, progress in try await transfer.fetch(request, progress: progress) })
        _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("weights.bin"), encoding: .utf8), "hello\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".installed"), encoding: .utf8), catalog.fingerprint)
        _ = try await store.prepare(.parakeet, allowNetwork: false) { _ in }
        let requests = await transfer.requests
        XCTAssertEqual(requests, 1)
    }
    func testCorruptTransferCannotOverwriteExistingFileOrInstallMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep!\n".utf8).write(to: folder.appendingPathComponent("weights.bin"))
        let transfer = FakeTransfer(text: "wrong\n")
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in try await transfer.fetch(request, progress: progress) })
        do { _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }; XCTFail("Corrupt transfer") } catch {}
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("weights.bin"), encoding: .utf8), "keep!\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".installed").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".download-") })
    }
    func testInterruptedDownloadRetriesAndStillVerifiesHash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = FakeTransfer(text: "hello\n", failures: 1)
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in
            try await transfer.fetch(request, progress: progress)
        }, retryDelay: { _ in })
        let folder = try await store.prepare(.parakeet, allowNetwork: true) { _ in }
        XCTAssertTrue(try smallCatalog().files[0].verify(folder.appendingPathComponent("weights.bin")))
        let requests = await transfer.requests
        XCTAssertEqual(requests, 2)
    }
    func testRepeatedTimeoutStopsAfterThreeAttempts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = FakeTransfer(text: "hello\n", failures: 10)
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in
            try await transfer.fetch(request, progress: progress)
        }, retryDelay: { _ in })
        do { _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let requests = await transfer.requests
        XCTAssertEqual(requests, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelStore.folder(.parakeet, root: root).appendingPathComponent(".installed").path))
    }
    func testOversizedDownloadCannotReplaceFilesOrRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("weights.bin")
        try Data("keep!\n".utf8).write(to: original)
        let transfer = FakeTransfer(text: "hello\nextra bytes")
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in
            try await transfer.fetch(request, progress: progress)
        }, retryDelay: { _ in })
        do { _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }; XCTFail("Expected size limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("превышает размер")) }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep!\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".installed").path))
        let requests = await transfer.requests
        XCTAssertEqual(requests, 1)
        let lastTemporary = await transfer.lastTemporary
        let temporary = try XCTUnwrap(lastTemporary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
    func testHTTPFailureIsNotReportedAsHashCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = FakeTransfer(text: "hello\n", status: 403)
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in
            try await transfer.fetch(request, progress: progress)
        }, retryDelay: { _ in })
        do { _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }; XCTFail("Expected HTTP failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 403")); XCTAssertFalse(error.localizedDescription.contains("хеша")) }
        let requests = await transfer.requests
        XCTAssertEqual(requests, 1)
        let temporary = await transfer.lastTemporary
        if let temporary { XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path)) }
    }
    func testCancelledTransferIsNeverRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = FakeTransfer(text: "hello\n", failures: 1, failureCode: .cancelled)
        let store = ModelStore(root: root, catalog: smallCatalog(), transfer: { request, progress in
            try await transfer.fetch(request, progress: progress)
        }, retryDelay: { _ in })
        do { _ = try await store.prepare(.parakeet, allowNetwork: true) { _ in }; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        let requests = await transfer.requests
        XCTAssertEqual(requests, 1)
    }
    func testCancelledVerificationPreservesPreviouslyInstalledModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: folder.appendingPathComponent("weights.bin"))
        try Data("parakeet".utf8).write(to: folder.appendingPathComponent(".installed"))
        XCTAssertTrue(ModelStore.isPresent(.parakeet, root: root))
        let store = ModelStore(root: root, catalog: smallCatalog())
        let task = Task {
            try await store.prepare(.parakeet, allowNetwork: false) { status in
                if status.description == "Проверка файлов…" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(ModelStore.isPresent(.parakeet, root: root))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("weights.bin"), encoding: .utf8), "hello\n")
    }
    func testModelParentContainerLinkCannotDeleteExternalFiles() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let sentinel = outside.appendingPathComponent("Models/parakeet/sentinel")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel)
        let link = sandbox.appendingPathComponent("app-container")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = ModelStore(root: link.appendingPathComponent("Models"))
        do { try await store.remove(.parakeet); XCTFail("Parent link must be rejected") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
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
    func testCaseInsensitiveDictionaryUsesActualUnicodeMatchLength() {
        let rules = [WordReplacement(original: "Straße", replacement: "street"),
                     WordReplacement(original: "ss", replacement: "pair")]
        XCTAssertEqual(ReplacementPipeline.apply("STRASSE, Straße; STRASSEN. ß!", rules: rules), "street, street; STRASSEN. pair!")
    }
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
    func testOfflineDiagnosticReturnsFailureAndRemovesItsOwnPreferences() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let suite = "ru.demichev.voice.tests.diagnostic." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = sandbox.appendingPathComponent("synthetic.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do { let writer = try AVAudioFile(forWriting: audio, settings: format.settings); try writer.write(from: buffer) }
        let status = await OfflineCheck.run(audio: audio, modelRoot: sandbox.appendingPathComponent("MissingModels"), suiteName: suite)
        XCTAssertEqual(status, 1)
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
    func testInterruptedPreparationLeavesModelChoiceAvailableAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("parakeet".utf8).write(to: folder.appendingPathComponent(".installed"))
        let held = FakeRecognizer(holdLoad: true)
        let interrupted = VoiceController(defaults: defaults, modelRoot: root, store: FakeStore(), recognizer: held,
            microphoneAuthorized: { false }, availableDevices: { [] }, cleanupOldRecordings: {})
        interrupted.prepare(download: false)
        for _ in 0..<100 where interrupted.phase != .loading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(interrupted.phase, .loading)
        XCTAssertEqual(defaults.string(forKey: VoiceController.pendingPreparationKey), "parakeet")
        let next = VoiceController(defaults: defaults, modelRoot: root, store: FakeStore(), recognizer: FakeRecognizer(),
            microphoneAuthorized: { false }, availableDevices: { [] }, cleanupOldRecordings: {})
        next.start(enableShortcuts: false)
        XCTAssertEqual(next.phase, .idle)
        XCTAssertFalse(next.busy)
        XCTAssertTrue(next.message.contains("не завершилась"))
        XCTAssertTrue(next.installedModels.contains(.parakeet))
        try snapshot(next, tab: "settings", name: "settings-recovery")
        interrupted.cancel()
        await held.finishLoad()
        await waitForOperation(interrupted)
        XCTAssertNotNil(defaults.string(forKey: VoiceController.pendingPreparationKey))
        next.prepare(download: false)
        await waitForOperation(next)
        XCTAssertEqual(next.phase, .ready)
        XCTAssertNil(defaults.string(forKey: VoiceController.pendingPreparationKey))
    }
    func testCleanupWarningSurvivesPreparationAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelStore.folder(.parakeet, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("parakeet".utf8).write(to: folder.appendingPathComponent(".installed"))
        var attempts = 0
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, modelRoot: root,
            store: FakeStore(), recognizer: FakeRecognizer(), microphoneAuthorized: { false }, availableDevices: { [] },
            cleanupOldRecordings: { attempts += 1; if attempts == 1 { throw VoiceError("Synthetic cleanup failure") } })
        controller.start(enableShortcuts: false)
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.storageWarning.contains("Synthetic cleanup failure"))
        XCTAssertTrue(controller.error.isEmpty)
        XCTAssertFalse(controller.shortcutsActive)
        try snapshot(controller, tab: "settings", name: "settings-cleanup-warning")
        controller.retryRecordingCleanup()
        XCTAssertTrue(controller.storageWarning.isEmpty)
        XCTAssertEqual(attempts, 2)
    }
    func testAllTabsRenderWithSyntheticDataWithoutPermissions() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            microphoneAuthorized: { false }, availableDevices: { [] })
        controller.preferences.replacements = [.init(original: "демичев", replacement: "Demichev")]
        controller.publish("Синтетический текст для проверки интерфейса.")
        for tab in ["dictation", "settings", "dictionary"] {
            try snapshot(controller, tab: tab, name: tab)
        }
        XCTAssertFalse(controller.shortcutsActive)
        XCTAssertFalse(controller.microphoneAllowed)
    }
    func testLoadingAndFailedPreparationRenderWithoutPermissions() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let recognizer = FakeRecognizer(holdLoad: true)
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            store: FakeStore(), recognizer: recognizer, microphoneAuthorized: { false }, availableDevices: { [] })
        controller.prepare(download: false)
        for _ in 0..<100 where controller.phase != .loading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .loading)
        // Allow the asynchronously published component status to arrive.
        try? await Task.sleep(for: .milliseconds(20))
        try snapshot(controller, tab: "dictation", name: "dictation-loading")
        try snapshot(controller, tab: "settings", name: "settings-loading")
        controller.cancel()
        await recognizer.finishLoad()
        await waitForOperation(controller)
        let failure = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            store: FakeStore(), recognizer: FakeRecognizer(failLoad: true), microphoneAuthorized: { false }, availableDevices: { [] })
        failure.prepare(download: false)
        await waitForOperation(failure)
        XCTAssertEqual(failure.phase, .idle)
        XCTAssertFalse(failure.error.isEmpty)
        try snapshot(failure, tab: "settings", name: "settings-error")
    }
    private func snapshot(_ controller: VoiceController, tab: String, name: String) throws {
            let host = NSHostingView(rootView: VoiceWindow(controller: controller, initialTab: tab))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 850, height: 720)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1_000)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["DEMICHEV_UI_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent(name + ".png"))
            }
            window.contentView = nil
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
        XCTAssertFalse(controller.message.contains("Загрузка"))
        let unloads = await recognizer.unloads
        XCTAssertEqual(unloads, 2)
    }
    func testFullDownloadBarCannotOverwriteModelLoadingOrReadyStatus() async {
        let store = FakeStore()
        let recognizer = FakeRecognizer(holdLoad: true)
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, store: store, recognizer: recognizer,
            microphoneAuthorized: { true }, availableDevices: { [] })
        controller.prepare(download: true)
        for _ in 0..<100 where controller.phase != .loading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .loading)
        XCTAssertNotNil(controller.loadingStartedAt)
        XCTAssertTrue(controller.busy)
        XCTAssertTrue(controller.canCancel)
        XCTAssertFalse(controller.canRecord)
        await store.publishLateProgress()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.phase, .loading)
        XCTAssertFalse(controller.message.contains("Файлы проверены"))
        await recognizer.finishLoad()
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.loadingStartedAt)
        await store.publishLateProgress()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.message, "Модель готова. Можно диктовать.")
    }
    func testCancelDuringMemoryLoadingPreservesNonReadyState() async {
        let recognizer = FakeRecognizer(holdLoad: true)
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, store: FakeStore(), recognizer: recognizer,
            microphoneAuthorized: { true }, availableDevices: { [] })
        controller.prepare(download: false)
        for _ in 0..<100 where controller.phase != .loading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .loading)
        controller.cancel()
        XCTAssertEqual(controller.phase, .cancelling)
        await recognizer.finishLoad()
        await waitForOperation(controller)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.canRecord)
        XCTAssertNil(controller.loadingStartedAt)
        XCTAssertEqual(controller.message, "Операция отменена.")
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
    func testDamagedDictionaryEntryDoesNotEraseOtherRules() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = [WordReplacement(original: "первый", replacement: "first"), WordReplacement(original: "второй", replacement: "second")]
        let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as! [Any]
        let fields: [String: Any] = ["language": "english", "replacements": [objects[0], ["original": 42], NSNull(), objects[1]]]
        defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: VoicePreferences.key)
        let restored = VoicePreferences.read(defaults)
        XCTAssertEqual(restored.replacements, rules)
        XCTAssertEqual(restored.language, .english)
        restored.save(defaults)
        XCTAssertEqual(VoicePreferences.read(defaults).replacements, rules)
    }
    func testCopyingPreviousResultPreservesBusyOperationStatus() async {
        let recognizer = FakeRecognizer(holdLoad: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = VoiceController(defaults: UserDefaults(suiteName: UUID().uuidString)!, clipboard: board,
            store: FakeStore(), recognizer: recognizer, microphoneAuthorized: { false }, availableDevices: { [] })
        controller.publish("previous synthetic result")
        controller.prepare(download: false)
        for _ in 0..<100 where controller.phase != .loading { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.phase, .loading)
        let status = controller.message
        controller.copyTranscript()
        XCTAssertEqual(board.string(forType: .string), "previous synthetic result")
        XCTAssertEqual(controller.phase, .loading)
        XCTAssertEqual(controller.message, status)
        controller.cancel()
        await recognizer.finishLoad()
        await waitForOperation(controller)
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
    func testFullLengthCaptureResamplesWithinRecognitionLimit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 44_100)
        let sink = try AudioFileSink(url: file, format: format)
        for _ in 0..<601 { sink.accept(buffer) }
        try sink.close()
        XCTAssertEqual(try AVAudioFile(forReading: file).length, 600 * 44_100)
        try RecognitionEngine.validateAudio(file)
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(file)
        XCTAssertGreaterThanOrEqual(samples.count, 16_000 * 599)
        XCTAssertLessThanOrEqual(samples.count, 16_000 * 600)
        XCTAssertTrue(RecognitionEngine.containsSignal(samples))
    }
    func testStereoRightChannelSurvivesCaptureAndMonoConversion() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        buffer.floatChannelData![1].initialize(repeating: 0.2, count: 16_000)
        let sink = try AudioFileSink(url: file, format: format)
        sink.accept(buffer)
        XCTAssertGreaterThan(sink.meter(), 0)
        try sink.close()
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(file)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertTrue(RecognitionEngine.containsSignal(samples))
    }
    func testCaptureAndRecognitionRejectUnsupportedFormatsBeforeWriting() throws {
        for format in [try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 384_000, channels: 1)),
                       try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 33))] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try AudioConstraints.validateFormat(format))
            XCTAssertThrowsError(try AudioFileSink(url: file, format: format))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testPCMRecordingFormatsAndStereoMeter() throws {
        for common in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
                defer { try? FileManager.default.removeItem(at: file) }
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 16_000, channels: 2, interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
                buffer.frameLength = 128
                for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    let data = try XCTUnwrap(plane.mData)
                    let count = 128 * Int(plane.mNumberChannels)
                    switch common {
                    case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self).initialize(repeating: 0.1, count: count)
                    case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self).initialize(repeating: 0.1, count: count)
                    case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self).initialize(repeating: 3_277, count: count)
                    case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self).initialize(repeating: 214_748_365, count: count)
                    default: XCTFail("Unsupported test format")
                    }
                }
                let sink = try AudioFileSink(url: file, format: format)
                sink.accept(buffer)
                XCTAssertNil(sink.failure(), "\(common) interleaved=\(interleaved)")
                XCTAssertEqual(sink.meter(), AudioCapture.level(energy: 0.01), accuracy: 0.001)
                try sink.close()
                XCTAssertEqual(try AVAudioFile(forReading: file).length, 128)
                XCTAssertNoThrow(try RecognitionEngine.validateAudio(file))
            }
        }
    }
    func testChangedBufferFormatBecomesRecoverableFailure() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let changed = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 128))
        buffer.frameLength = 128
        let sink = try AudioFileSink(url: file, format: expected)
        sink.accept(buffer)
        XCTAssertNotNil(sink.failure())
        XCTAssertThrowsError(try sink.close())
        XCTAssertEqual(try AVAudioFile(forReading: file).length, 0)
    }
    func testRecordingFrameLimitTrimsFinalBufferAndIgnoresLateBuffers() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 128)
        let sink = try AudioFileSink(url: file, format: format, maximumDuration: 0.01)
        sink.accept(buffer)
        XCTAssertFalse(sink.reachedLimit())
        sink.accept(buffer)
        XCTAssertTrue(sink.reachedLimit())
        XCTAssertEqual(buffer.frameLength, 128)
        sink.accept(buffer)
        try sink.close()
        let recording = try AVAudioFile(forReading: file)
        XCTAssertEqual(recording.length, 160)
        XCTAssertNoThrow(try RecognitionEngine.validateAudio(file))
    }
    func testRecordingBoundaryMatchesStrictTenMinuteValidation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        // A low sample rate exercises the real 600-second bound with a small file.
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768))
        buffer.frameLength = 32_768
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 32_768)
        let sink = try AudioFileSink(url: file, format: format)
        sink.accept(buffer); sink.accept(buffer); sink.accept(buffer)
        try sink.close()
        XCTAssertEqual(try AVAudioFile(forReading: file).length, 60_000)
        XCTAssertNoThrow(try RecognitionEngine.validateAudio(file))
    }
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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try RecordingFiles.prepareDirectory(root)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
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
    func testRecordingParentContainerLinkCannotChangePermissionsOrPurgeFiles() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outside = sandbox.appendingPathComponent("outside/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let sentinel = outside.appendingPathComponent(UUID().uuidString + ".caf")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: sentinel.path)
        let link = sandbox.appendingPathComponent("app-container")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let root = link.appendingPathComponent("Recordings")
        XCTAssertThrowsError(try RecordingFiles.prepareDirectory(root))
        XCTAssertThrowsError(try RecordingFiles.purgeExpired(under: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
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
    private var publish: (@Sendable (ModelProgress) -> Void)?
    func prepare(_ model: SpeechModel, allowNetwork: Bool, publish: @escaping @Sendable (ModelProgress) -> Void) async throws -> URL {
        self.publish = publish
        return URL(fileURLWithPath: "/tmp/synthetic-model")
    }
    func publishLateProgress() { publish?(.init(completed: 100, total: 100, description: "Файлы проверены")) }
    func remove(_ model: SpeechModel) async throws {}
}

private actor FakeTransfer {
    let text: String
    let failures: Int
    let status: Int
    let failureCode: URLError.Code
    private(set) var requests = 0
    private(set) var lastTemporary: URL?
    init(text: String, failures: Int = 0, status: Int = 200, failureCode: URLError.Code = .timedOut) {
        self.text = text; self.failures = failures; self.status = status; self.failureCode = failureCode
    }
    func fetch(_ request: URLRequest, progress: @Sendable (Int64) -> Void) throws -> (URL, URLResponse) {
        requests += 1
        if requests <= failures { throw URLError(failureCode) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lastTemporary = file
        try Data(text.utf8).write(to: file)
        progress(Int64(text.utf8.count))
        return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor FakeRecognizer: SpeechRecognizing {
    let delayed: Bool
    let failLoad: Bool
    let holdLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private(set) var recognizing = false
    private(set) var unloads = 0
    init(delayed: Bool = false, failLoad: Bool = false, holdLoad: Bool = false) {
        self.delayed = delayed; self.failLoad = failLoad; self.holdLoad = holdLoad
    }
    func load(_ model: SpeechModel, directory: URL, publish: @escaping @Sendable (String) -> Void) async throws {
        if failLoad { throw VoiceError("Synthetic load error") }
        publish("Синтетическая подготовка Core ML…")
        if holdLoad { await withCheckedContinuation { loadContinuation = $0 } }
    }
    func finishLoad() { loadContinuation?.resume(); loadContinuation = nil }
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
