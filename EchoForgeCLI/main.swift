import Foundation

// The whole of the executable: build the real environment, run one command,
// print what it produced, exit with what it decided.
//
// Nothing else lives here on purpose. `CommandRouter.execute` returns its
// output rather than printing it, so every command, every failure and every
// exit code is reachable from `EchoForgeCLITests` without a process - and this
// file, which cannot be, has nothing in it to get wrong.
//
// Top-level code in `main.swift` runs on the main actor, which is what
// `UpdateInstaller` needs: it is `@MainActor`, and an update installed from a
// tool that had blocked its main thread on a semaphore would deadlock rather
// than install.

let execution = await CommandRouter.execute(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: .system())

if !execution.output.isEmpty { StandardStreams.output(execution.output) }
if !execution.diagnostic.isEmpty {
    FileHandle.standardError.write(Data(execution.diagnostic.utf8))
}
exit(execution.exitCode.rawValue)
