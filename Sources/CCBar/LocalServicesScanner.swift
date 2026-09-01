import Foundation

struct LocalService: Identifiable, Hashable {
    let id: String          // "<pid>:<port>"
    let pid: Int32
    let processName: String
    let port: UInt16
    let bindHost: String    // "*", "127.0.0.1", "::1", etc.
    let processCwd: String? // cwd of the listening process, for folder grouping

    var url: URL? {
        Self.nonHttpPorts.contains(port) ? nil : URL(string: "http://localhost:\(port)")
    }

    var folderName: String {
        guard let c = processCwd else { return "(other)" }
        if c == NSHomeDirectory() { return "~" }
        return (c as NSString).lastPathComponent
    }

    // Ports we know are *not* HTTP — clicking these copies instead of opening
    // a browser. Conservative list; everything else gets the browser action.
    private static let nonHttpPorts: Set<UInt16> = [
        21,                         // ftp
        22,                         // ssh
        23,                         // telnet
        25, 465, 587,               // smtp
        53,                         // dns
        110, 995,                   // pop3
        143, 993,                   // imap
        2181,                       // zookeeper
        3306, 3307,                 // mysql
        5432, 5433,                 // postgres
        5984,                       // couchdb
        6379,                       // redis
        7000, 9042,                 // cassandra
        9092,                       // kafka
        9200, 9300,                 // elasticsearch
        11211,                      // memcached
        27017, 27018, 27019         // mongo
    ]
}

final class LocalServicesScanner {
    func scan() -> [LocalService] {
        guard let output = runLsof() else { return [] }
        let bare = parse(output)
        let cwds = fetchCwds(for: bare.map(\.pid))
        return bare.map {
            LocalService(
                id: $0.id, pid: $0.pid, processName: $0.processName,
                port: $0.port, bindHost: $0.bindHost,
                processCwd: cwds[$0.pid]
            )
        }
    }

    // Reused pattern from TabScanner: lsof of cwd FDs, AND-filtered to PID list.
    // -b -w keeps lsof off the blocking kernel calls that strand it in
    // uninterruptible state on a hung mount (where even SIGKILL won't reach it).
    private func fetchCwds(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        guard let out = Subprocess.run("/usr/sbin/lsof",
                                       ["-b", "-w", "-a",
                                        "-p", pids.map(String.init).joined(separator: ","),
                                        "-d", "cwd",
                                        "-Fpn"])
        else { return [:] }

        var result: [Int32: String] = [:]
        var currentPid: Int32?
        for line in out.split(separator: "\n") {
            if line.first == "p" {
                currentPid = Int32(line.dropFirst())
            } else if line.first == "n", let pid = currentPid {
                let path = String(line.dropFirst())
                if path.hasPrefix("/") { result[pid] = path }
            }
        }
        return result
    }

    private func runLsof() -> String? {
        // -b -w               → keep lsof off kernel calls that can block on a
        //                       hung mount (see fetchCwds)
        // -a                  → AND the filters. Without it lsof ORs them, so
        //                       "-u <user>" alone matched every open FD this
        //                       user owns: 27k lines instead of 9, re-split on
        //                       every 20s pass, and ~43 rows whose paths merely
        //                       end in ":<digits>" were parsed as live services.
        // -iTCP -sTCP:LISTEN  → only TCP listening sockets
        // -P -n               → numeric ports/hosts (no DNS)
        // -u <user>           → restrict to current user (drops mDNSResponder, etc.)
        Subprocess.run("/usr/sbin/lsof",
                       ["-b", "-w", "-a", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-u", NSUserName()],
                       timeout: 3)   // now milliseconds of work; a stall is a real hang
    }

    private func parse(_ output: String) -> [LocalService] {
        var seen = Set<String>()       // dedup IPv4/IPv6 same-port entries
        var result: [LocalService] = []

        for line in output.split(separator: "\n").dropFirst() {  // skip header
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 9, let pid = Int32(parts[1]) else { continue }

            // NAME field is column 8 onwards; trim trailing "(LISTEN)".
            let name = parts[8...].map(String.init).joined(separator: " ")
                .replacingOccurrences(of: " (LISTEN)", with: "")

            // Parse host:port — handles "*:3000", "127.0.0.1:5432", "[::1]:8080".
            guard let colon = name.range(of: ":", options: .backwards),
                  let port = UInt16(name[colon.upperBound...]) else { continue }
            var host = String(name[..<colon.lowerBound])
            if host.hasPrefix("["), host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }

            let key = "\(pid):\(port)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            result.append(LocalService(
                id: key,
                pid: pid,
                processName: String(parts[0]),
                port: port,
                bindHost: host,
                processCwd: nil    // filled in by scan() after batch lsof
            ))
        }
        // HTTP-ish services first (the ones you actually click to open),
        // then non-HTTP (databases, etc.). Within each, sort by port.
        return result.sorted { a, b in
            let aHttp = a.url != nil
            let bHttp = b.url != nil
            if aHttp != bHttp { return aHttp }
            return a.port < b.port
        }
    }
}
