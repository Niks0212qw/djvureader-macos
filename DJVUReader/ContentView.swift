import SwiftUI
import QuartzCore

struct ContentView: View {
    @StateObject private var djvuDocument = DJVUDocument()
    @State private var showingFileImporter = false
    @State private var zoomLevel: Double = 1.0
    @State private var pageOffset: CGFloat = 0
    @State private var isTransitioning = false
    
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
                    showingFileImporter: $showingFileImporter
                )
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [
                .init(filenameExtension: "djvu")!,
                .init(filenameExtension: "djv")!,
                .pdf
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let files):
                if let url = files.first {
                    djvuDocument.loadDocument(from: url)
                }
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
        }
        .onDisappear {
            removeMenuObservers()
        }
    }
    
    // MARK: - Обработка команд меню
    private func setupMenuObservers() {
        NotificationCenter.default.addObserver(
            forName: .switchToSingleMode,
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                djvuDocument.setViewMode(.single)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .switchToContinuousMode,
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                djvuDocument.setViewMode(.continuous)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .openDocument,
            object: nil,
            queue: .main
        ) { _ in
            showingFileImporter = true
        }
        
        NotificationCenter.default.addObserver(
            forName: .previousPage,
            object: nil,
            queue: .main
        ) { _ in
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.previousPage()
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .nextPage,
            object: nil,
            queue: .main
        ) { _ in
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.3)) {
                    djvuDocument.nextPage()
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .firstPage,
            object: nil,
            queue: .main
        ) { _ in
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.4)) {
                    djvuDocument.goToPage(0)
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .lastPage,
            object: nil,
            queue: .main
        ) { _ in
            if djvuDocument.isLoaded && !djvuDocument.isLoading {
                withAnimation(.easeInOut(duration: 0.4)) {
                    djvuDocument.goToPage(djvuDocument.totalPages - 1)
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .zoomIn,
            object: nil,
            queue: .main
        ) { _ in
            // Отправляем уведомление о том, что зум изменяется через клавиатуру
            NotificationCenter.default.post(name: .keyboardZoomChange, object: nil, userInfo: ["delta": 0.25])
        }
        
        NotificationCenter.default.addObserver(
            forName: .zoomOut,
            object: nil,
            queue: .main
        ) { _ in
            // Отправляем уведомление о том, что зум изменяется через клавиатуру
            NotificationCenter.default.post(name: .keyboardZoomChange, object: nil, userInfo: ["delta": -0.25])
        }
        
        NotificationCenter.default.addObserver(
            forName: .zoomReset,
            object: nil,
            queue: .main
        ) { _ in
            // Отправляем уведомление о том, что зум сбрасывается через клавиатуру
            NotificationCenter.default.post(name: .keyboardZoomReset, object: nil)
        }
    }
    
    private func removeMenuObservers() {
        NotificationCenter.default.removeObserver(self)
    }
}

// Reference-хранилище для scroll offset. Мутирование не триггерит SwiftUI,
// в отличие от @State CGPoint, который при каждом обновлении вызывает пересборку body
// всей ContinuousDocumentView (≈60 раз/сек во время скролла).
final class ScrollOffsetHolder {
    var value: CGPoint = .zero
}

// MARK: - Режим непрерывного просмотра с исправленной логикой масштабирования
struct ContinuousDocumentView: View {
    @ObservedObject var djvuDocument: DJVUDocument
    @Binding var zoomLevel: Double
    @State private var lastZoomLevel: Double = 1.0
    @State private var scrollOffsetHolder = ScrollOffsetHolder()
    @State private var lastPageUpdateTime: CFTimeInterval = 0
    // Индекс страницы, на которую currentPage был установлен в результате
    // естественного скролла. Позволяет отличить его от программной навигации
    // (next/prev/goToPage) и не триггерить автопрокрутку во время скролла.
    @State private var scrollDrivenPageIndex: Int? = nil
    @State private var zoomAnchor: UnitPoint = .center
    @State private var gestureLocation: CGPoint = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var keyboardZoomObserver: NSObjectProtocol?
    @State private var keyboardResetObserver: NSObjectProtocol?
    @State private var scrollProxy: ScrollViewProxy?
    
