import Foundation

/// The result of running an external process. `stdout`/`stderr` are decoded UTF-8.
struct ProcessResult: Equatable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
    var commandLine: String { ([executable] + arguments).joined(separator: " ") }
}

enum ProcessRunner {
    /// Runs `executable` with `arguments` off the main thread, reading stdout & stderr concurrently
    /// to avoid pipe-buffer deadlock. Throws AppError.process on launch failure, or on non-zero exit
    /// when `throwsOnNonZero` is true.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        throwsOnNonZero: Bool = false
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            // Hop entirely off the main thread; Process + blocking reads must never run on main.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                if let environment { process.environment = environment }
                let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                if standardInput != nil { process.standardInput = inPipe }
                do {
                    try process.run()
                } catch {
                    // Redact in case `arguments` carries a --token value.
                    continuation.resume(throwing: AppError.process(
                        command: Log.redact(([executable.path] + arguments).joined(separator: " ")),
                        exitCode: -1, stderr: "Failed to launch: \(error.localizedDescription)"))
                    return
                }
                if let standardInput, let data = standardInput.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(data)
                    try? inPipe.fileHandleForWriting.close()
                }
                // Read both pipes concurrently so a full stderr buffer can't block stdout (and vice versa).
                let group = DispatchGroup()
                var outData = Data(); var errData = Data()
                group.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                process.waitUntilExit()
                group.wait()
                let result = ProcessResult(
                    executable: executable.path, arguments: arguments,
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self))
                if throwsOnNonZero && !result.succeeded {
                    continuation.resume(throwing: AppError.process(
                        command: Log.redact(result.commandLine), exitCode: result.exitCode,
                        stderr: result.stderr.isEmpty ? result.stdout : result.stderr))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Convenience for running a shell script (e.g. ./svc.sh, ./config.sh) from its directory.
    static func runScript(_ scriptPath: URL, _ arguments: [String],
                          currentDirectory: URL? = nil, throwsOnNonZero: Bool = false) async throws -> ProcessResult {
        // config.sh / svc.sh ship with +x, so we exec them directly from their install directory.
        try await run(executable: scriptPath, arguments: arguments,
                      currentDirectory: currentDirectory ?? scriptPath.deletingLastPathComponent(),
                      throwsOnNonZero: throwsOnNonZero)
    }
}
