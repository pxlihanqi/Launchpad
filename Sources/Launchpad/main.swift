import AppKit

// Command line helpers (also used as the verification harness during
// development) run before the AppKit event loop starts.
if let mode = CLIMode.parse(CommandLine.arguments) {
    exit(MainActor.assumeIsolated { runCLI(mode) })
}

let application = NSApplication.shared
let delegate = AppDelegate()
delegate.autoPresent = CommandLine.arguments.contains("--show")
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
