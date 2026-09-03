import Foundation
import Combine
import Sparkle

/// Thin wrapper so SwiftUI can drive Sparkle's updater and keep the
/// "Check for Updates…" button correctly enabled/disabled.
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init() {
        // startingUpdater: true means it also checks automatically in the
        // background on the interval set by SUScheduledCheckInterval in Info.plist.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
