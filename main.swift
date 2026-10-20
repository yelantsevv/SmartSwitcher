import AppKit
import Carbon
import CoreGraphics
import ApplicationServices

// MARK: - Таблица соответствий символов (QWERTY <-> ЙЦУКЕН)
struct KeyMap {
    static let enToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д", ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь", "<": "Б", ">": "Ю",
        "`": "ё", "~": "Ё", "@": "\"", "#": "№", "$": ";", "^": ":", "&": "?"
    ]

    static let ruToEn: [Character: Character] = Dictionary(uniqueKeysWithValues: enToRu.map { ($1, $0) })

    static func convertText(_ text: String) -> (converted: String, toRussian: Bool) {
        let hasCyrillic = text.contains { $0.unicodeScalars.first?.value ?? 0 >= 0x0400 }
        let targetIsRussian = !hasCyrillic

        var result = ""
        for char in text {
            if targetIsRussian {
                result.append(enToRu[char] ?? char)
            } else {
                result.append(ruToEn[char] ?? char)
            }
        }
        return (result, targetIsRussian)
    }
}

// MARK: - Управление источниками ввода (Carbon TIS)
class InputSourceManager {
    static func currentLanguageCode() -> String {
        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(currentSource, kTISPropertyInputSourceID) else {
            return "EN"
        }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        return id.contains("Russian") ? "RU" : "EN"
    }

