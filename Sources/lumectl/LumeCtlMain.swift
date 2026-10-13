// lumectl is a macOS developer tool; the package's library products build for
// every platform and this target must not block them.
#if os(macOS)
import Dispatch
import Foundation
import LumeCtlCore
import Synchronization

/// `swift run lumectl --help`. Everything but process plumbing — argument
/// parsing, the run itself, output — lives in LumeCtlCore, where it is tested.
@main
enum LumeCtlMain {
    static func main() async {
        let command: Command
        do {
            command = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeLine("lumectl: \(error)\nrun 'lumectl --help' for usage", to: .standardError)
            exit(ExitCode.usage.rawValue)
        }

        let (interrupts, continuation) = AsyncStream<Void>.makeStream()
        let sigint = installInterruptHandler(continuation)
        let code = await LumeCtl.run(
            command,
            interrupts: interrupts,
            stdout: { writeLine($0, to: .standardOutput) },
            stderr: { writeLine($0, to: .standardError) }
        )
        sigint.cancel()
        exit(code.rawValue)
    }

    /// The first Ctrl-C ends the run cleanly (bounded session shutdown, then
    /// the summary); a second one means the user is done waiting.
    private static func installInterruptHandler(
        _ continuation: AsyncStream<Void>.Continuation
    ) -> DispatchSourceSignal {
        // Dispatch delivers the signal only once the default action is off.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "lumectl.sigint"))
        let count = InterruptCount()
        source.setEventHandler {
            if count.increment() == 1 {
                continuation.yield()
            } else {
                writeLine("lumectl: interrupted again, exiting without cleanup", to: .standardError)
                exit(ExitCode.interrupted.rawValue)
            }
        }
        source.resume()
        return source
    }

    /// Unbuffered, so piped output (`| tee`, `| jq`) shows each record as it
    /// happens rather than when a buffer fills.
    private static func writeLine(_ line: String, to handle: FileHandle) {
        handle.write(Data((line + "\n").utf8))
    }
}
/// Ctrl-C presses so far; the handler is a `@Sendable` closure.
private final class InterruptCount: Sendable {
    private let count = Mutex(0)

    func increment() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}
#else
@main
enum LumeCtlMain {
    static func main() {
        print("lumectl is macOS-only")
    }
}
#endif
