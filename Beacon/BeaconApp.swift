import SwiftUI

@main
struct BeaconApp: App {
    @StateObject private var monitor = MicMonitor()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(updater)
        } label: {
            Image(systemName: monitor.status.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}
