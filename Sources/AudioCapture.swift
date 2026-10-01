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
        var result: CFString? = nil
        var length = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &length, &result) == noErr else { return nil }
        return result as String?
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
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy = 0.0
        for frame in 0..<Int(buffer.frameLength) { energy += Double(channel[frame]) * Double(channel[frame]) }
        currentLevel = AudioCapture.level(energy: energy / Double(buffer.frameLength))
    }
    func meter() -> Double { lock.lock(); defer { lock.unlock() }; return currentLevel }
    func failure() -> Error? { lock.lock(); defer { lock.unlock() }; return writeFailure }
    func close() throws {
        lock.lock(); defer { lock.unlock() }
        file = nil
        if let writeFailure { throw writeFailure }
    }
}

@MainActor final class AudioCapture {
    private var engine: AVAudioEngine?
    private var sink: AudioFileSink?
    private var url: URL?
    var amplitude: Double { sink?.meter() ?? 0 }
    var failure: Error? { sink?.failure() }

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
        try FileManager.default.createDirectory(at: AppStorage.audio, withIntermediateDirectories: true)
        let file = AppStorage.audio.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let sink = try AudioFileSink(url: file, format: format)
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
