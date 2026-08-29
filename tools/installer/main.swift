// The two faces: a command line when given flags, a window otherwise.

import AppKit

// ── The command line ────────────────────────────────────────────────────────

func runCommandLine(_ args: [String]) -> Int32 {
    var layout = Layout.standard()
    var operation: String?
    var alsoUserData = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--install", "--reset", "--uninstall":
            operation = args[i]
        case "--user-data":
            alsoUserData = true
        case "--root", "--payload", "--user-data-root":
            guard i + 1 < args.count else {
                FileHandle.standardError.write(
                    Data("\(args[i]) needs a directory\n".utf8))
                return 64
            }
            let url = URL(fileURLWithPath: args[i + 1])
            switch args[i] {
            case "--root": layout.root = url
            case "--payload": layout.payload = url
            default: layout.userDataOverride = url
            }
            i += 1
        case "--help", "-h":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(
                Data("unknown argument: \(args[i])\n\(usage)\n".utf8))
            return 64
        }
        i += 1
    }
    guard let operation else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        return 64
    }
    let ops = Operations(layout) { print($0) }
    do {
        switch operation {
        case "--install": try ops.install()
        case "--reset": try ops.reset()
        default: try ops.uninstall(userData: alsoUserData)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

let usage = """
usage: Install Roast --install|--reset|--uninstall [options]
  --root DIR       install somewhere other than /Applications/Roast
  --payload DIR    take the payload from somewhere other than beside this app
  --user-data      with --uninstall, also remove Application Support/Roast
  --user-data-root DIR
                   treat DIR as Application Support/Roast. Tests that
                   exercise --user-data MUST pass this: without it they
                   delete the real thing, which is not a hypothetical.
"""

// ── The window ──────────────────────────────────────────────────────────────

final class Delegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false)
    let log = NSTextView()
    let alsoUserData = NSButton(checkboxWithTitle:
        "Also remove my work: edited standard library, examples, projects,"
        + " Python environments", target: nil, action: nil)
    var busy = false
    var buttons: [NSButton] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        let layout = Layout.standard()
        window.title = "Install Roast"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18,
                                        right: 18)

        let heading = NSTextField(labelWithString:
            "CocoaMojo \(layout.payloadVersion)")
        heading.font = .boldSystemFont(ofSize: 17)
        stack.addArrangedSubview(heading)

        let blurb = NSTextField(wrappingLabelWithString:
            "Compiler, language server, debugger, standard library, examples"
            + " and the IDE's own source — installed to"
            + " /Applications/Roast, and fronted by Roast.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(blurb)

        stack.addArrangedSubview(makeButton("Install", #selector(install)))
        stack.addArrangedSubview(
            makeButton("Reset Installation", #selector(reset)))
        stack.addArrangedSubview(
            makeButton("Uninstall All…", #selector(uninstall)))
        stack.addArrangedSubview(alsoUserData)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = log
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 484).isActive = true
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(scroll)

        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ app: NSApplication) -> Bool { true }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        buttons.append(b)
        return b
    }

    private func write(_ line: String) {
        DispatchQueue.main.async {
            self.log.string += line + "\n"
            self.log.scrollToEndOfDocument(nil)
        }
    }

    /// Copying a gigabyte takes time; the buttons go quiet while it does,
    /// so a second click cannot start a second copy over the first.
    private func perform(_ work: @escaping (Operations) throws -> Void) {
        guard !busy else { return }
        busy = true
        buttons.forEach { $0.isEnabled = false }
        let ops = Operations(.standard()) { self.write($0) }
        DispatchQueue.global().async {
            do { try work(ops) } catch { self.write("error: \(error)") }
            DispatchQueue.main.async {
                self.busy = false
                self.buttons.forEach { $0.isEnabled = true }
            }
        }
    }

    @objc func install() { perform { try $0.install() } }
    @objc func reset() { perform { try $0.reset() } }

    @objc func uninstall() {
        // The confirm states exactly what goes, and says it differently
        // depending on the checkbox — a dialog that does not describe the
        // action it is confirming is a dialog people learn to dismiss.
        let wantsUserData = alsoUserData.state == .on
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall CocoaMojo and Roast?"
        alert.informativeText = wantsUserData
            ? "Removes /Applications/Roast — every installed version and the"
              + " app — AND your work in Application Support: the standard"
              + " library, examples and IDE source you have edited, and your"
              + " Python environments. This cannot be undone."
            : "Removes /Applications/Roast — every installed version, the"
              + " app, and the current symlink.\n\nYour work is kept: edited"
              + " standard library, examples, IDE source, projects and Python"
              + " environments all stay in Application Support."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try $0.uninstall(userData: wantsUserData) }
    }
}

// ── main ────────────────────────────────────────────────────────────────────

if CommandLine.arguments.count > 1 {
    exit(runCommandLine(CommandLine.arguments))
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
