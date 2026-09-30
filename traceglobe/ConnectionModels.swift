import Foundation

struct LiveConnection: Identifiable, Codable, Equatable {
    let id: String
    let process: String
    let pid: Int
    let ip: String
    let port: String
    let transport: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    var location: GeoPoint?
    var destination: String { ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)" }
}

struct TraceHop: Identifiable, Codable {
    let id: Int
    let ip: String?
    let milliseconds: Double?
    var location: GeoPoint?
}

enum ConnectionParser {
    static func parse(_ text: String) -> [LiveConnection] {
        var process = "", pid = 0
        var connections: [LiveConnection] = []
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let name = columns.first else { continue }
            let socket = name.hasPrefix("tcp4 ") || name.hasPrefix("tcp6 ") || name.hasPrefix("udp4 ") || name.hasPrefix("udp6 ")
            if !socket {
                if let dot = name.lastIndex(of: "."), let number = Int(name[name.index(after: dot)...]) {
                    process = String(name[..<dot]); pid = number
                }
                continue
            }
            guard pid > 0, columns.count >= 4, let separator = name.range(of: "<->") else { continue }
            let transport = name.hasPrefix("tcp") ? "TCP" : "UDP"
            if transport == "TCP" && columns[1].lowercased() != "established" { continue }
            let remote = String(name[separator.upperBound...])
            let isIPv6 = name.hasPrefix("tcp6") || name.hasPrefix("udp6")
            guard let split = remote.lastIndex(of: isIPv6 ? "." : ":") else { continue }
            let ip = String(remote[..<split]).split(separator: "%").first.map(String.init) ?? ""
            let port = String(remote[remote.index(after: split)...])
            guard IPAddress.bytes(ip) != nil, IPAddress.isPublic(ip) else { continue }
            connections.append(LiveConnection(id: "\(pid)|\(name)", process: process, pid: pid, ip: ip, port: port, transport: transport, bytesIn: UInt64(columns[2]) ?? 0, bytesOut: UInt64(columns[3]) ?? 0))
        }
        return connections
    }
    static func trace(_ text: String) -> [TraceHop] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, let number = Int(fields[0]), number > 0 else { return nil }
            let ip = fields.dropFirst().first { IPAddress.bytes($0) != nil }
            let value = fields.firstIndex(of: "ms").flatMap { $0 > 0 ? Double(fields[$0 - 1]) : nil }
            return TraceHop(id: number, ip: ip, milliseconds: value)
        }
    }
}
