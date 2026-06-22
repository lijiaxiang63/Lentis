// Theme.swift
// Lentis
//
// Centralized design system for the Liquid Glass redesign (macOS 26): the
// signature accent + semantic colors, spacing/radius/typography tokens, and
// reusable Liquid Glass surfaces/controls. Chrome should source its visual
// values HERE rather than hardcoding them inline.
//
// The image VIEWPORT stays pure black regardless of these tokens — this file
// only styles the surrounding chrome. Deployment target is macOS 26, so the
// native glass APIs are unconditionally available (no #available guards).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

// MARK: - Color tokens

extension Color {
    /// Signature Lentis accent — a vivid indigo (≈ #6C6AF2). Drives active
    /// controls, selection, focus, and the active-panel border. Single source
    /// of truth: retune here to rebrand the whole app.
    static let lentisAccent = Color(red: 0.424, green: 0.416, blue: 0.949)

    /// CT modality — warm amber.
    static let lentisCT  = Color(red: 0.95, green: 0.62, blue: 0.18)
    /// MRI modality — cool teal.
    static let lentisMRI = Color(red: 0.16, green: 0.70, blue: 0.78)

    /// Crosshair lines/dot — luminous green-cyan.
    static let lentisCrosshair = Color(red: 0.30, green: 1.0, blue: 0.55)
    /// Synchronized-scroll active indicator.
    static let lentisLink = Color(red: 1.0, green: 0.79, blue: 0.24)
    /// Group-selection border/overlay.
    static let lentisGroup = Color.orange

    /// The chrome backdrop behind/between the panels — near-black, cohesive with
    /// the pure-black panel interiors but distinct enough to read panel edges.
    static let lentisViewport = Color(red: 0.04, green: 0.04, blue: 0.05)

    // Annotation semantics (pulled out of the inline overlay code).
    static let lentisRuler = Color(red: 0.25, green: 0.85, blue: 1.0)   // cyan
    static let lentisAngle = Color(red: 0.30, green: 0.90, blue: 0.45)  // green
    static let lentisROI   = Color(red: 1.0,  green: 0.62, blue: 0.20)  // orange
}

// MARK: - Layout tokens

enum Spacing {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let chip:  CGFloat = 8
    static let panel: CGFloat = 12
    static let card:  CGFloat = 16
}

// MARK: - Typography

extension Font {
    /// Monospaced numeric readouts (status pill, W/L, voxel coordinates).
    static let lentisReadout = Font.system(.caption, design: .monospaced)
    /// Compact rounded labels for chips (modality, 4D timepoint).
    static let lentisChip = Font.system(size: 11, weight: .semibold, design: .rounded)
}

// MARK: - Glass surfaces

extension View {
    /// Standard floating glass chrome surface (tool capsule, status pill,
    /// loading card). Apply AFTER layout/appearance modifiers.
    func glassChrome<S: Shape>(in shape: S = Capsule()) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// Compact glass "chip" styling for tinted indicators (modality, 4D).
    func lentisChip(tint: Color) -> some View {
        font(.lentisChip)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .glassEffect(.regular.tint(tint.opacity(0.85)).interactive(), in: Capsule())
    }
}

// MARK: - Reusable controls

/// A circular icon button on a Liquid Glass surface that tints with the accent
/// (or a custom color) when active. Used by the floating tool capsule and the
/// global view toggles. Place inside a `GlassEffectContainer` so neighbouring
/// buttons blend/merge.
struct GlassIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var activeTint: Color = .lentisAccent
    var size: CGFloat = 34
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive ? .regular.tint(activeTint).interactive() : .regular.interactive(),
            in: Circle()
        )
        .help(help)
    }
}
