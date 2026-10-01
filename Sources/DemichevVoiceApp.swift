import SwiftUI
import AppKit

@main struct DemichevVoiceApp: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate
    @State private var controller = VoiceController()
    private let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    var body: some Scene {
        WindowGroup("Demichev Voice", id: "voice") {
            VoiceWindow(controller: controller)
                .task { if !underTest && !ProcessInfo.processInfo.arguments.contains("--check-audio") { controller.start() } }
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
        Button("Отменить") { controller.cancel() }.disabled(!controller.busy)
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
                // Do not log the transcript or retain the user's audio.
                print("OFFLINE_OK \(model.rawValue)")
            }
            exit(0)
        } catch { FileHandle.standardError.write(Data("OFFLINE_FAILED: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
