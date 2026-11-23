// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import Foundation
import MagicLogiCore

/// Single source of truth: CFBundleShortVersionString of the Info.plist
/// embedded in the binary (scripts read the same file).
let magiclogiVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"

func printUsage() {
    print("""
    usage: magiclogid [run] [--config FILE]   run the agent (default; started by launchd)
           magiclogid check [--config FILE]  validate the configuration and exit
           magiclogid status                 last state written by the agent
           magiclogid conflicts              warn about Logitech software that takes the
                                             mouse over (exit status 2 if any is installed)
           magiclogid diag                   read-only HID++ report on the Logitech devices
           magiclogid events [SECONDS] [--motion] [--divert]
                                             print button and wheel reports (default 30 s)
           magiclogid reset                  native buttons, no inversion, default DPI
           magiclogid --version

    diag, events and reset open the mouse: run them through `magiclogictl`
    (as a one-shot launchd job) so that macOS checks magiclogid's own
    permissions, not the terminal's.
    """)
}

func configPath(_ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--config") else { return Config.defaultPath }
    return i + 1 < args.count ? args[i + 1] : nil
}

func runCheck(_ args: [String]) -> Int32 {
    guard let path = configPath(args) else { printUsage(); return 64 }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("\(path): cannot read (no file = mouse left unchanged)")
        return 1
    }
    do {
        let cfg = try Config.parse(text)
        print("\(path): OK — \(cfg.summary)")
        if cfg.needsEventPosting { print("note: remapped buttons need the Accessibility permission") }
        return 0
    } catch {
        print("\(path): \(error)")
        return 65
    }
}

func runStatus() -> Int32 {
    guard let s = try? String(contentsOfFile: StatusFile.path, encoding: .utf8) else {
        print("no status: the agent has never run")
        return 1
    }
    print(s, terminator: "")
    return 0
}

func runConflicts() -> Int32 {
    let found = Conflicts.installed { FileManager.default.fileExists(atPath: $0) }
    guard let w = Conflicts.warning(found) else { return 0 }
    print("WARNING: \(w)")
    return 2
}

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first.flatMap { $0.hasPrefix("--config") ? nil : $0 } ?? "run"
let rest = argv.first == command ? Array(argv.dropFirst()) : argv

switch command {
case "run":
    guard let path = configPath(rest) else { printUsage(); exit(64) }
    Agent(configPath: path).run()
case "check": exit(runCheck(rest))
case "status": exit(runStatus())
case "conflicts": exit(runConflicts())
case "diag": exit(runDiag(args: rest))
case "events": exit(runEvents(args: rest))
case "reset": exit(runReset())
case "--version", "version": print(magiclogiVersion); exit(0)
case "-h", "--help", "help": printUsage(); exit(0)
default: printUsage(); exit(64)
}
