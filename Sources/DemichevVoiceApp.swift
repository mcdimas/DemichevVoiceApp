import SwiftUI
import AppKit
import AVFoundation

@main struct DemichevVoiceApp: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate
    @State private var controller = VoiceController()
    private let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    var body: some Scene {
        WindowGroup("Demichev Voice", id: "voice") {
            VoiceWindow(controller: controller)
                .preferredColorScheme(.light)
                .task { if !underTest && !ProcessInfo.processInfo.arguments.contains("--check-audio") && !ProcessInfo.processInfo.arguments.contains("--install-models") { controller.start() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !underTest { controller.refreshPermissions() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in controller.cancel() }
        }
        .defaultSize(width: 850, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Диктовка") { Button("Отмена") { controller.cancel() }.keyboardShortcut(.escape, modifiers: []) }
        }
        MenuBarExtra("Demichev Voice", systemImage: "mic.circle") {
            MenuContent(controller: controller)
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
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--check-audio"), arguments.count > index + 1 {
            Task { await OfflineCheck.run(audio: URL(fileURLWithPath: arguments[index + 1])) }
        } else if arguments.contains("--install-models") {
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
            let store = ModelStore(); let engine = RecognitionEngine()
            for model in SpeechModel.allCases {
                let path = try await store.prepare(model, allowNetwork: false) { _ in }
                try await engine.load(model, directory: path)
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
                // Do not log the transcript or retain the user's audio.
                print("OFFLINE_OK \(model.rawValue)")
            }
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
