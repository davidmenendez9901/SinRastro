import Foundation

struct SafeFSError: Error, CustomStringConvertible, Sendable {
    let code: Int32
    let path: String

    var isPermission: Bool { code == EACCES || code == EPERM }
    var description: String { "\(String(cString: strerror(code))): \(path)" }
}

/// Borrado y movimiento que nunca siguen enlaces simbólicos. Cada componente
/// de la ruta se abre con O_NOFOLLOW y todo se hace relativo al descriptor,
/// para que cambiar una carpeta por un symlink después de validar no sirva.
enum SafeFS {
    static func openDirectoryNoFollow(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SafeFSError(code: errno, path: "/") }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw SafeFSError(code: code, path: path) }
            fd = next
        }
        return fd
    }

    static func remove(_ path: String) throws {
        let parent = try openDirectoryNoFollow(PathUtil.parent(path))
        defer { close(parent) }
        try removeTree(parent: parent, name: PathUtil.name(path), displayPath: path)
    }

    private static func removeTree(parent: Int32, name: String, displayPath: String) throws {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SafeFSError(code: errno, path: displayPath)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 else { throw SafeFSError(code: errno, path: displayPath) }
            return
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SafeFSError(code: errno, path: displayPath) }
        let children: [String]
        do {
            children = try listDirectory(fd: fd, displayPath: displayPath)
        } catch {
            close(fd)
            throw error
        }
        var firstError: Error?
        for child in children {
            do {
                try removeTree(parent: fd, name: child, displayPath: displayPath + "/" + child)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        close(fd)
        if let firstError { throw firstError }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw SafeFSError(code: errno, path: displayPath)
        }
    }

    private static func listDirectory(fd: Int32, displayPath: String) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { close(copy) }
            throw SafeFSError(code: code, path: displayPath)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Mueve `path` dentro de `directory` con el mismo nombre, sin sobrescribir.
    @discardableResult
    static func move(_ path: String, intoDirectory directory: String) throws -> String {
        let source = try openDirectoryNoFollow(PathUtil.parent(path))
        defer { close(source) }
        let destination = try openDirectoryNoFollow(directory)
        defer { close(destination) }
        let name = PathUtil.name(path)
        guard renameatx_np(source, name, destination, name, UInt32(RENAME_EXCL)) == 0 else {
            throw SafeFSError(code: errno, path: path)
        }
        return directory + "/" + name
    }

    /// Mueve `path` a la carpeta `trash` sin sobrescribir nada. Devuelve la
    /// ruta final. `trash` debe ser un directorio real del mismo dueño que
    /// `owner`.
    @discardableResult
    static func moveToTrash(_ path: String, trash: String, owner: uid_t) throws -> String {
        var st = stat()
        guard lstat(trash, &st) == 0 else { throw SafeFSError(code: errno, path: trash) }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == owner else {
            throw SafeFSError(code: EPERM, path: trash)
        }
        let parent = try openDirectoryNoFollow(PathUtil.parent(path))
        defer { close(parent) }
        let name = PathUtil.name(path)
        let stem = PathUtil.stem(name)
        let ext = (name as NSString).pathExtension
        for attempt in 0..<200 {
            var candidate = name
            if attempt > 0 {
                candidate = ext.isEmpty ? "\(stem) \(attempt + 1)" : "\(stem) \(attempt + 1).\(ext)"
            }
            let destination = trash + "/" + candidate
            if renameatx_np(parent, name, AT_FDCWD, destination, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            if errno != EEXIST { throw SafeFSError(code: errno, path: path) }
        }
        throw SafeFSError(code: EEXIST, path: path)
    }
}
