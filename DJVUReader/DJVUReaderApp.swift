import SwiftUI

@main
struct DJVUReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Меню "Вид"
            CommandMenu("Вид") {
                Button("Постраничный режим") {
                    NotificationCenter.default.post(name: .switchToSingleMode, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Непрерывный режим") {
                    NotificationCenter.default.post(name: .switchToContinuousMode, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Divider()
                
                Button("Увеличить") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Уменьшить") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Button("Реальный размер") {
                    NotificationCenter.default.post(name: .zoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            
            // Меню "Файл" с дополнительными командами
            CommandGroup(replacing: .newItem) {
                Button("Открыть документ...") {
                    NotificationCenter.default.post(name: .openDocument, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            
            // Меню "Навигация"
            CommandMenu("Навигация") {
                Button("Предыдущая страница") {
                    NotificationCenter.default.post(name: .previousPage, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                
                Button("Следующая страница") {
                    NotificationCenter.default.post(name: .nextPage, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                
                Divider()
                
                Button("Первая страница") {
                    NotificationCenter.default.post(name: .firstPage, object: nil)
                }
                .keyboardShortcut(.home, modifiers: .command)
                
                Button("Последняя страница") {
                    NotificationCenter.default.post(name: .lastPage, object: nil)
                }
                .keyboardShortcut(.end, modifiers: .command)
            }
        }
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
