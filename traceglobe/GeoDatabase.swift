import Foundation
import Darwin

struct GeoPoint: Codable, Equatable {
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    var label: String { city.isEmpty ? country : "\(city), \(country)" }
}

enum IPAddress {
    static func bytes(_ text: String) -> [UInt8]? {
        var v4 = [UInt8](repeating: 0, count: 4)
        if inet_pton(AF_INET, text, &v4) == 1 { return v4 }
        var v6 = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET6, text, &v6) == 1 { return v6 }
        return nil
    }
    static func isPublic(_ ip: String) -> Bool {
        guard let b = bytes(ip) else { return false }
        if b.count == 4 {
            return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1])))
        }
        return !(b.allSatisfy { $0 == 0 } || (b.dropLast().allSatisfy { $0 == 0 } && b.last == 1) || b[0] == 0xff || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80))
    }
}

// Reader for the MaxMind DB v2 format. Bundled DB-IP Lite data never leaves this Mac.
final class GeoDatabase {
    enum Failure: Error { case invalidDatabase }
    private let data: Data
    private var nodes = 0
    private var recordBits = 0
    private var ipVersion = 0
    private var treeBytes = 0

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        let marker = Data([0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8))
        guard let range = data.range(of: marker, options: .backwards, in: max(0, data.count - 131072)..<data.count) else { throw Failure.invalidDatabase }
        var offset = range.upperBound
        var budget = 4096
        guard let metadata = try decode(&offset, base: range.upperBound, depth: 0, budget: &budget) as? [String: Any],
              let count = metadata["node_count"] as? UInt64,
              let bits = metadata["record_size"] as? UInt64,
              let version = metadata["ip_version"] as? UInt64,
              metadata["binary_format_major_version"] as? UInt64 == 2,
              [24, 28, 32].contains(Int(bits)), [4, 6].contains(Int(version)) else { throw Failure.invalidDatabase }
        nodes = Int(count); recordBits = Int(bits); ipVersion = Int(version)
        treeBytes = nodes * recordBits / 4
        guard nodes > 0, treeBytes + 16 < range.lowerBound else { throw Failure.invalidDatabase }
    }

    func lookup(_ address: String) -> GeoPoint? {
        guard IPAddress.isPublic(address), var bytes = IPAddress.bytes(address) else { return nil }
        if ipVersion == 6 && bytes.count == 4 { bytes = Array(repeating: 0, count: 12) + bytes }
        if ipVersion == 4 && bytes.count != 4 { return nil }
        do {
            var node = 0
            for byte in bytes {
                for shift in stride(from: 7, through: 0, by: -1) {
                    if node >= nodes { break }
                    node = try child(node: node, right: (byte >> shift) & 1 == 1)
                }
                if node >= nodes { break }
            }
            guard node >= nodes + 16 else { return nil }
            var offset = node - nodes + treeBytes
            var budget = 4096
            guard let record = try decode(&offset, base: treeBytes + 16, depth: 0, budget: &budget) as? [String: Any],
                  let position = record["location"] as? [String: Any],
                  let latitude = position["latitude"] as? Double,
                  let longitude = position["longitude"] as? Double,
                  latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            let cityNames = (record["city"] as? [String: Any])?["names"] as? [String: Any]
            let country = (record["country"] as? [String: Any])?["iso_code"] as? String ?? ""
            return GeoPoint(city: cityNames?["ru"] as? String ?? cityNames?["en"] as? String ?? "", country: country, lat: latitude, lon: longitude)
        } catch { return nil }
    }

    private func child(node: Int, right: Bool) throws -> Int {
        let start = node * recordBits / 4
        if recordBits == 28 {
            let middle = try integer(at: start + 3, length: 1)
            let upper = right ? middle & 15 : middle >> 4
            return Int((upper << 24) | (try integer(at: start + (right ? 4 : 0), length: 3)))
        }
        return Int(try integer(at: start + (right ? recordBits / 8 : 0), length: recordBits / 8))
    }
    private func integer(at offset: Int, length: Int) throws -> UInt64 {
        guard length >= 0, length <= 8, offset >= 0, offset <= data.count - length else { throw Failure.invalidDatabase }
        var result: UInt64 = 0
        for i in 0..<length { result = (result << 8) | UInt64(data[offset + i]) }
        return result
    }
    private func decode(_ offset: inout Int, base: Int, depth: Int, budget: inout Int) throws -> Any {
        guard depth < 32, budget > 0 else { throw Failure.invalidDatabase }
        budget -= 1
        let control = Int(try integer(at: offset, length: 1)); offset += 1
        var type = control >> 5
        if type == 1 {
            let count = ((control >> 3) & 3) + 1
            let high = count == 4 ? UInt64(0) : UInt64(control & 7) << (count * 8)
            let adjustment: UInt64 = count == 2 ? 2048 : count == 3 ? 526336 : 0
            let pointer = high | (try integer(at: offset, length: count)); offset += count
            var target = base + Int(pointer + adjustment)
            return try decode(&target, base: base, depth: depth + 1, budget: &budget)
        }
        if type == 0 { type = Int(try integer(at: offset, length: 1)) + 7; offset += 1 }
        var count = control & 31
        if count >= 29 {
            let bytes = count - 28
            let extra = Int(try integer(at: offset, length: bytes)); offset += bytes
            count = (count == 29 ? 29 : count == 30 ? 285 : 65821) + extra
        }
        guard count <= 65536 else { throw Failure.invalidDatabase }
        if type == 7 {
            guard count * 2 <= budget else { throw Failure.invalidDatabase }
            var map: [String: Any] = [:]
            for _ in 0..<count {
                guard let key = try decode(&offset, base: base, depth: depth + 1, budget: &budget) as? String else { throw Failure.invalidDatabase }
                map[key] = try decode(&offset, base: base, depth: depth + 1, budget: &budget)
            }
            return map
        }
        if type == 11 {
            guard count <= budget else { throw Failure.invalidDatabase }
            var array: [Any] = []
            for _ in 0..<count { array.append(try decode(&offset, base: base, depth: depth + 1, budget: &budget)) }
            return array
        }
        if type == 14 { return count != 0 }
        guard offset >= 0, offset <= data.count - count else { throw Failure.invalidDatabase }
        let start = offset; offset += count
        switch type {
        case 2: return String(data: data[start..<offset], encoding: .utf8) ?? ""
        case 3: guard count == 8 else { throw Failure.invalidDatabase }; return Double(bitPattern: try integer(at: start, length: 8))
        case 5, 6, 9: return try integer(at: start, length: count)
        case 8: return Int64(Int32(bitPattern: UInt32(try integer(at: start, length: count))))
        case 15: guard count == 4 else { throw Failure.invalidDatabase }; return Double(Float(bitPattern: UInt32(try integer(at: start, length: 4))))
        case 4, 10: return Data(data[start..<offset])
        default: throw Failure.invalidDatabase
        }
    }
}
