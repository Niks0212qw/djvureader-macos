import AppKit
import SwiftUI

enum AppWindowLayout {
    private static let welcomeAspectRatio: CGFloat = 1417.0 / 1175.0
    private static let welcomeWidthRatio: CGFloat = 0.37
    private static let welcomeHeightRatio: CGFloat = 0.60
    private static let fallbackWelcomeFrameSize = NSSize(width: 710, height: 589)
    private static let documentAspectRatio: CGFloat = 0.69
    private static let documentWidthRatio: CGFloat = 0.35
    private static let documentHeightRatio: CGFloat = 0.92
    private static let fallbackDocumentFrameSize = NSSize(width: 1280, height: 1855)

    static func welcomeFrameSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return fallbackWelcomeFrameSize }

        let widthFromScreen = visibleFrame.width * welcomeWidthRatio
        let widthFromHeightConstraint = visibleFrame.height * welcomeHeightRatio * welcomeAspectRatio
        let width = min(widthFromScreen, widthFromHeightConstraint)
        let height = width / welcomeAspectRatio

        return NSSize(width: width, height: height)
    }

    static func documentFrameSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return fallbackDocumentFrameSize }

        let widthFromScreen = visibleFrame.width * documentWidthRatio
        let widthFromHeightConstraint = visibleFrame.height * documentHeightRatio * documentAspectRatio
        let width = min(widthFromScreen, widthFromHeightConstraint)
        let height = width / documentAspectRatio

        return NSSize(width: width, height: height)
    }
}

struct DocumentWindowPayload: Hashable, Codable {
    let path: String

