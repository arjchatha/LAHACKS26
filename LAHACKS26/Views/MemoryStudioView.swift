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
    @State private var searchText = ""
    @State private var selectedPersonId: String?
    @State private var isWikiExpanded = false
    @State private var editingPerson: DemoPersonMemory?
    @State private var isShowingClearMemoryConfirmation = false

    private var visiblePeople: [DemoPersonMemory] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? memoryBridge.allPeople()
            : memoryBridge.searchPeople(query: searchText)
    }

    private var selectedPerson: DemoPersonMemory? {
        if let selectedPersonId,
           let person = memoryBridge.allPeople().first(where: { $0.id == selectedPersonId }) {
            return person
        }

        return visiblePeople.first
    }

    private var hasStoredMemory: Bool {
        !memoryBridge.allPeople().isEmpty || !memoryBridge.recentInteractions().isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MemoryStudioBackground()

                ScrollView(.vertical, showsIndicators: true) {
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
                        clearMemoryButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 118)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .clipped()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editingPerson) { person in
            MemoryEditSheet(memoryBridge: memoryBridge, person: person)
                .preferredColorScheme(.dark)
        }
        .alert("Clear Memory?", isPresented: $isShowingClearMemoryConfirmation) {
            Button("Clear Memory", role: .destructive) {
                clearMemory()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all stored faces, embeddings, profiles, and memory information on this device.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memories")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)

                Text("Stored conversation memories")
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
                    .frame(width: 38, height: 38)
                    .memoryGlass(in: Circle(), tint: .white.opacity(0.07))
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
            .padding(.vertical, 13)
            .memoryGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: .white.opacity(0.07))

        }
    }

    private var overview: some View {
        HStack(spacing: 0) {
            MetricPill(title: "People", value: "\(memoryBridge.allPeople().count)", symbol: "person.2")
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.vertical, 10)
            MetricPill(title: "Stored", value: "\(memoryBridge.storedPeople().count)", symbol: "checkmark.seal")
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.vertical, 10)
            MetricPill(title: "Evidence", value: "\(memoryBridge.recentInteractions().count)", symbol: "quote.bubble")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), tint: .white.opacity(0.065))
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
                    onEdit: {
                        editingPerson = selectedPerson
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

    private var clearMemoryButton: some View {
        Button(role: .destructive) {
            isShowingClearMemoryConfirmation = true
        } label: {
            Label("Clear Memory", systemImage: "trash")
                .font(.headline.weight(.bold))
                .foregroundStyle(hasStoredMemory ? .red : .white.opacity(0.42))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .memoryGlass(
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                    tint: hasStoredMemory ? .red.opacity(0.10) : .white.opacity(0.035)
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasStoredMemory)
        .accessibilityLabel("Clear Memory")
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

            Text("Conversation memories created from the patient camera will appear here.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 34)
        .memoryGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), tint: .white.opacity(0.06))
    }

    private var listTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Results"
        }

        return "Memories"
    }

    private func clearMemory() {
        memoryBridge.clearMemory()
        searchText = ""
        selectedPersonId = nil
        isWikiExpanded = false
        editingPerson = nil
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                detail()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .memoryGlass(in: Circle(), tint: person.status.accent.opacity(0.32))

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
        }
        .padding(16)
        .memoryGlass(
            in: RoundedRectangle(cornerRadius: 30, style: .continuous),
            tint: isSelected ? .white.opacity(0.14) : .white.opacity(0.055)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(isSelected ? .white.opacity(0.34) : .white.opacity(0.06), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PersonDetailCard: View {
    let person: DemoPersonMemory
    let wikiPage: String?
    @Binding var isWikiExpanded: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.text.rectangle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .memoryGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .white.opacity(0.08))

                VStack(alignment: .leading, spacing: 5) {
                    Text(person.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text(person.relationship)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 10)

                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .frame(minWidth: 112, minHeight: 50)
                        .memoryGlass(in: Capsule(), tint: .white.opacity(0.09))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit memory")
            }

            detailGrid

            DetailSection(title: "Patient Prompt", symbol: "speaker.wave.2") {
                Text(person.patientPrompt)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
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
        .memoryGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous), tint: .white.opacity(0.065))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailGrid: some View {
        VStack(spacing: 10) {
            DetailRow(title: "Helpful Context", value: person.helpfulContext, symbol: "sparkles")
            if let lastEditedAt = person.lastEditedAt {
                DetailRow(
                    title: "Last Edit",
                    value: DateFormatter.memoryStudioTime.string(from: lastEditedAt),
                    symbol: "pencil.and.list.clipboard"
                )
            }
        }
    }
}

private struct MemoryEditSheet: View {
    @ObservedObject var memoryBridge: MockMemoryBridge
    let person: DemoPersonMemory
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var relationship: String
    @State private var helpfulContext: String
    @State private var patientPrompt: String

    init(memoryBridge: MockMemoryBridge, person: DemoPersonMemory) {
        self.memoryBridge = memoryBridge
        self.person = person
        _name = State(initialValue: person.name)
        _relationship = State(initialValue: person.relationship)
        _helpfulContext = State(initialValue: person.helpfulContext)
        _patientPrompt = State(initialValue: person.patientPrompt)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MemoryStudioBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Edit memory")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Update the stored memory shown in Patient Mode.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.68))

                        editField(title: "Name", text: $name, symbol: "person")
                        editField(title: "Relationship", text: $relationship, symbol: "person.2")

                        editEditor(title: "Helpful Context", text: $helpfulContext, symbol: "sparkles", minHeight: 92)
                        editEditor(title: "Patient Prompt", text: $patientPrompt, symbol: "speaker.wave.2", minHeight: 116)

                        DetailSection(title: "Original Evidence", symbol: "quote.bubble") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(person.transcriptEvidence.enumerated()), id: \.offset) { index, evidence in
                                    Text("\(index + 1). \(evidence)")
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.78))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        _ = memoryBridge.updatePersonMemory(
            personId: person.id,
            name: name,
            relationship: relationship,
            helpfulContext: helpfulContext,
            patientPrompt: patientPrompt
        )
        dismiss()
    }

    private func editField(title: String, text: Binding<String>, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))

            TextField(title, text: text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .padding(13)
                .memoryGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: .white.opacity(0.07))
        }
    }

    private func editEditor(title: String, text: Binding<String>, symbol: String, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))

            TextEditor(text: text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(9)
                .memoryGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: .white.opacity(0.07))
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
        .memoryGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: .white.opacity(0.055))
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
        .memoryGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: .white.opacity(0.045))
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
        .memoryGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: .white.opacity(0.055))
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

private struct MemoryStudioBackground: View {
    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    .white.opacity(0.055),
                    .white.opacity(0.018),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.15, green: 0.24, blue: 0.22).opacity(0.24),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
        }
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
                        shape.stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            } else {
                self
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

private extension DemoPersonStatus {
    var accent: Color {
        switch self {
        case .saved:
            .green
        case .removed:
            .red
        }
    }

    var iconName: String {
        switch self {
        case .saved:
            "checkmark.seal.fill"
        case .removed:
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
