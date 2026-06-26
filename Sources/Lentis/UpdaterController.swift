// UpdaterController.swift
// Lentis
//
// Sparkle 2.x wrapper for automatic updates. Owns the standard updater
// controller (download / EdDSA-verify / install / relaunch of GitHub Release
// DMGs) and exposes the manual "Check for Updates…" action.
// Licensed under the MIT License. See LICENSE for details.

import Sparkle
import SwiftUI

/// Thin `ObservableObject` owning the Sparkle standard updater so it can be
/// held for the app lifetime via `@StateObject` (created lazily on first body
/// evaluation — by then `NSApplication` is ready, which is the safe point to
/// start the updater). `SPUStandardUpdaterController(startingUpdater:true,…)`
/// schedules the automatic launch + 24 h checks and shows the native update
/// window; `SUFeedURL` / `SUPublicEDKey` in `Info.plist` drive the feed + EdDSA
/// verification (see `scripts/package_app.sh`).
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Manual check — wired to the "Check for Updates…" app-menu item.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
