//
//  MemoryStudioView.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import SwiftUI

struct MemoryStudioView: View {
    @ObservedObject var memoryBridge: MockMemoryBridge
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var filter: MemoryStudioFilter = .drafts
    @State private var searchText = ""
    @State private var selectedPersonId: String?
    @State private var isWikiExpanded = false

    private var visiblePeople: [DemoPersonMemory] {
        let base = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? memoryBridge.allPeople()
            : memoryBridge.searchPeople(query: searchText)

        switch filter {
        case .drafts:
            return base.filter { $0.status == .draft || $0.needsCaregiverReview }
        case .approved:
            return base.filter { $0.status == .approved }
        case .all:
            return base
        }
    }

    private var selectedPerson: DemoPersonMemory? {
        if let selectedPersonId,
           let person = memoryBridge.allPeople().first(where: { $0.id == selectedPersonId }) {
            return person
        }

        return visiblePeople.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MemoryStudioBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        controls
                        overview

                        if visiblePeople.isEmpty {
                            emptyState
                        } else {
                            MemoryStudioAdaptiveLayout {
                                peopleList
                            } detail: {
                                personDetail
                            }
                        }

                        recentInteractions
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                bottomCameraBar
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory Studio")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)

                Text("Caregiver review for conversation memories")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .memoryGlass(in: Circle(), tint: .white.opacity(0.08))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Memory Studio")
        }
        .padding(.top, 2)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))

                TextField("Search memories", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .memoryGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .white.opacity(0.06))

            Picker("Memory filter", selection: $filter) {
                ForEach(MemoryStudioFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var overview: some View {
        HStack(spacing: 0) {
            MetricPill(title: "Review", value: "\(memoryBridge.pendingDraftPeople().count)", symbol: "person.badge.clock")
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.vertical, 10)
            MetricPill(title: "Approved", value: "\(memoryBridge.approvedPeople().count)", symbol: "checkmark.seal")
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.vertical, 10)
            MetricPill(title: "Evidence", value: "\(memoryBridge.recentInteractions().count)", symbol: "quote.bubble")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: .white.opacity(0.05))
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(listTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            ForEach(visiblePeople) { person in
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        selectedPersonId = person.id
                        isWikiExpanded = false
                    }
                } label: {
                    PersonMemoryCard(
                        person: person,
                        isSelected: selectedPerson?.id == person.id
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var personDetail: some View {
        Group {
            if let selectedPerson {
                PersonDetailCard(
                    person: selectedPerson,
                    wikiPage: memoryBridge.wikiPage(for: selectedPerson.id),
                    isWikiExpanded: $isWikiExpanded,
                    onApprove: {
                        withAnimation(.smooth(duration: 0.2)) {
                            memoryBridge.approvePersonEnrollment(
                                personId: selectedPerson.id,
                                caregiverName: "Caregiver"
                            )
                            filter = .approved
                        }
                    },
                    onReject: {
                        withAnimation(.smooth(duration: 0.2)) {
                            memoryBridge.rejectPersonEnrollment(
                                personId: selectedPerson.id,
                                caregiverName: "Caregiver"
                            )
                            filter = .all
                        }
                    }
                )
            }
        }
    }

    private var recentInteractions: some View {
        let interactions = memoryBridge.recentInteractions()

        return Group {
            if !interactions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Evidence")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)

                    ForEach(interactions.prefix(4)) { interaction in
                        RecentInteractionCard(interaction: interaction)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.08), in: Circle())

            Text("No memories yet")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            Text("Conversation memories created from the patient camera will appear here for caregiver review.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 34)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: .white.opacity(0.055))
    }

    private var bottomCameraBar: some View {
        HStack {
            Button {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            } label: {
                Label("Patient Camera", systemImage: "camera.viewfinder")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var listTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Results"
        }

        return filter.title
    }
}

private enum MemoryStudioFilter: String, CaseIterable, Identifiable {
    case drafts
    case approved
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drafts:
            "Drafts"
        case .approved:
            "Approved"
        case .all:
            "All"
        }
    }
}

private struct MemoryStudioAdaptiveLayout<ListContent: View, DetailContent: View>: View {
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                list()
                    .frame(width: 340)

                detail()
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 16) {
                list()
                detail()
            }
        }
    }
}

