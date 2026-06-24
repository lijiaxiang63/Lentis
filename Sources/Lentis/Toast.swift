// Toast.swift
// Lentis
//
// A lightweight, auto-dismissing success/info banner in the Liquid-Glass idiom —
// the macOS "it worked" HUD pattern (think AirDrop-received / Xcode banners).
// Used for direct (no-dialog) segmentation exports so a save confirms itself
// without interrupting the user with a modal.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// One transient banner. Equatable/Identifiable so the host can animate
/// appearance and so a re-fired toast replaces the previous one cleanly.
struct ViewerToast: Identifiable, Equatable {
    let id = UUID()
    var icon: String = "checkmark.circle.fill"
    var tint: Color = .green
    var title: String
    var subtitle: String? = nil
    /// When set, the banner offers a "Show in Finder" action revealing this file.
    var fileURL: URL? = nil
}

/// The floating glass banner. Content-sized; host pins it (top-center) and
/// animates it in/out.
struct ToastBanner: View {
    let toast: ViewerToast
    var onReveal: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: toast.icon)
                .font(.title3)
                .foregroundStyle(toast.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle = toast.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if toast.fileURL != nil, let onReveal {
                Divider().frame(height: 26)
                Button("Show in Finder", action: onReveal)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s + 2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toast.title). \(toast.subtitle ?? "")")
    }
}
