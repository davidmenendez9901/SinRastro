import Darwin
import Foundation

enum ProcessLister {
    /// Procesos cuyo ejecutable está dentro del bundle.
    static func processes(inside bundlePath: String) -> [(pid: pid_t, path: String)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var result: [(pid_t, String)] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if PathUtil.isInside(path, bundlePath) { result.append((pid, path)) }
        }
        return result
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
