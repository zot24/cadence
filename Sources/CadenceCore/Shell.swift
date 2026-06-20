import Foundation

/// Minimal synchronous process runner for invoking crontab / launchctl / plutil.
public enum Shell {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public var ok: Bool { exitCode == 0 }
    }

    /// Run an executable with arguments, capturing output. `input` is fed to stdin.
    @discardableResult
    public static func run(_ launchPath: String, _ args: [String], input: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if input != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        }

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "Failed to launch \(launchPath): \(error)", exitCode: -1)
        }

        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Convenience: run a command line through `/bin/sh -c`.
    @discardableResult
    public static func sh(_ command: String) -> Result {
        run("/bin/sh", ["-c", command])
    }
}
