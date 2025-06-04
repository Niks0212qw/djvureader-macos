import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

class Logger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
    
    static func log(_ message: String, level: Level = .info, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(filename):\(line)] \(function): \(message)"
        
        #if DEBUG
        print(logMessage)
        #endif
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Simple Document State Manager
class DocumentStateManager: ObservableObject {
    @Published var recentDocuments: [URL] = []
    @Published var lastOpenedDocument: URL?
    
    private let maxRecentDocuments = 10
    private let userDefaults = UserDefaults.standard
    
    init() {
        loadState()
    }
    
    func addRecentDocument(_ url: URL) {
        recentDocuments.removeAll { $0 == url }
        recentDocuments.insert(url, at: 0)
        
        if recentDocuments.count > maxRecentDocuments {
            recentDocuments.removeLast()
        }
        
        lastOpenedDocument = url
        saveState()
    }
    
    func clearRecentDocuments() {
        recentDocuments.removeAll()
        saveState()
    }
    
    private func loadState() {
        if let data = userDefaults.data(forKey: "recentDocuments"),
           let urls = try? JSONDecoder().decode([URL].self, from: data) {
            recentDocuments = urls
        }
        
        if let data = userDefaults.data(forKey: "lastOpenedDocument"),
           let url = try? JSONDecoder().decode(URL.self, from: data) {
            lastOpenedDocument = url
        }
    }
    
    private func saveState() {
        if let data = try? JSONEncoder().encode(recentDocuments) {
            userDefaults.set(data, forKey: "recentDocuments")
        }
        
        if let lastDocument = lastOpenedDocument,
           let data = try? JSONEncoder().encode(lastDocument) {
            userDefaults.set(data, forKey: "lastOpenedDocument")
        }
        
        userDefaults.synchronize()
    }
}

// MARK: - File Manager Extensions
extension FileManager {

    func createDJVUTempDirectory() throws -> URL {
        let tempDir = temporaryDirectory.appendingPathComponent("DJVUReader-\(UUID().uuidString)")
        try createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
    func cleanupOldTempFiles() {
        let tempDir = temporaryDirectory
        
        do {
            let contents = try contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey])
            let cutoffDate = Date().addingTimeInterval(-3600) // 1 час назад
            
            for url in contents {
                if url.lastPathComponent.hasPrefix("djvu_") || url.lastPathComponent.hasPrefix("DJVUReader-") {
                    if let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       creationDate < cutoffDate {
                        try? removeItem(at: url)
                    }
                }
            }
        } catch {
            Logger.log("Ошибка очистки временных файлов: \(error)", level: .error)
        }
    }
    
    func fileSize(at url: URL) -> String {
        do {
            let attributes = try attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        } catch {
            Logger.log("Ошибка получения размера файла: \(error)", level: .error)
        }
        return "Неизвестно"
    }
}

// MARK: - NSImage Extensions
extension NSImage {

    func thumbnail(maxSize: CGSize) -> NSImage {
        let thumbnail = NSImage(size: maxSize)
        thumbnail.lockFocus()
        
        let aspectRatio = size.width / size.height
        let targetAspectRatio = maxSize.width / maxSize.height
        
        var drawRect: NSRect
        
        if aspectRatio > targetAspectRatio {
           
            let height = maxSize.width / aspectRatio
            drawRect = NSRect(x: 0, y: (maxSize.height - height) / 2, width: maxSize.width, height: height)
        } else {
            
            let width = maxSize.height * aspectRatio
            drawRect = NSRect(x: (maxSize.width - width) / 2, y: 0, width: width, height: maxSize.height)
        }
        
        draw(in: drawRect, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        thumbnail.unlockFocus()
        
        return thumbnail
    }
    
    func optimizedForDisplay() -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        
        let optimized = NSImage(size: size)
        optimized.lockFocus()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.interpolationQuality = .high
        context?.setShouldAntialias(true)
        context?.setAllowsAntialiasing(true)
        
        let rect = NSRect(origin: .zero, size: size)
        context?.draw(cgImage, in: rect)
        
        optimized.unlockFocus()
        return optimized
    }
}

// MARK: - String Extensions
extension String {
    
    func cleanedForSearch() -> String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    func highlightedText(query: String) -> AttributedString {
        var attributedString = AttributedString(self)
        
        let range = self.lowercased().range(of: query.lowercased())
        if let range = range {
            let nsRange = NSRange(range, in: self)
            if let attributedRange = Range<AttributedString.Index>(nsRange, in: attributedString) {
                attributedString[attributedRange].backgroundColor = .yellow
                attributedString[attributedRange].foregroundColor = .black
            }
        }
        
        return attributedString
    }
    
    func isValidPageNumber(totalPages: Int) -> Bool {
        guard let number = Int(self), number >= 1, number <= totalPages else { return false }
        return true
    }
}

// MARK: - URL Extensions
extension URL {
    
    var isDJVUDocument: Bool {
        let djvuExtensions = ["djvu", "djv"]
        return djvuExtensions.contains(pathExtension.lowercased())
    }
    
    var isPDFDocument: Bool {
        return pathExtension.lowercased() == "pdf"
    }
    
    var documentType: String {
        if isDJVUDocument { return "DJVU" }
        if isPDFDocument { return "PDF" }
        return "Неизвестный"
    }
    
