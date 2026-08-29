// Install Roast — the installer that ships on the DMG.
//
// One file, two faces. Double-clicked it is a window with three buttons;
// given a flag it is a command-line tool, because this project tests what a
// person does and a person cannot click unattended. The flags drive exactly
// the code the buttons call:
//
//   --install    [--root DIR] [--payload DIR]
//   --reset      [--root DIR] [--payload DIR]
//   --uninstall  [--root DIR] [--user-data]
//
// Swift, not cocoa-mojo: this must run on a machine where nothing is
// installed, and the platform's own language is the honest bootstrap.
// Dogfooding belongs in the product, not in the ladder up to it.

import AppKit

// ── Where things are ────────────────────────────────────────────────────────

struct Layout {
    var root: URL       // /Applications/Roast
    var payload: URL    // the payload folder beside this app on the DMG

    var toolchains: URL { root.appendingPathComponent("CocoaMojo") }
    var current: URL { toolchains.appendingPathComponent("current") }
    var installedApp: URL { root.appendingPathComponent("Roast.app") }
    var payloadToolchain: URL { payload.appendingPathComponent("CocoaMojo") }
    var payloadApp: URL { payload.appendingPathComponent("Roast.app") }

    /// What Roast keeps in Application Support, and what is NOT ours to
    /// remove unless someone asks twice: an edited standard library,
    /// examples, IDE source, and the per-project Python environments Roast
    /// created there. "Python environments" unqualified reads as the
    /// machine's Python, which is alarming and wrong -- nothing outside
    /// this folder is ever touched, and every string a person sees has to
    /// say so.
    ///
    /// Overridable, and that is not a convenience. `--root` used to redirect
    /// only the installation, so an unattended test of `--user-data` deleted
    /// the REAL Application Support -- which it duly did, taking a working
    /// set of Python environments with it. A destructive path that cannot be
    /// pointed somewhere harmless cannot be tested, and a test that must
    /// destroy real data to run is a test nobody should write.
    var userDataOverride: URL?
    var userData: URL {
        userDataOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Roast")
    }

    /// The version this payload carries, written by make-payload.sh.
    var payloadVersion: String {
        let f = payload.appendingPathComponent("VERSION")
        if let v = try? String(contentsOf: f, encoding: .utf8) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "unknown"
    }

    static func standard() -> Layout {
        Layout(root: URL(fileURLWithPath: "/Applications/Roast"),
               payload: Bundle.main.bundleURL
                   .deletingLastPathComponent()
                   .appendingPathComponent("payload"))
    }
}

enum Failure: Error, CustomStringConvertible {
    case reason(String)
    var description: String {
        if case let .reason(r) = self { return r }
        return "unknown"
    }
}

// ── The operations, shared by both faces ────────────────────────────────────

final class Operations {
    let fm = FileManager.default
    let layout: Layout
    let say: (String) -> Void

    init(_ layout: Layout, say: @escaping (String) -> Void) {
        self.layout = layout
        self.say = say
    }

    private func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    /// A directory is a toolchain only if it can actually compile. Roast
    /// checks the same thing for the same reason: a path that merely looks
    /// right, handed to something that raises rather than returns, ends a
    /// process.
    private func isToolchain(_ u: URL) -> Bool {
        exists(u.appendingPathComponent("bin/cocoamojo"))
    }

    /// The version `current` points at, if anything does.
    private func installedVersion() -> String? {
        guard let dest = try? fm.destinationOfSymbolicLink(
            atPath: layout.current.path) else { return nil }
        return URL(fileURLWithPath: dest).lastPathComponent
    }

    private func replace(_ source: URL, with destination: URL) throws {
        if exists(destination) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }

    // ── The one thing we cannot ship ───────────────────────────────────────

