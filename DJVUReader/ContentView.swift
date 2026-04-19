import AppKit
import SwiftUI

private enum WindowLayoutMode {
    case welcome
    case document
}

struct ContentView: View {
    let initialDocumentURL: URL?
    let participatesInPrimaryOpenQueue: Bool

    @StateObject private var djvuDocument = DJVUDocument()
    @ObservedObject private var documentOpenCoordinator = DocumentOpenCoordinator.shared
    @State private var showingFileImporter = false
    @State private var zoomLevel: Double = 1.0
    @State private var pageOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State private var window: NSWindow?
    @State private var appliedWindowLayout: WindowLayoutMode?
    @State private var didLoadInitialDocument = false
    @State private var isRegisteredAsPrimaryDocumentTarget = false
    @State private var commandObserverTokens: [NSObjectProtocol] = []
    @State private var keyWindowObserverToken: NSObjectProtocol?

    init(initialDocumentURL: URL? = nil, participatesInPrimaryOpenQueue: Bool = true) {
        self.initialDocumentURL = initialDocumentURL
        self.participatesInPrimaryOpenQueue = participatesInPrimaryOpenQueue
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if djvuDocument.isLoaded {
                // Основная область просмотра 
                Group {
                    switch djvuDocument.viewMode {
                    case .single:
                        DocumentView(
                            djvuDocument: djvuDocument,
                            zoomLevel: $zoomLevel,
                            pageOffset: $pageOffset,
                            isTransitioning: $isTransitioning
                        )
                    case .continuous:
                        ContinuousDocumentView(
                            djvuDocument: djvuDocument,
                            zoomLevel: $zoomLevel
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: djvuDocument.viewMode)
                
            } else {
                // Экран приветствия
                WelcomeView(
                    djvuDocument: djvuDocument,
                    showingFileImporter: $showingFileImporter,
                    onOpenDocuments: openDocuments
                )
            }
        }
        .background(WindowAccessor { window in
            handleResolvedWindow(window)
        })
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [
                .init(filenameExtension: "djvu")!,
                .init(filenameExtension: "djv")!,
                .pdf
            ],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                openDocuments(files)
            case .failure(let error):
                print("Ошибка выбора файла: \(error)")
            }
        }
        .onKeyPress(.leftArrow) {
            if djvuDocument.isLoaded && !djvuDocument.isLoading && djvuDocument.viewMode == .single {
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.previousPage()
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if djvuDocument.isLoaded && !djvuDocument.isLoading && djvuDocument.viewMode == .single {
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.nextPage()
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if djvuDocument.isLoaded && djvuDocument.viewMode == .continuous {
                // В непрерывном режиме стрелка вверх переходит к предыдущей странице
                if djvuDocument.currentPage > 0 {
                     withAnimation(.easeInOut(duration: 0.4)) {
                        djvuDocument.goToPage(djvuDocument.currentPage - 1)
                    }
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if djvuDocument.isLoaded && djvuDocument.viewMode == .continuous {
                // В непрерывном режиме стрелка вниз переходит к следующей странице
                if djvuDocument.currentPage < djvuDocument.totalPages - 1 {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        djvuDocument.goToPage(djvuDocument.currentPage + 1)
                    }
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                if djvuDocument.viewMode == .single {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        djvuDocument.nextPage()
                    }
                } else {
                    // В непрерывном режиме пробел прокручивает к следующей странице
                    if djvuDocument.currentPage < djvuDocument.totalPages - 1 {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            djvuDocument.goToPage(djvuDocument.currentPage + 1)
                        }
                    }
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.home) {
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.4)) {
                    djvuDocument.goToPage(0)
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.end) {
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.4)) {
                    djvuDocument.goToPage(djvuDocument.totalPages - 1)
                }
                return .handled
            }
            return .ignored
        }
        .onAppear {
            zoomLevel = 1.0
            setupMenuObservers()
            updatePrimaryDocumentTargetRegistration()

            let initialLayout: WindowLayoutMode = (
                djvuDocument.isLoaded
                || initialDocumentURL != nil
                || documentOpenCoordinator.pendingPrimaryDocumentURL != nil
            )
                ? .document
                : .welcome
            applyWindowLayoutIfNeeded(initialLayout, center: true)
            loadInitialDocumentIfNeeded()
            loadPendingPrimaryDocumentIfNeeded(documentOpenCoordinator.pendingPrimaryDocumentURL)
        }
        .onDisappear {
            removeMenuObservers()
            updatePrimaryDocumentTargetRegistration(forceUnregister: true)
        }
        .onReceive(documentOpenCoordinator.$pendingPrimaryDocumentURL) { url in
            if url != nil, participatesInPrimaryOpenQueue, initialDocumentURL == nil {
                applyWindowLayoutIfNeeded(.document, center: true)
            }
            loadPendingPrimaryDocumentIfNeeded(url)
        }
        .onChange(of: djvuDocument.isLoaded) { _, isLoaded in
            updatePrimaryDocumentTargetRegistration()
            applyWindowLayoutIfNeeded(isLoaded ? .document : .welcome, center: true)
        }
    }
    
    // MARK: - Обработка команд меню
    private func setupMenuObservers() {
        guard commandObserverTokens.isEmpty else { return }
        let notificationCenter = NotificationCenter.default

        commandObserverTokens = [
            notificationCenter.addObserver(forName: .switchToSingleMode, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.setViewMode(.single)
                }
            },
            notificationCenter.addObserver(forName: .switchToContinuousMode, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.setViewMode(.continuous)
                }
            },
            notificationCenter.addObserver(forName: .openDocument, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                showingFileImporter = true
            },
            notificationCenter.addObserver(forName: .previousPage, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                if djvuDocument.isLoaded && !djvuDocument.isLoading {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        djvuDocument.previousPage()
                    }
                }
            },
            notificationCenter.addObserver(forName: .nextPage, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                if djvuDocument.isLoaded && !djvuDocument.isLoading {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        djvuDocument.nextPage()
                    }
                }
            },
            notificationCenter.addObserver(forName: .firstPage, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                if djvuDocument.isLoaded && !djvuDocument.isLoading {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        djvuDocument.goToPage(0)
                    }
                }
            },
            notificationCenter.addObserver(forName: .lastPage, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                if djvuDocument.isLoaded && !djvuDocument.isLoading {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        djvuDocument.goToPage(djvuDocument.totalPages - 1)
                    }
                }
            },
            notificationCenter.addObserver(forName: .zoomIn, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                NotificationCenter.default.post(name: .keyboardZoomChange, object: nil, userInfo: ["delta": 0.25])
            },
            notificationCenter.addObserver(forName: .zoomOut, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                NotificationCenter.default.post(name: .keyboardZoomChange, object: nil, userInfo: ["delta": -0.25])
            },
            notificationCenter.addObserver(forName: .zoomReset, object: nil, queue: .main) { note in
                guard shouldHandleWindowCommand(note) else { return }
                NotificationCenter.default.post(name: .keyboardZoomReset, object: nil)
            }
        ]
    }
    
    private func removeMenuObservers() {
        let notificationCenter = NotificationCenter.default
        commandObserverTokens.forEach { notificationCenter.removeObserver($0) }
        commandObserverTokens.removeAll()

        if let keyWindowObserverToken {
            notificationCenter.removeObserver(keyWindowObserverToken)
            self.keyWindowObserverToken = nil
        }
    }

    private func loadInitialDocumentIfNeeded() {
        guard !didLoadInitialDocument, let initialDocumentURL else { return }
        didLoadInitialDocument = true
        applyWindowLayoutIfNeeded(.document, center: true)
        djvuDocument.loadDocument(from: initialDocumentURL)
    }

    private func loadPendingPrimaryDocumentIfNeeded(_ url: URL?) {
        guard participatesInPrimaryOpenQueue,
              initialDocumentURL == nil,
              !djvuDocument.isLoaded,
              let url,
              url.isSupportedDocumentURL else { return }

        applyWindowLayoutIfNeeded(.document, center: true)
        djvuDocument.loadDocument(from: url)
        documentOpenCoordinator.consumePendingPrimaryDocument()
        updatePrimaryDocumentTargetRegistration()
    }

    private func openDocuments(_ urls: [URL]) {
        let supportedURLs = urls.filter(\.isSupportedDocumentURL)
        guard !supportedURLs.isEmpty else { return }

        if supportedURLs.count > 1 {
            documentOpenCoordinator.openInNewWindows(supportedURLs)
            return
        }

        let canReuseCurrentWindow = initialDocumentURL == nil && !djvuDocument.isLoaded

        if canReuseCurrentWindow, let firstURL = supportedURLs.first {
            applyWindowLayoutIfNeeded(.document, center: true)
            djvuDocument.loadDocument(from: firstURL)
            documentOpenCoordinator.consumePendingPrimaryDocument()
            updatePrimaryDocumentTargetRegistration()
            documentOpenCoordinator.openInNewWindows(Array(supportedURLs.dropFirst()))
            return
        }

        documentOpenCoordinator.openInNewWindows(supportedURLs)
    }

    private func updatePrimaryDocumentTargetRegistration(forceUnregister: Bool = false) {
        let shouldRegister = !forceUnregister
            && participatesInPrimaryOpenQueue
            && initialDocumentURL == nil
            && !djvuDocument.isLoaded

        if shouldRegister && !isRegisteredAsPrimaryDocumentTarget {
            documentOpenCoordinator.registerPrimaryDocumentTarget()
            isRegisteredAsPrimaryDocumentTarget = true
        } else if !shouldRegister && isRegisteredAsPrimaryDocumentTarget {
            documentOpenCoordinator.unregisterPrimaryDocumentTarget()
            isRegisteredAsPrimaryDocumentTarget = false
        }
    }

    private func handleResolvedWindow(_ window: NSWindow) {
        if self.window !== window {
            self.window = window
            installKeyWindowObserver(for: window)
        }

        let preferredLayout: WindowLayoutMode = (
            djvuDocument.isLoaded
            || initialDocumentURL != nil
            || documentOpenCoordinator.pendingPrimaryDocumentURL != nil
        )
            ? .document
            : .welcome
        applyWindowLayoutIfNeeded(preferredLayout, center: true)
    }

    private func applyWindowLayoutIfNeeded(_ layout: WindowLayoutMode, center: Bool) {
        guard let window else { return }
        guard appliedWindowLayout != layout else { return }

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let targetSize: NSSize
        switch layout {
        case .welcome:
            targetSize = AppWindowLayout.welcomeFrameSize(for: visibleFrame)
        case .document:
            targetSize = AppWindowLayout.documentFrameSize(for: visibleFrame)
        }

        let currentFrame = window.frame
        let targetOrigin: NSPoint

        if center, let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            targetOrigin = NSPoint(
                x: screenFrame.midX - targetSize.width / 2,
                y: screenFrame.midY - targetSize.height / 2
            )
        } else {
            targetOrigin = NSPoint(
                x: currentFrame.midX - targetSize.width / 2,
                y: currentFrame.midY - targetSize.height / 2
            )
        }

        let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
        if abs(currentFrame.width - targetSize.width) > 0.5
            || abs(currentFrame.height - targetSize.height) > 0.5
            || abs(currentFrame.origin.x - targetOrigin.x) > 0.5
            || abs(currentFrame.origin.y - targetOrigin.y) > 0.5 {
            window.setFrame(targetFrame, display: true, animate: true)
        }

        appliedWindowLayout = layout
    }

    private func installKeyWindowObserver(for window: NSWindow) {
        if let keyWindowObserverToken {
            NotificationCenter.default.removeObserver(keyWindowObserverToken)
            self.keyWindowObserverToken = nil
        }

        if window.isKeyWindow {
            WindowCommandRouter.shared.activeWindowNumber = window.windowNumber
        }

        keyWindowObserverToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            WindowCommandRouter.shared.activeWindowNumber = window.windowNumber
        }
    }

    private func shouldHandleWindowCommand(_ note: Notification) -> Bool {
        guard let window else { return false }
        guard let targetWindowNumber = note.object as? Int else { return false }
        return targetWindowNumber == window.windowNumber
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

// MARK: - Непрерывный режим на AppKit-скролле как в DjVu Reader Pro
struct ContinuousDocumentView: View {
    @ObservedObject var djvuDocument: DJVUDocument
    @Binding var zoomLevel: Double
    @State private var keyboardZoomObserver: NSObjectProtocol?
    @State private var keyboardResetObserver: NSObjectProtocol?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(NSColor.controlBackgroundColor),
                        Color(NSColor.separatorColor).opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ContinuousScrollViewRepresentable(
                    djvuDocument: djvuDocument,
                    zoomLevel: $zoomLevel,
                    viewportSize: geometry.size
                )
            }
        }
        .onAppear {
            setupKeyboardZoomObservers()
        }
        .onDisappear {
            removeKeyboardZoomObservers()
        }
    }

    private func setupKeyboardZoomObservers() {
        keyboardZoomObserver = NotificationCenter.default.addObserver(
            forName: .keyboardZoomChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let delta = notification.userInfo?["delta"] as? Double else { return }
            zoomLevel = max(0.5, min(3.0, zoomLevel + delta))
        }

        keyboardResetObserver = NotificationCenter.default.addObserver(
            forName: .keyboardZoomReset,
            object: nil,
            queue: .main
        ) { _ in
            zoomLevel = 1.0
        }
    }

    private func removeKeyboardZoomObservers() {
        if let observer = keyboardZoomObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = keyboardResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct ContinuousScrollViewRepresentable: NSViewRepresentable {
    @ObservedObject var djvuDocument: DJVUDocument
    @Binding var zoomLevel: Double
    let viewportSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ContinuousHostingScrollView {
        let scrollView = ContinuousHostingScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0
        scrollView.magnification = CGFloat(max(0.5, min(3.0, zoomLevel)))
        scrollView.contentView.postsBoundsChangedNotifications = true

        let documentView = context.coordinator.documentView
        scrollView.documentView = documentView

        context.coordinator.attach(to: scrollView)
        context.coordinator.update(from: self, on: scrollView, animatedPageNavigation: false)
        return scrollView
    }

    func updateNSView(_ nsView: ContinuousHostingScrollView, context: Context) {
        context.coordinator.update(from: self, on: nsView, animatedPageNavigation: true)
    }

    static func dismantleNSView(_ nsView: ContinuousHostingScrollView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.documentView = nil
    }

    final class Coordinator: NSObject {
        private struct ReadingAnchor {
            let pageIndex: Int
            let relativeX: CGFloat
            let relativeY: CGFloat
        }

        private struct RenderSignature: Equatable {
            let startIndex: Int
            let endIndex: Int
            let magnificationKey: Int
            let isInteracting: Bool
            let layoutVersion: Int
            let documentWidthKey: Int
        }

        var parent: ContinuousScrollViewRepresentable
        let documentView = ContinuousPagesDocumentView()

        private weak var scrollView: ContinuousHostingScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var isUpdatingPageFromScroll = false
        private var isApplyingZoom = false
        private var lastViewportWidth: CGFloat = 0
        private var lastLayoutVersion = 0
        private var lastAppliedCurrentPage: Int?
        private var lastRenderSignature: RenderSignature?
        private var renderRequestWorkItem: DispatchWorkItem?

        init(parent: ContinuousScrollViewRepresentable) {
            self.parent = parent
        }

        func attach(to scrollView: ContinuousHostingScrollView) {
            guard self.scrollView !== scrollView else { return }

            detach()
            self.scrollView = scrollView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleScrollOrMagnificationChange()
            }

            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.documentView.setLiveScrolling(true)
                self?.scheduleVisiblePageRendering(force: true)
            }

            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let scrollView = self.scrollView else { return }
                self.documentView.setLiveScrolling(false)
                self.documentView.setNeedsDisplay(scrollView.contentView.bounds)
                self.scheduleVisiblePageRendering(force: true)
            }
        }

        func detach() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
                self.liveScrollStartObserver = nil
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
                self.liveScrollEndObserver = nil
            }
            renderRequestWorkItem?.cancel()
            renderRequestWorkItem = nil
            scrollView = nil
        }

        func update(from parent: ContinuousScrollViewRepresentable, on scrollView: ContinuousHostingScrollView, animatedPageNavigation: Bool) {
            self.parent = parent
            attach(to: scrollView)

            let clampedZoom = CGFloat(max(0.5, min(3.0, parent.zoomLevel)))
            let zoomWillChange = abs(scrollView.magnification - clampedZoom) > 0.001
            let layoutNeedsAnchorRestore = shouldRestoreAnchorForLayoutChange(parent: parent)
            let preservedAnchor = (layoutNeedsAnchorRestore || zoomWillChange) ? captureReadingAnchor() : nil

            documentView.updateContent(
                totalPages: parent.djvuDocument.totalPages,
                images: parent.djvuDocument.continuousImages,
                pageAspectRatios: parent.djvuDocument.continuousPageAspectRatios,
                layoutVersion: parent.djvuDocument.continuousLayoutVersion,
                viewportWidth: max(parent.viewportSize.width, 1),
                magnification: clampedZoom
            )

            lastViewportWidth = parent.viewportSize.width
            lastLayoutVersion = parent.djvuDocument.continuousLayoutVersion

            if let preservedAnchor, !zoomWillChange {
                restoreReadingAnchor(preservedAnchor, animated: false)
            }

            if zoomWillChange {
                applyMagnification(clampedZoom, on: scrollView, anchor: preservedAnchor)
            }

            if !isUpdatingPageFromScroll {
                scrollToRequestedPageIfNeeded(parent.djvuDocument.currentPage, animated: animatedPageNavigation)
            }

            scheduleVisiblePageRendering()
        }

        private func shouldRestoreAnchorForLayoutChange(parent: ContinuousScrollViewRepresentable) -> Bool {
            abs(lastViewportWidth - parent.viewportSize.width) > 0.5 ||
            lastLayoutVersion != parent.djvuDocument.continuousLayoutVersion
        }

        private func captureReadingAnchor() -> ReadingAnchor? {
            guard let scrollView else { return nil }

            let visibleRect = scrollView.contentView.bounds
            let centerPoint = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
            let pageIndex = documentView.pageIndex(at: centerPoint.y)

            guard let pageFrame = documentView.pageFrame(for: pageIndex),
                  pageFrame.width > 0,
                  pageFrame.height > 0 else {
                return nil
            }

            let relativeX = max(0, min(1, (centerPoint.x - pageFrame.minX) / pageFrame.width))
            let relativeY = max(0, min(1, (centerPoint.y - pageFrame.minY) / pageFrame.height))
            return ReadingAnchor(pageIndex: pageIndex, relativeX: relativeX, relativeY: relativeY)
        }

        private func restoreReadingAnchor(_ anchor: ReadingAnchor, animated: Bool) {
            guard let pageFrame = documentView.pageFrame(for: anchor.pageIndex) else {
                return
            }

            let targetCenter = CGPoint(
                x: pageFrame.minX + pageFrame.width * anchor.relativeX,
                y: pageFrame.minY + pageFrame.height * anchor.relativeY
            )
            scrollToVisibleCenter(targetCenter, animated: animated)
        }

        private func scrollToVisibleCenter(_ centerPoint: CGPoint, animated: Bool) {
            guard let scrollView else { return }

            let clipBounds = scrollView.contentView.bounds
            let documentBounds = documentView.bounds
            let maxX = max(0, documentBounds.width - clipBounds.width)
            let maxY = max(0, documentBounds.height - clipBounds.height)
            let targetOrigin = CGPoint(
                x: min(max(0, centerPoint.x - clipBounds.width / 2), maxX),
                y: min(max(0, centerPoint.y - clipBounds.height / 2), maxY)
            )

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
                }
            } else {
                scrollView.contentView.setBoundsOrigin(targetOrigin)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func scrollToRequestedPageIfNeeded(_ pageIndex: Int, animated: Bool) {
            guard let pageFrame = documentView.pageFrame(for: pageIndex),
                  lastAppliedCurrentPage != pageIndex else {
                return
            }

            let currentVisiblePage = documentView.pageIndex(at: scrollView?.contentView.bounds.midY ?? 0)
            if currentVisiblePage == pageIndex {
                lastAppliedCurrentPage = pageIndex
                return
            }

            guard let scrollView else { return }

            let clipBounds = scrollView.contentView.bounds
            let documentBounds = documentView.bounds
            let maxY = max(0, documentBounds.height - clipBounds.height)
            let targetOrigin = CGPoint(
                x: min(max(0, clipBounds.origin.x), max(0, documentBounds.width - clipBounds.width)),
                y: min(max(0, pageFrame.minY), maxY)
            )

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
                }
            } else {
                scrollView.contentView.setBoundsOrigin(targetOrigin)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
            lastAppliedCurrentPage = pageIndex
        }

        private func applyMagnification(_ magnification: CGFloat, on scrollView: ContinuousHostingScrollView, anchor: ReadingAnchor?) {
            isApplyingZoom = true

            if let anchor,
               let pageFrame = documentView.pageFrame(for: anchor.pageIndex) {
                let centerPoint = CGPoint(
                    x: pageFrame.minX + pageFrame.width * anchor.relativeX,
                    y: pageFrame.minY + pageFrame.height * anchor.relativeY
                )
                scrollView.setMagnification(magnification, centeredAt: centerPoint)
            } else {
                scrollView.magnification = magnification
            }

            DispatchQueue.main.async {
                self.isApplyingZoom = false
                self.handleScrollOrMagnificationChange()
            }
        }

        private func handleScrollOrMagnificationChange() {
            guard let scrollView else { return }

            let visiblePage = documentView.pageIndex(at: scrollView.contentView.bounds.midY)
            lastAppliedCurrentPage = visiblePage

            if !isUpdatingPageFromScroll && parent.djvuDocument.currentPage != visiblePage {
                isUpdatingPageFromScroll = true
                parent.djvuDocument.currentPage = visiblePage
                DispatchQueue.main.async {
                    self.isUpdatingPageFromScroll = false
                }
            }

            if !isApplyingZoom {
                let magnification = Double(scrollView.magnification)
                if abs(parent.zoomLevel - magnification) > 0.001 {
                    parent.zoomLevel = magnification
                }
            }

            scheduleVisiblePageRendering()
        }

        private func scheduleVisiblePageRendering(force: Bool = false) {
            renderRequestWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.requestVisiblePageRendering(force: force)
            }
            renderRequestWorkItem = workItem

            let delay: TimeInterval = force ? 0 : (documentView.isCurrentlyLiveScrolling ? 0.03 : 0.01)
            if delay == 0 {
                workItem.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func requestVisiblePageRendering(force: Bool) {
            guard let scrollView else { return }

            let visibleRect = scrollView.contentView.bounds
            let highPriorityPadding = documentView.isCurrentlyLiveScrolling ? 1 : 0
            let highPriorityStartIndex = max(0, documentView.pageIndex(at: visibleRect.minY) - highPriorityPadding)
            let highPriorityEndIndex = min(parent.djvuDocument.totalPages - 1, documentView.pageIndex(at: visibleRect.maxY) + highPriorityPadding)
            let highPriorityPages = highPriorityStartIndex <= highPriorityEndIndex
                ? Set(highPriorityStartIndex...highPriorityEndIndex)
                : []

            let verticalPrefetchSpan = visibleRect.height * (documentView.isCurrentlyLiveScrolling ? 2.5 : 2.0)
            let bufferedRect = visibleRect.insetBy(dx: 0, dy: -verticalPrefetchSpan)
            let pagePrefetchPadding = documentView.isCurrentlyLiveScrolling ? 8 : 5
            let startIndex = max(0, documentView.pageIndex(at: bufferedRect.minY) - pagePrefetchPadding)
            let endIndex = min(parent.djvuDocument.totalPages - 1, documentView.pageIndex(at: bufferedRect.maxY) + pagePrefetchPadding)
            guard endIndex >= startIndex else { return }

            var pageSizes: [Int: CGSize] = [:]
            for pageIndex in startIndex...endIndex {
                guard let pageFrame = documentView.pageFrame(for: pageIndex) else { continue }
                pageSizes[pageIndex] = pageFrame.size
            }

            let hasAllRequestedImages = pageSizes.keys.allSatisfy { parent.djvuDocument.continuousImages[$0] != nil }

            let signature = RenderSignature(
                startIndex: startIndex,
                endIndex: endIndex,
                magnificationKey: Int((scrollView.magnification * 1000).rounded()),
                isInteracting: documentView.isCurrentlyLiveScrolling,
                layoutVersion: parent.djvuDocument.continuousLayoutVersion,
                documentWidthKey: Int(documentView.bounds.width.rounded())
            )
            if !force, signature == lastRenderSignature, hasAllRequestedImages {
                return
            }
            lastRenderSignature = signature

            parent.djvuDocument.updateContinuousVisiblePages(
                pageSizes: pageSizes,
                highPriorityPages: highPriorityPages,
                magnification: scrollView.magnification,
                backingScale: scrollView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                isInteracting: documentView.isCurrentlyLiveScrolling
            )
        }
    }
}

