import HideMyEmailCore
import SwiftUI
import UniformTypeIdentifiers

enum AddressFilter: Hashable {
    case all
    case active
    case inactive
    case site(String)
}

struct ManagerView: View {
    let model: AppModel
    @State private var filter: AddressFilter? = .all
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\HMEAddress.createTimestamp, order: .reverse)]
    @State private var showsInspector = true
    @State private var pendingDeletion: Set<String>?
    @State private var exportFormat: ExportFormat?
    @State private var showsNewAddress = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            table
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 290)
                }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar { toolbar }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingDeletion {
                    Task { await model.delete(ids) }
                    selection.subtract(ids)
                }
            }
        } message: {
            Text("Mail sent to deleted addresses will no longer reach you.")
        }
        .fileExporter(isPresented: Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } }),
                      document: ExportDocument(addresses: exportedAddresses, format: exportFormat ?? .csv),
                      contentType: exportFormat?.contentType ?? .commaSeparatedText,
                      defaultFilename: "Hide My Email") { _ in }
        .task { await model.refresh() }
        .onChange(of: filter) { selection = [] }
        .overlay {
            if model.state == .signedOut {
                ContentUnavailableView("Signed Out", systemImage: "envelope.badge.shield.half.filled")
            }
        }
    }

    // MARK: Sidebar

    private var topSites: [(String, Int)] {
        let counts = Dictionary(grouping: model.addresses.compactMap { Sites.site($0.label) }, by: { $0 })
            .mapValues(\.count)
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(15).map { ($0.key, $0.value) }
    }

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                Label("All Addresses", systemImage: "tray.full")
                    .badge(model.addresses.count)
                    .tag(AddressFilter.all)
                Label(String(localized: "sidebar.active", defaultValue: "Active"), systemImage: "checkmark.circle")
                    .badge(model.addresses.filter(\.isActive).count)
                    .tag(AddressFilter.active)
                Label(String(localized: "sidebar.inactive", defaultValue: "Inactive"), systemImage: "pause.circle")
                    .badge(model.addresses.filter { !$0.isActive }.count)
                    .tag(AddressFilter.inactive)
            }
            if !topSites.isEmpty {
                Section("Sites") {
                    ForEach(topSites, id: \.0) { site, count in
                        Label {
                            Text(site)
                        } icon: {
                            SiteTile(site: site, size: 18)
                        }
                        .badge(count)
                            .tag(AddressFilter.site(site))
                    }
                }
            }
        }
    }

    // MARK: Table

    private var filteredAddresses: [HMEAddress] {
        var result: [HMEAddress]
        switch filter ?? .all {
        case .all: result = model.addresses
        case .active: result = model.addresses.filter(\.isActive)
        case .inactive: result = model.addresses.filter { !$0.isActive }
        case .site(let site): result = Sites.addresses(model.addresses, for: site)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result = result.filter {
                $0.label.localizedCaseInsensitiveContains(trimmed) || $0.hme.localizedCaseInsensitiveContains(trimmed)
                    || $0.note.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return result.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(filteredAddresses, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Label", value: \.label) { address in
                HStack(spacing: 8) {
                    SiteTile(address: address, size: 20)
                    Text(address.label).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Address", value: \.hme) { address in
                Text(address.hme)
                    .foregroundStyle(address.isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Created", value: \.createTimestamp) { address in
                Text(address.createdAt, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 84, ideal: 96)
            TableColumn("Status", value: \.isActive, comparator: BoolComparator()) { address in
                if !address.isActive {
                    Text("Inactive").foregroundStyle(.red)
                }
            }
            .width(min: 56, ideal: 64)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let first = ids.first, let address = model.addresses.first(where: { $0.id == first }) {
                Filler.copy(address.hme)
            }
        }
        .onDeleteCommand {
            requestDeletion(selection)
        }
        .overlay {
            if model.state == .signedIn, filteredAddresses.isEmpty, !model.isRefreshing {
                if query.isEmpty {
                    ContentUnavailableView("No Addresses", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let items = model.addresses.filter { ids.contains($0.id) }
        Button(items.count > 1 ? "Copy Addresses" : "Copy Address") {
            Filler.copy(items.map(\.hme).joined(separator: "\n"))
        }
        Divider()
        if items.contains(where: \.isActive) {
            Button("Deactivate") { Task { await model.setActive(false, for: Set(items.filter(\.isActive).map(\.id))) } }
        }
        if items.contains(where: { !$0.isActive }) {
            Button("Reactivate") { Task { await model.setActive(true, for: Set(items.filter { !$0.isActive }.map(\.id))) } }
            Divider()
            Button("Delete…", role: .destructive) { requestDeletion(ids) }
        }
    }

    private func requestDeletion(_ ids: Set<String>) {
        // iCloud only deletes addresses that are already deactivated.
        let inactive = Set(model.addresses.filter { ids.contains($0.id) && !$0.isActive }.map(\.id))
        if !inactive.isEmpty { pendingDeletion = inactive }
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.count ?? 0
        return count == 1 ? String(localized: "Delete this address?") : String(localized: "Delete \(count) addresses?")
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        let selected = model.addresses.filter { selection.contains($0.id) }
        if selected.count == 1, let address = selected.first {
            AddressInspector(model: model, address: address) { requestDeletion([address.id]) }
                .id(address.id)
        } else if selected.count > 1 {
            ContentUnavailableView("\(selected.count) Addresses", systemImage: "square.stack")
        } else {
            ContentUnavailableView("No Selection", systemImage: "envelope")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsNewAddress = true
            } label: {
                Label("New Address", systemImage: "plus")
            }
            .popover(isPresented: $showsNewAddress, arrowEdge: .bottom) {
                NewAddressPopover(model: model) { address in
                    selection = [address.id]
                    showsNewAddress = false
                }
            }
            Menu {
                Button("Export as CSV…") { exportFormat = .csv }
                Button("Export as JSON…") { exportFormat = .json }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.addresses.isEmpty)
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }

    private var exportedAddresses: [HMEAddress] {
        selection.count > 1 ? model.addresses.filter { selection.contains($0.id) } : filteredAddresses
    }
}

private struct BoolComparator: SortComparator {
    var order: SortOrder = .forward

    func compare(_ lhs: Bool, _ rhs: Bool) -> ComparisonResult {
        guard lhs != rhs else { return .orderedSame }
        let result: ComparisonResult = lhs ? .orderedAscending : .orderedDescending
        return order == .forward ? result : (result == .orderedAscending ? .orderedDescending : .orderedAscending)
    }
}

private struct AddressInspector: View {
    let model: AppModel
    let address: HMEAddress
    let onDelete: () -> Void
    @State private var label = ""
    @State private var note = ""
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SiteTile(address: address, size: 56)
                    VStack(spacing: 3) {
                        Text(address.label)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(address.hme)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        Filler.copy(address.hme)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Forward To", value: address.forwardToEmail)
                LabeledContent("Status") {
                    Text(address.isActive ? "Active" : "Inactive")
                        .foregroundStyle(address.isActive ? .green : .red)
                }
            }
            Section {
                TextField("Label", text: $label)
                    .onSubmit(save)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(save)
                LabeledContent("Created") {
                    Text(address.createdAt, format: .dateTime.day().month().year().hour().minute())
                }
            }
            Section {
                Toggle("Active", isOn: Binding(get: { address.isActive }, set: { active in
                    Task { await model.setActive(active, for: [address.id]) }
                }))
                Button("Delete Address…", role: .destructive, action: onDelete)
                    .disabled(address.isActive)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            label = address.label
            note = address.note
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let newLabel = label.trimmingCharacters(in: .whitespaces)
        let newNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty, newLabel != address.label || newNote != address.note else { return }
        Task { await model.update(address, label: newLabel, note: newNote) }
    }
}

private struct NewAddressPopover: View {
    let model: AppModel
    let onCreated: (HMEAddress) -> Void
    @State private var hme: String?
    @State private var label = ""
    @State private var note = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(hme ?? " ")
                    .font(.system(size: 15, weight: .semibold))
                    .redacted(reason: hme == nil ? .placeholder : [])
                    .textSelection(.enabled)
                Spacer()
                Button {
                    Task { await generate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(isWorking)
            }
            TextField("Label", text: $label)
            TextField("Note", text: $note)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Button {
                Task { await reserve() }
            } label: {
                Text("Create Address").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(hme == nil || isWorking || label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 320)
        .task { await generate() }
    }

    private func generate() async {
        isWorking = true
        defer { isWorking = false }
        do { hme = try await model.generate() } catch { self.error = error.localizedDescription }
    }

    private func reserve() async {
        guard let hme else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            onCreated(try await model.reserve(hme, label: label.trimmingCharacters(in: .whitespaces),
                                              note: note.trimmingCharacters(in: .whitespaces)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ExportFormat {
    case csv
    case json

    var contentType: UTType { self == .csv ? .commaSeparatedText : .json }
}

struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]
    let addresses: [HMEAddress]
    let format: ExportFormat

    init(addresses: [HMEAddress], format: ExportFormat) {
        self.addresses = addresses
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = format == .csv ? Data(Export.csv(addresses).utf8) : try Export.json(addresses)
        return FileWrapper(regularFileWithContents: data)
    }
}
