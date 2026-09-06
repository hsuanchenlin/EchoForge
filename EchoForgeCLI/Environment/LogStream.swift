import Foundation

/// `log stream`, and the part that makes `--follow` allowed to exist: Ctrl-C
/// ends it, and ends the child with it.
///
/// A streaming command is the one place this tool runs something that never
/// exits on its own, so it does not go through `CommandRunning` - that protocol
/// waits for a process and hands back its whole output, which is the opposite of
/// streaming. What it owes in exchange is a clean stop, and "clean" here has two
/// halves that are easy to get half right.
///
/// The **signal** half: the default SIGINT action kills this process
/// immediately, so the child `log stream` would be orphaned and keep running
/// with nothing reading it. SIGINT is therefore ignored at the C level and
/// observed through a `DispatchSourceSignal` instead, which is what lets the
/// handler run at all.
///
/// The **child** half: `terminate()` only raises SIGTERM, so the wait after it
/// is not politeness - it is what makes "the stream stopped" true when this
/// returns, the same reason `SystemCommandRunner`'s own sweep waits.
enum LogStream {

    /// How long the child is given to go away after SIGTERM before it is left
    /// to the kernel. Short: it is a reader with nothing to flush.
    static let terminationGracePeriod: TimeInterval = 2

    static func run(
        executable: String = "/usr/bin/log",
        arguments: [String],
        onLine: @escaping (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // Installed before the process starts, so a Ctrl-C in the window
        // between launching and reading is still caught.
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var interrupted = false
        interrupts.setEventHandler {
            interrupted = true
            if process.isRunning { process.terminate() }
        }
        interrupts.resume()
        defer {
            interrupts.cancel()
            signal(SIGINT, SIG_DFL)
        }

        do {
            try process.run()
        } catch {
            throw CLIError("Could not start \(executable). \(error.localizedDescription)")
        }

        // Read on a background queue so the signal source on the main queue can
        // still fire while this is blocked on the pipe.
        let reader = DispatchQueue(label: "com.hsuanchenlin.echoforge.logstream")
        reader.async {
            var buffer = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine(line) }
                }
            }
        }

        // The main queue has to be *running* for the signal source to fire, and
        // this function is called from `main`, so it drives the run loop itself
        // rather than blocking on the semaphore.
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if interrupted {
            let deadline = Date().addingTimeInterval(terminationGracePeriod)
            while process.isRunning, Date() < deadline {
                usleep(20_000)
            }
        }
    }
}
