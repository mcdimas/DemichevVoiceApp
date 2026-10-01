import Foundation
import CryptoKit

struct CatalogFile: Codable, Sendable {
    enum Algorithm: String, Codable, Sendable { case sha256, gitSHA1 }
    let relativePath: String
    let sourceURL: URL
    let byteCount: Int64
    let digest: String
    let algorithm: Algorithm

    func destination(under root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\"), !relativePath.contains("\0"), byteCount > 0 else {
            throw VoiceError("Некорректный путь файла модели.")
        }
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw VoiceError("Файл выходит за каталог модели.") }
        return target
    }

    func verify(_ url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value == byteCount else { return false }
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        if algorithm == .gitSHA1 { sha1.update(data: Data("blob \(byteCount)\0".utf8)) }
        while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if algorithm == .sha256 { sha256.update(data: data) } else { sha1.update(data: data) }
        }
        let hash = algorithm == .sha256 ? Array(sha256.finalize()) : Array(sha1.finalize())
        return hash.map { String(format: "%02x", $0) }.joined() == digest
    }
}

struct ModelCatalog: Codable, Sendable {
    let name: String
    let files: [CatalogFile]
    var size: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    static func bundled(_ model: SpeechModel) throws -> Self {
        guard let url = Bundle.main.url(forResource: model.rawValue, withExtension: "json") else { throw VoiceError("Список файлов модели отсутствует.") }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.name == model.rawValue, !catalog.files.isEmpty else { throw VoiceError("Неверный список файлов модели.") }
        return catalog
    }
}

struct ModelProgress: Sendable {
    let completed: Int64
    let total: Int64
    let description: String
    var fraction: Double { Double(completed) / Double(max(total, 1)) }
}

private final class TransferObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let publish: @Sendable (Int64) -> Void
    init(publish: @escaping @Sendable (Int64) -> Void) { self.publish = publish }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { publish(totalBytesWritten) }
}

actor ModelStore {
    let root: URL
    private var working = false
    init(root: URL = AppStorage.models) { self.root = root }
    nonisolated static func folder(_ model: SpeechModel, root: URL = AppStorage.models) -> URL { root.appendingPathComponent(model.rawValue, isDirectory: true) }
    nonisolated static func isPresent(_ model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: folder(model).appendingPathComponent(".installed").path)
    }

    func prepare(_ model: SpeechModel, allowNetwork: Bool, publish: @escaping @Sendable (ModelProgress) -> Void) async throws -> URL {
        guard !working else { throw VoiceError("Подготовка предыдущей модели ещё не завершена.") }
        working = true
        defer { working = false }
        let fm = FileManager.default
        let directory = Self.folder(model, root: root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalog = try ModelCatalog.bundled(model)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            let destination = try file.destination(under: directory)
            publish(.init(completed: completed, total: catalog.size, description: "Проверка файлов…"))
            if try file.verify(destination) { completed += file.byteCount; continue }
            guard allowNetwork else { throw VoiceError("Модель не установлена или файл повреждён. Нажмите «Скачать модель».") }
            guard file.sourceURL.scheme == "https", file.sourceURL.host == "huggingface.co",
                  file.sourceURL.path.range(of: "/resolve/[a-f0-9]{40}/", options: .regularExpression) != nil else { throw VoiceError("Источник модели не закреплён.") }
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > file.byteCount + 100_000_000 else { throw VoiceError("Недостаточно места для загрузки модели.") }
            let offset = completed
            let observer = TransferObserver { bytes in publish(.init(completed: offset + min(bytes, file.byteCount), total: catalog.size, description: "Загрузка модели…")) }
            var request = URLRequest(url: file.sourceURL)
            request.timeoutInterval = 300
            let (temporary, response) = try await session.download(for: request, delegate: observer)
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, try file.verify(temporary) else { throw VoiceError("Файл модели не прошёл проверку хеша. Повторите загрузку.") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Move only validated files into this app's model directory.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
            completed += file.byteCount
        }
        try Task.checkCancellation()
        try Data(model.rawValue.utf8).write(to: directory.appendingPathComponent(".installed"), options: .atomic)
        publish(.init(completed: catalog.size, total: catalog.size, description: "Файлы проверены"))
        return directory
    }

    func remove(_ model: SpeechModel) throws {
        guard !working else { throw VoiceError("Сначала завершите загрузку.") }
        let directory = Self.folder(model, root: root)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
