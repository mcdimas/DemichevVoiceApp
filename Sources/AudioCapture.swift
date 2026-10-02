import AVFoundation
import AudioToolbox
import CoreAudio

struct InputDevice: Identifiable, Equatable {
    let id: String
    let device: AudioDeviceID
    let name: String
}

enum InputDevices {
    private static func property(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        result.initialize(to: nil)
        defer { result.deinitialize(count: 1); result.deallocate() }
        var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &length, result) == noErr else { return nil }
        return result.pointee?.takeRetainedValue() as String?
    }
    static func available() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var length: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &length) == noErr else { return [] }
        var devices = Array(repeating: AudioDeviceID(0), count: Int(length) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &length, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = property(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = property(device, selector: kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, device: device, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private final class AudioFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var currentLevel = 0.0
    private var writeFailure: Error?
    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }
    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, writeFailure == nil else { return }
        do { try file.write(from: buffer) } catch { writeFailure = error }
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var energy = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { energy += Double(channels[channel][frame]) * Double(channels[channel][frame]) }
        }
        currentLevel = AudioCapture.level(energy: energy / Double(buffer.frameLength) / Double(max(1, buffer.format.channelCount)))
    }
    func meter() -> Double { lock.lock(); defer { lock.unlock() }; return currentLevel }
    func failure() -> Error? { lock.lock(); defer { lock.unlock() }; return writeFailure }
    func close() throws {
        lock.lock(); defer { lock.unlock() }
        file = nil
        if let writeFailure { throw writeFailure }
    }
}

@MainActor protocol AudioRecording: AnyObject {
    var amplitude: Double { get }
    var failure: Error? { get }
    func begin(inputUID: String) throws
    func finish() throws -> URL?
    func discard()
}

enum RecordingFiles {
    static func prepareDirectory(_ root: URL = AppStorage.audio) throws {
        try StorageSafety.check(root, under: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory's attributes do not update a pre-existing directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    static func purgeExpired(under root: URL = AppStorage.audio, now: Date = Date()) throws {
        try StorageSafety.check(root, under: root)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            guard url.pathExtension == "caf", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let date = values.contentModificationDate, now.timeIntervalSince(date) > 86_400 else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor final class AudioCapture: AudioRecording {
    private var engine: AVAudioEngine?
    private var sink: AudioFileSink?
    private var url: URL?
    var amplitude: Double { sink?.meter() ?? 0 }
    var failure: Error? {
        if let error = sink?.failure() { return error }
        if let engine, !engine.isRunning { return VoiceError("Аудиоустройство изменилось или запись прервана. Начните запись снова.") }
        return nil
    }

    nonisolated static func level(energy: Double) -> Double {
        guard energy.isFinite, energy > 0 else { return 0 }
        let decibels = 10 * log10(energy)
        return min(1, max(0, (decibels + 48) / 42))
    }

    func begin(inputUID: String) throws {
        guard engine == nil else { throw VoiceError("Запись уже включена.") }
        let selected = inputUID.isEmpty ? nil : InputDevices.available().first { $0.id == inputUID }
        if !inputUID.isEmpty, selected == nil { throw VoiceError("Выбранный микрофон недоступен.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceError("Разрешите доступ к микрофону.") }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let selected {
            guard let unit = node.audioUnit else { throw VoiceError("Не удалось выбрать микрофон.") }
            var id = selected.device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw VoiceError("Не удалось открыть микрофон (\(status)).") }
        }
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError("Микрофон не передаёт звук.") }
        try RecordingFiles.prepareDirectory()
        let file = AppStorage.audio.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let sink: AudioFileSink
        do {
            sink = try AudioFileSink(url: file, format: format)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { try? FileManager.default.removeItem(at: file); throw error }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.accept(buffer) }
        do { try engine.start() }
        catch {
            node.removeTap(onBus: 0); engine.stop(); try? sink.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        self.engine = engine; self.sink = sink; url = file
    }

    func finish() throws -> URL? {
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        let file = url
        self.engine = nil; url = nil
        defer { sink = nil }
        do { try sink?.close(); return file }
        catch { if let file { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    func discard() { if let file = try? finish() { try? FileManager.default.removeItem(at: file) } }
}