private final class ContinuousHostingScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
}

private final class ContinuousPagesDocumentView: NSView {
    private static let verticalSpacing: CGFloat = 8
    fileprivate static let placeholderAspectRatio: CGFloat = 0.75

    private var pageFrames: [CGRect] = []
    private var pageImages: [Int: NSImage] = [:]
    private var lastViewportWidth: CGFloat = 0
    private var lastMagnification: CGFloat = 1
    private var lastTotalPages: Int = 0
    private var lastLayoutVersion: Int = 0
    private var pageAspectRatios: [Int: CGFloat] = [:]
    private var knownLoadedPages = Set<Int>()
    private var isLiveScrolling = false

    override var isFlipped: Bool { true }

    func updateContent(
        totalPages: Int,
        images: [Int: NSImage],
        pageAspectRatios: [Int: CGFloat],
        layoutVersion: Int,
        viewportWidth: CGFloat,
        magnification: CGFloat
    ) {
        let previousLoadedPages = knownLoadedPages
        let requiresLayout = totalPages != lastTotalPages ||
            abs(lastViewportWidth - viewportWidth) > 0.5 ||
            abs(lastMagnification - magnification) > 0.001 ||
            lastLayoutVersion != layoutVersion

        if totalPages != lastTotalPages {
            pageImages.removeAll()
        }

        self.pageAspectRatios = pageAspectRatios
        pageImages = images
        knownLoadedPages = Set(images.keys)

        lastViewportWidth = viewportWidth
        lastMagnification = magnification
        lastTotalPages = totalPages
        lastLayoutVersion = layoutVersion

        if requiresLayout {
            layoutPages(totalPages: totalPages, viewportWidth: viewportWidth, magnification: magnification)
            needsDisplay = true
        } else {
            let changedPages = Set(images.keys).symmetricDifference(previousLoadedPages)
            for pageIndex in changedPages {
                if let pageFrame = pageFrame(for: pageIndex) {
                    setNeedsDisplay(pageFrame)
                }
            }
        }
    }