    var fileSize: String {
        return FileManager.default.fileSize(at: self)
    }
    
    var modificationDate: Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.modificationDate] as? Date
        } catch {
            return nil
        }
    }
}

// MARK: - Color Extensions
extension Color {
    
    static let djvuPrimary = Color(red: 0.2, green: 0.4, blue: 0.8)
    static let djvuSecondary = Color(red: 0.6, green: 0.7, blue: 0.9)
    static let djvuAccent = Color(red: 0.9, green: 0.6, blue: 0.2)
    
    static let documentBackground = Color(NSColor.textBackgroundColor)
    static let sidebarBackground = Color(NSColor.controlBackgroundColor)
    static let toolbarBackground = Color(NSColor.windowBackgroundColor)
}

// MARK: - Animation Extensions
extension Animation {
    
    static let pageTransition = Animation.easeInOut(duration: 0.3)
    static let zoomTransition = Animation.spring(response: 0.6, dampingFraction: 0.8)
    static let sidebarTransition = Animation.easeInOut(duration: 0.2)
}

// MARK: - Performance Monitor
class PerformanceMonitor: ObservableObject {
    @Published var memoryUsage: Double = 0
    @Published var renderTime: Double = 0
    @Published var cacheHitRate: Double = 0
    
    private var renderStartTime: Date?
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                self.updateMemoryUsage()
            }
            .store(in: &cancellables)
    }
    
    func startRenderTimer() {
        renderStartTime = Date()
    }
    
    func endRenderTimer() {
        if let startTime = renderStartTime {
            renderTime = Date().timeIntervalSince(startTime)
            renderStartTime = nil
        }
    }
    
    func recordCacheHit() {
        cacheHits += 1
        updateCacheHitRate()
    }
    
    func recordCacheMiss() {
        cacheMisses += 1
        updateCacheHitRate()
    }
    
    private func updateMemoryUsage() {

        let processInfo = ProcessInfo.processInfo
        memoryUsage = Double(processInfo.physicalMemory) / (1024 * 1024 * 1024) // GB
    }
    
    private func updateCacheHitRate() {
        let total = cacheHits + cacheMisses
        cacheHitRate = total > 0 ? Double(cacheHits) / Double(total) : 0
    }
}

// MARK: - Error Handling
enum DJVUError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case djvuLibraryNotFound
    case renderingFailed(String)
    case exportFailed(String)
    case invalidPageNumber(Int, Int)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound(let filename):
            return "Файл не найден: \(filename)"
        case .unsupportedFormat(let format):
            return "Неподдерживаемый формат: \(format)"
        case .djvuLibraryNotFound:
            return "DjVu библиотеки не установлены. Установите djvulibre через Homebrew."
        case .renderingFailed(let reason):
            return "Ошибка рендеринга: \(reason)"
        case .exportFailed(let reason):
            return "Ошибка экспорта: \(reason)"
        case .invalidPageNumber(let page, let total):
            return "Неверный номер страницы: \(page). Доступно страниц: \(total)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .djvuLibraryNotFound:
            return "Выполните команду: brew install djvulibre"
        case .unsupportedFormat:
            return "Поддерживаются только файлы DJVU и PDF"
        case .invalidPageNumber:
            return "Введите номер страницы от 1 до максимального"
        default:
            return "Попробуйте открыть другой файл или перезапустить приложение"
        }
    }
}

// MARK: - Simple File Preview
class SimpleFilePreview {
    static func openInFinder(url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    
    static func openWithDefaultApp(url: URL) {
        NSWorkspace.shared.open(url)
    }
    
    static func showFileInfo(url: URL) -> String {
        let fileManager = FileManager.default
        var info = "Информация о файле:\n"
        info += "Имя: \(url.lastPathComponent)\n"
        info += "Путь: \(url.path)\n"
        info += "Размер: \(fileManager.fileSize(at: url))\n"
        
        if let modDate = url.modificationDate {
            info += "Изменен: \(DateFormatter.localizedString(from: modDate, dateStyle: .short, timeStyle: .short))\n"
        }
        
        info += "Тип: \(url.documentType)"
        
        return info
    }
}

// MARK: - Accessibility
extension NSView {
    func setupAccessibility(label: String, hint: String? = nil, role: NSAccessibility.Role = .unknown) {
        setAccessibilityLabel(label)
        if let hint = hint {
            setAccessibilityHelp(hint)
        }
        setAccessibilityRole(role)
        setAccessibilityEnabled(true)
    }
}

// MARK: - Data Extension for File Writing
extension Data {
    func append(to url: URL) throws {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        } else {
            try write(to: url)
        }
    }
}

// MARK: - Safe File Operations
extension FileManager {
    func safeRemoveItem(at url: URL) {
        do {
            try removeItem(at: url)
        } catch {
            Logger.log("Не удалось удалить файл: \(url.lastPathComponent), ошибка: \(error)", level: .warning)
        }
    }
    
    func createDirectoryIfNeeded(at url: URL) throws {
        if !fileExists(atPath: url.path) {
            try createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Combine Extensions
extension Publisher {
    func debounce<S: Scheduler>(for interval: S.SchedulerTimeType.Stride, scheduler: S) -> AnyPublisher<Output, Failure> {
        return debounce(for: interval, scheduler: scheduler).eraseToAnyPublisher()
    }
}
