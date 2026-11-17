import Foundation

enum PathUtil {
    static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    static func isInside(_ path: String, _ directory: String) -> Bool {
        path.hasPrefix(directory + "/")
    }

    /// Absoluta, sin componentes vacíos, "." ni "..", y sin barra final.
    static func isStructurallySafe(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.contains("\0") else { return false }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
