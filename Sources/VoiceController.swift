import AppKit
import AVFoundation
import Observation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let recordVoice = Self("demichev.record", initial: .init(.space, modifiers: [.control, .option]))
    static let cancelVoice = Self("demichev.cancel", initial: .init(.escape))
}

enum VoicePhase: Equatable { case idle, preparing, removing, ready, recording, recognizing, cancelling }

@MainActor @Observable final class VoiceController {
    private let defaults: UserDefaults
    private let clipboard: NSPasteboard
    private let store: any ModelPreparing
    private let recognizer: any SpeechRecognizing
    private let capture: any AudioRecording
    private let modelRoot: URL
    private let microphoneAuthorized: () -> Bool
    private let availableDevices: () -> [InputDevice]
    private var operation: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var started = false
    private var operationID = UUID()
    private var shortcutHeld = false
    private var recordingUsesHoldShortcut = false
    private var startedAt = Date()
    private var ready = false

    var preferences: VoicePreferences { didSet { preferences.save(defaults) } }
    private(set) var phase: VoicePhase = .idle
    private(set) var transcript = ""
    private(set) var clipboardCopied = false
    private(set) var message = "Выберите модель для локального распознавания."
    private(set) var error = ""
    private(set) var progress = 0.0
    private(set) var level = 0.0
    private(set) var elapsed = 0
    private(set) var microphoneAllowed = false
    private(set) var installedModels: Set<SpeechModel> = []
    var devices: [InputDevice] = []
    var canRecord: Bool { phase == .ready && microphoneAllowed }
    var busy: Bool { [.preparing, .removing, .recording, .recognizing, .cancelling].contains(phase) }
    var canCancel: Bool { [.preparing, .recording, .recognizing].contains(phase) }

    init(defaults: UserDefaults = .standard, clipboard: NSPasteboard = .general, modelRoot: URL = AppStorage.models,
         store: (any ModelPreparing)? = nil, recognizer: any SpeechRecognizing = RecognitionEngine(),
         capture: any AudioRecording = AudioCapture(),
         microphoneAuthorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         availableDevices: @escaping () -> [InputDevice] = { InputDevices.available() }) {
        self.defaults = defaults; self.clipboard = clipboard
        self.modelRoot = modelRoot; self.store = store ?? ModelStore(root: modelRoot)
        self.recognizer = recognizer; self.capture = capture
        self.microphoneAuthorized = microphoneAuthorized; self.availableDevices = availableDevices
        preferences = VoicePreferences.read(defaults)
    }

    func start() {
        guard !started else { return }
        started = true
        do { try RecordingFiles.purgeExpired() } catch { self.error = error.localizedDescription }
        refreshPermissions()
        KeyboardShortcuts.onKeyDown(for: .recordVoice) { [weak self] in self?.shortcutDown() }
        KeyboardShortcuts.onKeyUp(for: .recordVoice) { [weak self] in self?.shortcutUp() }
        KeyboardShortcuts.onKeyDown(for: .cancelVoice) { [weak self] in self?.cancel() }
        cancelShortcut(enabled: false)
        if installedModels.contains(preferences.model) { prepare(download: false) }
    }

