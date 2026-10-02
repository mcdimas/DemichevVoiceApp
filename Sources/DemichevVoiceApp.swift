import SwiftUI
import AppKit
import AVFoundation

enum LaunchCommand: Equatable {
    case normal, installModels, checkAudio(URL), invalid
    static func parse(_ arguments: [String]) -> Self {
        let installs = arguments.filter { $0 == "--install-models" }.count
        let checks = arguments.filter { $0 == "--check-audio" }.count
        guard installs + checks <= 1 else { return .invalid }
        if installs == 1 { return .installModels }
        if let index = arguments.firstIndex(of: "--check-audio") {
            guard arguments.count > index + 1, !arguments[index + 1].hasPrefix("--") else { return .invalid }
            return .checkAudio(URL(fileURLWithPath: arguments[index + 1]))
        }
        return .normal
    }
}

@main struct DemichevVoiceApp: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate
    @State private var controller = VoiceController()
    private let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    var body: some Scene {
        WindowGroup("Demichev Voice", id: "voice") {
            if underTest { EmptyView() } else {
            VoiceWindow(controller: controller)
                .preferredColorScheme(.light)
                .task { if !underTest && LaunchCommand.parse(ProcessInfo.processInfo.arguments) == .normal { controller.start() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !underTest { controller.refreshPermissions() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in controller.cancel() }
            }
        }
        .defaultSize(width: 850, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Диктовка") { Button("Отмена") { controller.cancel() }.keyboardShortcut(.escape, modifiers: []) }
        }
        MenuBarExtra("Demichev Voice", systemImage: "mic.circle") {
            if !underTest { MenuContent(controller: controller) }
        }
    }
}

struct MenuContent: View {
    let controller: VoiceController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Demichev Voice")
        Button("Открыть приложение") { openWindow(id: "voice"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(controller.phase == .recording ? "Завершить запись" : "Начать запись") {
            if controller.phase == .recording { controller.endRecording() } else { controller.beginRecording() }
        }.disabled(!controller.canRecord && controller.phase != .recording)
        Button("Отменить") { controller.cancel() }.disabled(!controller.canCancel)
        Divider()
        Button("Завершить Demichev Voice") { NSApp.terminate(nil) }
    }
}

final class VoiceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        switch LaunchCommand.parse(ProcessInfo.processInfo.arguments) {
        case .normal: break
        case .invalid:
            FileHandle.standardError.write(Data("Supply --check-audio /absolute/path or --install-models separately.\n".utf8))
            exit(2)
        case .checkAudio(let audio):
            Task { await OfflineCheck.run(audio: audio) }
        case .installModels:
            Task {
                do {
                    let store = ModelStore()
                    for model in SpeechModel.allCases {
                        _ = try await store.prepare(model, allowNetwork: true) { _ in }
                        print("MODEL_VERIFIED \(model.rawValue)")
                    }
                    exit(0)
                } catch { FileHandle.standardError.write(Data("MODEL_FAILED: \(error.localizedDescription)\n".utf8)); exit(1) }
            }
        }
    }
}

@MainActor enum OfflineCheck {
    static func run(audio: URL) async {
        do {
            try RecognitionEngine.validateAudio(audio)
            let store = ModelStore(); let engine = RecognitionEngine()
            let suite = "ru.demichev.voice.check." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let board = NSPasteboard.withUniqueName()
            defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
            let controller = VoiceController(defaults: defaults, clipboard: board, store: store, recognizer: engine,
                microphoneAuthorized: { false }, availableDevices: { [] })
            for model in SpeechModel.allCases {
                // Exercise the same verification -> memory loading -> ready
                // path as the window, without permissions or real preferences.
                controller.preferences.model = model
                let started = Date()
                controller.prepare(download: false)
                while controller.busy {
                    guard Date().timeIntervalSince(started) < 600 else {
                        throw VoiceError("Подготовка \(model.title) не завершилась за 10 минут: \(controller.message)")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard controller.phase == .ready else { throw VoiceError("\(model.title): \(controller.error)") }
                print("MODEL_READY \(model.rawValue) elapsed_seconds=\(Int(Date().timeIntervalSince(started)))")
                let path = ModelStore.folder(model)
                let result = try await engine.recognize(audio, language: .automatic)
                guard !result.isEmpty else { throw VoiceError("Нет результата для \(model.title).") }
                if let expected = ProcessInfo.processInfo.environment["DEMICHEV_EXPECT_WORDS"] {
                    guard expected.split(separator: ",").allSatisfy({ result.lowercased().contains($0.lowercased()) }) else { throw VoiceError("Не распознаны контрольные слова для \(model.title).") }
                }
                let silence = try silentAudio()
                defer { try? FileManager.default.removeItem(at: silence) }
                let quiet = try await engine.recognize(silence, language: .automatic)
                guard quiet.isEmpty else { throw VoiceError("Тишина дала текст.") }
                let cancelled = Task { try await engine.recognize(audio, language: .automatic) }
                cancelled.cancel()
                do { _ = try await cancelled.value; throw VoiceError("Отмена вернула результат.") }
                catch is CancellationError {}
                // Also verify model reloading and that a cancelled request does
                // not leave the recognizer locked for the next dictation.
                try await engine.unload()
                try await engine.load(model, directory: path)
                let retry = try await engine.recognize(audio, language: .automatic)
                guard !retry.isEmpty else { throw VoiceError("Распознавание не восстановилось после отмены.") }
                // Do not log the transcript or retain the user's audio.
                print("OFFLINE_OK \(model.rawValue)")
            }
            try await engine.unload()
            exit(0)
        } catch { FileHandle.standardError.write(Data("OFFLINE_FAILED: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    private static func silentAudio() throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        do { let writer = try AVAudioFile(forWriting: file, settings: format.settings); try writer.write(from: buffer) }
        return file
    }
}
