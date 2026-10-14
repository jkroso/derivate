import Darwin

/// A process of this user at the other end of a connection to Derivate.
/// An agent session is a process: Claude Code runs one for each session,
/// in the folder the user started it in.
struct PeerProcess: Sendable, Equatable {
    /// The process's ID and start time, which name it while it runs: a
    /// later process can get the same ID, but not the same start.
    struct ID: Hashable, Sendable {
        var pid: pid_t
        var started: UInt64
    }

    let id: ID
    /// The name of its executable.
    let name: String
    /// Its working folder.
    let folder: String?

    /// The process whose TCP socket goes from `clientPort` to `serverPort`,
    /// on loopback. It looks through the sockets of every process that this
    /// user can see, which takes some milliseconds.
    static func find(clientPort: UInt16, serverPort: UInt16) -> PeerProcess? {
        guard clientPort != 0, serverPort != 0 else { return nil }
        return allPIDs().first { owns(socketFrom: clientPort, to: serverPort, pid: $0) }.flatMap(Self.init(pid:))
    }

    init?(pid: pid_t) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        id = ID(pid: pid, started: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
        name = String(cString: info.pbi_name).ifEmpty(String(cString: info.pbi_comm))

        var paths = proc_vnodepathinfo()
        let pathsSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathsSize) == pathsSize {
            folder = String(cString: paths.pvi_cdir.vip_path).ifEmpty(nil)
        } else {
            folder = nil
        }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(found, 0))).filter { $0 > 0 }
    }

    private static func owns(socketFrom clientPort: UInt16, to serverPort: UInt16, pid: pid_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ends = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            // The ports are in network byte order.
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_lport)) == clientPort,
               UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_fport)) == serverPort {
                return true
            }
        }
        return false
    }
}

private extension String {
    /// The text of a C string that a fixed-size array holds.
    init<Tuple>(cString tuple: Tuple) {
        self = withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func ifEmpty(_ other: @autoclosure () -> String?) -> String? { isEmpty ? other() : self }
    func ifEmpty(_ other: @autoclosure () -> String) -> String { isEmpty ? other() : self }
}
