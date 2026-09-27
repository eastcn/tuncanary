import AppKit

/// 菜单栏应用（`.accessory`）不显示主菜单，但 ⌘V、⌘C 等快捷键要靠主菜单里“编辑”菜单的键位分派到输入框。
/// 没有主菜单时，设置页的输入框只能用右键菜单粘贴。这里装一个不可见的主菜单，只含“编辑”菜单。
public enum EditMenu {
    /// “编辑”菜单的条目：标题、动作和快捷键。动作发给当前的第一响应者。
    static let items: [(title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("撤销", Selector(("undo:")), "z", [.command]),
        ("重做", Selector(("redo:")), "z", [.command, .shift]),
        ("剪切", #selector(NSText.cut(_:)), "x", [.command]),
        ("拷贝", #selector(NSText.copy(_:)), "c", [.command]),
        ("粘贴", #selector(NSText.paste(_:)), "v", [.command]),
        ("全选", #selector(NSText.selectAll(_:)), "a", [.command]),
    ]

    /// 生成主菜单：一个空的应用菜单（占位）和“编辑”菜单。
    public static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = item.modifiers
            edit.addItem(menuItem)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @MainActor
    public static func install(on application: NSApplication = .shared) {
        application.mainMenu = makeMainMenu()
    }
}
