import AppKit
import AVFoundation
import Observation
import ApplicationServices
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let recordVoice = Self("demichev.record", initial: .init(.space, modifiers: [.control, .option]))
    static let cancelVoice = Self("demichev.cancel", initial: .init(.escape))
}

enum VoicePhase: Equatable { case idle, preparing, removing, ready, recording, recognizing, cancelling }

@MainActor @Observable final class VoiceController {
    private let defaults: UserDefaults
    private let clipboard: NSPasteboard
    private let store = ModelStore()
    private let recognizer = RecognitionEngine()
    private let capture = AudioCapture()
    private let paste = PasteCoordinator()
    private var operation: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var started = false
    private var operationID = UUID()
    private var shortcutHeld = false
    private var startedAt = Date()
    private var ready = false

    var preferences: VoicePreferences { didSet { preferences.save(defaults) } }
    private(set) var phase: VoicePhase = .idle
    private(set) var transcript = ""
    private(set) var message = "Выберите модель для локального распознавания."
    private(set) var error = ""
    private(set) var progress = 0.0
    private(set) var level = 0.0
    private(set) var elapsed = 0
    private(set) var microphoneAllowed = false
    private(set) var pasteAllowed = false
    var devices: [InputDevice] = []
    var canRecord: Bool { phase == .ready && microphoneAllowed }
    var busy: Bool { [.preparing, .removing, .recording, .recognizing, .cancelling].contains(phase) }
    var canCancel: Bool { [.preparing, .recording, .recognizing].contains(phase) }

    init(defaults: UserDefaults = .standard, clipboard: NSPasteboard = .general) {
        self.defaults = defaults; self.clipboard = clipboard
        preferences = VoicePreferences.read(defaults)
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        KeyboardShortcuts.onKeyDown(for: .recordVoice) { [weak self] in self?.shortcutDown() }
        KeyboardShortcuts.onKeyUp(for: .recordVoice) { [weak self] in self?.shortcutUp() }
        KeyboardShortcuts.onKeyDown(for: .cancelVoice) { [weak self] in self?.cancel() }
        KeyboardShortcuts.disable(.cancelVoice)
        if ModelStore.isPresent(preferences.model) { prepare(download: false) }
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        pasteAllowed = AXIsProcessTrusted()
        devices = InputDevices.available()
    }
    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() }
        } else { openPrivacy("Privacy_Microphone") }
    }
    func requestPaste() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }

    func selectModel(_ model: SpeechModel) {
        guard !busy, model != preferences.model else { return }
        preferences.model = model; ready = false; phase = .idle; error = ""; transcript = ""
        if ModelStore.isPresent(model) { prepare(download: false) }
    }

    func prepare(download: Bool) {
        guard !busy, operation == nil else { return }
        phase = .preparing; ready = false; error = ""; progress = 0
        message = "Подготовка модели…"
        let model = preferences.model
        let id = UUID(); operationID = id
        KeyboardShortcuts.enable(.cancelVoice)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                let directory = try await store.prepare(model, allowNetwork: download) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.phase == .preparing else { return }
                        self.progress = status.fraction; self.message = status.description
                    }
                }
                try Task.checkCancellation()
                message = "Загрузка модели в память…"
                try await recognizer.load(model, directory: directory)
                try Task.checkCancellation()
                ready = true; message = "Модель готова. Можно диктовать."
            } catch { report(error) }
        }
    }

    func removeModel() {
        guard !busy, operation == nil else { return }
        let model = preferences.model
        phase = .removing; ready = false; message = "Удаление модели…"; error = ""
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try await recognizer.unload()
                try await store.remove(model)
                message = "Файлы выбранной модели удалены."
            } catch { report(error) }
        }
    }

    func beginRecording() {
        refreshPermissions()
        guard canRecord, operation == nil else { return }
        error = ""; transcript = ""; elapsed = 0; level = 0
        paste.capture()
        do { try capture.begin(inputUID: preferences.inputUID) }
        catch { paste.reset(); self.error = error.localizedDescription; return }
        phase = .recording; message = "Говорите. Отпустите клавиши для завершения."
        startedAt = Date(); KeyboardShortcuts.enable(.cancelVoice)
        meter = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.phase == .recording else { return }
                self.level = self.capture.amplitude
                self.elapsed = Int(Date().timeIntervalSince(self.startedAt))
                if let failure = self.capture.failure {
                    self.cancel(); self.error = failure.localizedDescription; return
                }
                if !self.preferences.inputUID.isEmpty, !InputDevices.available().contains(where: { $0.id == self.preferences.inputUID }) {
                    self.cancel(); self.error = "Микрофон отключён. Выберите доступный вход."; return
                }
                if self.elapsed >= 600 { self.endRecording(); return }
            }
        }
    }

    func endRecording() {
        guard phase == .recording else { return }
        meter?.cancel(); meter = nil; level = 0; shortcutHeld = false
        let file: URL
        do { guard let url = try capture.finish() else { cancel(); return }; file = url }
        catch { cancel(); self.error = error.localizedDescription; return }
        phase = .recognizing; message = "Распознавание на вашем Mac…"
        let language = preferences.language
        operation = Task { [weak self] in
            guard let self else { try? FileManager.default.removeItem(at: file); return }
            defer { try? FileManager.default.removeItem(at: file); finishOperation() }
            do {
                let result = try await recognizer.recognize(file, language: language)
                try Task.checkCancellation()
                publish(result)
                if !transcript.isEmpty {
                    let inserted = preferences.pasteAutomatically && paste.paste()
                    message = inserted ? "Текст вставлен и скопирован." : "Текст скопирован. Используйте Cmd+V."
                } else { message = "Речь не обнаружена."; paste.reset() }
            } catch { paste.reset(); report(error) }
        }
    }

    func publish(_ text: String) {
        let result = ReplacementPipeline.apply(text, rules: preferences.replacements)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return }
        transcript = result
        clipboard.clearContents(); clipboard.setString(result, forType: .string)
    }
    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        clipboard.clearContents(); clipboard.setString(transcript, forType: .string)
    }

    func cancel() {
        guard phase != .removing else { return }
        shortcutHeld = false; meter?.cancel(); meter = nil; level = 0
        capture.discard(); paste.reset()
        if let operation { phase = .cancelling; message = "Завершаем отмену…"; operation.cancel() }
        else { phase = ready ? .ready : .idle; message = "Запись отменена."; KeyboardShortcuts.disable(.cancelVoice) }
    }
    private func finishOperation() {
        operation = nil; phase = ready ? .ready : .idle
        KeyboardShortcuts.disable(.cancelVoice)
    }
    private func report(_ failure: Error) {
        if Task.isCancelled || failure is CancellationError { message = "Операция отменена. Проверенные файлы сохранены." }
        else { error = failure.localizedDescription }
    }

    private func shortcutDown() {
        guard !shortcutHeld else { return }
        shortcutHeld = true
        if preferences.recordingMode == .toggle, phase == .recording { endRecording() }
        else { beginRecording() }
    }
    private func shortcutUp() {
        shortcutHeld = false
        if preferences.recordingMode == .hold, phase == .recording { endRecording() }
    }
}
