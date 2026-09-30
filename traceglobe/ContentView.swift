import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var network: NetworkStatus
    @ObservedObject var monitor: ConnectionMonitor

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "globe.americas.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TraceGlobe").font(.headline)
                    Text("\(monitor.connections.count) внешних соединений · \(network.interfaceName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { monitor.toggleMonitoring() } label: {
                    Label(monitor.isMonitoring ? "Пауза" : "Продолжить", systemImage: monitor.isMonitoring ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.showingTrace ? "Маршрут с этого Mac" : "Куда подключаются приложения")
                    .font(.subheadline.weight(.semibold))
                Text(monitor.showingTrace
                     ? "Линии соединяют узлы трассировки с известным городом. Неизвестные узлы — в списке ниже."
                     : "Точки — серверы активных соединений. Выберите строку ниже и нажмите «Показать маршрут», чтобы увидеть узлы и линии.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)

            GlobeView(snapshot: monitor.globeJSON, onSelect: monitor.chooseMapPoint)
                .frame(height: 265)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Circle().fill(monitor.isMonitoring && monitor.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                if let error = monitor.error { Text(error).font(.caption).foregroundStyle(.orange) }
                else if !monitor.isMonitoring { Text("Обновление приостановлено").font(.caption).foregroundStyle(.secondary) }
                else if let date = monitor.lastUpdated { Text("Обновлено \(date.formatted(date: .omitted, time: .standard)) · каждые 4 с").font(.caption).foregroundStyle(.secondary) }
                else { Text("Получение соединений…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }

            if monitor.showingTrace {
                HStack {
                    Button { monitor.showConnections() } label: { Label("Соединения", systemImage: "chevron.left") }
                    Text(monitor.traceTarget).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Spacer()
                    if monitor.tracing { ProgressView().controlSize(.small) }
                }
                Text(monitor.traceStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.traceHops) { hop in
                            HStack {
                                Text(String(format: "%02d", hop.id)).monospacedDigit().foregroundStyle(.green).frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hop.ip ?? "Нет ответа").font(.system(.caption, design: .monospaced))
                                    Text(hop.location?.label ?? (hop.ip == nil ? "Узел не ответил" : "Местоположение не определено")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(hop.milliseconds.map { String(format: "%.1f ms", $0) } ?? "—").font(.system(.caption, design: .monospaced))
                            }.padding(.vertical, 7)
                            Divider()
                        }
                    }
                }.frame(height: 140)
            } else {
                HStack {
                    TextField("Приложение, IP или город", text: $monitor.search).textFieldStyle(.roundedBorder)
                    Button("Показать маршрут") { monitor.runTrace() }.disabled(monitor.selected == nil || monitor.tracing)
                }
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(monitor.filtered) { connection in
                            Button { monitor.choose(connection) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(connection.process).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(connection.destination).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(connection.location?.label ?? "Город неизвестен").font(.caption).lineLimit(1)
                                        Text("\(connection.transport) · ↓ \(ByteCountFormatter.string(fromByteCount: Int64(clamping: connection.bytesIn), countStyle: .binary))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(8).contentShape(Rectangle())
                                    .background(monitor.selectedID == connection.id ? Color.green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        if monitor.filtered.isEmpty {
                            Text(monitor.lastUpdated == nil ? "Ожидание данных macOS…" : "Подходящих внешних соединений нет")
                                .font(.caption).foregroundStyle(.secondary).padding(22)
                        }
                    }
                }.frame(height: 174)
            }
            Divider()
            HStack {
                Link("Геолокация: DB-IP Lite", destination: URL(string: "https://db-ip.com")!)
                Text("· приблизительно").foregroundStyle(.secondary)
                Spacer()
                Button("Завершить") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").buttonStyle(.borderless)
            }.font(.caption2)
        }.padding(16).frame(width: 640).preferredColorScheme(.dark)
    }
}
