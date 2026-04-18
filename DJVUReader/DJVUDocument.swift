import Foundation
import AppKit
import PDFKit
import CoreGraphics
import ImageIO

// MARK: - Pro-style image pipeline
//
// Профессиональные DJVU/PDF-читалки на macOS не держат ленивый NSImage в кэше —
// они хранят уже распакованный CGImage в нативном для CoreAnimation пиксельном
// формате. Это даёт два выигрыша при скролле:
//   1. Распаковка PPM/PNG выполняется один раз, на фоновом потоке, в момент
//      загрузки страницы. При выходе страницы в viewport главный поток уже не
//      тратит время на декодирование.
//   2. Формат пикселей (ARGB8, premultipliedFirst, little-endian) совпадает с
//      форматом, которого ждёт CALayer — GPU заливает текстуру без промежуточной
//      конверсии.
//
// `decodeEagerly(from:)` читает файл прямо через ImageIO, включает
// shouldCacheImmediately и ещё раз рисует результат в CGContext c нативным
// форматом, получая CGImage, указывающий на «собственную» распакованную память.

func decodeEagerly(from url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldCache: true
    ]
    guard let rawCG = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions as CFDictionary) else {
        return nil
    }

    let width = rawCG.width
    let height = rawCG.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        // Fallback: оборачиваем исходный CGImage в NSImage как есть.
        let rep = NSBitmapImageRep(cgImage: rawCG)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        img.cacheMode = .always
        return img
    }

    context.interpolationQuality = .high
    context.draw(rawCG, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let decoded = context.makeImage() else { return nil }

    let rep = NSBitmapImageRep(cgImage: decoded)
    let img = NSImage(size: NSSize(width: width, height: height))
    img.addRepresentation(rep)
    img.cacheMode = .always
    return img
}

private extension NSCache where KeyType == NSNumber, ObjectType == NSImage {
    subscript(key: Int) -> NSImage? {
        get { object(forKey: NSNumber(value: key)) }
        set {
            if let newValue = newValue {
                setObject(newValue, forKey: NSNumber(value: key))
            } else {
                removeObject(forKey: NSNumber(value: key))
            }
        }
    }
}

// Режим просмотра документа
enum ViewMode: String, CaseIterable, Identifiable {
    case single = "single"
    case continuous = "continuous"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .single: return "Постраничный"
        case .continuous: return "Непрерывный"
        }
    }
}

