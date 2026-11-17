import Foundation

// Helper de un solo uso. Se ejecuta como root desde SinRastro con la ruta de
// un manifiesto JSON, revalida cada ruta, borra, imprime un informe JSON y
// termina. No se instala ni queda residente.

func emit(_ report: HelperReport) -> Never {
    let data = (try? JSONEncoder().encode(report)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}

func readManifest(_ path: String, owner: uid_t) -> HelperManifest? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard
        fstat(fd, &st) == 0,
        (st.st_mode & S_IFMT) == S_IFREG,
        st.st_uid == owner,
        st.st_size < 4_000_000,
        let data = try? handle.readToEnd()
    else { return nil }
    return try? JSONDecoder().decode(HelperManifest.self, from: data)
}

func main() -> Never {
    guard CommandLine.arguments.count == 2 else { emit(HelperReport(error: "Uso: SinRastroHelper <manifiesto>")) }
    guard geteuid() == 0 else { emit(HelperReport(error: "El helper debe ejecutarse como administrador")) }

    // El usuario de la sesión gráfica; no se toma del manifiesto.
    var console = stat()
    guard
        stat("/dev/console", &console) == 0, console.st_uid != 0,
        let entry = getpwuid(console.st_uid)
    else { emit(HelperReport(error: "No se pudo determinar el usuario de la sesión")) }
    let home = String(cString: entry.pointee.pw_dir)

    guard let manifest = readManifest(CommandLine.arguments[1], owner: console.st_uid) else {
        emit(HelperReport(error: "Manifiesto ilegible o de otro usuario"))
    }

    let hooks = HelperHooks(
        packages: LivePackageDatabase(),
        bootoutDaemon: { label in
            _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
        },
        killBundleProcesses: { bundlePath in
            let own = getpid()
            let pids = ProcessLister.processes(inside: bundlePath).map(\.pid).filter { $0 != own }
            guard !pids.isEmpty else { return }
            for pid in pids { kill(pid, SIGTERM) }
            usleep(700_000)
            for pid in pids where ProcessLister.isAlive(pid) { kill(pid, SIGKILL) }
        }
    )
    let executor = HelperExecutor(layout: FSLayout(root: "", home: home), hooks: hooks)
    emit(executor.run(manifest))
}

main()
