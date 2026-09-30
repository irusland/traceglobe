import Foundation
import Combine
import Network

@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var interfaceName = "Проверка подключения…"
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "TraceGlobe.NetworkStatus")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let name: String
            if !connected { name = "Нет подключения" }
            else if path.usesInterfaceType(.wifi) { name = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { name = "Ethernet" }
            else if path.usesInterfaceType(.cellular) { name = "Мобильная сеть" }
            else { name = "Сетевое подключение" }
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                self?.interfaceName = name
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
