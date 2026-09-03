import Foundation
import Combine
import AppKit
import CoreAudio
import ServiceManagement

// MARK: - Status

/// What the menu bar icon and the status dot are showing right now.
enum BeaconStatus {
    case disabled
    case idle
    case onCall

    var symbolName: String {
        switch self {
        case .disabled: return "mic.slash"
        case .idle: return "mic"
        case .onCall: return "mic.fill"
        }
    }

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .idle: return "Idle"
        case .onCall: return "On a call"
        }
    }
}

/// Result of the most recent webhook POST, surfaced in the panel so a bad
/// URL is obvious instead of failing silently.
enum WebhookStatus {
    case never
    case sending
    case delivered(Date)
    case failed(String)
}

// MARK: - Monitor (state, Core Audio, webhook, login item)

final class MicMonitor: ObservableObject {
    @Published private(set) var isOnCall: Bool = false
    @Published private(set) var webhookStatus: WebhookStatus = .never

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            if isEnabled {
                // Re-sync Home Assistant with whatever the mic is doing now.
                checkAndReport(force: true)
            } else {
                pendingReport?.cancel()
                pendingReport = nil
                // Don't leave the helper stuck "on" while we're paused.
                if lastSentState == true {
                    sendWebhook(active: false)
                    lastSentState = false
                }
            }
        }
    }

    @Published var webhookURLString: String {
        didSet {
            guard webhookURLString != oldValue else { return }
            UserDefaults.standard.set(webhookURLString, forKey: "webhookURL")
            webhookStatus = .never
            lastSentState = nil
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    var status: BeaconStatus {
        guard isEnabled else { return .disabled }
        return isOnCall ? .onCall : .idle
    }

    private var deviceID: AudioDeviceID = 0
    private var lastSentState: Bool?
    private var pendingReport: DispatchWorkItem?

    /// Core Audio flaps `IsRunningSomewhere` while a device spins up — an app
    /// opening the mic can produce on/off/on inside the same second. Settle the
    /// signal before reporting so Home Assistant sees one clean transition.
    /// Going quiet waits longer, which also rides out switching between two
    /// apps that both want the mic (e.g. Zoom -> Meet) without a false "off".
    private static let onDebounce: TimeInterval = 0.75
    private static let offDebounce: TimeInterval = 3.0

    /// Held so the listener can be removed when the default device changes —
    /// Core Audio matches the block by identity, not by address.
    private var runningListener: AudioObjectPropertyListenerBlock?

    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true
        webhookURLString = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
        launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false

        attachDefaultDeviceChangeListener()
        attachRunningListener()
        checkAndReport(force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: Login item

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("Login item error: \(error)")
            // Snap the toggle back so it reflects reality.
            DispatchQueue.main.async {
                self.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: Core Audio

    private func attachDefaultDeviceChangeListener() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultInputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.attachRunningListener()
            self?.checkAndReport(force: false)
        }
    }

    private func attachRunningListener() {
        let newDeviceID = currentDefaultInputDevice()
        guard newDeviceID != deviceID else { return }

        detachRunningListener()
        deviceID = newDeviceID
        guard deviceID != 0 else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkAndReport(force: false)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &Self.runningAddress,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            runningListener = listener
        }
    }

    private func detachRunningListener() {
        guard deviceID != 0, let listener = runningListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &Self.runningAddress,
            DispatchQueue.main,
            listener
        )
        runningListener = nil
    }

    private func currentDefaultInputDevice() -> AudioDeviceID {
        var newDeviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultInputAddress,
            0,
            nil,
            &size,
            &newDeviceID
        )
        return status == noErr ? newDeviceID : 0
    }

    private func checkAndReport(force: Bool) {
        guard deviceID != 0 else { return }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &Self.runningAddress,
            0,
            nil,
            &size,
            &isRunning
        )
        guard status == noErr else { return }

        let micActive = isRunning != 0
        isOnCall = micActive

        guard isEnabled else { return }
        scheduleReport(active: micActive, force: force)
    }

    /// Coalesces bursts of Core Audio callbacks into a single webhook. Each new
    /// reading cancels the previous pending send, so only the settled state ships.
    private func scheduleReport(active: Bool, force: Bool) {
        pendingReport?.cancel()
        pendingReport = nil

        guard force || active != lastSentState else { return }

        if force {
            lastSentState = active
            sendWebhook(active: active)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReport = nil
            guard self.isEnabled, active != self.lastSentState else { return }
            self.lastSentState = active
            self.sendWebhook(active: active)
        }
        pendingReport = work
        let delay = active ? Self.onDebounce : Self.offDebounce
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Webhook

    private func webhookRequest(active: Bool) -> URLRequest? {
        let trimmed = webhookURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "state": active ? "on" : "off",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sendWebhook(active: Bool) {
        guard let request = webhookRequest(active: active) else {
            webhookStatus = webhookURLString.isEmpty
                ? .never
                : .failed("Not a valid http(s) URL")
            return
        }

        webhookStatus = .sending
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.webhookStatus = .failed(error.localizedDescription)
                    // Let the next state change retry rather than latching a bad send.
                    self.lastSentState = nil
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    self.webhookStatus = .delivered(Date())
                } else {
                    self.webhookStatus = .failed("Home Assistant returned HTTP \(code)")
                    self.lastSentState = nil
                }
            }
        }.resume()
    }

    /// Fired on quit so Home Assistant isn't left believing you're still on a
    /// call. Blocks briefly — the process is going away either way.
    @objc private func applicationWillTerminate() {
        detachRunningListener()
        pendingReport?.cancel()
        pendingReport = nil
        guard isEnabled, lastSentState == true,
              let request = webhookRequest(active: false) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
