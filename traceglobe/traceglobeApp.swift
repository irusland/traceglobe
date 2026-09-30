import SwiftUI

@main
struct traceglobeApp: App {
    @StateObject private var network = NetworkStatus()
    @StateObject private var monitor = ConnectionMonitor()
    var body: some Scene {
        MenuBarExtra("TraceGlobe", systemImage: "globe.americas.fill") {
            ContentView(network: network, monitor: monitor)
        }.menuBarExtraStyle(.window)
    }
}
