import SwiftUI
import KeyboardShortcuts

struct VoiceWindow: View {
    @Bindable var controller: VoiceController
    @State private var tab = "dictation"
    @State private var showLicenses = false
    @State private var confirmRemoval = false
    @State private var original = ""
    @State private var replacement = ""
    private let navy = Color(red: 0.06, green: 0.17, blue: 0.28)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "mic.circle.fill").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Demichev Voice").font(.system(size: 25, weight: .semibold))
                    Text("Ваш голос. Ваш Mac.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Локально", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
            Divider()
            Picker("Раздел", selection: $tab) {
                Text("Диктовка").tag("dictation")
                Text("Настройки").tag("settings")
                Text("Словарь").tag("dictionary")
            }.pickerStyle(.segmented).padding(.horizontal, 26).padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == "dictation" { dictation }
                    else if tab == "settings" { settings }
                    else { dictionary }
                    if !controller.error.isEmpty {
                        Label(controller.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Text(controller.preferences.model.title)
                Spacer()
                Text("Без аккаунта · Без облака")
                Button("Лицензии") { showLicenses = true }.buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary).padding(16)
        }.frame(minWidth: 700, minHeight: 600).foregroundStyle(navy)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { controller.cancel() }
            .sheet(isPresented: $showLicenses) { licenseSheet }
            .alert("Удалить выбранную модель?", isPresented: $confirmRemoval) {
                Button("Удалить", role: .destructive) { controller.removeModel() }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Для следующего использования потребуется повторная загрузка файлов.") }
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Диктовка").font(.title2.bold())
            Text("Удерживайте \(KeyboardShortcuts.getShortcut(for: .recordVoice)?.description ?? "сочетание клавиш") в текстовом поле. В режиме переключения нажмите ещё раз для завершения.")
                .foregroundStyle(.secondary).font(.callout)
            GroupBox {
                VStack(spacing: 18) {
                    Image(systemName: controller.phase == .recording ? "mic.fill" : "waveform")
                        .font(.system(size: 44)).foregroundStyle(.blue).padding(.top, 12)
                    Text(controller.message).multilineTextAlignment(.center)
                    if controller.phase == .recording {
                        ProgressView(value: controller.level).frame(maxWidth: 300)
                            .accessibilityLabel("Уровень микрофона")
                        Text(String(format: "%d:%02d", controller.elapsed / 60, controller.elapsed % 60)).monospacedDigit()
                    }
                    if [.preparing, .recognizing, .cancelling].contains(controller.phase) {
                        if controller.phase == .preparing { ProgressView(value: controller.progress).frame(maxWidth: 300) }
                        else { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        Button(controller.phase == .recording ? "Завершить запись" : "Начать запись") {
                            if controller.phase == .recording { controller.endRecording() } else { controller.beginRecording() }
                        }.buttonStyle(.borderedProminent).disabled(!controller.canRecord && controller.phase != .recording)
                        if controller.busy { Button("Отменить") { controller.cancel() }.disabled(controller.phase == .cancelling) }
                    }
                    if controller.phase == .idle {
                        Button("Подготовить модель") { tab = "settings" }.buttonStyle(.link)
                    }
                    if !controller.microphoneAllowed {
                        Button("Разрешить микрофон") { controller.requestMicrophone() }.buttonStyle(.link)
                    }
                }.frame(maxWidth: .infinity).padding(18)
            }
            if !controller.transcript.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Результат").fontWeight(.semibold); Spacer(); Button("Скопировать") { controller.copyTranscript() } }
                        Text(controller.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Настройки").font(.title2.bold())
            GroupBox("Модель распознавания") {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SpeechModel.allCases) { model in
                        HStack {
                            Image(systemName: controller.preferences.model == model ? "checkmark.circle.fill" : "circle").foregroundStyle(.blue)
                            VStack(alignment: .leading) { Text(model.title); Text(model.detail).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if ModelStore.isPresent(model) { Text("На Mac").font(.caption).foregroundStyle(.secondary) }
                            Button("Выбрать") { controller.selectModel(model) }.disabled(controller.busy || controller.preferences.model == model)
                        }
                    }
                    HStack {
                        Button("Скачать модель") { controller.prepare(download: true) }.buttonStyle(.borderedProminent).disabled(controller.busy)
                        Button("Загрузить без сети") { controller.prepare(download: false) }.disabled(controller.busy || !ModelStore.isPresent(controller.preferences.model))
                        Spacer()
                        Button("Удалить…", role: .destructive) { confirmRemoval = true }.disabled(controller.busy || !ModelStore.isPresent(controller.preferences.model))
                    }
                    if controller.phase == .preparing { ProgressView(value: controller.progress); Text(controller.message).font(.caption) }
                }.padding(12)
            }
            GroupBox("Запись") {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Микрофон", selection: $controller.preferences.inputUID) {
                        Text("Системный вход").tag("")
                        ForEach(controller.devices) { Text($0.name).tag($0.id) }
                        if !controller.preferences.inputUID.isEmpty, !controller.devices.contains(where: { $0.id == controller.preferences.inputUID }) {
                            Text("Микрофон отключён").tag(controller.preferences.inputUID)
                        }
                    }
                    Picker("Язык", selection: $controller.preferences.language) {
                        ForEach(SpeechLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Горячая клавиша", selection: $controller.preferences.recordingMode) {
                        Text("Удержание").tag(RecordingMode.hold)
                        Text("Повторное нажатие").tag(RecordingMode.toggle)
                    }.pickerStyle(.segmented)
                    KeyboardShortcuts.Recorder("Сочетание клавиш", name: .recordVoice)
                    Toggle("Вставлять в исходное поле", isOn: $controller.preferences.pasteAutomatically)
                }.padding(12).disabled(controller.busy)
            }
            HStack {
                Label(controller.microphoneAllowed ? "Микрофон разрешён" : "Нужен микрофон", systemImage: "mic")
                Button("Настроить") { controller.requestMicrophone() }
                Spacer()
                Label(controller.pasteAllowed ? "Вставка разрешена" : "Нужен Универсальный доступ", systemImage: "text.cursor")
                Button("Настроить") { controller.requestPaste() }
            }.font(.caption)
        }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Личный словарь").font(.title2.bold())
            Text("Замены применяются к целым словам и фразам перед копированием. Хранятся на этом Mac.").foregroundStyle(.secondary)
            HStack {
                TextField("Модель пишет", text: $original)
                Image(systemName: "arrow.right")
                TextField("Заменить на", text: $replacement)
                Button("Добавить") {
                    controller.preferences.replacements.append(.init(original: original.trimmingCharacters(in: .whitespacesAndNewlines), replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines)))
                    original = ""; replacement = ""
                }.disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || original.count > 100 || replacement.count > 300 || controller.preferences.replacements.count >= 200)
            }.textFieldStyle(.roundedBorder)
            ForEach(controller.preferences.replacements) { rule in
                HStack {
                    Text(rule.original); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(rule.replacement)
                    Spacer()
                    Button(rule.enabled ? "Отключить" : "Включить") {
                        if let index = controller.preferences.replacements.firstIndex(where: { $0.id == rule.id }) { controller.preferences.replacements[index].enabled.toggle() }
                    }
                    Button("Удалить", role: .destructive) { controller.preferences.replacements.removeAll { $0.id == rule.id } }
                }.opacity(rule.enabled ? 1 : 0.5)
            }
        }.disabled(controller.busy)
    }

    private var licenseSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Лицензии и авторы моделей").font(.title2.bold())
            ScrollView {
                Text(licenseText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Закрыть") { showLicenses = false }
        }.padding(24).frame(width: 650, height: 520)
    }
    private var licenseText: String {
        let names = ["LICENSE", "ModelCredits", "FluidAudio", "WhisperKit", "KeyboardShortcuts", "SwiftArgumentParser", "Whisper"]
        return names.compactMap { name in
            let url = Bundle.main.url(forResource: name, withExtension: name == "LICENSE" ? nil : "txt")
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { "\(name)\n\n\($0)" }
        }.joined(separator: "\n\n────────────────────\n\n")
    }
}
