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

    /// User data lives in Application Support and is NOT ours to remove
    /// unless someone asks twice: an edited standard library, examples, IDE
    /// source, and Python environments that took real time to build.
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

    // ── Install ────────────────────────────────────────────────────────────

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
        say("Done. Everything is under \(layout.root.path);"
            + " `current` says which version answers.")
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
        say("  your work was not touched: the standard library, examples and")
        say("  IDE source you have edited, your projects, and your Python")
        say("  environments are all exactly as they were")
    }

    // ── Uninstall ──────────────────────────────────────────────────────────

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
        if userData {
            if exists(layout.userData) {
                try fm.removeItem(at: layout.userData)
                say("  removed your user data as asked:"
                    + " \(layout.userData.path)")
            } else {
                say("  no user data to remove")
            }
        } else {
            say("  your user data was KEPT at \(layout.userData.path)")
            say("  (edited standard library, examples, IDE source, projects,")
            say("  Python environments)")
        }
        say("The machine is the way you found it.")
    }

    private func launchServices(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath:
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