class DJVUDocument: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var totalPages: Int = 0
    @Published var currentImage: NSImage?
    @Published var isLoaded: Bool = false
    @Published var errorMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var backgroundLoadingProgress: Double = 0.0
    @Published var isBackgroundLoading: Bool = false
    @Published var viewMode: ViewMode = .continuous
    @Published var continuousImages: [Int: NSImage] = [:]
    @Published var continuousLoadingProgress: Double = 0.0
    @Published var isContinuousLoading: Bool = false
    // Соотношение сторон страницы (width/height). Ключ — pageIndex.
    // Заполняется во время открытия документа (djvused size / PDFKit bounds),
    // чтобы placeholder'ы в LazyVStack имели ту же высоту, что и готовая
    // страница — это устраняет скачки layout'а при подгрузке изображений.
    @Published var pageAspectRatios: [Int: CGFloat] = [:]
    // Дефолт на случай, если не удалось получить размеры заранее.
    @Published var defaultPageAspectRatio: CGFloat = 0.707 // ~A4 portrait
    
    private var documentURL: URL?
    private let imageCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 60
        return cache
    }()
    private var thumbnailCache: [Int: NSImage] = [:]
    private var pdfDocument: PDFDocument?
    
    private var isLoadingPage: Bool = false
    private var preloadQueue = Set<Int>()
    private var completedPreloads: Int = 0
    private var continuousLoadingQueue = Set<Int>()
    
    private let backgroundQueue = DispatchQueue(label: "djvu.background", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "djvu.cache", qos: .utility)
    private let preloadQueue_dispatch = DispatchQueue(label: "djvu.preload", qos: .utility)
    private let continuousQueue = DispatchQueue(label: "djvu.continuous", qos: .userInitiated)
    
    private func copyToTempWithASCIIName(originalURL: URL) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let asciiName = "djvu_copy_\(UUID().uuidString).\(originalURL.pathExtension)"
        let tempURL = tempDir.appendingPathComponent(asciiName)
        
        do {
            try FileManager.default.copyItem(at: originalURL, to: tempURL)
            return tempURL
        } catch {
            print(" Не удалось скопировать файл: \(error)")
            return nil
        }
    }
    
    private func hasNonASCIICharacters(in url: URL) -> Bool {
        return !url.lastPathComponent.allSatisfy({ $0.isASCII })
    }
    
    func loadDocument(from url: URL) {
        documentURL = url
        errorMessage = ""
        
        if hasNonASCIICharacters(in: url) {
            print(" Обнаружены non-ASCII символы в имени файла: \(url.lastPathComponent)")
        }
        
        DispatchQueue.main.async {
            self.backgroundLoadingProgress = 0.0
            self.isBackgroundLoading = false
            self.completedPreloads = 0
            self.isLoaded = false
            self.currentImage = nil
            self.continuousImages.removeAll()
            self.continuousLoadingProgress = 0.0
            self.isContinuousLoading = false
        }
        
        // Очищаем кэш в фоне
        cacheQueue.async {
            self.imageCache.removeAllObjects()
            self.thumbnailCache.removeAll()
            self.preloadQueue.removeAll()
            self.continuousLoadingQueue.removeAll()
        }
        
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Нет доступа к выбранному файлу"
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Файл не найден: \(url.lastPathComponent)"
            return
        }
        
        let fileExtension = url.pathExtension.lowercased()
        
        if fileExtension == "pdf" {
            loadPDFDocument(from: url)
        } else if fileExtension == "djvu" || fileExtension == "djv" {
            loadDJVUDocument(from: url)
        } else {
            errorMessage = "Неподдерживаемый формат файла: .\(fileExtension)"
        }
    }
    
    // MARK: - Режим просмотра
    func setViewMode(_ mode: ViewMode) {
        print(" Переключаем режим просмотра с \(viewMode.rawValue) на \(mode.rawValue)")
        
        DispatchQueue.main.async {
            self.viewMode = mode
            
            if mode == .continuous {
                print(" continuousImages содержит \(self.continuousImages.count) страниц")
                
                // Очищаем и заново заполняем continuousImages
                self.continuousImages.removeAll()
                
                // Сначала заполняем continuousImages из кэша
                self.populateContinuousFromCache()
                
                print(" После заполнения из кэша: continuousImages содержит \(self.continuousImages.count) страниц")
                
                // Принудительно обновляем UI несколько раз
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.objectWillChange.send()
                }
                
                self.loadAllPagesForContinuousView()
            }
        }
    }
    
    private func populateContinuousFromCache() {
        var addedCount = 0
        for pageIndex in 0..<totalPages {
            if let image = imageCache[pageIndex] {
                continuousImages[pageIndex] = image
                addedCount += 1
            }
        }
        print(" Добавлено \(addedCount) страниц из кэша в continuousImages")
        print(" Общее количество в continuousImages: \(continuousImages.count)")
        

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    // MARK: - Непрерывный просмотр
    private func loadAllPagesForContinuousView() {
        print(" Начинаем загрузку всех страниц для непрерывного просмотра")
        print(" Уже загружено: \(continuousImages.count)/\(totalPages) страниц")
        
        let pagesToLoad = (0..<totalPages).filter { pageIndex in
            continuousImages[pageIndex] == nil
        }
        
        if pagesToLoad.isEmpty {
            print(" Все страницы уже загружены для непрерывного просмотра")
            DispatchQueue.main.async {
                self.isContinuousLoading = false
                self.continuousLoadingProgress = 1.0
            }
            return
        }
        
        DispatchQueue.main.async {
            self.isContinuousLoading = true
            self.continuousLoadingProgress = Double(self.continuousImages.count) / Double(self.totalPages)
        }
        
        continuousQueue.async {
            let concurrency = 3
            let semaphore = DispatchSemaphore(value: concurrency)
            let group = DispatchGroup()

            for pageIndex in pagesToLoad {
                semaphore.wait()
                group.enter()
                self.backgroundQueue.async {
                    self.loadPageForContinuous(pageIndex: pageIndex) {
                        semaphore.signal()
                        DispatchQueue.main.async {
                            let loadedCount = self.continuousImages.count
                            self.continuousLoadingProgress = Double(loadedCount) / Double(self.totalPages)
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                self.isContinuousLoading = false
                self.continuousLoadingProgress = 1.0
                print(" Все страницы загружены для непрерывного просмотра: \(self.continuousImages.count)/\(self.totalPages)")
            }
        }
    }
    
    private func loadPageForContinuous(pageIndex: Int, completion: @escaping () -> Void) {
        defer { completion() }
        
        // Проверяем кэш сначала
        if let cachedImage = imageCache[pageIndex] {
            DispatchQueue.main.async {
                self.continuousImages[pageIndex] = cachedImage
            }
            return
        }

        // Проверяем, что мы уже не загружаем эту страницу
        guard !continuousLoadingQueue.contains(pageIndex) else {
            return
        }

        continuousLoadingQueue.insert(pageIndex)

        defer {
            continuousLoadingQueue.remove(pageIndex)
        }


        if let pdfDocument = self.pdfDocument {
            loadPDFPageForContinuous(pageIndex: pageIndex, pdfDocument: pdfDocument)
        } else if let documentURL = self.documentURL {
            loadDJVUPageForContinuous(pageIndex: pageIndex, documentURL: documentURL)
        }
    }
    
    private func loadPDFPageForContinuous(pageIndex: Int, pdfDocument: PDFDocument) {
        guard let page = pdfDocument.page(at: pageIndex) else {
            print(" Не удалось получить PDF страницу \(pageIndex + 1)")
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 5.0 // Максимальное разрешение для непрерывного просмотра
        let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.scaleBy(x: scale, y: scale)
        
        page.draw(with: .mediaBox, to: context!)
        
        context?.restoreGState()
        image.unlockFocus()

        self.recordAspectRatio(for: pageIndex, from: image)

        // Сохраняем в оба места одновременно
        cacheQueue.async {
            self.imageCache[pageIndex] = image

            DispatchQueue.main.async {
                self.continuousImages[pageIndex] = image
            }
        }
    }

    private func loadDJVUPageForContinuous(pageIndex: Int, documentURL: URL) {
        guard let ddjvuPath = findSystemExecutable(name: "ddjvu") else {
            print(" ddjvu не найден для загрузки страницы \(pageIndex + 1)")
            return
        }
        
        var workingURL = documentURL
        var needsCleanup = false
        
        if hasNonASCIICharacters(in: documentURL) {
            if let tempURL = copyToTempWithASCIIName(originalURL: documentURL) {
                workingURL = tempURL
                needsCleanup = true
            }
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempImageURL = tempDir.appendingPathComponent("djvu_continuous_\(pageIndex)_\(UUID().uuidString).ppm")
        
        let settings = ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=400"]
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ddjvuPath)
        task.arguments = settings + [workingURL.path, tempImageURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path) {
                if let image = decodeEagerly(from: tempImageURL) {
                    self.recordAspectRatio(for: pageIndex, from: image)
                    cacheQueue.async {
                        self.imageCache[pageIndex] = image

                        DispatchQueue.main.async {
                            self.continuousImages[pageIndex] = image
                        }
                    }
                } else {
                    print(" Не удалось создать NSImage из DJVU страницы \(pageIndex + 1)")
                }
            } else {
                print(" Ошибка конвертации DJVU страницы \(pageIndex + 1), код: \(task.terminationStatus)")
            }
            
            try? FileManager.default.removeItem(at: tempImageURL)
        } catch {
            print(" Исключение при загрузке DJVU страницы \(pageIndex + 1): \(error)")
            try? FileManager.default.removeItem(at: tempImageURL)
        }
    }
    
    // MARK: - PDF Support
    private func loadPDFDocument(from url: URL) {
        guard let pdf = PDFDocument(url: url) else {
            errorMessage = "Не удалось загрузить PDF документ"
            return
        }
        
        pdfDocument = pdf
        totalPages = pdf.pageCount
        isLoaded = true
        print(" PDF документ загружен, страниц: \(totalPages)")

        // Получаем размеры всех страниц из PDFKit сразу — это дешёвая операция,
        // bounds(for:) читает метаданные, а не растеризует страницу. LazyVStack
        // в непрерывном режиме использует эти соотношения для точной геометрии
        // placeholder'ов, что устраняет прыжки layout'а при подгрузке картинок.
        var aspects: [Int: CGFloat] = [:]
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i) {
                let bounds = page.bounds(for: .mediaBox)
                if bounds.width > 0 && bounds.height > 0 {
                    aspects[i] = bounds.width / bounds.height
                }
            }
        }
        if !aspects.isEmpty {
            pageAspectRatios = aspects
            if let first = aspects[0] ?? aspects.values.first {
                defaultPageAspectRatio = first
            }
        }

        loadFirstPageOnly(0)
    }
    
    // MARK: - DJVU Support (без библиотеки)
    private func loadDJVUDocument(from url: URL) {
        print("Загружаем DJVU файл: \(url.lastPathComponent)")
        
        guard let djvusedPath = findSystemExecutable(name: "djvused") else {
            errorMessage = "DJVU утилиты не установлены. Установите djvulibre через Homebrew: brew install djvulibre"
            return
        }
        
        getDJVUPageCount(url: url, djvusedPath: djvusedPath)
    }
    
    private func findSystemExecutable(name: String) -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            print("Ошибка поиска \(name): \(error)")
        }
        
        print(" \(name) не найден")
        return nil
    }
    
    private func getDJVUPageCount(url: URL, djvusedPath: String) {
        var workingURL = url
        var needsCleanup = false
        
        // Проверяем, есть ли в имени файла non-ASCII символы
        if hasNonASCIICharacters(in: url) {
            print(" Обнаружены non-ASCII символы в имени файла, создаем временную копию")
            if let tempURL = copyToTempWithASCIIName(originalURL: url) {
                workingURL = tempURL
                needsCleanup = true
            } else {
                DispatchQueue.main.async {
                    self.errorMessage = "Не удалось обработать файл с русским именем"
                }
                return
            }
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: djvusedPath)
        task.arguments = [workingURL.path, "-e", "n"]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            if let output = String(data: data, encoding: .utf8) {
                print("djvused output: '\(output)'")
            }
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                print("djvused error: '\(errorOutput)'")
            }
            
            if task.terminationStatus == 0 {
                if let output = String(data: data, encoding: .utf8) {
                    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if let pages = Int(trimmedOutput) {
                        DispatchQueue.main.async {
                            self.totalPages = pages
                            self.isLoaded = true
                            print(" DJVU документ загружен, страниц: \(pages)")
                            self.loadFirstPageOnly(0)
                        }
                        // Предзагружаем размеры всех страниц в фоне, чтобы
                        // placeholder'ы в LazyVStack имели точный размер.
                        self.backgroundQueue.async {
                            self.fetchDJVUPageSizes(url: workingURL, djvusedPath: djvusedPath, totalPages: pages)
                        }
                        return
                    }

                    let numbers = trimmedOutput.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                    if let firstNumber = numbers.first, firstNumber > 0 {
                        DispatchQueue.main.async {
                            self.totalPages = firstNumber
                            self.isLoaded = true
                            print(" DJVU документ загружен, страниц: \(firstNumber)")
                            self.loadFirstPageOnly(0)
                        }
                        self.backgroundQueue.async {
                            self.fetchDJVUPageSizes(url: workingURL, djvusedPath: djvusedPath, totalPages: firstNumber)
                        }
                        return
                    }
                }
            }
            
            tryDirectDJVUPageLoad(url: url)
            
        } catch {
            print("Ошибка запуска djvused: \(error)")
            tryDirectDJVUPageLoad(url: url)
        }
    }
    
    // Обновляет pageAspectRatios по факту загрузки изображения — safety net
    // на случай, если djvused/PDFKit не успели или не смогли предзагрузить
    // геометрию. Вызывается после любой успешной загрузки.
    private func recordAspectRatio(for pageIndex: Int, from image: NSImage) {
        let aspect = image.size.width / max(image.size.height, 1)
        guard aspect.isFinite, aspect > 0 else { return }
        DispatchQueue.main.async {
            if self.pageAspectRatios[pageIndex] == nil {
                self.pageAspectRatios[pageIndex] = aspect
            }
            // Если defaultPageAspectRatio ещё «заводской» (~A4), переопределим
            // по первой реально загруженной странице — остальные placeholder'ы
            // получат её геометрию и не прыгнут.
            if abs(self.defaultPageAspectRatio - 0.707) < 0.01, self.pageAspectRatios.count <= 1 {
                self.defaultPageAspectRatio = aspect
            }
        }
    }

    // Получает размеры всех страниц одним вызовом djvused. Это позволяет
    // LazyVStack в непрерывном режиме зарезервировать точную высоту под каждую
    // страницу ДО загрузки её изображения — иначе при подгрузке картинки
    // строка меняет высоту, и весь контент ниже сдвигается («прыжок» страниц).
    private func fetchDJVUPageSizes(url: URL, djvusedPath: String, totalPages: Int) {
        // Собираем скрипт: select 1; size; select 2; size; ...
        var parts: [String] = []
        parts.reserveCapacity(totalPages * 2)
        for page in 1...totalPages {
            parts.append("select \(page); size")
        }
        let script = parts.joined(separator: "; ")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: djvusedPath)
        task.arguments = [url.path, "-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            // Каждая строка имеет вид: "width=2550 height=3300 rotation=0"
            var aspects: [Int: CGFloat] = [:]
            var pageIndex = 0
            for line in output.split(separator: "\n") {
                var width: CGFloat = 0
                var height: CGFloat = 0
                for token in line.split(separator: " ") {
                    if token.hasPrefix("width=") {
                        width = CGFloat(Int(token.dropFirst(6)) ?? 0)
                    } else if token.hasPrefix("height=") {
                        height = CGFloat(Int(token.dropFirst(7)) ?? 0)
                    }
                }
                if width > 0 && height > 0 && pageIndex < totalPages {
                    aspects[pageIndex] = width / height
                    pageIndex += 1
                }
            }

            guard !aspects.isEmpty else { return }
            let firstAspect = aspects[0] ?? aspects.values.first ?? 0.707

            DispatchQueue.main.async {
                self.pageAspectRatios = aspects
                self.defaultPageAspectRatio = firstAspect
            }
        } catch {
            // Не критично — поправим по первой загруженной картинке.
        }
    }

    private func tryDirectDJVUPageLoad(url: URL) {
        guard let ddjvuPath = findSystemExecutable(name: "ddjvu") else {
            DispatchQueue.main.async {
                self.errorMessage = "ddjvu не найден для загрузки страниц"
            }
            return
        }
        
        print("Пробуем прямую загрузку DJVU страниц...")
        
        var workingURL = url
        var needsCleanup = false
        
        if hasNonASCIICharacters(in: url) {
            if let tempURL = copyToTempWithASCIIName(originalURL: url) {
                workingURL = tempURL
                needsCleanup = true
            }
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempImageURL = tempDir.appendingPathComponent("djvu_test_page_1.ppm")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ddjvuPath)
        task.arguments = [
            "-format=ppm",
            "-page=1",
            "-scale=100",
            workingURL.path,
            tempImageURL.path
        ]
        
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path) {
                print(" Первая DJVU страница загружена успешно")
                
                var foundPages = 1
                for pageNum in 2...50 {
                    if testDJVUPageExists(url: workingURL, pageNumber: pageNum, ddjvuPath: ddjvuPath) {
                        foundPages = pageNum
                    } else {
                        break
                    }
                }
                
                try? FileManager.default.removeItem(at: tempImageURL)
                
                DispatchQueue.main.async {
                    self.totalPages = foundPages
                    self.isLoaded = true
                    print(" DJVU определено страниц: \(foundPages)")
                    self.loadFirstPageOnly(0)
                }
            } else {
                try? FileManager.default.removeItem(at: tempImageURL)
                DispatchQueue.main.async {
                    self.errorMessage = "Не удалось загрузить DJVU файл. Проверьте его целостность."
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Ошибка при загрузке DJVU: \(error.localizedDescription)"
            }
        }
    }
    
    private func testDJVUPageExists(url: URL, pageNumber: Int, ddjvuPath: String) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        
        let testSettings = [
            ["-format=ppm", "-page=\(pageNumber)", "-scale=25"],
            ["-format=png", "-page=\(pageNumber)", "-scale=25"],
            ["-format=ppm", "-page=\(pageNumber)", "-scale=10"],
            ["-format=ppm", "-page=\(pageNumber)", "-scale=25", "-mode=black"]
        ]
        
        for settings in testSettings {
            let format = settings.first(where: { $0.hasPrefix("-format=") })?.replacingOccurrences(of: "-format=", with: "") ?? "ppm"
            let tempImageURL = tempDir.appendingPathComponent("djvu_test_page_\(pageNumber).\(format)")
            
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ddjvuPath)
            task.arguments = settings + [url.path, tempImageURL.path]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let exists = task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path)
                try? FileManager.default.removeItem(at: tempImageURL)
                
                if exists {
                    return true
                }
            } catch {
                try? FileManager.default.removeItem(at: tempImageURL)
            }
        }
        
        return false
    }
    
    // MARK: - Page Loading (обновлено с увеличенным разрешением)
    
    private func loadFirstPageOnly(_ pageIndex: Int) {
        guard pageIndex >= 0 && pageIndex < totalPages else {
            print(" Неверный индекс страницы: \(pageIndex)")
            return
        }
        
        print(" Загружаем ТОЛЬКО первую страницу \(pageIndex + 1) без предзагрузки")
        
        if let cachedImage = imageCache[pageIndex] {
            print(" Первая страница \(pageIndex + 1) найдена в кэше")
            DispatchQueue.main.async {
                self.currentImage = cachedImage
                self.currentPage = pageIndex
                self.isLoading = false
                
                self.setViewMode(.continuous)
            }
            
            startBackgroundPreloading(from: pageIndex)
            return
        }
        
        isLoadingPage = true
        
        DispatchQueue.main.async {
            self.isLoading = true
            self.currentPage = pageIndex
        }
        
        backgroundQueue.async {
            if let pdfDocument = self.pdfDocument {
                self.loadPDFPageForDisplay(pageIndex: pageIndex, pdfDocument: pdfDocument, isFirstPage: true)
            } else if let documentURL = self.documentURL {
                self.loadDJVUPageForDisplay(pageIndex: pageIndex, documentURL: documentURL, isFirstPage: true)
            }
        }
    }
    
    func loadPage(_ pageIndex: Int) {
        guard pageIndex >= 0 && pageIndex < totalPages else {
            print(" Неверный индекс страницы: \(pageIndex)")
            return
        }
        
        guard !isLoadingPage else {
            print(" Загрузка уже в процессе, игнорируем запрос на страницу \(pageIndex)")
            return
        }
        
        print("🔄 Загружаем страницу \(pageIndex + 1) по запросу пользователя")
        
        if let cachedImage = imageCache[pageIndex] {
            print(" Страница \(pageIndex + 1) найдена в кэше")
            DispatchQueue.main.async {
                self.currentImage = cachedImage
                self.currentPage = pageIndex
                self.isLoading = false
            }
            
            schedulePreloadAdjacentPages(around: pageIndex)
            return
        }
        
        isLoadingPage = true
        
        DispatchQueue.main.async {
            self.isLoading = true
            self.currentPage = pageIndex
        }
        
        backgroundQueue.async {
            if let pdfDocument = self.pdfDocument {
                self.loadPDFPageForDisplay(pageIndex: pageIndex, pdfDocument: pdfDocument, isFirstPage: false)
            } else if let documentURL = self.documentURL {
                self.loadDJVUPageForDisplay(pageIndex: pageIndex, documentURL: documentURL, isFirstPage: false)
            }
        }
    }
    
    private func loadPDFPageForDisplay(pageIndex: Int, pdfDocument: PDFDocument, isFirstPage: Bool) {
        guard let page = pdfDocument.page(at: pageIndex) else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.isLoadingPage = false
                self.errorMessage = "Не удалось загрузить PDF страницу \(pageIndex + 1)"
            }
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 5.0
        let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.scaleBy(x: scale, y: scale)
        
        page.draw(with: .mediaBox, to: context!)
        
        context?.restoreGState()
        image.unlockFocus()

        self.recordAspectRatio(for: pageIndex, from: image)

        cacheQueue.async {
            self.imageCache[pageIndex] = image
        }

        DispatchQueue.main.async {
            if self.currentPage == pageIndex {
                self.currentImage = image
                self.isLoading = false
                self.errorMessage = ""
                print(" PDF страница \(pageIndex + 1) загружена успешно")
                
                // Всегда переключаемся на непрерывный режим после загрузки первой страницы
                if isFirstPage {
                    self.setViewMode(.continuous)
                }
            } else {
                print(" PDF страница \(pageIndex + 1) загружена, но currentPage уже изменился")
            }
            self.isLoadingPage = false
        }
        
        if !isFirstPage {
            schedulePreloadAdjacentPages(around: pageIndex)
        } else {
            startBackgroundPreloading(from: pageIndex)
        }
    }
    
    private func loadDJVUPageForDisplay(pageIndex: Int, documentURL: URL, isFirstPage: Bool) {
        guard let ddjvuPath = findSystemExecutable(name: "ddjvu") else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.isLoadingPage = false
                self.errorMessage = "ddjvu не найден"
            }
            return
        }
        
        var workingURL = documentURL
        var needsCleanup = false
        
        // Обрабатываем русские имена файлов
        if hasNonASCIICharacters(in: documentURL) {
            if let tempURL = copyToTempWithASCIIName(originalURL: documentURL) {
                workingURL = tempURL
                needsCleanup = true
            }
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempImageURL = tempDir.appendingPathComponent("djvu_page_\(pageIndex)_\(UUID().uuidString).ppm")
        
        let conversionSettings = [
            ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=400"],
            ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=350"],
            ["-format=png", "-page=\(pageIndex + 1)", "-scale=400"],
            ["-format=tiff", "-page=\(pageIndex + 1)", "-scale=400"],
            ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=300", "-mode=color"],
            ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=250", "-mode=black"]
        ]
        
        for (attemptIndex, settings) in conversionSettings.enumerated() {
            print("Попытка \(attemptIndex + 1)/\(conversionSettings.count) для страницы \(pageIndex + 1)")
            
            let format = settings.first(where: { $0.hasPrefix("-format=") })?.replacingOccurrences(of: "-format=", with: "") ?? "ppm"
            let currentTempURL = tempDir.appendingPathComponent("djvu_page_\(pageIndex)_\(UUID().uuidString).\(format)")
            
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ddjvuPath)
            task.arguments = settings + [workingURL.path, currentTempURL.path]
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: currentTempURL.path) {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: currentTempURL.path),
                       let fileSize = attributes[.size] as? Int64 {
                        
                        if fileSize > 1000 {
                            if let image = decodeEagerly(from: currentTempURL) {
                                self.recordAspectRatio(for: pageIndex, from: image)
                                print(" Успешно загружена страница \(pageIndex + 1)")
                                
                                cacheQueue.async {
                                    self.imageCache[pageIndex] = image
                                }
                                
                                DispatchQueue.main.async {
                                    if self.currentPage == pageIndex {
                                        self.currentImage = image
                                        self.isLoading = false
                                        self.errorMessage = ""
                                        print(" DJVU страница \(pageIndex + 1) отображена")
                                        
                                        // Если это первая страница, переключаемся на непрерывный режим
                                        if isFirstPage {
                                            self.setViewMode(.continuous)
                                        }
                                    } else {
                                        print(" DJVU страница \(pageIndex + 1) загружена, но currentPage уже изменился на \(self.currentPage + 1)")
                                    }
                                    self.isLoadingPage = false
                                }
                                
                                try? FileManager.default.removeItem(at: currentTempURL)
                                
                                if !isFirstPage {
                                    self.schedulePreloadAdjacentPages(around: pageIndex)
                                } else {
                                    self.startBackgroundPreloading(from: pageIndex)
                                }
                                
                                return
                            }
                        }
                    }
                }
                
                try? FileManager.default.removeItem(at: currentTempURL)
                
            } catch {
                print(" Исключение при запуске ddjvu: \(error)")
                try? FileManager.default.removeItem(at: currentTempURL)
            }
        }
        
        DispatchQueue.main.async {
            self.isLoading = false
            self.isLoadingPage = false
            self.errorMessage = "Не удалось загрузить страницу \(pageIndex + 1). Возможно, она имеет сложную структуру."
        }
    }
    
    // MARK: - Фоновая предзагрузка
    private func startBackgroundPreloading(from startPage: Int) {
        print(" Запускаем фоновую предзагрузку всего документа, начиная с окрестности страницы \(startPage + 1)")
        
        let totalPagesToPreload = totalPages - 1
        
        DispatchQueue.main.async {
            self.isBackgroundLoading = true
            self.backgroundLoadingProgress = 0.0
            self.completedPreloads = 0
        }
        
        preloadQueue_dispatch.async {
            let nearbyPages = [
                startPage + 1, startPage - 1,
                startPage + 2, startPage - 2,
                startPage + 3, startPage - 3
            ].filter { $0 >= 0 && $0 < self.totalPages && $0 != startPage }
            
            for pageIndex in nearbyPages {
                guard self.imageCache[pageIndex] == nil,
                      !self.preloadQueue.contains(pageIndex) else {
                    self.updateBackgroundProgress(totalToLoad: totalPagesToPreload)
                    continue
                }
                
                self.preloadQueue.insert(pageIndex)

                self.backgroundQueue.async {
                    self.preloadPageSilently(pageIndex: pageIndex, totalToLoad: totalPagesToPreload)
                }

                Thread.sleep(forTimeInterval: 0.1)
            }

            for pageIndex in 0..<self.totalPages {
                guard pageIndex != startPage,
                      !nearbyPages.contains(pageIndex),
                      self.imageCache[pageIndex] == nil,
                      !self.preloadQueue.contains(pageIndex) else {
                    self.updateBackgroundProgress(totalToLoad: totalPagesToPreload)
                    continue
                }

                self.preloadQueue.insert(pageIndex)

                self.backgroundQueue.async {
                    self.preloadPageSilently(pageIndex: pageIndex, totalToLoad: totalPagesToPreload)
                }

                Thread.sleep(forTimeInterval: 0.2)
            }
            
            print(" Фоновая предзагрузка всех страниц запланирована")
        }
    }
    
    private func updateBackgroundProgress(totalToLoad: Int) {
        DispatchQueue.main.async {
            self.completedPreloads += 1
            self.backgroundLoadingProgress = Double(self.completedPreloads) / Double(totalToLoad)
            
            if self.completedPreloads >= totalToLoad {
                self.isBackgroundLoading = false
                print(" Фоновая предзагрузка завершена: \(self.completedPreloads)/\(totalToLoad)")
            }
        }
    }
    
    private func schedulePreloadAdjacentPages(around centerPage: Int) {
        let pagesToPreload = [centerPage - 1, centerPage + 1]
        
        preloadQueue_dispatch.async {
            for pageIndex in pagesToPreload {
                guard pageIndex >= 0 && pageIndex < self.totalPages,
                      self.imageCache[pageIndex] == nil,
                      !self.preloadQueue.contains(pageIndex) else { continue }
                
                self.preloadQueue.insert(pageIndex)

                self.backgroundQueue.async {
                    self.preloadPageSilently(pageIndex: pageIndex, totalToLoad: 0)
                }
            }
        }
    }
    
    private func preloadPageSilently(pageIndex: Int, totalToLoad: Int = 0) {
        defer {
            preloadQueue_dispatch.async {
                self.preloadQueue.remove(pageIndex)
            }
            
            if totalToLoad > 0 {
                self.updateBackgroundProgress(totalToLoad: totalToLoad)
            }
        }
        
        if let pdfDocument = self.pdfDocument {
            self.preloadPDFPageSilently(pageIndex: pageIndex, pdfDocument: pdfDocument)
        } else if let documentURL = self.documentURL {
            self.preloadDJVUPageSilently(pageIndex: pageIndex, documentURL: documentURL)
        }
    }
    
    private func preloadPDFPageSilently(pageIndex: Int, pdfDocument: PDFDocument) {
        guard let page = pdfDocument.page(at: pageIndex) else { return }
        
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4.0
        let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.scaleBy(x: scale, y: scale)
        
        page.draw(with: .mediaBox, to: context!)
        
        context?.restoreGState()
        image.unlockFocus()
        
        cacheQueue.async {
            self.imageCache[pageIndex] = image
        }
    }

    private func preloadDJVUPageSilently(pageIndex: Int, documentURL: URL) {
        guard let ddjvuPath = findSystemExecutable(name: "ddjvu") else { return }
        
        var workingURL = documentURL
        var needsCleanup = false
        
        if hasNonASCIICharacters(in: documentURL) {
            if let tempURL = copyToTempWithASCIIName(originalURL: documentURL) {
                workingURL = tempURL
                needsCleanup = true
            }
        }
        
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempImageURL = tempDir.appendingPathComponent("djvu_preload_\(pageIndex)_\(UUID().uuidString).ppm")
        
        let settings = ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=300"]
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ddjvuPath)
        task.arguments = settings + [workingURL.path, tempImageURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path) {
                if let image = decodeEagerly(from: tempImageURL) {
                    cacheQueue.async {
                        self.imageCache[pageIndex] = image
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: tempImageURL)
        } catch {
            print(" Ошибка предзагрузки DJVU страницы \(pageIndex + 1): \(error)")
            try? FileManager.default.removeItem(at: tempImageURL)
        }
    }
    
    // MARK: - Thumbnail Support
    func getThumbnail(for pageIndex: Int) -> NSImage? {
        return thumbnailCache[pageIndex]
    }
    
    func loadThumbnail(for pageIndex: Int, completion: @escaping (NSImage?) -> Void) {
        if let thumbnail = thumbnailCache[pageIndex] {
            completion(thumbnail)
            return
        }
        
        backgroundQueue.async {
            var thumbnailImage: NSImage?
            
            if let pdfDocument = self.pdfDocument,
               let page = pdfDocument.page(at: pageIndex) {
                let pageRect = page.bounds(for: .mediaBox)
                let aspectRatio = pageRect.width / pageRect.height
                let thumbnailSize = NSSize(width: min(80, 80 * aspectRatio), height: min(120, 120 / aspectRatio))
                
                thumbnailImage = NSImage(size: thumbnailSize)
                thumbnailImage?.lockFocus()
                
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.scaleBy(x: thumbnailSize.width / pageRect.width, y: thumbnailSize.height / pageRect.height)
                page.draw(with: .mediaBox, to: context!)
                context?.restoreGState()
                
                thumbnailImage?.unlockFocus()
                
            } else if let documentURL = self.documentURL,
                      let ddjvuPath = self.findSystemExecutable(name: "ddjvu") {
                
                var workingURL = documentURL
                var needsCleanup = false
                
                if self.hasNonASCIICharacters(in: documentURL) {
                    if let tempURL = self.copyToTempWithASCIIName(originalURL: documentURL) {
                        workingURL = tempURL
                        needsCleanup = true
                    }
                }
                
                defer {
                    if needsCleanup {
                        try? FileManager.default.removeItem(at: workingURL)
                    }
                }
                
                let tempDir = FileManager.default.temporaryDirectory
                
                let thumbnailSettings = [
                    ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=50"],
                    ["-format=png", "-page=\(pageIndex + 1)", "-scale=50"],
                    ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=30"],
                    ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=50", "-mode=color"],
                    ["-format=ppm", "-page=\(pageIndex + 1)", "-scale=25"]
                ]
                
                for settings in thumbnailSettings {
                    let format = settings.first(where: { $0.hasPrefix("-format=") })?.replacingOccurrences(of: "-format=", with: "") ?? "ppm"
                    let tempImageURL = tempDir.appendingPathComponent("djvu_thumb_\(pageIndex)_\(UUID().uuidString).\(format)")
                    
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: ddjvuPath)
                    task.arguments = settings + [workingURL.path, tempImageURL.path]
                    
                    do {
                        try task.run()
                        task.waitUntilExit()
                        
                        if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path) {
                            if let originalImage = NSImage(contentsOf: tempImageURL) {
                                let thumbnailSize = NSSize(width: 80, height: 120)
                                thumbnailImage = NSImage(size: thumbnailSize)
                                thumbnailImage?.lockFocus()
                                originalImage.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                                                 from: NSRect(origin: .zero, size: originalImage.size),
                                                 operation: .copy,
                                                 fraction: 1.0)
                                thumbnailImage?.unlockFocus()
                                
                                try? FileManager.default.removeItem(at: tempImageURL)
                                break
                            }
                        }
                        
                        try? FileManager.default.removeItem(at: tempImageURL)
                    } catch {
                        print("Ошибка создания DJVU миниатюры: \(error)")
                        try? FileManager.default.removeItem(at: tempImageURL)
                    }
                }
            }
            
            if let thumbnail = thumbnailImage {
                self.cacheQueue.async {
                    self.thumbnailCache[pageIndex] = thumbnail
                }
            }
            
            completion(thumbnailImage)
        }
    }
    
    // MARK: - Navigation
    func nextPage() {
        guard !isLoadingPage else {
            print(" Загрузка в процессе, игнорируем nextPage")
            return
        }
        
        if currentPage < totalPages - 1 {
            print(" Переходим на следующую страницу: \(currentPage + 1) → \(currentPage + 2)")
            loadPage(currentPage + 1)
        } else {
            print(" Уже на последней странице")
        }
    }
    
    func previousPage() {
        guard !isLoadingPage else {
            print(" Загрузка в процессе, игнорируем previousPage")
            return
        }
        
        if currentPage > 0 {
            print(" Переходим на предыдущую страницу: \(currentPage + 1) → \(currentPage)")
            loadPage(currentPage - 1)
        } else {
            print(" Уже на первой странице")
        }
    }
    
    func goToPage(_ page: Int) {
        guard !isLoadingPage else {
            print(" Загрузка в процессе, игнорируем goToPage(\(page))")
            return
        }
        
        if page >= 0 && page < totalPages && page != currentPage {
            print(" Переходим на страницу: \(currentPage + 1) → \(page + 1)")
            loadPage(page)
        } else if page == currentPage {
            print(" Уже на странице \(page + 1)")
        } else {
            print(" Неверный номер страницы: \(page + 1)")
        }
    }
    
    // MARK: - Cache Management
    func clearCache() {
        cacheQueue.async {
            self.imageCache.removeAllObjects()
            self.thumbnailCache.removeAll()
        }
        
        DispatchQueue.main.async {
            self.continuousImages.removeAll()
        }
    }
}
