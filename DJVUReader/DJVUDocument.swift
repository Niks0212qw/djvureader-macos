import Foundation
import AppKit
import PDFKit

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
    
    private var documentURL: URL?
    private var imageCache: [Int: NSImage] = [:]
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
            print(" Создана временная копия: \(tempURL.lastPathComponent)")
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
            self.imageCache.removeAll()
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
                print(" Текущий кэш содержит \(self.imageCache.count) страниц")
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
                print(" Добавили страницу \(pageIndex + 1) из кэша")
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
            let batchSize = 3 // Загружаем по 3 страницы одновременно
            let totalBatches = (pagesToLoad.count + batchSize - 1) / batchSize
            
            for batchIndex in 0..<totalBatches {
                let startIndex = batchIndex * batchSize
                let endIndex = min(startIndex + batchSize, pagesToLoad.count)
                let batchPages = Array(pagesToLoad[startIndex..<endIndex])
                
                let group = DispatchGroup()
                
                for pageIndex in batchPages {
                    group.enter()
                    self.backgroundQueue.async {
                        self.loadPageForContinuous(pageIndex: pageIndex) {
                            group.leave()
                        }
                    }
                }
                
                group.wait()
                
                DispatchQueue.main.async {
                    let loadedCount = self.continuousImages.count
                    self.continuousLoadingProgress = Double(loadedCount) / Double(self.totalPages)
                    print(" Прогресс загрузки: \(loadedCount)/\(self.totalPages)")
                }
                
                // Небольшая пауза между батчами
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            DispatchQueue.main.async {
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
                print(" Страница \(pageIndex + 1) взята из кэша для непрерывного просмотра")
            }
            return
        }
        
        // Проверяем, что мы уже не загружаем эту страницу
        guard !continuousLoadingQueue.contains(pageIndex) else {
            print(" Страница \(pageIndex + 1) уже загружается")
            return
        }
        
        continuousLoadingQueue.insert(pageIndex)
        
        defer {
            continuousLoadingQueue.remove(pageIndex)
        }
        
        print(" Загружаем страницу \(pageIndex + 1) для непрерывного просмотра")
        
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
        
        // Сохраняем в оба места одновременно
        cacheQueue.async {
            self.imageCache[pageIndex] = image
            
            DispatchQueue.main.async {
                self.continuousImages[pageIndex] = image
                print(" PDF страница \(pageIndex + 1) загружена для непрерывного просмотра")
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
                if let image = NSImage(contentsOf: tempImageURL) {
                    
                    cacheQueue.async {
                        self.imageCache[pageIndex] = image
                        
                        DispatchQueue.main.async {
                            self.continuousImages[pageIndex] = image
                            print(" DJVU страница \(pageIndex + 1) загружена для непрерывного просмотра")
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
                print(" Найден \(name) по пути: \(path)")
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
                    print(" Найден \(name) через which: \(path)")
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
        
        cacheQueue.async {
            self.imageCache[pageIndex] = image
            self.limitCacheSize()
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
                            if let image = NSImage(contentsOf: currentTempURL) {
                                print(" Успешно загружена страница \(pageIndex + 1)")
                                
                                cacheQueue.async {
                                    self.imageCache[pageIndex] = image
                                    self.limitCacheSize()
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
                print(" Планируем фоновую загрузку страницы \(pageIndex + 1)")
                
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
                print(" Планируем фоновую загрузку страницы \(pageIndex + 1)")
                
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
                print(" Планируем предзагрузку страницы \(pageIndex + 1)")
                
                self.backgroundQueue.async {
                    self.preloadPageSilently(pageIndex: pageIndex, totalToLoad: 0)
                }
            }
        }
    }
    
    private func preloadPageSilently(pageIndex: Int, totalToLoad: Int = 0) {
        print(" Предзагружаем страницу \(pageIndex + 1) в фоне")
        
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
            self.limitCacheSize()
            print(" PDF страница \(pageIndex + 1) предзагружена в кэш")
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
                if let image = NSImage(contentsOf: tempImageURL) {
                    cacheQueue.async {
                        self.imageCache[pageIndex] = image
                        self.limitCacheSize()
                        print(" DJVU страница \(pageIndex + 1) предзагружена в кэш")
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: tempImageURL)
        } catch {
            print(" Ошибка предзагрузки DJVU страницы \(pageIndex + 1): \(error)")
            try? FileManager.default.removeItem(at: tempImageURL)
        }
    }
    
    private func limitCacheSize() {
        if imageCache.count > 20 { // Увеличиваем размер кэша
            let oldestKeys = Array(imageCache.keys).sorted().prefix(imageCache.count - 15)
            for key in oldestKeys {
                imageCache.removeValue(forKey: key)
            }
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
            self.imageCache.removeAll()
            self.thumbnailCache.removeAll()
        }
        
        DispatchQueue.main.async {
            self.continuousImages.removeAll()
        }
    }
}