    /// Xcode's Command Line Tools. Every Mojo build links against the SDK's
    /// framework stubs and finds its linker through `xcrun`, so without them
    /// the editor opens and nothing compiles. Apple's licence does not let
    /// anyone redistribute the SDK, so this is detected and reported rather
    /// than bundled -- and `xcode-select --install` runs Apple's own
    /// installer, which is the polite way to ask.
    func commandLineToolsPresent() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !out.isEmpty && fm.fileExists(atPath: out)
    }

    func offerCommandLineTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }

    // ── The database, built here rather than carried ───────────────────────

    /// Generate cocoa.sqlite from THIS machine's SDK.
    ///
    /// 343 MB of the old payload was a snapshot of whichever Mac cut the
    /// release. Built here it is smaller to ship, and more correct: it
    /// describes the frameworks this person actually has. Fifteen seconds
    /// of pure-stdlib Python against the live Objective-C runtime and
    /// BridgeSupport.
    ///
    /// `progress` is called with a phase name and a fraction; the phases
    /// come from the generator's own output, so the bar tracks real work
    /// rather than a timer pretending to.
    /// A high-water mark that only ever rises. The generator's output is
    /// read on a background queue, so the mark is guarded.
    private final class Ratchet {
        private let lock = NSLock()
        private var high = 0.0
        func advance(to fraction: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard fraction > high else { return false }
            high = fraction
            return true
        }
    }

    func generateDatabase(into toolchain: URL,
                          progress: @escaping (String, Double) -> Void)
        throws {
        let generator = toolchain.appendingPathComponent("share/cocoakb")
        let build = generator.appendingPathComponent("build.py")
        guard exists(build) else {
            throw Failure.reason("No database generator in this payload")
        }
        let python = toolchain.appendingPathComponent(
            "Python/Python.framework/Versions/Current/bin/python3")
        let interpreter = exists(python)
            ? python : URL(fileURLWithPath: "/usr/bin/python3")

        let p = Process()
        p.executableURL = interpreter
        p.arguments = [build.path]
        p.currentDirectoryURL = generator
        // The generator writes cocoa.sqlite beside itself (DB is derived
        // from its own directory) and takes no output flag, so the file is
        // moved afterwards rather than pretending a flag exists.

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // Named phases, in the order the generator prints them. A bar that
        // moves when something happened is worth more than one that moves
        // smoothly and means nothing.
        // The generator prints its four phase headers hard against the left
        // margin and indents every detail line under them, so a prefix match
        // picks out headers and cannot be fooled by a count that happens to
        // mention the same word ("... classes -> method_abi").
        let phases: [(String, String, Double)] = [
            ("BridgeSupport", "Reading Apple's BridgeSupport files", 0.15),
            ("Runtime", "Asking the live Objective-C runtime", 0.40),
            ("POSIX", "Reading the SDK's C headers", 0.65),
            ("Derive", "Deriving signatures and calling conventions", 0.85),
        ]
        // A ratchet, not a search. Several of these words also occur in the
        // per-table row counts the generator prints at the end, so a plain
        // match fires the same phase repeatedly and out of order. Reporting
        // only what beats the high-water mark makes the bar monotonic and
        // says each phase exactly once.
        let reached = Ratchet()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData,
                                    encoding: .utf8), !text.isEmpty
            else { return }
            for line in text.split(separator: "\n") {
                for (needle, label, fraction) in phases
                where line.hasPrefix(needle) && reached.advance(to: fraction) {
                    progress(label, fraction)
                }
            }
        }
        progress("Starting", 0.05)
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        guard p.terminationStatus == 0 else {
            throw Failure.reason(
                "The database generator failed (exit \(p.terminationStatus))")
        }
        let produced = generator.appendingPathComponent("cocoa.sqlite")
        guard exists(produced) else {
            throw Failure.reason("The generator produced no database")
        }
        let db = toolchain.appendingPathComponent("share/cocoa.sqlite")
        if exists(db) { try fm.removeItem(at: db) }
        try fm.moveItem(at: produced, to: db)
        let size = (try? fm.attributesOfItem(atPath: db.path)[.size]
            as? Int) ?? 0
        progress("Database ready (\(size / 1_048_576) MB)", 1.0)
    }

    // ── Install ────────────────────────────────────────────────────────────

    /// Set by the window so Install can drive a progress bar; the command
    /// line leaves it nil and gets lines instead.
    var onProgress: ((String, Double) -> Void)?

    func install() throws {
        guard isToolchain(layout.payloadToolchain) else {
            throw Failure.reason(
                "No toolchain in the payload at \(layout.payload.path)")
        }
        let version = layout.payloadVersion
        say("Installing CocoaMojo \(version) into \(layout.root.path)")

        if let old = installedVersion(), old != version {
            say("  \(old) is already installed; this lands beside it")
        }
        try replace(layout.payloadToolchain,
                    with: layout.toolchains.appendingPathComponent(version))
        say("  toolchain copied")

        // `current` is replaced, never edited: a half-written symlink is
        // worse than a missing one, and everything resolves through it.
        if exists(layout.current)
            || (try? fm.destinationOfSymbolicLink(
                atPath: layout.current.path)) != nil {
            try fm.removeItem(at: layout.current)
        }
        try fm.createSymbolicLink(
            at: layout.current,
            withDestinationURL: layout.toolchains
                .appendingPathComponent(version))
        say("  current -> \(version)")

        if exists(layout.payloadApp) {
            try replace(layout.payloadApp, with: layout.installedApp)
            launchServices(["-f", layout.installedApp.path])
            say("  Roast.app installed and registered")
        } else {
            say("  (this payload carries no Roast.app)")
        }
        // Last, because it is the only step that needs the machine rather
        // than the payload, and the only one worth a progress bar.
        let installed = layout.toolchains.appendingPathComponent(version)
        if exists(installed.appendingPathComponent("share/cocoakb/build.py")) {
            say("")
            say("Building the Cocoa database from this Mac's SDK")
            say("  (about fifteen seconds -- it is generated here rather than")
            say("  shipped, so it describes YOUR frameworks, and it is 343 MB")
            say("  the download did not have to carry)")
            try generateDatabase(into: installed) { label, fraction in
                self.onProgress?(label, fraction)
                self.say("  " + label)
            }
        }
        say("Done. Everything is under \(layout.root.path);"
            + " `current` says which version answers.")
        if !commandLineToolsPresent() {
            say("")
            say("  NOTE: Xcode Command Line Tools are not installed.")
            say("  Every build links against the macOS SDK and finds its")
            say("  linker through xcrun, so Roast will open but nothing")
            say("  will compile until they are. Apple does not permit")
            say("  redistributing the SDK, so this is the one piece the")
            say("  installer cannot bring with it.")
            say("  Install them with:  xcode-select --install")
        }
    }

    // ── Reset ──────────────────────────────────────────────────────────────

    func reset() throws {
        guard let version = installedVersion() else {
            throw Failure.reason(
                "Nothing installed at \(layout.root.path) — use Install")
        }
        guard isToolchain(layout.payloadToolchain) else {
            throw Failure.reason(
                "Reset needs the payload — run this from the disk image")
        }
        say("Resetting CocoaMojo \(version) from the payload")
        try replace(layout.payloadToolchain,
                    with: layout.toolchains.appendingPathComponent(version))
        say("  toolchain restored, pristine")
        if exists(layout.payloadApp) {
            try replace(layout.payloadApp, with: layout.installedApp)
            say("  Roast.app restored")
        }
        say("  your work was not touched: the standard library, examples")
        say("  and IDE source you have edited, your projects, and the")
        say("  per-project Python environments Roast made, are as they were")
    }

    // ── Uninstall ──────────────────────────────────────────────────────────

    /// Preferences AppKit writes on its own: window frames, autosave state,
    /// the things nobody chose to create. They are settings rather than
    /// work, so they go with the installation and not with `--user-data`.
    /// An uninstall that says "the machine is the way you found it" and
    /// leaves sixteen plists behind is telling a small lie.
    private func preferenceFiles() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter {
            $0.hasSuffix(".plist")
                && ($0.hasPrefix("org.mojococoa.") || $0 == "roast.plist")
        }.map { dir.appendingPathComponent($0) }
    }

    private func savedStateFolders() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("org.mojococoa.") }
            .map { dir.appendingPathComponent($0) }
    }

    func uninstall(userData: Bool) throws {
        say("Uninstalling from \(layout.root.path)")
        if exists(layout.installedApp) {
            launchServices(["-u", layout.installedApp.path])
        }
        if exists(layout.root) {
            try fm.removeItem(at: layout.root)
            say("  removed \(layout.root.path): every version, the app,"
                + " the symlink")
        } else {
            say("  nothing was installed there")
        }
        // Launch Services can hold an entry for a path that no longer
        // exists -- unregistering the app only helps if the app was there
        // to unregister. Ask it to forget the whole directory as well.
        launchServices(["-u", layout.root.path])

        var swept = 0
        for f in preferenceFiles() + savedStateFolders() {
            if (try? fm.removeItem(at: f)) != nil { swept += 1 }
        }
        if swept > 0 {
            say("  removed \(swept) preference file(s) and saved window state")
        }

        if userData {
            if exists(layout.userData) {
                try fm.removeItem(at: layout.userData)
                say("  removed your user data as asked:"
                    + " \(layout.userData.path)")
            } else {
                say("  no user data to remove")
            }
        } else {
            say("  kept: \(layout.userData.path)")
            say("  (your edited standard library, examples and IDE source,")
            say("  and the per-project Python environments Roast made there)")
        }
        say("The machine is the way you found it.")
    }

    private func launchServices(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath:
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister")
        p.arguments = args
        // Best-effort: lsregister complains to stderr about paths it cannot
        // scan (an uninstall has already removed the one it is being told to
        // forget), and that complaint is not the reader's business. The
        // outcomes that matter are reported by the caller.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
