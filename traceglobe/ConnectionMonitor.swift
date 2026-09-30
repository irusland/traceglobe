import Foundation
import Combine

struct CommandResult { let text: String; let status: Int32 }
enum LocalCommand {
    static func run(_ executable: String, arguments: [String], timeout: Double) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
            try process.run()
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); stop.cancel()
            return CommandResult(text: String(data: bytes, encoding: .utf8) ?? "", status: process.terminationStatus)
        }.value
    }
}

actor ConnectionSampler {
    private var database: GeoDatabase?
    private var triedDatabase = false
    private var locations: [String: GeoPoint] = [:]
    private var missing: Set<String> = []
    private func locate(_ ip: String) -> GeoPoint? {
        if !triedDatabase {
            triedDatabase = true
            if let url = Bundle.main.url(forResource: "city", withExtension: "mmdb") { database = try? GeoDatabase(url: url) }
        }
        if let cached = locations[ip] { return cached }
        if missing.contains(ip) { return nil }
        if let point = database?.lookup(ip) { locations[ip] = point; return point }
        missing.insert(ip); return nil
    }
    func snapshot() async throws -> [LiveConnection] {
        let result = try await LocalCommand.run("/usr/bin/nettop", arguments: ["-L", "1", "-n", "-J", "state,bytes_in,bytes_out", "-x"], timeout: 10)
        guard result.status == 0 else { throw NSError(domain: "TraceGlobe", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS не предоставила список соединений."]) }
        return ConnectionParser.parse(result.text).map { connection in
            var item = connection; item.location = locate(item.ip); return item
        }.sorted { ($0.process.lowercased(), $0.ip, $0.port) < ($1.process.lowercased(), $1.ip, $1.port) }
    }
    func trace(_ ip: String) async throws -> (hops: [TraceHop], raw: String, completed: Bool) {
        guard IPAddress.isPublic(ip) else { throw NSError(domain: "TraceGlobe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Выберите внешний IP-адрес."]) }
        let command = ip.contains(":") ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute"
        let result = try await LocalCommand.run(command, arguments: ["-n", "-q", "1", "-w", "1", "-m", "16", ip], timeout: 25)
        let hops = ConnectionParser.trace(result.text).map { hop in
            var item = hop; if let address = item.ip { item.location = locate(address) }; return item
        }
        if hops.isEmpty { throw NSError(domain: "TraceGlobe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Трассировка не получила ответов. Адрес может блокировать диагностические пакеты."]) }
        return (hops, result.text, hops.last?.ip == ip)
    }
}

struct GlobePoint: Codable {
    let id: String
    let city: String
    let lat: Double?
    let lon: Double?
    let times: [Double]
}
struct GlobeSnapshot: Codable { let points: [GlobePoint]; let selected: String?; let showRoutes: Bool }

@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var connections: [LiveConnection] = []
    @Published private(set) var isMonitoring = true
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var error: String?
    @Published var search = ""
    @Published private(set) var selectedID: String?
    @Published private(set) var traceHops: [TraceHop] = []
    @Published private(set) var tracing = false
    @Published private(set) var showingTrace = false
    @Published private(set) var traceTarget = ""
    @Published private(set) var traceStatus = ""
    @Published private(set) var traceOutput = ""
    private var polling: Task<Void, Never>?
    private var traceTask: Task<Void, Never>?
    private var generation = 0
    private let sampler = ConnectionSampler()

    init() { start() }
    var filtered: [LiveConnection] {
        guard !search.isEmpty else { return connections }
        return connections.filter { "\($0.process) \($0.ip) \($0.location?.label ?? "")".localizedCaseInsensitiveContains(search) }
    }
    var selected: LiveConnection? { connections.first { $0.id == selectedID } }
    func choose(_ connection: LiveConnection) { selectedID = connection.id; if !tracing { showingTrace = false } }
    func chooseMapPoint(_ id: String) {
        if showingTrace { return }
        if let connection = filtered.first(where: { $0.ip == id }) { choose(connection) }
    }
    func toggleMonitoring() {
        if isMonitoring { isMonitoring = false; polling?.cancel(); polling = nil }
        else { isMonitoring = true; start() }
    }
    private func start() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let sampler = self?.sampler else { return }
                do {
                    let values = try await sampler.snapshot()
                    guard !Task.isCancelled else { return }
                    self?.connections = values
                    self?.lastUpdated = Date(); self?.error = nil
                    if self?.selected == nil { self?.selectedID = values.first?.id }
                } catch {
                    if !Task.isCancelled { self?.error = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }
    func runTrace() {
        guard let selected, !tracing else { return }
        generation += 1; let current = generation
        traceTarget = selected.ip; tracing = true; showingTrace = true
        traceHops = []; traceOutput = ""; traceStatus = "Трассировка с этого Mac…"; error = nil
        traceTask = Task { [weak self, sampler] in
            do {
                let result = try await sampler.trace(selected.ip)
                guard self?.generation == current else { return }
                self?.traceHops = result.hops; self?.traceOutput = result.raw
                let located = result.hops.filter { $0.location != nil }.count
                let outcome = result.completed ? "Адрес достигнут" : "Частичный маршрут: не все узлы ответили"
                self?.traceStatus = outcome + (located < 2 ? ". Для линии нужны хотя бы два узла с известными координатами; ответы показаны ниже." : ". Линии показывают порядок узлов, а не физический путь кабеля.")
            } catch { if self?.generation == current { self?.traceStatus = error.localizedDescription } }
            if self?.generation == current { self?.tracing = false }
        }
    }
    func showConnections() { showingTrace = false }
    var globeJSON: String {
        let points: [GlobePoint]
        if showingTrace {
            points = traceHops.map { GlobePoint(id: String($0.id), city: $0.location?.label ?? $0.ip ?? "Нет ответа", lat: $0.location?.lat, lon: $0.location?.lon, times: $0.milliseconds.map { [$0] } ?? []) }
        } else {
            var seen = Set<String>()
            points = filtered.compactMap { connection in
                guard seen.insert(connection.ip).inserted else { return nil }
                return GlobePoint(id: connection.ip, city: connection.location?.label ?? connection.ip, lat: connection.location?.lat, lon: connection.location?.lon, times: [])
            }
        }
        let snapshot = GlobeSnapshot(points: points, selected: showingTrace ? nil : selected?.ip, showRoutes: showingTrace)
        return (try? String(data: JSONEncoder().encode(snapshot), encoding: .utf8)) ?? "{}"
    }
    deinit { polling?.cancel(); traceTask?.cancel() }
}
