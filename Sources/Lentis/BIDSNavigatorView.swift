// BIDSNavigatorView.swift
// Lentis
//
// The sidebar dataset navigator shown when a folder (BIDS dataset or a loose
// folder of NIfTI files) is open. A native macOS source-list outline:
//   Subject (disclosure) → [Session (disclosure)] → image rows
// with a filter field, datatype-aware icons, and an accent highlight on the
// currently-loaded image. Tapping a row loads it (keeping the navigator open).
//
// For a non-BIDS "loose" folder the files are listed flat. Selecting an image
// routes through ViewerModel.selectDatasetFile (preserves the dataset).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct BIDSNavigatorView: View {
    @ObservedObject var model: ViewerModel
    let dataset: BIDSDataset
    @State private var query: String = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            BIDSSearchField(text: $query)
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)

            List {
                if searching {
                    searchResults
                } else if dataset.isBIDS {
                    ForEach(Array(dataset.subjects.enumerated()), id: \.element.id) { index, subject in
                        SubjectDisclosure(
                            model: model, subject: subject,
                            initiallyExpanded: index == 0 || containsLoaded(subject))
                    }
                } else {
                    Section("NIfTI files") {
                        ForEach(dataset.looseFiles) { BIDSFileRow(model: model, file: $0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay { if isEmpty { emptyState } }
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        if dataset.isBIDS {
            ForEach(filteredSubjects) { subject in
                Section(subject.label) {
                    ForEach(subject.sessions.flatMap(\.files)) { BIDSFileRow(model: model, file: $0) }
                }
            }
        } else {
            Section("NIfTI files") {
                ForEach(dataset.looseFiles.filter(matches)) { BIDSFileRow(model: model, file: $0) }
            }
        }
    }

    private func matches(_ file: BIDSImageFile) -> Bool {
        guard searching else { return true }
        let q = query.lowercased()
        return file.fileName.lowercased().contains(q)
            || (file.subjectLabel ?? "").lowercased().contains(q)
            || (file.sessionLabel ?? "").lowercased().contains(q)
            || (file.datatype ?? "").lowercased().contains(q)
    }

    /// Subjects reduced to their matching files (sessions/subjects with no match
    /// drop out), for the flat search view.
    private var filteredSubjects: [BIDSSubject] {
        dataset.subjects.compactMap { subj in
            let sessions = subj.sessions.compactMap { ses -> BIDSSession? in
                let files = ses.files.filter(matches)
                return files.isEmpty ? nil : BIDSSession(label: ses.label, files: files)
            }
            return sessions.isEmpty ? nil : BIDSSubject(label: subj.label, sessions: sessions)
        }
    }

    private var isEmpty: Bool {
        if searching {
            return dataset.isBIDS ? filteredSubjects.isEmpty : !dataset.looseFiles.contains(where: matches)
        }
        return dataset.imageCount == 0
    }

    @ViewBuilder
    private var emptyState: some View {
        if searching {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView("No images", systemImage: "brain",
                                   description: Text("This folder has no NIfTI images."))
        }
    }

    private func containsLoaded(_ subject: BIDSSubject) -> Bool {
        guard let loaded = model.loadedFileURL else { return false }
        return subject.sessions.contains { $0.files.contains { $0.url == loaded } }
    }
}

// MARK: - Search field

/// A compact, native-feeling search field for the sidebar (a rounded capsule
/// with a leading glyph + inline clear button).
private struct BIDSSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter subjects & images", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Subject / Session disclosures

private struct SubjectDisclosure: View {
    @ObservedObject var model: ViewerModel
    let subject: BIDSSubject
    @State var expanded: Bool

    init(model: ViewerModel, subject: BIDSSubject, initiallyExpanded: Bool) {
        self.model = model
        self.subject = subject
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if subject.showsSessions {
                ForEach(subject.sessions) { session in
                    SessionDisclosure(model: model, session: session)
                }
            } else {
                ForEach(subject.sessions.first?.files ?? []) { BIDSFileRow(model: model, file: $0) }
            }
        } label: {
            BIDSOutlineLabel(icon: "person.fill", title: subject.label,
                             count: subject.imageCount, tint: .lentisAccent)
        }
    }
}

private struct SessionDisclosure: View {
    @ObservedObject var model: ViewerModel
    let session: BIDSSession
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.files) { BIDSFileRow(model: model, file: $0) }
        } label: {
            BIDSOutlineLabel(icon: "calendar", title: session.label ?? "session",
                             count: session.files.count, tint: .secondary)
        }
    }
}

/// A subject/session disclosure label: icon + title + a trailing count pill.
private struct BIDSOutlineLabel: View {
    let icon: String
    let title: String
    let count: Int
    var tint: Color

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Spacing.xs)
            Text("\(count)")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }
}

// MARK: - File row

private struct BIDSFileRow: View {
    @ObservedObject var model: ViewerModel
    let file: BIDSImageFile

    private var isLoaded: Bool { model.loadedFileURL == file.url }

    var body: some View {
        Button {
            // Re-tapping the loaded row is a no-op (selectDatasetFile also guards)
            // — reloading would wipe in-progress segmentation + layers.
            guard !isLoaded else { return }
            model.selectDatasetFile(file)
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: BIDSFileRow.icon(for: file))
                    .foregroundStyle(isLoaded ? Color.lentisAccent : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.displayTitle)
                        .font(.callout)
                        .fontWeight(isLoaded ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if isLoaded {
                    Image(systemName: "eye.fill")
                        .font(.caption2).foregroundStyle(Color.lentisAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isLoaded ? Color.lentisAccent.opacity(0.16) : Color.clear)
        .help(file.fileName)
    }

    /// Datatype/suffix-aware metadata line (datatype · acq-… · run-… · size).
    private var subtitle: String {
        var parts: [String] = []
        if let dt = file.datatype { parts.append(dt) }
        parts.append(contentsOf: file.detailChips)
        if file.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// Pick an SF Symbol for the image by suffix, then datatype.
    static func icon(for file: BIDSImageFile) -> String {
        let s = file.entities.suffix.lowercased()
        if s == "ct" || s.hasSuffix("ct") { return "rays" }
        if s.hasPrefix("t1") || s.hasPrefix("t2") || s.contains("flair")
            || s.contains("mprage") || s.hasPrefix("pd") || s.contains("angio") {
            return "brain.head.profile"
        }
        switch (file.datatype ?? "").lowercased() {
        case "anat": return "brain.head.profile"
        case "func": return "waveform.path"
        case "dwi":  return "arrow.triangle.branch"
        case "ct":   return "rays"
        case "fmap": return "dot.radiowaves.left.and.right"
        case "pet":  return "circle.dotted"
        default:     return "doc"
        }
    }
}