private struct PersonMemoryCard: View {
    let person: DemoPersonMemory
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: person.status.iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(person.status.accent)
                    .frame(width: 30, height: 30)
                    .background(person.status.accent.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(person.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        StatusPill(status: person.status)
                    }

                    Text(person.relationship)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer()
            }

            Text(person.helpfulContext)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(2)

            if person.needsCaregiverReview {
                Label("Needs review", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow.opacity(0.92))
            }
        }
        .padding(15)
        .memoryGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: isSelected ? .white.opacity(0.14) : .white.opacity(0.06)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isSelected ? .white.opacity(0.34) : .clear, lineWidth: 1)
        }
    }
}

private struct PersonDetailCard: View {
    let person: DemoPersonMemory
    let wikiPage: String?
    @Binding var isWikiExpanded: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.text.rectangle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(person.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text(person.relationship)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()
                StatusPill(status: person.status)
            }

            detailGrid

            DetailSection(title: "Patient Prompt", symbol: "speaker.wave.2") {
                Text(person.caregiverApproved ? person.patientPrompt : "Hidden from patient until caregiver approval.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailSection(title: "Transcript Evidence", symbol: "quote.bubble") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(person.transcriptEvidence.enumerated()), id: \.offset) { index, transcript in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Transcript \(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.54))

                            Text(transcript)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if person.status == .draft || person.needsCaregiverReview {
                HStack(spacing: 10) {
                    Button(action: onApprove) {
                        Label("Approve", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MemoryStudioActionButtonStyle(tint: .green))

                    Button(action: onReject) {
                        Label("Reject", systemImage: "xmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MemoryStudioActionButtonStyle(tint: .red))
                }
            }

            if let wikiPage {
                DisclosureGroup(isExpanded: $isWikiExpanded) {
                    Text(wikiPage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 8)
                        .textSelection(.enabled)
                } label: {
                    Label("Wiki Page Preview", systemImage: "doc.text")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                }
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(18)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: .white.opacity(0.07))
    }

    private var detailGrid: some View {
        VStack(spacing: 10) {
            DetailRow(title: "Helpful Context", value: person.helpfulContext, symbol: "sparkles")
            DetailRow(title: "Approval", value: person.caregiverApproved ? "Caregiver approved" : "Waiting for caregiver", symbol: "checkmark.shield")
            DetailRow(title: "Recognition", value: person.recognitionStatus.rawValue, symbol: "faceid")
            DetailRow(title: "Face Profile", value: person.faceProfileId ?? "None", symbol: "camera.viewfinder")
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.52))

                Text(value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RecentInteractionCard: View {
    let interaction: InteractionMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(interaction.memoryType.capitalized, systemImage: "clock.badge")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Text(DateFormatter.memoryStudioTime.string(from: interaction.createdAt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Text(interaction.summary)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)

            Text(interaction.evidenceQuote)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(3)
        }
        .padding(15)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: .white.opacity(0.05))
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.66))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

private struct StatusPill: View {
    let status: DemoPersonStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.accent.opacity(0.15), in: Capsule())
    }
}

private struct MemoryStudioActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(tint.opacity(configuration.isPressed ? 0.5 : 0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct MemoryStudioBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.08),
                Color(red: 0.08, green: 0.10, blue: 0.13),
                Color(red: 0.02, green: 0.02, blue: 0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private extension View {
    func memoryGlass<S: InsettableShape>(in shape: S, tint: Color) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                self
                    .glassEffect(.regular.tint(tint), in: shape)
                    .overlay {
                        shape.stroke(.white.opacity(0.16), lineWidth: 1)
                    }
            } else {
                self
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(.white.opacity(0.14), lineWidth: 1)
                    }
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}

private extension DemoPersonStatus {
    var accent: Color {
        switch self {
        case .draft:
            .yellow
        case .approved:
            .green
        case .rejected:
            .red
        }
    }

    var iconName: String {
        switch self {
        case .draft:
            "person.badge.clock"
        case .approved:
            "checkmark.seal.fill"
        case .rejected:
            "xmark.seal.fill"
        }
    }
}

private extension DateFormatter {
    static let memoryStudioTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