    // Переменные для правильного зумирования с сохранением позиции
    @State private var isPerformingZoom: Bool = false
    @State private var zoomCenterPoint: CGPoint = .zero
    @State private var scrollReader: ScrollViewProxy?
    @State private var currentScrollOffset: CGFloat = 0 // Текущий компенсирующий offset
    @State private var savedPagePosition: CGFloat = 0 // Сохраненная позиция внутри страницы (0.0 - 1.0)
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Фон
                LinearGradient(
                    colors: [
                        Color(NSColor.controlBackgroundColor),
                        Color(NSColor.separatorColor).opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Основное содержимое
                Group {
                    if djvuDocument.continuousImages.isEmpty {
                        if djvuDocument.isContinuousLoading {
                            loadingView
                        } else {
                            placeholderView
                        }
                    } else {
                        continuousContentView(geometry: geometry)
                    }
                }
            }
            .onAppear {
                viewportSize = geometry.size
            }
            .onChange(of: geometry.size) { newSize in
                viewportSize = newSize
            }
        }
        .onAppear {
            setupKeyboardZoomObservers()
        }
        .onDisappear {
            removeKeyboardZoomObservers()
        }
    }
    
    // MARK: - Обработка команд зума с клавиатуры (исправлено для центрирования)
    private func setupKeyboardZoomObservers() {
        keyboardZoomObserver = NotificationCenter.default.addObserver(
            forName: .keyboardZoomChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let delta = notification.userInfo?["delta"] as? Double else { return }
            // Для клавиатурного зума используем центр экрана как точку фокуса
            let centerPoint = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            performZoomWithFocus(delta: delta, focusPoint: centerPoint, animated: true)
        }
        
        keyboardResetObserver = NotificationCenter.default.addObserver(
            forName: .keyboardZoomReset,
            object: nil,
            queue: .main
        ) { _ in
            let centerPoint = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            resetZoomWithFocus(focusPoint: centerPoint, animated: true)
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
    
    // MARK: - Определение текущей страницы и позиции
    
    /// - Returns: (индекс страницы, относительная позиция внутри страницы 0.0-1.0, Y-координата начала страницы)
    private func getCurrentPageInfo() -> (pageIndex: Int, relativePosition: CGFloat, pageStartY: CGFloat) {
        let scrollY = -scrollOffsetHolder.value.y
        let adjustedScrollY = max(0, scrollY)
        
        let estimatedPageHeight = viewportSize.height * 0.75 * zoomLevel + 8
        
        let currentPageIndex = max(0, min(djvuDocument.totalPages - 1, Int(adjustedScrollY / estimatedPageHeight)))
        let pageStartY = CGFloat(currentPageIndex) * estimatedPageHeight
        let positionInPage = (adjustedScrollY - pageStartY) / estimatedPageHeight
        let clampedPosition = max(0, min(1, positionInPage))

        return (currentPageIndex, clampedPosition, pageStartY)
    }

    /// - Parameters:
    ///   - pageIndex: Индекс страницы (0-based)
    ///   - zoom: Масштаб для вычисления
    /// - Returns: Y-координата центра страницы в координатах контента
    private func calculatePageCenterY(for pageIndex: Int, zoom: Double) -> CGFloat {
        let estimatedPageHeight = viewportSize.height * 0.75 * zoom + 8
        let pageStartY = CGFloat(pageIndex) * estimatedPageHeight
        let pageCenterY = pageStartY + (estimatedPageHeight - 8) / 2 // Вычитаем padding
        return pageCenterY
    }
    // MARK: - Зуммирование
    private func performZoomWithFocus(delta: Double, focusPoint: CGPoint, animated: Bool) {
        let newZoom = max(0.5, min(3.0, zoomLevel + delta))
        if newZoom == zoomLevel { return }
        
        zoomToLevel(newZoom, focusPoint: focusPoint, animated: animated)
    }
    
    private func resetZoomWithFocus(focusPoint: CGPoint, animated: Bool) {
        zoomToLevel(1.0, focusPoint: focusPoint, animated: animated)
    }
    
    private func zoomToLevel(_ newZoom: Double, focusPoint: CGPoint, animated: Bool) {
        guard newZoom != zoomLevel else { return }
        
        isPerformingZoom = true
        
        let oldZoom = zoomLevel
        
        let currentPageInfo = getCurrentPageInfo()
        let currentPageIndex = currentPageInfo.pageIndex
        savedPagePosition = currentPageInfo.relativePosition
        
        print(" Зум относительно страницы \(currentPageIndex + 1): \(oldZoom) → \(newZoom)")
        print(" Сохраненная позиция в странице: \(String(format: "%.2f", savedPagePosition))")
        
        // Вычисляем центр текущей страницы ДО масштабирования
        let oldPageCenterY = calculatePageCenterY(for: currentPageIndex, zoom: oldZoom)
        let currentViewCenterY = -scrollOffsetHolder.value.y + viewportSize.height / 2
        
        // Вычисляем смещение от центра страницы до центра экрана
        let offsetFromPageCenter = currentViewCenterY - oldPageCenterY
        
        print(" Центр страницы ДО: \(oldPageCenterY), центр экрана: \(currentViewCenterY)")
        print(" Смещение от центра страницы: \(offsetFromPageCenter)")
        
        // Выполняем зум
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                zoomLevel = newZoom
            }
        } else {
            zoomLevel = newZoom
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.25 : 0.05)) {
            self.restorePositionAfterZoom(
                pageIndex: currentPageIndex,
                newZoom: newZoom,
                offsetFromPageCenter: offsetFromPageCenter,
                animated: animated
            )
        }
    }
    
    private func restorePositionAfterZoom(pageIndex: Int, newZoom: Double, offsetFromPageCenter: CGFloat, animated: Bool) {
    
        let newPageCenterY = calculatePageCenterY(for: pageIndex, zoom: newZoom)
        

        let oldZoom = zoomLevel == newZoom ? lastZoomLevel : zoomLevel // Получаем старый зум
        let scaledOffsetFromPageCenter = offsetFromPageCenter * (newZoom / oldZoom)
        let targetViewCenterY = newPageCenterY + scaledOffsetFromPageCenter
        

        let targetScrollY = -(targetViewCenterY - viewportSize.height / 2)
        let currentScrollY = scrollOffsetHolder.value.y
        let offsetDelta = targetScrollY - currentScrollY
        
        print(" Центр страницы ПОСЛЕ: \(newPageCenterY)")
        print(" Целевая позиция экрана: \(targetViewCenterY)")
        print(" Требуемый offset: \(offsetDelta)")
        
        // Применяем компенсирующий offset
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                currentScrollOffset = offsetDelta
            }
        } else {
            currentScrollOffset = offsetDelta
        }
        
        // Плавно убираем offset через некоторое время
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0.2)) {
            withAnimation(.easeOut(duration: 0.3)) {
                self.currentScrollOffset = 0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isPerformingZoom = false
            }
        }
    }
    
    // MARK: - Обновление текущей страницы (при ручной прокрутке)
    private func updateCurrentPageFromScroll() {
        guard !isPerformingZoom else { return }
        
        // Используем нашу функцию для определения текущей страницы
        let currentPageInfo = getCurrentPageInfo()
        let visiblePageIndex = currentPageInfo.pageIndex
        
        if visiblePageIndex != djvuDocument.currentPage {
            scrollDrivenPageIndex = visiblePageIndex
            djvuDocument.currentPage = visiblePageIndex
        }
    }
    
    // MARK: - Загрузка
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView(value: djvuDocument.continuousLoadingProgress, total: 1.0)
                .frame(width: 200)
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
            
            VStack(spacing: 8) {
                Text("Подготовка непрерывного просмотра")
                    .font(.headline)
                    .fontWeight(.medium)
                
                Text("Загружено \(djvuDocument.continuousImages.count) из \(djvuDocument.totalPages) страниц")
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
    }
    
    // MARK: - Плейсхолдер
    private var placeholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundColor(.secondary)
                .symbolEffect(.pulse.wholeSymbol, options: .repeat(.continuous))
            
            VStack(spacing: 10) {
                Text("Непрерывный просмотр")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text("Переключитесь обратно на постраничный режим или подождите загрузки")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private func continuousContentView(geometry: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<djvuDocument.totalPages, id: \.self) { pageIndex in
                        ContinuousPageView(
                            image: djvuDocument.continuousImages[pageIndex],
                            pageIndex: pageIndex,
                            geometry: geometry
                        )
                        .equatable()
                        .id("page-\(pageIndex)")
                    }
                }
                .scaleEffect(zoomLevel, anchor: .top) // Изменено с .topLeading на .top для центрирования
                .offset(y: currentScrollOffset) // Компенсирующий offset для сохранения позиции
                .background(
                    GeometryReader { contentGeometry in
                        Color.clear
                            .preference(key: ScrollOffsetPreferenceKey.self,
                                      value: contentGeometry.frame(in: .named("scrollView")).origin)
                    }
                )
                .onAppear {
                    scrollReader = proxy
                    
                    // Первоначальная прокрутка к текущей странице (только один раз)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if !isPerformingZoom {
                            proxy.scrollTo("page-\(djvuDocument.currentPage)", anchor: .top)
                        }
                    }
                }
                .onChange(of: djvuDocument.currentPage) { newPage in
                    // Если страница изменилась из-за естественной прокрутки —
                    // не трогаем scroll offset: scrollTo() посреди user-скролла
                    // вызывает визуальное «подпрыгивание».
                    if scrollDrivenPageIndex == newPage {
                        scrollDrivenPageIndex = nil
                        return
                    }
                    if !isPerformingZoom {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo("page-\(newPage)", anchor: .top)
                        }
                    }
                }
            }
            .coordinateSpace(name: "scrollView")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                scrollOffsetHolder.value = value
                let now = CACurrentMediaTime()
                if now - lastPageUpdateTime >= 0.1 {
                    lastPageUpdateTime = now
                    updateCurrentPageFromScroll()
                }
            }
            // Обработка жестов зумирования относительно центра текущей страницы
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isPerformingZoom {
                            isPerformingZoom = true
                            lastZoomLevel = zoomLevel
                            
                            // Сохраняем информацию о текущей странице при начале жеста
                            let currentPageInfo = getCurrentPageInfo()
                            savedPagePosition = currentPageInfo.relativePosition
                            
                            zoomCenterPoint = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                        }
                        
                        let newZoom = max(0.5, min(3.0, lastZoomLevel * value))
                        zoomLevel = newZoom
                    }
                    .onEnded { _ in
                        lastZoomLevel = zoomLevel
                        
                        // Получаем текущую страницу для восстановления позиции
                        let currentPageInfo = getCurrentPageInfo()
                        let pageIndex = currentPageInfo.pageIndex
                        
                        // Восстанавливаем позицию после жеста
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.restorePositionAfterZoom(
                                pageIndex: pageIndex,
                                newZoom: self.zoomLevel,
                                offsetFromPageCenter: 0, // Для жестов используем центр страницы
                                animated: false
                            )
                        }
                        
                        // Привязка к стандартным значениям (как в Preview)
                        let snapValues: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
                        if let closest = snapValues.min(by: { abs($0 - zoomLevel) < abs($1 - zoomLevel) }),
                           abs(closest - zoomLevel) < 0.08 {
                            
                            withAnimation(.easeOut(duration: 0.2)) {
                                zoomLevel = closest
                                lastZoomLevel = closest
                            }
                            
                            // Восстанавливаем позицию для привязанного значения
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                self.restorePositionAfterZoom(
                                    pageIndex: pageIndex,
                                    newZoom: closest,
                                    offsetFromPageCenter: 0,
                                    animated: true
                                )
                            }
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            self.isPerformingZoom = false
                        }
                    }
            )
            // Обработка зума колесом мыши
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    gestureLocation = location
                case .ended:
                    break
                }
            }
            .onAppear {
                lastZoomLevel = zoomLevel
                currentScrollOffset = 0
                savedPagePosition = 0
            }
            .onChange(of: zoomLevel) { newValue in
                // Ограничиваем зум в допустимых пределах
                let clampedValue = max(0.5, min(3.0, newValue))
                if clampedValue != newValue {
                    DispatchQueue.main.async {
                        zoomLevel = clampedValue
                    }
                }
                
                // Обновляем lastZoomLevel только если не выполняется программное масштабирование
                if !isPerformingZoom {
                    lastZoomLevel = clampedValue
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - AppKit-обёртка для быстрой отрисовки страниц при скролле
// SwiftUI `Image(nsImage:)` повторно ресемплирует большие картинки на каждом
// кадре скролла, а SwiftUI `.shadow()` создаёт offscreen-буфер размера страницы
// — для больших картинок обе операции очень дорогие. Здесь мы вешаем CGImage
// напрямую на CALayer и рисуем тень самим слоем: GPU при скролле только двигает
// готовый слой.
struct PageImageView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageLayer = CALayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let bg = CALayer()
            bg.backgroundColor = NSColor.white.cgColor
            bg.shadowColor = NSColor.black.cgColor
            bg.shadowOpacity = 0.1
            bg.shadowRadius = 1
            bg.shadowOffset = CGSize(width: 0, height: 1)
            bg.contentsScale = scale
            layer = bg

            imageLayer.contentsGravity = .resizeAspect
            imageLayer.contentsScale = scale
            imageLayer.minificationFilter = .trilinear
            imageLayer.magnificationFilter = .trilinear
            imageLayer.drawsAsynchronously = true
            imageLayer.masksToBounds = true
            bg.addSublayer(imageLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if (nsView.imageLayer.contents as! CGImage?) !== cg {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            nsView.imageLayer.contents = cg
            CATransaction.commit()
        }
    }
}

// MARK: - Страница в непрерывном режиме
struct ContinuousPageView: View, Equatable {
    let image: NSImage?
    let pageIndex: Int
    let geometry: GeometryProxy

    static func == (lhs: ContinuousPageView, rhs: ContinuousPageView) -> Bool {
        lhs.pageIndex == rhs.pageIndex
            && lhs.image === rhs.image
            && lhs.geometry.size == rhs.geometry.size
    }

    var body: some View {
        Group {
            if let image = image {
                PageImageView(image: image)
                    .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                    .frame(maxWidth: geometry.size.width)
            } else {
                // Плейсхолдер для загружающейся страницы в стиле Preview
                Rectangle()
                    .fill(Color.secondary.opacity(0.05))
                    .aspectRatio(0.75, contentMode: .fit)
                    .frame(maxWidth: geometry.size.width)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                            
                            Text("Страница \(pageIndex + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            }
        }
        .padding(.vertical, 4) // Небольшое разделение между страницами как в Preview
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
                    
                    Text("Современный просмотрщик DJVU и PDF документов")
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
                            Label("PDF", systemImage: "doc.text.fill")
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
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                let fileExtension = url.pathExtension.lowercased()
                if ["djvu", "djv", "pdf"].contains(fileExtension) {
                    DispatchQueue.main.async {
                        djvuDocument.loadDocument(from: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Отслеживание позиции прокрутки
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

// MARK: - Отслеживане размера контента
struct ContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
