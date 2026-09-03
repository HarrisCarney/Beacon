import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var monitor: MicMonitor
    @EnvironmentObject var updater: UpdaterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(monitor.status.label)
                    .font(.headline)
            }

            Divider()

            Toggle("Enabled", isOn: $monitor.isEnabled)
            Toggle("Launch at login", isOn: $monitor.launchAtLogin)

            VStack(alignment: .leading, spacing: 4) {
                Text("Home Assistant Webhook URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://homeassistant.local:8123/api/webhook/...", text: $monitor.webhookURLString)
                    .textFieldStyle(.roundedBorder)
                Text(webhookStatusText)
                    .font(.caption)
                    .foregroundStyle(webhookStatusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Button("Quit Beacon") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusColor: Color {
        switch monitor.status {
        case .disabled: return .gray
        case .idle: return .green
        case .onCall: return .red
        }
    }

    private var webhookStatusText: String {
        switch monitor.webhookStatus {
        case .never:
            return monitor.webhookURLString.isEmpty
                ? "Paste your webhook URL to start reporting."
                : "Not sent yet."
        case .sending:
            return "Sending…"
        case .delivered(let date):
            return "Last delivered \(date.formatted(date: .omitted, time: .standard))"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var webhookStatusColor: Color {
        if case .failed = monitor.webhookStatus { return .red }
        return .secondary
    }
}