    func pageFrame(for pageIndex: Int) -> CGRect? {
        guard pageIndex >= 0 && pageIndex < pageFrames.count else { return nil }
        return pageFrames[pageIndex]
    }

    func setLiveScrolling(_ isLiveScrolling: Bool) {
        guard self.isLiveScrolling != isLiveScrolling else { return }
        self.isLiveScrolling = isLiveScrolling
        needsDisplay = true
    }

    var isCurrentlyLiveScrolling: Bool {
        isLiveScrolling
    }

    func pageIndex(at y: CGFloat) -> Int {
        guard !pageFrames.isEmpty else { return 0 }

        var low = 0
        var high = pageFrames.count - 1
        var nearestIndex = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude

        while low <= high {
            let mid = (low + high) / 2
            let frame = pageFrames[mid]

            if y < frame.minY {
                let distance = frame.minY - y
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = mid
                }
                high = mid - 1
            } else if y > frame.maxY {
                let distance = y - frame.maxY
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = mid
                }
                low = mid + 1
            } else {
                return mid
            }
        }

        return nearestIndex
    }

    private func layoutPages(totalPages: Int, viewportWidth: CGFloat, magnification: CGFloat) {
        let pageWidth = max(viewportWidth, 1)
        let contentWidth = magnification < 1 ? max(pageWidth / magnification, pageWidth) : pageWidth
        var frames = Array(repeating: CGRect.zero, count: totalPages)
        var currentY: CGFloat = 0

        for pageIndex in 0..<totalPages {
            let pageSize = Self.preferredPageSize(
                forWidth: pageWidth,
                aspectRatio: pageAspectRatios[pageIndex] ?? (1 / Self.placeholderAspectRatio)
            )
            let frame = CGRect(
                x: (contentWidth - pageSize.width) / 2,
                y: currentY,
                width: pageSize.width,
                height: pageSize.height
            )

            frames[pageIndex] = frame
            currentY = frame.maxY + Self.verticalSpacing
        }

        if totalPages > 0 {
            currentY -= Self.verticalSpacing
        }

        pageFrames = frames
        frame = CGRect(origin: .zero, size: CGSize(width: contentWidth, height: max(1, currentY)))
    }

    private static func preferredPageSize(forWidth width: CGFloat, aspectRatio: CGFloat) -> CGSize {
        CGSize(width: width, height: max(1, width * aspectRatio))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard lastTotalPages > 0 else { return }

        if let context = NSGraphicsContext.current {
            context.imageInterpolation = isLiveScrolling ? .low : .high
        }

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let startIndex = max(0, pageIndex(at: dirtyRect.minY))
        let endIndex = min(lastTotalPages - 1, pageIndex(at: dirtyRect.maxY))
        guard endIndex >= startIndex else { return }

        for pageIndex in startIndex...endIndex {
            let pageFrame = pageFrames[pageIndex]
            guard pageFrame.intersects(dirtyRect) else { continue }

            drawPageBackground(in: pageFrame)

            if let image = pageImages[pageIndex] {
                image.draw(
                    in: pageFrame,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
            } else {
                drawPlaceholder(in: pageFrame, pageIndex: pageIndex)
            }
        }
    }

    private func drawPageBackground(in rect: CGRect) {
        if !isLiveScrolling {
            let shadowRect = rect.offsetBy(dx: 0, dy: 1)
            NSColor.black.withAlphaComponent(0.08).setFill()
            shadowRect.fill()
        }

        NSColor.white.setFill()
        rect.fill()
    }

    private func drawPlaceholder(in rect: CGRect, pageIndex: Int) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.05).setFill()
        rect.fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        let title = NSString(string: "Страница \(pageIndex + 1)")
        let titleSize = title.size(withAttributes: attributes)
        let titleRect = CGRect(
            x: rect.minX,
            y: rect.midY - titleSize.height / 2,
            width: rect.width,
            height: titleSize.height
        )
        title.draw(in: titleRect, withAttributes: attributes)
    }
}