    func refreshPermissions() {
        microphoneAllowed = microphoneAuthorized()
        devices = availableDevices()
        refreshModels()
    }
    private func refreshModels() { installedModels = Set(SpeechModel.allCases.filter { ModelStore.isPresent($0, root: modelRoot) }) }
    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() }
        } else { openPrivacy("Privacy_Microphone") }
    }
    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }

    func selectModel(_ model: SpeechModel) {
        guard !busy, model != preferences.model else { return }
        preferences.model = model
        prepare(download: false, onlyIfInstalled: true)
    }

    func prepare(download: Bool, onlyIfInstalled: Bool = false) {
        guard !busy, operation == nil else { return }
        phase = .preparing; ready = false; error = ""; progress = 0
        message = "Подготовка модели…"
        let model = preferences.model
        let id = UUID(); operationID = id
        cancelShortcut(enabled: true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try await recognizer.unload()
                try Task.checkCancellation()
                if onlyIfInstalled && !ModelStore.isPresent(model, root: modelRoot) {
                    message = "Скачайте выбранную модель для локального распознавания."
                    return
                }
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
            } catch { try? await recognizer.unload(); report(error) }
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

    func beginRecording(fromShortcut: Bool = false) {
        refreshPermissions()
        guard canRecord, operation == nil else { return }
        error = ""; elapsed = 0; level = 0
        do { try capture.begin(inputUID: preferences.inputUID) }
        catch { self.error = error.localizedDescription; return }
        recordingUsesHoldShortcut = fromShortcut && preferences.recordingMode == .hold
        phase = .recording
        message = recordingUsesHoldShortcut ? "Говорите. Отпустите клавиши для завершения." : "Говорите. Нажмите «Завершить запись» или горячую клавишу в режиме переключения."
        startedAt = Date(); cancelShortcut(enabled: true)
        meter = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.phase == .recording else { return }
                self.level = self.capture.amplitude
                self.elapsed = Int(Date().timeIntervalSince(self.startedAt))
                if let failure = self.capture.failure {
                    self.cancel(); self.error = failure.localizedDescription; return
                }
                if !self.preferences.inputUID.isEmpty, !self.availableDevices().contains(where: { $0.id == self.preferences.inputUID }) {
                    self.cancel(); self.error = "Микрофон отключён. Выберите доступный вход."; return
                }
                if self.elapsed >= 600 { self.endRecording(); return }
            }
        }
    }

    func endRecording() {
        guard phase == .recording else { return }
        meter?.cancel(); meter = nil; level = 0; recordingUsesHoldShortcut = false
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
                if publish(result) {
                    message = clipboardCopied ? "Текст скопирован. Используйте Cmd+V." : "Текст готов. Скопируйте его из результата."
                } else { message = "Речь не обнаружена." }
            } catch { report(error) }
        }
    }

    @discardableResult func publish(_ text: String) -> Bool {
        let result = ReplacementPipeline.apply(text, rules: preferences.replacements)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return false }
        transcript = result
        clipboard.clearContents(); clipboardCopied = clipboard.setString(result, forType: .string)
        return true
    }
    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        clipboard.clearContents(); clipboardCopied = clipboard.setString(transcript, forType: .string)
        message = clipboardCopied ? "Текст скопирован. Используйте Cmd+V." : "Не удалось записать в буфер. Скопируйте текст из результата."
    }

    func cancel() {
        guard phase != .removing else { return }
        guard phase != .idle && phase != .ready else { return }
        recordingUsesHoldShortcut = false; meter?.cancel(); meter = nil; level = 0
        capture.discard()
        if let operation { phase = .cancelling; message = "Завершаем отмену…"; operation.cancel() }
        else { phase = ready ? .ready : .idle; message = "Запись отменена."; cancelShortcut(enabled: false) }
    }
    private func finishOperation() {
        operation = nil; phase = ready ? .ready : .idle
        refreshModels()
        cancelShortcut(enabled: false)
    }
    private func cancelShortcut(enabled: Bool) {
        guard started else { return }
        if enabled { KeyboardShortcuts.enable(.cancelVoice) } else { KeyboardShortcuts.disable(.cancelVoice) }
    }
    private func report(_ failure: Error) {
        if Task.isCancelled || failure is CancellationError { message = "Операция отменена." }
        else { error = failure.localizedDescription }
    }

    func shortcutDown() {
        guard !shortcutHeld else { return }
        shortcutHeld = true
        if preferences.recordingMode == .toggle, phase == .recording { endRecording() }
        else { beginRecording(fromShortcut: true) }
    }
    func shortcutUp() {
        shortcutHeld = false
        if recordingUsesHoldShortcut, phase == .recording { endRecording() }
    }
}
