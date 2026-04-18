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
    private struct ContinuousRenderRequest: Hashable {
        let generation: UInt64
        let pageIndex: Int
        let pixelSize: CGSize
        let isPreview: Bool
        let attempt: Int

        private var pixelArea: CGFloat {
            pixelSize.width * pixelSize.height
        }

        var cacheKey: String {
            "\(pageIndex)-\(Int(pixelSize.width))x\(Int(pixelSize.height))-\(isPreview ? "preview" : "full")"
        }

        func isHigherPriority(than other: ContinuousRenderRequest) -> Bool {
            if generation != other.generation {
                return generation > other.generation
            }

            if isPreview != other.isPreview {
                return !isPreview
            }

            return pixelArea > other.pixelArea * 1.02
        }
    }

    private struct ContinuousRenderedPage {
        let image: NSImage
        let pixelSize: CGSize
        let isPreview: Bool

        private var pixelArea: CGFloat {
            pixelSize.width * pixelSize.height
        }

        func satisfies(_ request: ContinuousRenderRequest) -> Bool {
            let widthOkay = pixelSize.width >= request.pixelSize.width * 0.98
            let heightOkay = pixelSize.height >= request.pixelSize.height * 0.98

            if request.isPreview {
                return widthOkay && heightOkay
            }

            return !isPreview && widthOkay && heightOkay
        }

        func isBetter(than other: ContinuousRenderedPage) -> Bool {
            if isPreview != other.isPreview {
                return !isPreview
            }

            return pixelArea > other.pixelArea * 1.05
        }
    }

    private struct DJVURendererSlot {
        let renderer: DJVULibreRenderer
        let queue: DispatchQueue
    }

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
    @Published private(set) var continuousPageAspectRatios: [Int: CGFloat] = [:]
    @Published private(set) var continuousLayoutVersion: Int = 0

    private let continuousRetentionPadding = 6
    
    private var documentURL: URL?
    private var imageCache: [Int: NSImage] = [:]
    private var thumbnailCache: [Int: NSImage] = [:]
    private var pdfDocument: PDFDocument?
    private var djvuRenderer: DJVULibreRenderer?
    private var djvuRendererSlots: [DJVURendererSlot] = []
    
    private var isLoadingPage: Bool = false
    private var preloadQueue = Set<Int>()
    private var completedPreloads: Int = 0
    private var lastPublishedBackgroundProgress: Double = 0.0
    private var continuousRenderedPages: [Int: ContinuousRenderedPage] = [:]
    private var continuousVisiblePages = Set<Int>()
    private var continuousPendingRequests: [Int: ContinuousRenderRequest] = [:]
    private var continuousInFlightPages = Set<Int>()
    private var continuousRenderGeneration: UInt64 = 0
    private let continuousStateQueue = DispatchQueue(label: "djvu.continuous.state", qos: .userInitiated)
    private let continuousRenderSemaphore = DispatchSemaphore(value: 3)
    
    private let backgroundQueue = DispatchQueue(label: "djvu.background", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "djvu.cache", qos: .utility)
    private let preloadQueue_dispatch = DispatchQueue(label: "djvu.preload", qos: .utility)
    private let continuousRenderQueue = DispatchQueue(label: "djvu.continuous.render", qos: .utility, attributes: .concurrent)
    private let djvuRendererQueue = DispatchQueue(label: "djvu.renderer.queue", qos: .userInitiated)
    
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
            self.lastPublishedBackgroundProgress = 0.0
            self.continuousPageAspectRatios.removeAll()
            self.continuousLayoutVersion &+= 1
        }

        pdfDocument = nil
        djvuRenderer = nil
        djvuRendererSlots = []
        
        // Очищаем кэш в фоне
        cacheQueue.async {
            self.imageCache.removeAll()
            self.thumbnailCache.removeAll()
            self.preloadQueue.removeAll()
        }

        continuousStateQueue.async {
            self.continuousRenderedPages.removeAll()
            self.continuousVisiblePages.removeAll()
            self.continuousPendingRequests.removeAll()
            self.continuousInFlightPages.removeAll()
            self.continuousRenderGeneration &+= 1
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
                self.clearContinuousViewportCache()
                self.populateContinuousFromCache()
            } else {
                self.clearContinuousViewportCache()
            }
        }
    }
    
    private func populateContinuousFromCache() {
        var restoredImages: [Int: NSImage] = [:]

        let candidatePages = [currentPage - 1, currentPage, currentPage + 1]
            .filter { $0 >= 0 && $0 < totalPages }

        for pageIndex in candidatePages {
            guard let image = imageCache[pageIndex] else { continue }
            restoredImages[pageIndex] = image
        }

        DispatchQueue.main.async {
            self.continuousImages = restoredImages
        }
    }

    private func setContinuousPageAspectRatios(_ aspectRatios: [Int: CGFloat]) {
        let applyChanges = {
            self.continuousPageAspectRatios = aspectRatios
            self.continuousLayoutVersion &+= 1
        }

        if Thread.isMainThread {
            applyChanges()
        } else {
            DispatchQueue.main.async(execute: applyChanges)
        }
    }
    
    // MARK: - Непрерывный просмотр
    func updateContinuousVisiblePages(
        pageSizes: [Int: CGSize],
        highPriorityPages: Set<Int>,
        magnification: CGFloat,
        backingScale: CGFloat,
        isInteracting: Bool
    ) {
        guard viewMode == .continuous else { return }

        let requestedPages = Set(pageSizes.keys)
        let keepPages = retainedContinuousPages(around: requestedPages.union([currentPage]))
        let resolvedBackingScale = max(backingScale, 1)
        let resolvedMagnification = max(magnification, 0.5)

        continuousStateQueue.async {
            self.continuousRenderGeneration &+= 1
            let generation = self.continuousRenderGeneration
            self.continuousVisiblePages = keepPages
            self.pruneContinuousRenderedPages(keeping: keepPages)
            self.continuousPendingRequests = self.continuousPendingRequests.filter { keepPages.contains($0.key) }

            DispatchQueue.main.async {
                self.prunePublishedContinuousImages(keeping: keepPages)
            }

            guard !pageSizes.isEmpty else {
                self.publishContinuousLoadingStateLocked()
                return
            }

            let sortedPageIndices = pageSizes.keys.sorted { lhs, rhs in
                let lhsHighPriority = highPriorityPages.contains(lhs)
                let rhsHighPriority = highPriorityPages.contains(rhs)
                if lhsHighPriority != rhsHighPriority {
                    return lhsHighPriority && !rhsHighPriority
                }

                let lhsDistance = abs(lhs - self.currentPage)
                let rhsDistance = abs(rhs - self.currentPage)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }

                return lhs < rhs
            }

            for pageIndex in sortedPageIndices {
                guard let pageSize = pageSizes[pageIndex] else { continue }
                let request = self.makeContinuousRenderRequest(
                    generation: generation,
                    pageIndex: pageIndex,
                    pageSize: pageSize,
                    magnification: resolvedMagnification,
                    backingScale: resolvedBackingScale,
                    isPreview: false
                )
                self.scheduleContinuousRenderLocked(request)
            }

            self.publishContinuousLoadingStateLocked()
        }
    }
    
    private func clearContinuousViewportCache() {
        continuousStateQueue.async {
            self.continuousRenderedPages.removeAll()
            self.continuousVisiblePages.removeAll()
            self.continuousPendingRequests.removeAll()
            self.continuousInFlightPages.removeAll()
            self.continuousRenderGeneration &+= 1
            self.publishContinuousLoadingStateLocked()
        }

        DispatchQueue.main.async {
            self.continuousImages.removeAll()
            self.continuousLoadingProgress = 0
        }
    }

    private func retainedContinuousPages(around seedPages: Set<Int>) -> Set<Int> {
        guard totalPages > 0, !seedPages.isEmpty else { return seedPages }

        var retainedPages = seedPages
        for pageIndex in seedPages {
            let lowerBound = max(0, pageIndex - continuousRetentionPadding)
            let upperBound = min(totalPages - 1, pageIndex + continuousRetentionPadding)
            for neighbor in lowerBound...upperBound {
                retainedPages.insert(neighbor)
            }
        }

        return retainedPages
    }

    private func makeContinuousRenderRequest(
        generation: UInt64,
        pageIndex: Int,
        pageSize: CGSize,
        magnification: CGFloat,
        backingScale: CGFloat,
        isPreview: Bool
    ) -> ContinuousRenderRequest {
        let previewScale: CGFloat = isPreview ? 0.45 : 1.0
        let minimumWidth = isPreview ? 220 : 320
        let pixelWidth = max(minimumWidth, Int(ceil(min(pageSize.width * magnification * backingScale * previewScale, 4096))))
        let aspectRatio = continuousPageAspectRatios[pageIndex] ?? (pageSize.height / max(pageSize.width, 1))
        let pixelHeight = max(1, Int(ceil(min(CGFloat(pixelWidth) * aspectRatio, 4096))))

        return ContinuousRenderRequest(
            generation: generation,
            pageIndex: pageIndex,
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            isPreview: isPreview,
            attempt: 0
        )
    }

    private func scheduleContinuousRenderLocked(_ request: ContinuousRenderRequest) {
        if let existing = continuousRenderedPages[request.pageIndex],
           existing.satisfies(request) {
            publishContinuousImageIfNeeded(existing, for: request.pageIndex)
            return
        }

        if continuousInFlightPages.contains(request.pageIndex) {
            continuousPendingRequests[request.pageIndex] = request
            return
        }

        continuousInFlightPages.insert(request.pageIndex)

        continuousRenderQueue.async {
            self.continuousRenderSemaphore.wait()
            defer { self.continuousRenderSemaphore.signal() }

            let shouldRender = self.shouldExecuteContinuousRender(request)
            let renderedImage = shouldRender ? autoreleasepool {
                self.renderContinuousImage(for: request)
            } : nil

            self.completeContinuousRender(
                renderedImage,
                request: request,
                allowRetry: shouldRender
            )
        }
    }

    private func shouldExecuteContinuousRender(_ request: ContinuousRenderRequest) -> Bool {
        continuousStateQueue.sync {
            guard continuousVisiblePages.contains(request.pageIndex) else {
                return false
            }

            if let existing = continuousRenderedPages[request.pageIndex],
               existing.satisfies(request) {
                return false
            }

            if request.isPreview && request.generation < continuousRenderGeneration {
                return false
            }

            if let pendingRequest = continuousPendingRequests[request.pageIndex],
               pendingRequest != request,
               pendingRequest.isHigherPriority(than: request) {
                return false
            }

            return true
        }
    }

    private func completeContinuousRender(_ image: NSImage?, request: ContinuousRenderRequest, allowRetry: Bool) {
        continuousStateQueue.async {
            self.continuousInFlightPages.remove(request.pageIndex)

            let isRelevant = self.isContinuousRequestRelevantLocked(request)

            if let image, isRelevant {
                let newRecord = ContinuousRenderedPage(
                    image: image,
                    pixelSize: request.pixelSize,
                    isPreview: request.isPreview
                )

                if let existing = self.continuousRenderedPages[request.pageIndex],
                   !newRecord.isBetter(than: existing) {
                    // Keep the better cached record but continue with a pending fresher request if needed.
                } else {
                    self.continuousRenderedPages[request.pageIndex] = newRecord
                    self.publishContinuousImageIfNeeded(newRecord, for: request.pageIndex)
                }
            }

            if allowRetry,
               image == nil,
               isRelevant,
               request.attempt < 2,
               self.continuousPendingRequests[request.pageIndex] == nil {
                let retryRequest = ContinuousRenderRequest(
                    generation: request.generation,
                    pageIndex: request.pageIndex,
                    pixelSize: request.pixelSize,
                    isPreview: request.isPreview,
                    attempt: request.attempt + 1
                )
                self.scheduleContinuousRenderLocked(retryRequest)
            }

            if let pendingRequest = self.continuousPendingRequests[request.pageIndex],
               pendingRequest != request {
                self.continuousPendingRequests.removeValue(forKey: request.pageIndex)
                if self.isContinuousRequestRelevantLocked(pendingRequest) {
                    self.scheduleContinuousRenderLocked(pendingRequest)
                }
            }

            self.publishContinuousLoadingStateLocked()
        }
    }

    private func publishContinuousImageIfNeeded(_ record: ContinuousRenderedPage, for pageIndex: Int) {
        guard continuousVisiblePages.contains(pageIndex) else { return }

        DispatchQueue.main.async {
            guard self.viewMode == .continuous else { return }

            var updatedImages = self.continuousImages
            if let existingImage = updatedImages[pageIndex], existingImage === record.image {
                return
            }
            updatedImages[pageIndex] = record.image
            self.continuousImages = updatedImages
            self.continuousLoadingProgress = 1.0
        }
    }

    private func pruneContinuousRenderedPages(keeping allowedPages: Set<Int>) {
        guard !continuousRenderedPages.isEmpty else { return }

        let stalePages = continuousRenderedPages.keys.filter { !allowedPages.contains($0) }
        for pageIndex in stalePages {
            continuousRenderedPages.removeValue(forKey: pageIndex)
        }
    }
    
    private func prunePublishedContinuousImages(keeping allowedPages: Set<Int>) {
        let stalePages = continuousImages.keys.filter { !allowedPages.contains($0) }
        guard !stalePages.isEmpty else { return }

        var updatedImages = continuousImages
        for pageIndex in stalePages {
            updatedImages.removeValue(forKey: pageIndex)
        }
        continuousImages = updatedImages
    }

    private func renderContinuousImage(for request: ContinuousRenderRequest) -> NSImage? {
        if let pdfDocument = self.pdfDocument {
            return renderPDFPageForContinuous(pageIndex: request.pageIndex, pdfDocument: pdfDocument, pixelSize: request.pixelSize)
        } else if let documentURL = self.documentURL {
            return renderDJVUPageForContinuous(
                pageIndex: request.pageIndex,
                documentURL: documentURL,
                pixelSize: request.pixelSize,
                isPreview: request.isPreview
            )
        }

        return nil
    }

    private func isContinuousRequestRelevantLocked(_ request: ContinuousRenderRequest) -> Bool {
        continuousVisiblePages.contains(request.pageIndex)
    }

    private func publishContinuousLoadingStateLocked() {
        let isLoading = !continuousInFlightPages.isEmpty || !continuousPendingRequests.isEmpty
        DispatchQueue.main.async {
            self.isContinuousLoading = isLoading
        }
    }

    private func renderDJVUPageUsingRenderer(pageIndex: Int, pixelSize: CGSize, isPreview: Bool) -> NSImage? {
        guard let slot = rendererSlot(for: pageIndex) else { return nil }

        do {
            return try slot.queue.sync {
                try slot.renderer.renderPage(at: pageIndex, pixelSize: pixelSize, isPreview: isPreview)
            }
        } catch {
            print(" libdjvu render error для страницы \(pageIndex + 1): \(error.localizedDescription)")
            return nil
        }
    }

    private func preferredDJVUDisplayPixelSize(for pageIndex: Int, maxLongEdge: CGFloat) -> CGSize {
        if let pageSize = primaryDJVUPageSize(at: pageIndex),
           pageSize.width > 0,
           pageSize.height > 0 {
            let scale = min(1.0, maxLongEdge / max(pageSize.width, pageSize.height))
            return CGSize(
                width: max(1, ceil(pageSize.width * scale)),
                height: max(1, ceil(pageSize.height * scale))
            )
        }

        let aspectRatio = continuousPageAspectRatios[pageIndex] ?? (4.0 / 3.0)
        let width = min(maxLongEdge, 2200)
        return CGSize(width: width, height: max(1, ceil(width * aspectRatio)))
    }
    
    private func renderPDFPageForContinuous(pageIndex: Int, pdfDocument: PDFDocument, pixelSize: CGSize) -> NSImage? {
        guard let page = pdfDocument.page(at: pageIndex) else {
            print(" Не удалось получить PDF страницу \(pageIndex + 1)")
            return nil
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setFillColor(NSColor.white.cgColor)
        context?.fill(CGRect(origin: .zero, size: pixelSize))
        context?.interpolationQuality = .high
        context?.scaleBy(
            x: pixelSize.width / max(pageRect.width, 1),
            y: pixelSize.height / max(pageRect.height, 1)
        )
        
        page.draw(with: .mediaBox, to: context!)
        
        context?.restoreGState()
        image.unlockFocus()

        print(" PDF страница \(pageIndex + 1) загружена для непрерывного просмотра")
        return image
    }

    private func renderDJVUPageUsingDDJVU(pageIndex: Int, documentURL: URL, pixelSize: CGSize) -> NSImage? {
        guard let ddjvuPath = findSystemExecutable(name: "ddjvu") else {
            print(" ddjvu не найден для загрузки страницы \(pageIndex + 1)")
            return nil
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
        let settings = [
            "-format=ppm",
            "-page=\(pageIndex + 1)",
            "-size=\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        ]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ddjvuPath)
        task.arguments = settings + [workingURL.path, tempImageURL.path]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempImageURL.path) {
                if let image = NSImage(contentsOf: tempImageURL) {
                    try? FileManager.default.removeItem(at: tempImageURL)
                    return image
                }

                print(" Не удалось создать NSImage из DJVU страницы \(pageIndex + 1)")
            } else {
                print(" Ошибка конвертации DJVU страницы \(pageIndex + 1), код: \(task.terminationStatus)")
            }

            try? FileManager.default.removeItem(at: tempImageURL)
        } catch {
            print(" Исключение при загрузке DJVU страницы \(pageIndex + 1): \(error)")
            try? FileManager.default.removeItem(at: tempImageURL)
        }

        return nil
    }
    
    private func renderDJVUPageForContinuous(pageIndex: Int, documentURL: URL, pixelSize: CGSize, isPreview: Bool) -> NSImage? {
        if isPreview {
            if let renderedImage = renderDJVUPageUsingRenderer(pageIndex: pageIndex, pixelSize: pixelSize, isPreview: true) {
                return renderedImage
            }

            return renderDJVUPageUsingDDJVU(pageIndex: pageIndex, documentURL: documentURL, pixelSize: pixelSize)
        }

        if let renderedImage = renderDJVUPageUsingRenderer(pageIndex: pageIndex, pixelSize: pixelSize, isPreview: false) {
            return renderedImage
        }

        return renderDJVUPageUsingDDJVU(pageIndex: pageIndex, documentURL: documentURL, pixelSize: pixelSize)
    }
    
    // MARK: - PDF Support
    private func loadPDFDocument(from url: URL) {
        djvuRenderer = nil

        guard let pdf = PDFDocument(url: url) else {
            errorMessage = "Не удалось загрузить PDF документ"
            return
        }

        pdfDocument = pdf
        totalPages = pdf.pageCount
        preparePDFContinuousLayoutMetrics(pdf)
        isLoaded = true
        print(" PDF документ загружен, страниц: \(totalPages)")

        loadFirstPageOnly(0)
    }
    
    // MARK: - DJVU Support
    private func loadDJVUDocument(from url: URL) {
        print("Загружаем DJVU файл: \(url.lastPathComponent)")

        do {
            let rendererPool = try createPersistentDJVURenderers(for: url, preferredCount: 3)
            guard let renderer = rendererPool.first else {
                throw NSError(domain: "DJVUDocument", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать renderer pool"])
            }
            djvuRenderer = renderer
            djvuRendererSlots = rendererPool.enumerated().map { index, renderer in
                DJVURendererSlot(
                    renderer: renderer,
                    queue: DispatchQueue(label: "djvu.renderer.queue.\(index)", qos: .userInitiated)
                )
            }

            DispatchQueue.main.async {
                self.totalPages = renderer.pageCount
                self.setContinuousPageAspectRatios(self.swiftAspectRatios(from: renderer.pageAspectRatios))
                self.isLoaded = true
                print(" DJVU документ загружен через libdjvu, страниц: \(renderer.pageCount)")
                self.loadFirstPageOnly(0)
            }
            return
        } catch {
            print(" libdjvu renderer не инициализирован, используем fallback: \(error.localizedDescription)")
        }
        
        guard let djvusedPath = findSystemExecutable(name: "djvused") else {
            errorMessage = "DJVU утилиты не установлены. Установите djvulibre через Homebrew: brew install djvulibre"
            return
        }
        
        getDJVUPageCount(url: url, djvusedPath: djvusedPath)
    }

    private func createPersistentDJVURenderers(for url: URL, preferredCount: Int) throws -> [DJVULibreRenderer] {
        try djvuRendererQueue.sync {
            let rendererCount = max(1, preferredCount)
            return try (0..<rendererCount).map { _ in
                try DJVULibreRenderer(url: url)
            }
        }
    }

    private func rendererSlot(for pageIndex: Int) -> DJVURendererSlot? {
        guard !djvuRendererSlots.isEmpty else {
            guard let djvuRenderer else { return nil }
            return DJVURendererSlot(renderer: djvuRenderer, queue: djvuRendererQueue)
        }

        let slotIndex = pageIndex % djvuRendererSlots.count
        return djvuRendererSlots[slotIndex]
    }

    private func primaryDJVUPageSize(at pageIndex: Int) -> CGSize? {
        if let primarySlot = djvuRendererSlots.first {
            return primarySlot.queue.sync {
                primarySlot.renderer.pageSize(at: pageIndex)
            }
        }

        if let djvuRenderer {
            return djvuRendererQueue.sync {
                djvuRenderer.pageSize(at: pageIndex)
            }
        }

        return nil
    }

    private func swiftAspectRatios(from source: [NSNumber: NSNumber]) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        for (key, value) in source {
            result[key.intValue] = CGFloat(value.doubleValue)
        }
        return result
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
                        let aspectRatios = self.fetchDJVUPageAspectRatios(
                            url: workingURL,
                            totalPages: pages,
                            djvusedPath: djvusedPath
                        )
                        DispatchQueue.main.async {
                            self.totalPages = pages
                            self.continuousPageAspectRatios = aspectRatios
                            self.continuousLayoutVersion &+= 1
                            self.isLoaded = true
                            print(" DJVU документ загружен, страниц: \(pages)")
                            self.loadFirstPageOnly(0)
                        }
                        return
                    }
                    
                    let numbers = trimmedOutput.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                    if let firstNumber = numbers.first, firstNumber > 0 {
                        let aspectRatios = self.fetchDJVUPageAspectRatios(
                            url: workingURL,
                            totalPages: firstNumber,
                            djvusedPath: djvusedPath
                        )
                        DispatchQueue.main.async {
                            self.totalPages = firstNumber
                            self.continuousPageAspectRatios = aspectRatios
                            self.continuousLayoutVersion &+= 1
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

                let aspectRatios: [Int: CGFloat]
                if let djvusedPath = self.findSystemExecutable(name: "djvused") {
                    aspectRatios = self.fetchDJVUPageAspectRatios(
                        url: workingURL,
                        totalPages: foundPages,
                        djvusedPath: djvusedPath
                    )
                } else {
                    aspectRatios = [:]
                }
                
                DispatchQueue.main.async {
                    self.totalPages = foundPages
                    self.continuousPageAspectRatios = aspectRatios
                    self.continuousLayoutVersion &+= 1
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

    private func preparePDFContinuousLayoutMetrics(_ pdfDocument: PDFDocument) {
        var aspectRatios: [Int: CGFloat] = [:]

        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            aspectRatios[pageIndex] = bounds.height / bounds.width
        }

        setContinuousPageAspectRatios(aspectRatios)
    }

    private func fetchDJVUPageAspectRatios(url: URL, totalPages: Int, djvusedPath: String) -> [Int: CGFloat] {
        guard totalPages > 0 else { return [:] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: djvusedPath)
        task.arguments = [url.path]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        let commands = (1...totalPages)
            .map { "select \($0)\nsize" }
            .joined(separator: "\n") + "\n"

        do {
            try task.run()

            if let commandData = commands.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(commandData)
            }
            inputPipe.fileHandleForWriting.closeFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                    print(" Не удалось получить размеры страниц DJVU: \(errorOutput)")
                }
                return [:]
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return [:]
            }

            let lines = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var aspectRatios: [Int: CGFloat] = [:]
            var pageIndex = 0

            for line in lines {
                guard pageIndex < totalPages else { break }

                let numbers = line
                    .components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .compactMap(Int.init)

                guard numbers.count >= 2 else { continue }

                let width = CGFloat(numbers[0])
                let height = CGFloat(numbers[1])
                guard width > 0, height > 0 else { continue }

                aspectRatios[pageIndex] = height / width
                pageIndex += 1
            }

            return aspectRatios
        } catch {
            print(" Ошибка получения размеров страниц DJVU: \(error)")
            return [:]
        }
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
        if let renderedImage = renderDJVUPageUsingRenderer(
            pageIndex: pageIndex,
            pixelSize: preferredDJVUDisplayPixelSize(for: pageIndex, maxLongEdge: 3200),
            isPreview: false
        ) {
            cacheQueue.async {
                self.imageCache[pageIndex] = renderedImage
                self.limitCacheSize()
            }

            DispatchQueue.main.async {
                if self.currentPage == pageIndex {
                    self.currentImage = renderedImage
                    self.isLoading = false
                    self.errorMessage = ""

                    if isFirstPage {
                        self.setViewMode(.continuous)
                    }
                }
                self.isLoadingPage = false
            }

            if !isFirstPage {
                schedulePreloadAdjacentPages(around: pageIndex)
            } else {
                startBackgroundPreloading(from: pageIndex)
            }
            return
        }

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
        guard viewMode == .single else {
            DispatchQueue.main.async {
                self.isBackgroundLoading = false
                self.backgroundLoadingProgress = 0
            }
            return
        }

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
            let progress = Double(self.completedPreloads) / Double(totalToLoad)

            if progress >= 1.0 || progress - self.lastPublishedBackgroundProgress >= 0.05 {
                self.backgroundLoadingProgress = progress
                self.lastPublishedBackgroundProgress = progress
            }
            
            if self.completedPreloads >= totalToLoad {
                self.isBackgroundLoading = false
                self.backgroundLoadingProgress = 1.0
                self.lastPublishedBackgroundProgress = 1.0
                print(" Фоновая предзагрузка завершена: \(self.completedPreloads)/\(totalToLoad)")
            }
        }
    }
    
    private func schedulePreloadAdjacentPages(around centerPage: Int) {
        guard viewMode == .single else { return }

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
        if let renderedImage = renderDJVUPageUsingRenderer(
            pageIndex: pageIndex,
            pixelSize: preferredDJVUDisplayPixelSize(for: pageIndex, maxLongEdge: 2200),
            isPreview: true
        ) {
            cacheQueue.async {
                self.imageCache[pageIndex] = renderedImage
                self.limitCacheSize()
                print(" DJVU страница \(pageIndex + 1) предзагружена через libdjvu")
            }
            return
        }

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