// MARK: - Область просмотра для постраничного режима
struct DocumentView: View {
    @ObservedObject var djvuDocument: DJVUDocument
    @Binding var zoomLevel: Double
    @Binding var pageOffset: CGFloat
    @Binding var isTransitioning: Bool
    @State private var dragOffset: CGSize = .zero
    @State private var lastZoomLevel: Double = 1.0
    @State private var isDragging: Bool = false
    @State private var zoomAnchor: UnitPoint = .center
    @State private var gestureStartLocation: CGPoint = .zero
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                
                LinearGradient(
                    colors: [
                        Color(NSColor.controlBackgroundColor),
                        Color(NSColor.separatorColor).opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if djvuDocument.isLoading {
                
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.3)
                            .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                        
                        VStack(spacing: 6) {
                            Text("Загрузка страницы \(djvuDocument.currentPage + 1)")
                                .font(.headline)
                                .fontWeight(.medium)
                            
                            Text("Обработка документа...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color(NSColor.textBackgroundColor)
                            .opacity(0.98)
                            .blur(radius: 15)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    
                } else if let image = djvuDocument.currentImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoomLevel, anchor: zoomAnchor)
                            .offset(x: panOffset.width + dragOffset.width, y: panOffset.height + dragOffset.height)
                            .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
                            .padding(max(20, geometry.size.width * 0.03))
                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: zoomLevel)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .trailing)),
                                removal: .opacity.combined(with: .scale(scale: 1.05)).combined(with: .move(edge: .leading))
                            ))
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .onTapGesture(count: 2) {
                    
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                            if zoomLevel <= 1.0 {
                                zoomLevel = 1.5
                            } else if zoomLevel <= 1.5 {
                                zoomLevel = 2.0
                            } else {
                                zoomLevel = 1.0
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                if zoomLevel > 1.0 {
                                
                                    panOffset = CGSize(
                                        width: lastPanOffset.width + value.translation.width,
                                        height: lastPanOffset.height + value.translation.height
                                    )
                                } else {
                                    
                                    let horizontalDominance = abs(value.translation.width) > abs(value.translation.height) * 2
                                    let isHorizontalSwipe = abs(value.translation.width) > 30
                                    
                                    if horizontalDominance && !djvuDocument.isLoading && isHorizontalSwipe {
                                        isDragging = true
                                        dragOffset = CGSize(
                                            width: min(max(value.translation.width * 0.15, -50), 50),
                                            height: 0
                                        )
                                    }
                                }
                            }
                            .onEnded { value in
                                if zoomLevel > 1.0 {
                                    
                                    lastPanOffset = panOffset
                                } else {
                                    // Обработка свайпа
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        dragOffset = .zero
                                        isDragging = false
                                    }
                                    
                                    let threshold: CGFloat = 120
                                    let horizontalDominance = abs(value.translation.width) > abs(value.translation.height) * 3
                                    let sufficientDistance = abs(value.translation.width) > threshold
                                    let notLoading = !djvuDocument.isLoading
                                    let sufficientVelocity = abs(value.velocity.width) > 200
                                    
                                    if horizontalDominance && sufficientDistance && notLoading && sufficientVelocity {
                                        withAnimation(.easeInOut(duration: 0.4)) {
                                            if value.translation.width > 0 && djvuDocument.currentPage > 0 {
                                                djvuDocument.previousPage()
                                            } else if value.translation.width < 0 && djvuDocument.currentPage < djvuDocument.totalPages - 1 {
                                                djvuDocument.nextPage()
                                            }
                                        }
                                    }
                                }
                            }
                    )
                    .gesture(
                
                        MagnificationGesture()
                            .onChanged { value in
                                let newZoom = lastZoomLevel * value
                                zoomLevel = min(max(newZoom, 0.5), 3.0)
                            }
                            .onEnded { _ in
                                lastZoomLevel = zoomLevel
                                
                                // Привязка к удобным значениям
                                let snapValues: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
                                if let closest = snapValues.min(by: { abs($0 - zoomLevel) < abs($1 - zoomLevel) }),
                                   abs(closest - zoomLevel) < 0.08 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        zoomLevel = closest
                                        lastZoomLevel = closest
                                        
                                        if closest == 1.0 {
                                            panOffset = .zero
                                            lastPanOffset = .zero
                                        }
                                    }
                                }
                            }
                    )
                    .onAppear {
                        lastZoomLevel = zoomLevel
                    }
                    .onChange(of: zoomLevel) { newValue in
                        lastZoomLevel = newValue
                        
                        if newValue == 1.0 {
                            withAnimation(.easeOut(duration: 0.2)) {
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        }
                    }
                    .onChange(of: djvuDocument.currentPage) { _ in
                
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                    
                } else {
                    // Компактный плейсхолдер
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 60, weight: .ultraLight))
                            .foregroundColor(.secondary)
                            .symbolEffect(.pulse.wholeSymbol, options: .repeat(.continuous))
                        
                        VStack(spacing: 10) {
                            Text("Документ не загружен")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            if !djvuDocument.errorMessage.isEmpty {
                                Text(djvuDocument.errorMessage)
                                    .font(.callout)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(10)
                            } else {
                                Text("Выберите файл для начала просмотра")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                }
            }
        }
        .id("document-\(djvuDocument.currentPage)")
    }
}

