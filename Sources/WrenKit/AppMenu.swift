import AppKit

/// The standard Mac menu bar for Wren: Wren (About, Settings, Hide, Quit), File, Edit, Window, Help.
/// Built in code because Wren has no storyboard.
@MainActor
enum AppMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        let app = NSMenu(title: "Wren")
        app.addItem(item("About Wren", #selector(AppDelegate.showAboutAction), "", target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.openSettingsAction), ",", target))
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(servicesItem)
        app.addItem(.separator())
        app.addItem(item("Hide Wren", #selector(NSApplication.hide(_:)), "h"))
        let others = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Quit Wren", #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("Open Wren", #selector(AppDelegate.openMainWindowAction), "0", target))
        file.addItem(item("New Capture", #selector(AppDelegate.newCaptureAction), "n", target))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        let redo = item("Redo", Selector(("redo:")), "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        add(edit, to: main)

        // ⌘1…⌘9: the sections of Wren's window, in sidebar order.
        let go = NSMenu(title: "Go")
        for (i, s) in MainWindowView.Section.allCases.enumerated() where i < 9 {
            let it = item(s.rawValue, #selector(AppDelegate.goToSectionAction(_:)), "\(i + 1)", target)
            it.tag = i
            go.addItem(it)
        }
        add(go, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        NSApp.windowsMenu = window
        add(window, to: main)

        let help = NSMenu(title: "Help")
        help.addItem(item("Wren Help", #selector(AppDelegate.openHelpAction), "?", target))
        help.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showShortcutsAction), "/", target))
        help.addItem(item("Shortcuts and Commands (web)", #selector(AppDelegate.openShortcutsAction), "", target))
        NSApp.helpMenu = help
        add(help, to: main)

        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        main.addItem(i)
    }
}