    static func switchToLanguage(russian: Bool) {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        
        for source in sourceList {
            if let categoryPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) {
                let category = Unmanaged<CFString>.fromOpaque(categoryPtr).takeUnretainedValue() as String
                if category == (kTISCategoryKeyboardInputSource as String) {
                    if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                        let isRussianLayout = id.contains("Russian")
                        let isEnglishLayout = id.contains("US") || id.contains("ABC") || id.contains("British")
                        
                        if (russian && isRussianLayout) || (!russian && isEnglishLayout) {
                            if TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) != nil {
                                TISSelectInputSource(source)
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Конвертер через буфер обмена
class TextConverterEngine {
    static let shared = TextConverterEngine()

    private var isProcessing = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isEnabled = false

    func start() {
        guard eventTap == nil else { return }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = TextConverterEngine.shared.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }
                return TextConverterEngine.shared.handle(event: event)
            },
            userInfo: nil
        ) else {
            print("❌ Ошибка: предоставьте разрешения Accessibility!")
            isEnabled = false
            return
        }

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isEnabled = true
    }

    func stop() {
        guard let tap = eventTap else {
            isEnabled = false
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isEnabled = false
    }

    func toggle() {
        if isEnabled { stop() } else { start() }
    }

    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        if isProcessing { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Код 49 — это Пробел. Проверяем нажатие Fn (маска флага Fn в macOS)
        let isFnPressed = flags.contains(.maskSecondaryFn) || (flags.rawValue & 0x800000) != 0

        if keyCode == 49 && isFnPressed {
            isProcessing = true
            
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleFnSpace()
                Thread.sleep(forTimeInterval: 0.05)
                self.isProcessing = false
            }
            
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFnSpace() {
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount
        let oldString = pasteboard.string(forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)

        // Имитация Cmd + C через CGEvent
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)

        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        usleep(12000)
        cDown?.post(tap: .cghidEventTap)
        usleep(12000)
        cUp?.post(tap: .cghidEventTap)
        usleep(12000)
        cmdUp?.post(tap: .cghidEventTap)

        var attempts = 0
        while pasteboard.changeCount == oldChangeCount && attempts < 10 {
            usleep(10000)
            attempts += 1
        }

        let hasSelection = (pasteboard.changeCount != oldChangeCount)
        let selectedText = hasSelection ? (pasteboard.string(forType: .string) ?? "") : ""
        let isFullLineWithoutSelection = selectedText.contains("\n") || selectedText.contains("\r")

        if hasSelection && !selectedText.isEmpty && !isFullLineWithoutSelection {
            let (convertedText, targetIsRussian) = KeyMap.convertText(selectedText)
            
            pasteboard.clearContents()
            pasteboard.setString(convertedText, forType: .string)

            // Имитация Cmd + V
            let vCmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            let vCmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)

            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand

            vCmdDown?.post(tap: .cghidEventTap)
            usleep(12000)
            vDown?.post(tap: .cghidEventTap)
            usleep(12000)
            vUp?.post(tap: .cghidEventTap)
            usleep(12000)
            vCmdUp?.post(tap: .cghidEventTap)

            usleep(30000)
            InputSourceManager.switchToLanguage(russian: targetIsRussian)
        } else {
            // Если текст не выделен, просто шлем обычный пробел
            let spaceDown = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let spaceUp = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)
            spaceDown?.post(tap: .cghidEventTap)
            usleep(5000)
            spaceUp?.post(tap: .cghidEventTap)
        }

        DispatchQueue.global().async {
            usleep(500000) // 0.5 сек перед возвратом старого буфера
            if let oldString {
                pasteboard.clearContents()
                pasteboard.setString(oldString, forType: .string)
            }
        }
    }
}

// MARK: - Menu Bar Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var functionMenuItem: NSMenuItem?
    var russianMenuItem: NSMenuItem?
    var englishMenuItem: NSMenuItem?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        
        functionMenuItem = NSMenuItem(title: "", action: #selector(toggleFunction), keyEquivalent: "")
        functionMenuItem?.target = self
        menu.addItem(functionMenuItem!)

        menu.addItem(NSMenuItem.separator())
        
        englishMenuItem = NSMenuItem(title: "Английский (US)", action: #selector(selectEnglish), keyEquivalent: "")
        englishMenuItem?.target = self
        menu.addItem(englishMenuItem!)

        russianMenuItem = NSMenuItem(title: "Русский", action: #selector(selectRussian), keyEquivalent: "")
        russianMenuItem?.target = self
        menu.addItem(russianMenuItem!)

        menu.addItem(NSMenuItem.separator())
        
        let infoItem = NSMenuItem(title: "Fn + Space: конвертация выделенного", action: #selector(dummyAction), keyEquivalent: "")
        infoItem.target = self
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Открыть настройки клавиатуры", action: #selector(openKeyboardSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Завершить", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu

        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)

        let shouldEnable = UserDefaults.standard.object(forKey: "functionEnabled") as? Bool ?? true
        if shouldEnable {
            TextConverterEngine.shared.start()
        }

        updateUIState()

        // Увеличен интервал таймера с 0.5 до 2.0 секунд, чтобы разгрузить процессор
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateUIState()
        }
    }

    func updateUIState() {
        let enabled = TextConverterEngine.shared.isEnabled
        
        functionMenuItem?.title = enabled ? "Отключить" : "Включить"
        
        if let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "SmartSwitcher") {
            statusItem?.button?.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        }
        
        let langCode = InputSourceManager.currentLanguageCode()
        statusItem?.button?.title = enabled ? " \(langCode)" : " OFF (\(langCode))"
        statusItem?.button?.imagePosition = .imageLeft

        if langCode == "RU" {
            russianMenuItem?.state = .on
            englishMenuItem?.state = .off
        } else {
            russianMenuItem?.state = .off
            englishMenuItem?.state = .on
        }
    }

    @objc func toggleFunction() {
        TextConverterEngine.shared.toggle()
        UserDefaults.standard.set(TextConverterEngine.shared.isEnabled, forKey: "functionEnabled")
        updateUIState()
    }

    @objc func selectEnglish() {
        InputSourceManager.switchToLanguage(russian: false)
        updateUIState()
    }

    @objc func selectRussian() {
        InputSourceManager.switchToLanguage(russian: true)
        updateUIState()
    }

    @objc func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func dummyAction() {}

    @objc func quit() {
        timer?.invalidate()
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// для сборки проекта app
// swiftc main.swift -o "SmartSwitcher" -framework AppKit -framework Carbon
// mkdir -p "SmartSwitcher.app/Contents/MacOS"
// mv "SmartSwitcher" "SmartSwitcher.app/Contents/MacOS/SmartSwitcher"

// для сборки проекта бинарника
// swiftc -O main.swift -o SmartSwitcher -framework AppKit -framework Carbon -framework CoreGraphics -framework ApplicationServices
запустить бинарник
// ./SmartSwitcher