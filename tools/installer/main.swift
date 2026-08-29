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
    // "Python environments" alone reads as the machine's Python. These are
    // per-project environments this app created inside its own Application
    // Support folder; nothing outside it is ever touched, and the wording
    // has to say so before someone declines out of reasonable alarm.
    let alsoUserData = NSButton(checkboxWithTitle:
        "Also remove my edits and settings in Application Support"
        + " (edited standard library, examples, IDE source, and the"
        + " per-project Python environments Roast created there)",
        target: nil, action: nil)
    var busy = false
    var buttons: [NSButton] = []
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")

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
            + " /Applications/Roast, and fronted by Roast.\n\n"
            + "Installing also builds the Cocoa database — the description"
            + " of every Objective-C class and method that Roast completes"
            + " and the compiler calls. It is generated here, from this"
            + " Mac's own macOS SDK, so it describes the frameworks you"
            + " actually have. That takes about fifteen seconds and saves"
            + " the download 343 MB.")
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

        // Said before anyone presses anything, because it is the difference
        // between an editor that works and one that only opens.
        if !Operations(.standard(), say: { _ in }).commandLineToolsPresent() {
            let warn = NSTextField(wrappingLabelWithString:
                "⚠︎ Xcode Command Line Tools are not installed. Roast will"
                + " open, but nothing will compile until they are — every"
                + " build needs the macOS SDK and Apple does not allow it to"
                + " be redistributed. Click to install them.")
            warn.font = .systemFont(ofSize: 11)
            warn.textColor = .systemOrange
            warn.preferredMaxLayoutWidth = 480
            stack.addArrangedSubview(warn)
            let fix = NSButton(title: "Install Command Line Tools…",
                               target: self, action: #selector(installCLT))
            fix.bezelStyle = .rounded
            stack.addArrangedSubview(fix)
        }

        // A real bar, driven by the generator's own phases. Hidden until
        // something is happening, because an idle progress bar is a lie
        // about what the window is doing.
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 484).isActive = true
        stack.addArrangedSubview(progress)
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        stack.addArrangedSubview(progressLabel)

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
        // The window was a fixed 520x460, which silently clipped the stack
        // the moment the blurb grew. Sizing to what the content actually
        // needs means text can be added without measuring it by hand.
        window.setContentSize(stack.fittingSize)
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
        ops.onProgress = { label, fraction in
            DispatchQueue.main.async {
                self.progress.isHidden = false
                self.progressLabel.isHidden = false
                self.progress.doubleValue = fraction
                self.progressLabel.stringValue = label
            }
        }
        DispatchQueue.global().async {
            do { try work(ops) } catch { self.write("error: \(error)") }
            DispatchQueue.main.async {
                self.busy = false
                self.buttons.forEach { $0.isEnabled = true }
                self.progress.isHidden = true
                self.progressLabel.isHidden = true
            }
        }
    }

    @objc func installCLT() {
        Operations(.standard(), say: { self.write($0) })
            .offerCommandLineTools()
        write("Asked macOS to install the Command Line Tools.")
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
              + " app — AND everything Roast keeps in Application Support:"
              + " the standard library, examples and IDE source you have"
              + " edited, and the per-project Python environments Roast"
              + " created there.\n\nYour own projects, and any Python on"
              + " this Mac outside Roast, are not touched. This cannot be"
              + " undone."
            : "Removes /Applications/Roast — every installed version, the"
              + " app, and the current symlink.\n\nEverything Roast keeps in"
              + " Application Support stays: your edited standard library,"
              + " examples and IDE source, and the per-project Python"
              + " environments it created there."
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
