import AppKit
import SwiftUI

/// Borderless, non activating overlay window: it can take keyboard focus
/// without stealing application focus from whatever was in front.
final class LaunchpadPanel: NSPanel {
    weak var controller: LaunchpadController?
    var displayID: CGDirectDisplayID = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(displayID: CGDirectDisplayID, frame: CGRect) {
        self.displayID = displayID
        // Deliberately *not* `.nonactivatingPanel`: such a panel tells macOS not
        // to activate the app, and the system then takes activation away again,
        // leaving no key window — which kills text input and the input method.
        // We activate on present and hand focus back on dismiss instead.
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        // High enough to cover the menu bar and the Dock, but *below* system UI
        // such as the input method candidate window and alerts. At
        // .screenSaver (1000) the 中文候选词窗口 would be hidden behind us.
        self.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.acceptsMouseMovedEvents = true
        // Text input (and therefore the input method) requires a key window.
        self.becomesKeyOnlyIfNeeded = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.escape()
    }

    /// When the panel becomes key, hand keyboard focus to the search field so
    /// typing (and the input method) work immediately.
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { FieldFocus.focusSearch() }
    }

    override func mouseUp(with event: NSEvent) {
        if controller?.drag != nil {
            controller?.endDrag()
        } else {
            // Second chance when SwiftUI does not consume the mouse event.
            OverlayCoordinator.shared.handlePossibleClick(event: event)
        }
        super.mouseUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        OverlayCoordinator.shared.recordMouseDown(event: event)
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let controller, controller.isOpen, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            controller.handleScroll(deltaX: event.scrollingDeltaX,
                                    momentum: !event.momentumPhase.isEmpty)
            return
        }
        super.scrollWheel(with: event)
    }

    /// 触控板捏合：在启动台里向内捏合即关闭（与打开手势互逆）。
    override func magnify(with event: NSEvent) {
        if let controller, controller.isOpen {
            controller.handlePinch(magnification: event.magnification)
            return
        }
        super.magnify(with: event)
    }

    // MARK: - Keyboard routing

    private func handle(_ event: NSEvent) -> Bool {
        guard let controller, controller.isOpen else { return false }
        // A modal confirmation owns the keyboard while it is up.
        if controller.isAlertPresented { return false }
        if controller.isClosing { return false }

        // While an input method is composing (中文候选词、日文、表情符号), every
        // key belongs to the input method: Esc cancels the composition, arrows
        // pick candidates, Return commits. We must stay out of the way.
        if FieldFocus.isComposing(in: self) { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode
        // A real text field owns plain typing; we only handle commands then.
        let editingText = FieldFocus.isSearchEditing() || controller.folderNameEditing

        // Page navigation, matching Launchpad's shortcuts:
        // ⌘←/→ · ⌃←/→ · ⌥←/→ · Page Up/Down · Home/End · ⌘1…9
        if !controller.isFiltering, controller.openFolderID == nil {
            let digitKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if flags.contains(.command), let target = digitKeys[key] {
                controller.goToPage(target)
                return true
            }
            // ⌘A 全选当前页；⌘⌫ 把选中的应用移到废纸篓（会先确认）。
            if flags.contains(.command), key == 0, !editingText {
                controller.selectAllOnPage()
                return true
            }
            if flags.contains(.command), key == 51, !editingText, controller.hasMultiSelection {
                controller.requestDeleteSelected()
                return true
            }
            if key == 116 { // Page Up
                controller.flipPage(-1)
                return true
            }
            if key == 121 { // Page Down
                controller.flipPage(1)
                return true
            }
            // The rest would steal caret movement from the text field.
            if !editingText {
                let modified = !flags.intersection([.command, .control, .option]).isEmpty
                switch key {
                case 123 where modified: // ⌘/⌃/⌥←
                    controller.flipPage(-1)
                    return true
                case 124 where modified: // ⌘/⌃/⌥→
                    controller.flipPage(1)
                    return true
                case 115: // Home
                    controller.goToPage(0)
                    return true
                case 119: // End
                    controller.goToPage(controller.pageCount - 1)
                    return true
                default:
                    break
                }
            }
        }

        switch key {
        case 53: // esc
            controller.escape()
            return true
        case 36, 76: // return / enter
            if controller.folderNameEditing {
                controller.commitFolderName()
            } else if controller.searchActive {
                controller.commitSearch()
            } else if controller.openFolderID == nil {
                controller.activateSelection()
            }
            return true
        case 48: // tab
            if !editingText {
                controller.moveSelection(dx: flags.contains(.shift) ? -1 : 1, dy: 0)
                return true
            }
            return false
        case 51: // delete
            // The focused text field deletes the character itself.
            if editingText { return false }
            if controller.searchActive { controller.backspaceSearch() }
            return true
        case 117: // forward delete
            if editingText { return false }
            if controller.searchActive { controller.deleteForwardSearch() }
            return true
        case 123: // left
            // With text in the field the arrows move the caret instead.
            if editingText, !controller.searchText.isEmpty { return false }
            if controller.folderNameEditing { return false }
            controller.moveSelection(dx: -1, dy: 0)
            return true
        case 124: // right
            if editingText, !controller.searchText.isEmpty { return false }
            if controller.folderNameEditing { return false }
            controller.moveSelection(dx: 1, dy: 0)
            return true
        case 125: // down
            if controller.searchActive { controller.moveSearchSelection(1) }
            else if !controller.folderNameEditing { controller.moveSelection(dx: 0, dy: 1) }
            return true
        case 126: // up
            if controller.searchActive { controller.moveSearchSelection(-1) }
            else if !controller.folderNameEditing { controller.moveSelection(dx: 0, dy: -1) }
            return true
        default:
            break
        }

        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                controller.quitApplication()
                return true
            case "w":
                controller.closeAndDismiss()
                return true
            case "f":
                FieldFocus.focusSearch()
                return true
            default:
                // ⌘A/⌘C/⌘V/⌘Z… belong to the focused text field.
                return false
            }
        }

        // Typing without a focused field is a corner case (e.g. after clicking
        // away): keep the old behaviour as a fallback.
        if editingText || controller.openFolderID != nil { return false }

        guard let characters = event.characters, !characters.isEmpty else { return false }
        // Ignore the control characters that function keys produce.
        let printable = characters.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
        guard printable else { return false }

        if controller.folderNameEditing {
            controller.insertFolderNameText(characters)
        } else {
            controller.insertSearchText(characters)
        }
        return true
    }

    /// Used by the self test to drive the real key handling.
    func handleKeyEventForTesting(_ event: NSEvent) -> Bool { handle(event) }
}