    init(url: URL) {
        self.path = url.path
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

final class DocumentOpenCoordinator: ObservableObject {
    static let shared = DocumentOpenCoordinator()

    @Published private(set) var pendingPrimaryDocumentURL: URL?

    private var openDocumentWindowHandler: ((URL) -> Void)?
    private var queuedWindowDocuments: [URL] = []
    private var primaryDocumentTargetCount = 0

    func configureOpenDocumentWindowHandler(_ handler: @escaping (URL) -> Void) {
        openDocumentWindowHandler = handler
        flushQueuedWindowDocuments()
    }

    func requestOpen(_ urls: [URL]) {
        let supportedURLs = urls.filter { $0.isSupportedDocumentURL }
        guard !supportedURLs.isEmpty else { return }

        if supportedURLs.count > 1 {
            openInNewWindows(supportedURLs)
            return
        }

        DispatchQueue.main.async {
            var remainingURLs = supportedURLs

            if self.primaryDocumentTargetCount > 0,
               self.pendingPrimaryDocumentURL == nil,
               let firstURL = remainingURLs.first {
                self.pendingPrimaryDocumentURL = firstURL
                remainingURLs.removeFirst()
            }

            self.openInNewWindows(remainingURLs)
        }
    }

    func openInNewWindow(_ url: URL) {
        openInNewWindows([url])
    }

    func openInNewWindows(_ urls: [URL]) {
        let supportedURLs = urls.filter { $0.isSupportedDocumentURL }
        guard !supportedURLs.isEmpty else { return }

        DispatchQueue.main.async {
            if let openDocumentWindowHandler = self.openDocumentWindowHandler {
                supportedURLs.forEach(openDocumentWindowHandler)
            } else {
                self.queuedWindowDocuments.append(contentsOf: supportedURLs)
            }
        }
    }

    func consumePendingPrimaryDocument() {
        pendingPrimaryDocumentURL = nil
    }

    func registerPrimaryDocumentTarget() {
        primaryDocumentTargetCount += 1
    }

    func unregisterPrimaryDocumentTarget() {
        primaryDocumentTargetCount = max(0, primaryDocumentTargetCount - 1)
    }

    private func flushQueuedWindowDocuments() {
        guard let openDocumentWindowHandler, !queuedWindowDocuments.isEmpty else { return }

        let queuedDocuments = queuedWindowDocuments
        queuedWindowDocuments.removeAll()
        queuedDocuments.forEach(openDocumentWindowHandler)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        DocumentOpenCoordinator.shared.requestOpen(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        DocumentOpenCoordinator.shared.requestOpen([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        DocumentOpenCoordinator.shared.requestOpen(urls)
        sender.reply(toOpenOrPrint: .success)
    }
}

final class WindowCommandRouter {
    static let shared = WindowCommandRouter()

    var activeWindowNumber: Int?

    func post(_ notificationName: Notification.Name) {
        NotificationCenter.default.post(name: notificationName, object: activeWindowNumber)
    }
}

struct DocumentWindowRoot: View {
    @Environment(\.openWindow) private var openWindow

    let initialDocumentURL: URL?
    let participatesInPrimaryOpenQueue: Bool

    var body: some View {
        ContentView(
            initialDocumentURL: initialDocumentURL,
            participatesInPrimaryOpenQueue: participatesInPrimaryOpenQueue
        )
        .onAppear {
            DocumentOpenCoordinator.shared.configureOpenDocumentWindowHandler { url in
                openWindow(id: "document", value: DocumentWindowPayload(url: url))
            }
        }
    }
}

@main
struct DJVUReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DocumentWindowRoot(
                initialDocumentURL: nil,
                participatesInPrimaryOpenQueue: true
            )
        }
        .defaultSize(
            width: AppWindowLayout.welcomeFrameSize(for: NSScreen.main?.visibleFrame).width,
            height: AppWindowLayout.welcomeFrameSize(for: NSScreen.main?.visibleFrame).height
        )
        .defaultPosition(.center)

        WindowGroup(id: "document", for: DocumentWindowPayload.self) { $payload in
            DocumentWindowRoot(
                initialDocumentURL: payload?.url,
                participatesInPrimaryOpenQueue: false
            )
        }
        .defaultSize(
            width: AppWindowLayout.documentFrameSize(for: NSScreen.main?.visibleFrame).width,
            height: AppWindowLayout.documentFrameSize(for: NSScreen.main?.visibleFrame).height
        )
        .defaultPosition(.center)
        .commands {
            // Меню "Вид"
            CommandMenu("Вид") {
                Button("Постраничный режим") {
                    WindowCommandRouter.shared.post(.switchToSingleMode)
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Непрерывный режим") {
                    WindowCommandRouter.shared.post(.switchToContinuousMode)
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Divider()
                
                Button("Увеличить") {
                    WindowCommandRouter.shared.post(.zoomIn)
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Уменьшить") {
                    WindowCommandRouter.shared.post(.zoomOut)
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Button("Реальный размер") {
                    WindowCommandRouter.shared.post(.zoomReset)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            
            // Меню "Файл" с дополнительными командами
            CommandGroup(replacing: .newItem) {
                Button("Открыть документ...") {
                    WindowCommandRouter.shared.post(.openDocument)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            
            // Меню "Навигация"
            CommandMenu("Навигация") {
                Button("Предыдущая страница") {
                    WindowCommandRouter.shared.post(.previousPage)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                
                Button("Следующая страница") {
                    WindowCommandRouter.shared.post(.nextPage)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                
                Divider()
                
                Button("Первая страница") {
                    WindowCommandRouter.shared.post(.firstPage)
                }
                .keyboardShortcut(.home, modifiers: .command)
                
                Button("Последняя страница") {
                    WindowCommandRouter.shared.post(.lastPage)
                }
                .keyboardShortcut(.end, modifiers: .command)
            }
        }
    }
}

extension URL {
    var isSupportedDocumentURL: Bool {
        ["djvu", "djv", "pdf"].contains(pathExtension.lowercased())
    }
}

// MARK: - Уведомления для команд меню
extension Notification.Name {
    static let switchToSingleMode = Notification.Name("switchToSingleMode")
    static let switchToContinuousMode = Notification.Name("switchToContinuousMode")
    static let openDocument = Notification.Name("openDocument")
    static let previousPage = Notification.Name("previousPage")
    static let nextPage = Notification.Name("nextPage")
    static let firstPage = Notification.Name("firstPage")
    static let lastPage = Notification.Name("lastPage")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomReset = Notification.Name("zoomReset")
    static let keyboardZoomChange = Notification.Name("keyboardZoomChange")
    static let keyboardZoomReset = Notification.Name("keyboardZoomReset")
}