// MARK: - Экран приветствия
struct WelcomeView: View {
    @ObservedObject var djvuDocument: DJVUDocument
    @Binding var showingFileImporter: Bool
    let onOpenDocuments: ([URL]) -> Void
    
    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 20) {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 100, weight: .ultraLight))
                    .foregroundColor(.accentColor)
                    .symbolEffect(.bounce.wholeSymbol, options: .speed(0.5))
                
                VStack(spacing: 12) {
                    Text("DJVU Reader")
                        .font(.system(.largeTitle, design: .rounded))
                        .fontWeight(.light)
                    
                    Text("Современный просмотрщик DJVU документов")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            VStack(spacing: 20) {
                if !djvuDocument.errorMessage.isEmpty {
                    Text(djvuDocument.errorMessage)
                        .foregroundColor(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 16) {
                    Button(action: {
                        showingFileImporter = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.headline)
                            Text("Открыть документ")
                                .font(.headline)
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    VStack(spacing: 8) {
                        Text("Или перетащите файл в это окно")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 16) {
                            Label("DJVU", systemImage: "doc.text")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.textBackgroundColor),
                    Color(NSColor.controlBackgroundColor).opacity(0.3)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers: providers)
        }
    }
    
    private func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        let dispatchGroup = DispatchGroup()
        let lock = NSLock()
        var droppedURLs: [URL] = []

        for provider in fileProviders {
            dispatchGroup.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { dispatchGroup.leave() }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   url.isSupportedDocumentURL {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            if !droppedURLs.isEmpty {
                onOpenDocuments(droppedURLs)
            }
        }

        return true
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
