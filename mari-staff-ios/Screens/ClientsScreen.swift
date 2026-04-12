import Charts
import Combine
import PhotosUI
import SwiftUI

private enum ClientSegment: String, CaseIterable, Identifiable {
    case all
    case new
    case repeatClient
    case lost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .new: "Новые"
        case .repeatClient: "Повторные"
        case .lost: "Потерянные"
        }
    }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all
    case visited
    case withoutVisits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .visited: "С визитами"
        case .withoutVisits: "Без визитов"
        }
    }
}

private enum SortMode: String, CaseIterable, Identifiable {
    case recent
    case visits
    case revenue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "По последнему визиту"
        case .visits: "По числу визитов"
        case .revenue: "По выручке"
        }
    }
}

private enum ClientModalTab: String, CaseIterable, Identifiable {
    case card
    case history
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: "Карточка"
        case .history: "История"
        case .stats: "Статистика"
        }
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case upcoming
    case confirmed
    case arrived
    case noShow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .upcoming: "Ожидание"
        case .confirmed: "Подтвержденные"
        case .arrived: "Завершенные"
        case .noShow: "Неявки"
        }
    }
}

private struct ClientDraft {
    var name = ""
    var phone = ""
    var email = ""
    var comment = ""
    var permanentDiscountPercent = ""
}

private struct DistributionItem: Identifiable, Hashable {
    let label: String
    let value: Double

    var id: String { label }
}

private struct RevenuePoint: Identifiable, Hashable {
    let month: Date
    let label: String
    let value: Double

    var id: String { label }
}

private struct ClientsCachePayload: Codable {
    let clients: [MariAPIClient.ClientRecord]
    let appointments: [MariAPIClient.AppointmentRecord]
}

private struct ClientAnalyticsSummary: Identifiable {
    let client: MariAPIClient.ClientRecord
    let appointments: [MariAPIClient.AppointmentRecord]
    let totalVisits: Int
    let totalRevenue: Double
    let totalPaid: Double
    let averageDiscount: Double
    let averageCheck: Double
    let firstVisit: Date?
    let lastVisit: Date?
    let noShows: Int
    let confirmed: Int
    let upcoming: Int
    let topServices: [DistributionItem]
    let topStaff: [DistributionItem]
    let statusBreakdown: [DistributionItem]

    var id: String { client.id }
}

@MainActor
private final class ClientsStore: ObservableObject {
    @Published private(set) var clients: [MariAPIClient.ClientRecord] = []
    @Published private(set) var appointments: [MariAPIClient.AppointmentRecord] = []
    @Published private(set) var summaries: [ClientAnalyticsSummary] = []
    @Published private(set) var filteredSummaries: [ClientAnalyticsSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var detailLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isDeleting = false
    @Published private(set) var avatarBusy = false
    @Published var errorMessage = ""
    @Published var query = ""
    @Published var segment: ClientSegment = .all
    @Published var activityFilter: ActivityFilter = .all
    @Published var sortMode: SortMode = .recent
    @Published var selectedClientID: String?
    @Published var selectedTab: ClientModalTab = .card
    @Published var historyFilter: HistoryFilter = .all
    @Published var statsFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @Published var statsTo = Date()
    @Published var draft = ClientDraft()
    @Published var isEditing = false

    private let apiClient: MariAPIClient
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var session: StaffSession?
    private var hasLoaded = false
    private var cancellables: Set<AnyCancellable> = []

    init(apiClient: MariAPIClient, session: StaffSession?) {
        self.apiClient = apiClient
        self.session = session
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        setupDerivedState()
    }

    func updateSession(_ session: StaffSession?) {
        if self.session?.staff.id != session?.staff.id {
            hasLoaded = false
        }
        self.session = session
    }

    var canEdit: Bool {
        mariHasPermissionAccess(session, permissionCode: "EDIT_CLIENTS")
    }

    var canManageDiscounts: Bool {
        isOwner || permissions.contains("MANAGE_CLIENT_DISCOUNTS")
    }

    var canManageAvatars: Bool {
        isOwner ||
            mariHasPermissionAccess(session, permissionCode: "EDIT_CLIENTS") ||
            mariHasPermissionAccess(session, permissionCode: "MANAGE_CLIENT_AVATARS")
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadCache()
        await syncWithAPI(showLoading: clients.isEmpty && appointments.isEmpty)
    }

    func reload() async {
        await syncWithAPI(showLoading: true)
    }

    func select(summary: ClientAnalyticsSummary) {
        selectedClientID = summary.client.id
        selectedTab = .card
        historyFilter = .all
        isEditing = false
        applyDraft(from: summary.client)
        let calendar = Calendar.current
        statsFrom = summary.firstVisit ?? calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        statsTo = summary.lastVisit ?? Date()

        Task {
            await loadClientDetails(id: summary.client.id)
        }
    }

    func closeDetails() {
        selectedClientID = nil
        selectedTab = .card
        historyFilter = .all
        isEditing = false
    }

    func saveSelectedClient() async {
        guard let client = selectedClient else { return }
        isSaving = true
        errorMessage = ""
        defer { isSaving = false }

        do {
            let updated = try await apiClient.updateClient(
                id: client.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                phone: draft.phone.trimmingCharacters(in: .whitespacesAndNewlines),
                email: emptyToNil(draft.email),
                comment: emptyToNil(draft.comment)
            )
            upsert(updated)
            applyDraft(from: updated)
            isEditing = false
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func saveSelectedDiscount() async {
        guard canManageDiscounts, let client = selectedClient else { return }
        isSaving = true
        errorMessage = ""
        defer { isSaving = false }

        let percent = parsePercent(draft.permanentDiscountPercent)

        do {
            let updated = try await apiClient.updateClientPermanentDiscount(id: client.id, percent: percent)
            upsert(updated)
            applyDraft(from: updated)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func uploadSelectedClientAvatar(_ image: MariPreparedUploadImage) async {
        guard canManageAvatars, let client = selectedClient else { return }
        avatarBusy = true
        errorMessage = ""
        defer { avatarBusy = false }

        do {
            let updated = try await apiClient.uploadClientAvatar(id: client.id, image: image)
            upsert(updated)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func deleteSelectedClientAvatar() async {
        guard canManageAvatars, let client = selectedClient else { return }
        avatarBusy = true
        errorMessage = ""
        defer { avatarBusy = false }

        do {
            let updated = try await apiClient.deleteClientAvatar(id: client.id)
            upsert(updated)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func deleteSelectedClient() async {
        guard let client = selectedClient else { return }
        isDeleting = true
        errorMessage = ""
        defer { isDeleting = false }

        do {
            _ = try await apiClient.deleteClient(id: client.id)
            clients.removeAll { $0.id == client.id }
            appointments.removeAll { $0.client.id == client.id }
            rebuildSummaries()
            persistCache()
            closeDetails()
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    var selectedClient: MariAPIClient.ClientRecord? {
        guard let selectedClientID else { return nil }
        return clients.first(where: { $0.id == selectedClientID })
    }

    private var permissions: Set<String> {
        Set(session?.staff.permissions ?? [])
    }

    private var isOwner: Bool {
        session?.staff.role == "OWNER"
    }

    private var cacheKey: String {
        "mari-staff-ios.clients-cache.\(session?.staff.id ?? "guest")"
    }

    private func fetchAllClients() async throws -> [MariAPIClient.ClientRecord] {
        var page = 1
        var result: [MariAPIClient.ClientRecord] = []

        while true {
            let response = try await apiClient.listClients(page: page, limit: 200)
            result.append(contentsOf: response.items)
            if response.items.count < 200 {
                break
            }
            page += 1
        }

        return result
    }

    private func fetchAllAppointments() async throws -> [MariAPIClient.AppointmentRecord] {
        var page = 1
        var result: [MariAPIClient.AppointmentRecord] = []

        while true {
            let response = try await apiClient.listAppointments(page: page, limit: 200)
            result.append(contentsOf: response.items)
            if response.items.count < 200 {
                break
            }
            page += 1
        }

        return result
    }

    private func loadClientDetails(id: String) async {
        detailLoading = true
        defer { detailLoading = false }

        do {
            let detailedClient = try await apiClient.getClient(id: id)
            upsert(detailedClient)
            if selectedClientID == id {
                applyDraft(from: detailedClient)
            }
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    private func upsert(_ client: MariAPIClient.ClientRecord) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index] = client
        } else {
            clients.append(client)
        }
        rebuildSummaries()
        persistCache()
    }

    private func applyDraft(from client: MariAPIClient.ClientRecord) {
        draft = ClientDraft(
            name: client.displayName,
            phone: client.phoneE164,
            email: client.email ?? "",
            comment: client.comment ?? "",
            permanentDiscountPercent: client.permanentDiscountString
        )
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parsePercent(_ value: String) -> Double? {
        let trimmed = value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func syncWithAPI(showLoading: Bool) async {
        if showLoading {
            isLoading = true
        }
        errorMessage = ""
        defer {
            if showLoading {
                isLoading = false
            }
        }

        async let clientsTask = fetchAllClients()
        async let appointmentsTask = fetchAllAppointments()

        do {
            let fetchedClients = try await clientsTask
            let fetchedAppointments = try await appointmentsTask

            let clientsChanged = clientsSignature(fetchedClients) != clientsSignature(clients)
            let appointmentsChanged = appointmentsSignature(fetchedAppointments) != appointmentsSignature(appointments)

            if clientsChanged {
                clients = fetchedClients
            }
            if appointmentsChanged {
                appointments = fetchedAppointments
            }
            if clientsChanged || appointmentsChanged {
                rebuildSummaries()
                persistCache()
            }
        } catch {
            if clients.isEmpty && appointments.isEmpty {
                errorMessage = localizedMessage(for: error)
            }
        }
    }

    private func loadCache() {
        guard let data = defaults.data(forKey: cacheKey) else { return }
        guard let payload = try? decoder.decode(ClientsCachePayload.self, from: data) else { return }
        clients = payload.clients
        appointments = payload.appointments
        rebuildSummaries()
    }

    private func persistCache() {
        let payload = ClientsCachePayload(clients: clients, appointments: appointments)
        guard let data = try? encoder.encode(payload) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private func clientsSignature(_ items: [MariAPIClient.ClientRecord]) -> String {
        let sortedItems = items.sorted { $0.id < $1.id }
        var lines: [String] = []
        lines.reserveCapacity(sortedItems.count)

        for item in sortedItems {
            let lineComponents: [String] = [
                item.id,
                item.name ?? "",
                item.phoneE164,
                item.email ?? "",
                item.avatarUrl ?? "",
                item.comment ?? "",
                item.discount.permanent.type,
                String(item.discount.permanent.value ?? 0),
                item.discount.temporary.type,
                String(item.discount.temporary.value ?? 0),
            ]
            lines.append(lineComponents.joined(separator: "|"))
        }

        return lines.joined(separator: "\n")
    }

    private func appointmentsSignature(_ items: [MariAPIClient.AppointmentRecord]) -> String {
        let sortedItems = items.sorted { $0.id < $1.id }
        var lines: [String] = []
        lines.reserveCapacity(sortedItems.count)

        for item in sortedItems {
            let line = [
                item.id,
                item.client.id,
                normalizedPhone(item.client.phoneE164),
                item.staff.id,
                item.status,
                String(item.startAt.timeIntervalSince1970),
                String(item.endAt.timeIntervalSince1970),
                String(item.prices.finalTotal),
                String(item.updatedAt.timeIntervalSince1970),
            ].joined(separator: "|")
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private func setupDerivedState() {
        Publishers.CombineLatest4($query, $segment, $activityFilter, $sortMode)
            .combineLatest($summaries)
            .map { [weak self] filters, summaries in
                guard let self else { return summaries }
                let (query, segment, activityFilter, sortMode) = filters
                return self.filterSummaries(
                    summaries,
                    query: query,
                    segment: segment,
                    activityFilter: activityFilter,
                    sortMode: sortMode
                )
            }
            .receive(on: RunLoop.main)
            .assign(to: \.filteredSummaries, on: self)
            .store(in: &cancellables)
    }

    private func rebuildSummaries() {
        let lookup = buildAppointmentLookup(appointments: appointments)
        summaries = clients.map { client in
            buildSummary(client: client, appointments: linkedAppointments(for: client, lookup: lookup))
        }
    }

    private func filterSummaries(
        _ items: [ClientAnalyticsSummary],
        query: String,
        segment: ClientSegment,
        activityFilter: ActivityFilter,
        sortMode: SortMode
    ) -> [ClientAnalyticsSummary] {
        let search = normalizedSearch(query)
        let now = Date()

        return items
            .filter { summary in
                if segment != .all, resolvedSegment(for: summary, now: now) != segment {
                    return false
                }
                if activityFilter == .visited, summary.totalVisits == 0 {
                    return false
                }
                if activityFilter == .withoutVisits, summary.totalVisits > 0 {
                    return false
                }
                if search.isEmpty {
                    return true
                }
                return summary.client.displayName.lowercased().contains(search) ||
                    summary.client.phoneE164.contains(search) ||
                    (summary.client.email ?? "").lowercased().contains(search)
            }
            .sorted { lhs, rhs in
                self.sortPredicate(lhs: lhs, rhs: rhs, sortMode: sortMode)
            }
    }

    private func sortPredicate(lhs: ClientAnalyticsSummary, rhs: ClientAnalyticsSummary, sortMode: SortMode) -> Bool {
        switch sortMode {
        case .recent:
            return (lhs.lastVisit ?? .distantPast) > (rhs.lastVisit ?? .distantPast)
        case .visits:
            if lhs.totalVisits == rhs.totalVisits {
                return lhs.client.displayName < rhs.client.displayName
            }
            return lhs.totalVisits > rhs.totalVisits
        case .revenue:
            if lhs.totalRevenue == rhs.totalRevenue {
                return lhs.client.displayName < rhs.client.displayName
            }
            return lhs.totalRevenue > rhs.totalRevenue
        }
    }
}

struct ClientsScreen: View {
    let sessionStore: AppSessionStore
    @StateObject private var store: ClientsStore
    @State private var showsStartupSkeleton = true
    @State private var visibleSummaryCount = 40

    private let pageSize = 40

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        _store = StateObject(wrappedValue: ClientsStore(apiClient: sessionStore.api, session: sessionStore.currentSession))
    }

    private var segmentCounts: [ClientSegment: Int] {
        let now = Date()
        return ClientSegment.allCases.reduce(into: [:]) { partial, segment in
            partial[segment] = segment == .all ? store.summaries.count : store.summaries.filter { resolvedSegment(for: $0, now: now) == segment }.count
        }
    }

    private var displayedSummaries: [ClientAnalyticsSummary] {
        Array(store.filteredSummaries.prefix(visibleSummaryCount))
    }

    private var hasMoreSummaries: Bool {
        displayedSummaries.count < store.filteredSummaries.count
    }

    private var selectedSummary: ClientAnalyticsSummary? {
        guard let selectedClientID = store.selectedClientID else { return nil }
        return store.summaries.first(where: { $0.id == selectedClientID })
    }

    private var isShowingSkeleton: Bool {
        showsStartupSkeleton || store.isLoading
    }

    var body: some View {
        MariScrollContainer(onRefresh: {
            await store.reload()
        }) {
            if isShowingSkeleton {
                ClientsInitialSkeleton()
            } else {
                ClientsSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Клиенты")
                                    .font(.system(size: 36, weight: .black, design: .rounded))
                                    .foregroundStyle(MariPalette.ink)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 8) {
                                ClientsIconButton(systemImage: "ellipsis") {}
                                ClientsIconButton(systemImage: "arrow.clockwise") {
                                    Task { await store.reload() }
                                }
                            }
                        }

                        ClientsSearchField(query: $store.query)

                        VStack(spacing: 10) {
                            Menu {
                                Picker("Клиенты", selection: $store.activityFilter) {
                                    ForEach(ActivityFilter.allCases) { filter in
                                        Text(filter.title).tag(filter)
                                    }
                                }
                            } label: {
                                ClientsSelectField(title: store.activityFilter == .all ? "Все клиенты" : store.activityFilter.title)
                            }

                            Menu {
                                Picker("Сортировка", selection: $store.sortMode) {
                                    ForEach(SortMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                            } label: {
                                ClientsSelectField(title: store.sortMode.title)
                            }
                        }

                        if store.isLoading {
                            ClientsStatusNote(text: "Загружаю клиентов", tint: MariPalette.accentSecondary, showsProgress: true)
                        }

                        if !store.errorMessage.isEmpty {
                            ClientsStatusNote(text: store.errorMessage, tint: Color(hex: 0xF2C6BF), showsProgress: false)
                        }
                    }
                }

                ClientsSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("СПИСОК КЛИЕНТОВ")
                                .font(.caption2.weight(.bold))
                                .tracking(1.4)
                                .foregroundStyle(MariPalette.softInk.opacity(0.64))

                            Text("\(store.filteredSummaries.count)")
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .foregroundStyle(MariPalette.ink)
                        }

                        if store.filteredSummaries.isEmpty, !store.isLoading {
                            ClientsEmptyState()
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(displayedSummaries) { summary in
                                    ClientCard(
                                        summary: summary,
                                        segment: resolvedSegment(for: summary, now: Date()),
                                        mediaBaseURL: sessionStore.configuration.baseURL
                                    ) {
                                        store.select(summary: summary)
                                    }
                                }

                                if hasMoreSummaries {
                                    ClientsPaginator(
                                        remainingCount: store.filteredSummaries.count - displayedSummaries.count,
                                        action: loadNextPage
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .sheet(
            isPresented: Binding(
                get: { store.selectedClientID != nil },
                set: { isPresented in
                    if !isPresented {
                        store.closeDetails()
                    }
                }
            )
        ) {
            if let selectedSummary {
                ClientDetailsSheet(
                    store: store,
                    summary: selectedSummary,
                    mediaBaseURL: sessionStore.configuration.baseURL
                )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .task {
            store.updateSession(sessionStore.currentSession)
            await store.loadIfNeeded()
            resetPagination()
            showsStartupSkeleton = false
        }
        .onChange(of: store.query) { _, _ in
            resetPagination()
        }
        .onChange(of: store.segment) { _, _ in
            resetPagination()
        }
        .onChange(of: store.activityFilter) { _, _ in
            resetPagination()
        }
        .onChange(of: store.sortMode) { _, _ in
            resetPagination()
        }
    }

    private func loadNextPage() {
        MariHaptics.navigationTap()
        visibleSummaryCount = min(visibleSummaryCount + pageSize, store.filteredSummaries.count)
    }

    private func resetPagination() {
        visibleSummaryCount = pageSize
    }
}

private struct ClientCard: View {
    let summary: ClientAnalyticsSummary
    let segment: ClientSegment
    let mediaBaseURL: String
    let onTap: () -> Void

    var body: some View {
        Button {
            MariHaptics.navigationTap()
            onTap()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ClientAvatarView(
                    title: summary.client.displayName,
                    avatarURL: summary.client.avatarUrl,
                    mediaBaseURL: mediaBaseURL,
                    size: 52,
                    cornerRadius: 16,
                    tint: Color(hex: 0xF7F8FB),
                    placeholderColor: MariPalette.softInk,
                    placeholderFont: .title3.weight(.black)
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.client.displayName)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(MariPalette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Text(summary.client.phoneE164)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(MariPalette.softInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        ClientsBadge(title: segment.title.uppercased(), tint: segment.accentColor)
                    }

                    HStack(spacing: 8) {
                        ClientsMetaPill(title: visitsTitle)
                        ClientsMetaPill(title: formatMoney(summary.totalRevenue))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.96))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    private var visitsTitle: String {
        let count = summary.totalVisits
        let suffix: String
        switch count % 100 {
        case 11...14:
            suffix = "визитов"
        default:
            switch count % 10 {
            case 1: suffix = "визит"
            case 2...4: suffix = "визита"
            default: suffix = "визитов"
            }
        }
        return "\(count) \(suffix)"
    }
}

private struct ClientsSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
        }
        .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 10)
    }
}

private struct ClientsInitialSkeleton: View {
    var body: some View {
        ClientsSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    MariSkeletonBlock(width: 156, height: 38, cornerRadius: 14)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        MariSkeletonCircle(size: 34)
                        MariSkeletonCircle(size: 34)
                    }
                }

                MariSkeletonBlock(height: 52, cornerRadius: 18)

                VStack(spacing: 10) {
                    MariSkeletonBlock(height: 52, cornerRadius: 18)
                    MariSkeletonBlock(height: 52, cornerRadius: 18)
                }

                MariSkeletonBlock(height: 44, cornerRadius: 16)
            }
        }

        ClientsSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    MariSkeletonBlock(width: 132, height: 11, cornerRadius: 6)
                    MariSkeletonBlock(width: 42, height: 34, cornerRadius: 12)
                }

                VStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 12) {
                            MariSkeletonBlock(width: 46, height: 46, cornerRadius: 14)

                            VStack(alignment: .leading, spacing: 8) {
                                MariSkeletonBlock(width: 148, height: 16, cornerRadius: 8)
                                MariSkeletonBlock(width: 110, height: 12, cornerRadius: 6)
                                MariSkeletonBlock(height: 44, cornerRadius: 12)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ClientsIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.black))
                .foregroundStyle(MariPalette.ink)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .overlay {
                            Circle().stroke(Color.black.opacity(0.06), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct ClientsSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MariPalette.softInk.opacity(0.7))

            TextField("Поиск по имени, телефону или email", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(MariPalette.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                }
        }
    }
}

private struct ClientsSelectField: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.ink)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.black))
                .foregroundStyle(MariPalette.softInk.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                }
        }
    }
}

private struct ClientsSegmentPill: View {
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(isActive ? MariPalette.ink : MariPalette.softInk)

                Text("\(count)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(isActive ? MariPalette.ink : MariPalette.softInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(isActive ? MariPalette.accent : Color(hex: 0xEEF2F7))
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(isActive ? Color(hex: 0xFFF7D8) : Color.white.opacity(0.84))
                    .overlay {
                        Capsule()
                            .stroke(isActive ? MariPalette.accent.opacity(0.8) : Color.black.opacity(0.06), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ClientsInlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(MariPalette.softInk.opacity(0.64))

            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClientsStatusNote: View {
    let text: String
    let tint: Color
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .scaleEffect(0.85)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(MariPalette.ink.opacity(0.7))
            }

            Text(text)
                .font(.footnote.weight(.bold))
                .foregroundStyle(MariPalette.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.65))
        }
    }
}

private struct ClientsEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Клиенты не найдены")
                .font(.title3.weight(.black))
                .fontDesign(.rounded)
                .foregroundStyle(MariPalette.ink)
            Text("Проверь поиск или фильтры.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.88))
        }
    }
}

private struct ClientsBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.black))
            .tracking(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(tint == MariPalette.accent ? MariPalette.ink : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(tint.opacity(0.14))
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ClientsMetaPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(MariPalette.softInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(Color(hex: 0xF4F6FA))
            }
    }
}

private struct ClientsPaginator: View {
    let remainingCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Показать еще")
                    .font(.subheadline.weight(.bold))
                Text("\(remainingCount)")
                    .font(.caption.weight(.black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(MariPalette.accent.opacity(0.22))
                    }
            }
            .foregroundStyle(MariPalette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.88))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ClientAvatarView: View {
    let title: String
    let avatarURL: String?
    let mediaBaseURL: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let tint: Color
    let placeholderColor: Color
    let placeholderFont: Font

    private var resolvedURL: URL? {
        resolveMediaURL(avatarURL, relativeTo: mediaBaseURL)
    }

    private var placeholderText: String {
        String(title.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint)

            if let resolvedURL {
                AsyncImage(url: resolvedURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(placeholderColor.opacity(0.72))
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        }
        .accessibilityLabel("Аватар \(title)")
    }

    private var placeholder: some View {
        Text(placeholderText)
            .font(placeholderFont)
            .fontDesign(.rounded)
            .foregroundStyle(placeholderColor)
    }
}

private struct ClientDetailsSheet: View {
    @ObservedObject var store: ClientsStore
    let summary: ClientAnalyticsSummary
    let mediaBaseURL: String
    @State private var confirmsDelete = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    private var activeClient: MariAPIClient.ClientRecord {
        store.selectedClient ?? summary.client
    }

    private var historyItems: [MariAPIClient.AppointmentRecord] {
        summary.appointments.filter { appointment in
            switch store.historyFilter {
            case .all:
                true
            case .upcoming:
                normalizedStatus(appointment.status) == "PENDING"
            case .confirmed:
                normalizedStatus(appointment.status) == "CONFIRMED"
            case .arrived:
                ["ARRIVED", "DONE", "COMPLETED"].contains(normalizedStatus(appointment.status))
            case .noShow:
                normalizedStatus(appointment.status) == "NO_SHOW"
            }
        }
    }

    private var statsItems: [MariAPIClient.AppointmentRecord] {
        summary.appointments.filter { appointment in
            appointment.startAt >= startOfDay(store.statsFrom) && appointment.startAt <= endOfDay(store.statsTo)
        }
    }

    private var statsSummary: ClientAnalyticsSummary {
        buildSummary(client: activeClient, appointments: statsItems)
    }

    private var revenueSeries: [RevenuePoint] {
        buildRevenueSeries(appointments: statsItems, from: store.statsFrom, to: store.statsTo)
    }

    private var avatarActionTitle: String {
        if store.avatarBusy {
            return "Загружаю фото..."
        }
        return activeClient.avatarUrl == nil ? "Добавить фото" : "Изменить фото"
    }

    var body: some View {
        NavigationStack {
            MariScrollContainer(onRefresh: {
                await store.reload()
            }) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        ClientAvatarView(
                            title: activeClient.displayName,
                            avatarURL: activeClient.avatarUrl,
                            mediaBaseURL: mediaBaseURL,
                            size: 42.64,
                            cornerRadius: 21.32,
                            tint: MariPalette.accent.opacity(0.28),
                            placeholderColor: MariPalette.ink,
                            placeholderFont: .headline.weight(.black)
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(activeClient.displayName)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(MariPalette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Text(activeClient.phoneE164)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MariPalette.softInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if store.canEdit {
                        Button {
                            if store.isEditing {
                                Task { await store.saveSelectedClient() }
                            } else {
                                store.isEditing = true
                            }
                        } label: {
                            Label(store.isEditing ? "Сохранить" : "Изменить", systemImage: store.isEditing ? "checkmark" : "pencil")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MariPalette.ink)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule()
                                        .fill(Color.white.opacity(0.92))
                                        .overlay {
                                            Capsule()
                                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isSaving || store.isDeleting)
                    }
                }

                if store.isEditing && store.canManageAvatars {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(
                                avatarActionTitle,
                                systemImage: "photo"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MariPalette.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background {
                                Capsule()
                                    .fill(Color.white.opacity(0.92))
                                    .overlay {
                                        Capsule()
                                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.avatarBusy || store.isSaving || store.isDeleting)

                        if activeClient.avatarUrl != nil {
                            Button {
                                Task { await store.deleteSelectedClientAvatar() }
                            } label: {
                                Label("Удалить фото", systemImage: "trash")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(hex: 0x9A5447))
                                    .lineLimit(1)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background {
                                        Capsule()
                                            .fill(Color.white.opacity(0.92))
                                            .overlay {
                                                Capsule()
                                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                            }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(store.avatarBusy || store.isSaving || store.isDeleting)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.detailLoading {
                    ProgressView("Обновляю карточку")
                        .font(.footnote.weight(.semibold))
                        .tint(MariPalette.accent)
                }

                if store.avatarBusy {
                    ProgressView("Загружаю аватар")
                        .font(.footnote.weight(.semibold))
                        .tint(MariPalette.accent)
                }

                Picker("Раздел", selection: $store.selectedTab) {
                    ForEach(ClientModalTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                if !store.errorMessage.isEmpty {
                    GlassPanel(tint: Color(hex: 0xE5988B)) {
                        Text(store.errorMessage)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)
                    }
                }

                switch store.selectedTab {
                case .card:
                    cardTab
                case .history:
                    historyTab
                case .stats:
                    statsTab
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Карточка клиента")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        store.closeDetails()
                    }
                    .fontWeight(.bold)
                }
            }
            .alert("Удалить клиента?", isPresented: $confirmsDelete) {
                Button("Удалить", role: .destructive) {
                    Task { await store.deleteSelectedClient() }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут удалены клиент и связанные записи, как в backend staff.")
            }
            .onChange(of: selectedPhotoItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    defer { selectedPhotoItem = nil }
                    do {
                        guard let rawData = try await newValue.loadTransferable(type: Data.self) else {
                            throw MariImagePreparationError.unreadableImage
                        }
                        let image = try MariImagePreparation.prepareWebPImage(
                            from: rawData,
                            suggestedBaseName: activeClient.id
                        )
                        await store.uploadSelectedClientAvatar(image)
                    } catch {
                        store.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
    }

    private var cardTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                CompactClientMetricCard(
                    title: "Визиты",
                    value: "\(summary.totalVisits)",
                    detail: visitWindowLine(first: summary.firstVisit, last: summary.lastVisit),
                    tint: MariPalette.accent
                )
                CompactClientMetricCard(
                    title: "Средний чек",
                    value: formatMoney(summary.averageCheck),
                    detail: "Оплачено \(formatMoney(summary.totalPaid))",
                    tint: MariPalette.sky
                )
                CompactClientMetricCard(
                    title: "Неявки",
                    value: "\(summary.noShows)",
                    detail: "Подтверждено \(summary.confirmed)",
                    tint: MariPalette.rose
                )
                CompactClientMetricCard(
                    title: "Скидка",
                    value: activeClient.permanentDiscountString.isEmpty ? "—" : "\(activeClient.permanentDiscountString)%",
                    detail: "Постоянная скидка клиента",
                    tint: MariPalette.mint
                )
            }

            GlassPanel(tint: MariPalette.accentSecondary) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Быстрые действия")
                        .font(.title3.weight(.black))
                        .fontDesign(.rounded)
                        .foregroundStyle(MariPalette.ink)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        if let url = URL(string: "tel:\(activeClient.phoneE164)") {
                            Link(destination: url) {
                                CompactActionChip(title: "Позвонить", systemImage: "phone.fill")
                            }
                        }
                        if let url = URL(string: "sms:\(activeClient.phoneE164)") {
                            Link(destination: url) {
                                CompactActionChip(title: "SMS", systemImage: "message.fill")
                            }
                        }
                        if let telegramURL = telegramURL(for: activeClient.phoneE164) {
                            Link(destination: telegramURL) {
                                CompactActionChip(title: "Telegram", systemImage: "paperplane.fill")
                            }
                        }
                        if let email = activeClient.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                            Link(destination: url) {
                                CompactActionChip(title: "Email", systemImage: "envelope.fill")
                            }
                        }
                    }
                }
            }

            GlassPanel(tint: MariPalette.sky) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Карточка")
                        .font(.title3.weight(.black))
                        .fontDesign(.rounded)
                        .foregroundStyle(MariPalette.ink)

                    DetailField(title: "Имя", value: $store.draft.name, editable: store.isEditing)
                    DetailField(title: "Телефон", value: $store.draft.phone, editable: store.isEditing)
                    DetailField(title: "Email", value: $store.draft.email, editable: store.isEditing)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Комментарий")
                            .font(.caption.weight(.bold))
                            .fontDesign(.rounded)
                            .tracking(1.1)
                            .foregroundStyle(MariPalette.softInk.opacity(0.8))

                        if store.isEditing {
                            TextEditor(text: $store.draft.comment)
                                .font(.subheadline)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 104)
                                .padding(12)
                                .background {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.white.opacity(0.82))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(Color.black.opacity(0.05), lineWidth: 1)
                                        }
                                }
                        } else {
                            Text(store.draft.comment.isEmpty ? "Комментарий не заполнен" : store.draft.comment)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(store.draft.comment.isEmpty ? MariPalette.softInk : MariPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.white.opacity(0.72))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(Color.black.opacity(0.04), lineWidth: 1)
                                        }
                                }
                        }
                    }
                }
            }

            if store.canManageDiscounts {
                GlassPanel(tint: MariPalette.rose) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Скидка")
                            .font(.title3.weight(.black))
                            .fontDesign(.rounded)
                            .foregroundStyle(MariPalette.ink)

                        DetailField(
                            title: "Постоянная скидка, %",
                            value: $store.draft.permanentDiscountPercent,
                            editable: true,
                            keyboardType: .decimalPad
                        )

                        Button {
                            Task { await store.saveSelectedDiscount() }
                        } label: {
                            Text(store.isSaving ? "Сохраняю..." : "Сохранить скидку")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MariPalette.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.86))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.black.opacity(0.05), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isSaving || store.isDeleting)
                    }
                }
            }

            if store.canEdit {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.bold))
                        Text(store.isDeleting ? "Удаляю..." : "Удалить клиента")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(hex: 0xC9523A))
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isSaving || store.isDeleting)
                .opacity(store.isSaving || store.isDeleting ? 0.65 : 1)
            }
        }
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                store.historyFilter = filter
                            }
                        } label: {
                            Text(filter.title)
                                .font(.footnote.weight(.bold))
                                .fontDesign(.rounded)
                                .foregroundStyle(store.historyFilter == filter ? MariPalette.ink : MariPalette.softInk)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background {
                                    Capsule()
                                        .fill(store.historyFilter == filter ? Color.white.opacity(0.92) : Color.white.opacity(0.58))
                                        .overlay {
                                            Capsule()
                                                .stroke(Color.black.opacity(store.historyFilter == filter ? 0.06 : 0.03), lineWidth: 1)
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)

            if historyItems.isEmpty {
                GlassPanel(tint: MariPalette.accentSecondary) {
                    Text("История пустая для выбранного фильтра.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.ink)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(historyItems, id: \.id) { appointment in
                        HistoryCard(appointment: appointment)
                    }
                }
            }
        }
    }

    private var statsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassPanel(tint: MariPalette.sky) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Период")
                        .font(.title3.weight(.black))
                        .fontDesign(.rounded)
                        .foregroundStyle(MariPalette.ink)

                    DatePicker("С", selection: $store.statsFrom, displayedComponents: .date)
                        .font(.subheadline.weight(.semibold))
                    DatePicker("По", selection: $store.statsTo, displayedComponents: .date)
                        .font(.subheadline.weight(.semibold))
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                CompactClientMetricCard(
                    title: "Выручка",
                    value: formatMoney(statsSummary.totalRevenue),
                    detail: "Оплачено \(formatMoney(statsSummary.totalPaid))",
                    tint: MariPalette.accent
                )
                CompactClientMetricCard(
                    title: "Визиты",
                    value: "\(statsSummary.totalVisits)",
                    detail: "Средний чек \(formatMoney(statsSummary.averageCheck))",
                    tint: MariPalette.sky
                )
                CompactClientMetricCard(
                    title: "Неявки",
                    value: "\(statsSummary.noShows)",
                    detail: "Подтверждено \(statsSummary.confirmed)",
                    tint: MariPalette.rose
                )
                CompactClientMetricCard(
                    title: "Ожидает",
                    value: "\(statsSummary.upcoming)",
                    detail: "Период выбран вручную",
                    tint: MariPalette.mint
                )
            }

            GlassPanel(tint: MariPalette.accentSecondary) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Динамика")
                        .font(.title3.weight(.black))
                        .fontDesign(.rounded)
                        .foregroundStyle(MariPalette.ink)

                    if revenueSeries.isEmpty {
                        Text("Недостаточно данных за период.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MariPalette.softInk)
                    } else {
                        Chart(revenueSeries) { item in
                            AreaMark(
                                x: .value("Месяц", item.month),
                                y: .value("Выручка", item.value)
                            )
                            .foregroundStyle(MariPalette.accent.opacity(0.22))

                            LineMark(
                                x: .value("Месяц", item.month),
                                y: .value("Выручка", item.value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(MariPalette.accent)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round))
                        }
                        .frame(height: 220)
                    }
                }
            }

            GlassEffectContainer(spacing: 14) {
                DistributionPanel(title: "Услуги", items: statsSummary.topServices, formatter: formatMoney)
                DistributionPanel(title: "Сотрудники", items: statsSummary.topStaff, formatter: formatCount)
                DistributionPanel(title: "Статусы", items: statsSummary.statusBreakdown, formatter: formatCount)
            }
        }
    }
}

private struct CompactClientMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(2)
                .foregroundStyle(MariPalette.softInk.opacity(0.7))

            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(detail)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(tint.opacity(0.65))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1)
                }
        }
    }
}

private struct HistoryCard: View {
    let appointment: MariAPIClient.AppointmentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appointment.primaryServiceName)
                        .font(.subheadline.weight(.bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(MariPalette.ink)
                        .lineLimit(2)

                    Text("\(historyDate(appointment.startAt)) · \(appointment.staff.name)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(MariPalette.softInk)
                }

                Spacer(minLength: 10)

                MariBadge(title: localizedStatus(appointment.status), tint: statusAccentColor(appointment.status))
            }

            HStack(spacing: 12) {
                Text("Стоимость \(formatMoney(appointment.prices.finalTotal))")
                Spacer()
                Text("Оплачено \(formatMoney(appointment.payment.paidAmount))")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(MariPalette.softInk)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                }
        }
    }
}

private struct DistributionPanel: View {
    let title: String
    let items: [DistributionItem]
    let formatter: (Double) -> String

    var body: some View {
        GlassPanel(tint: MariPalette.sky) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title3.weight(.black))
                    .fontDesign(.rounded)
                    .foregroundStyle(MariPalette.ink)

                if items.isEmpty {
                    Text("Недостаточно данных")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(MariPalette.ink)
                            Spacer(minLength: 12)
                            Text(formatter(item.value))
                                .font(.footnote.weight(.black))
                                .foregroundStyle(MariPalette.softInk)
                        }
                    }
                }
            }
        }
    }
}

private struct DetailField: View {
    let title: String
    @Binding var value: String
    let editable: Bool
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .fontDesign(.rounded)
                .tracking(1.0)
                .foregroundStyle(MariPalette.softInk.opacity(0.78))

            if editable {
                TextField(title, text: $value)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.white.opacity(0.84))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
                            }
                    }
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(value.isEmpty ? MariPalette.softInk : MariPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.white.opacity(0.72))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
                            }
                    }
            }
        }
    }
}

private struct CompactActionChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(width: 16)

            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .fontDesign(.rounded)
        .foregroundStyle(MariPalette.ink)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.horizontal, 12)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.86))
                .overlay {
                    Capsule()
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                }
        }
    }
}

private struct SegmentButton: View {
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .fontDesign(.rounded)

                Text("\(count)")
                    .font(.caption.weight(.black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(.white.opacity(isActive ? 0.28 : 0.12))
                    }
            }
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(.white.opacity(isActive ? 0.18 : 0.08))
            }
            .glassEffect(
                isActive ? .regular.tint(MariPalette.accent).interactive() : .clear.interactive(),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FilterCapsule: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(value)
                .foregroundStyle(MariPalette.ink)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.black))
        }
        .font(.footnote.weight(.bold))
        .fontDesign(.rounded)
        .foregroundStyle(MariPalette.softInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.white.opacity(0.14))
        }
        .glassEffect(.regular.tint(MariPalette.sky), in: Capsule())
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .fontDesign(.rounded)
                .tracking(1.2)
                .foregroundStyle(MariPalette.softInk.opacity(0.84))

            Text(value)
                .font(.footnote.weight(.black))
                .foregroundStyle(MariPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.12))
        }
    }
}

private func buildSummary(
    client: MariAPIClient.ClientRecord,
    appointments: [MariAPIClient.AppointmentRecord]
) -> ClientAnalyticsSummary {
    let history = appointments.sorted { $0.startAt > $1.startAt }
    let totalRevenue = history.reduce(0) { $0 + $1.prices.finalTotal }
    let totalPaid = history.reduce(0) { $0 + $1.payment.paidAmount }
    let averageDiscount = history.isEmpty ? 0 : history.reduce(0) { $0 + discountPercent(for: $1) } / Double(history.count)
    let firstVisit = history.last?.startAt
    let lastVisit = history.first?.startAt

    var serviceTotals: [String: Double] = [:]
    var staffTotals: [String: Double] = [:]
    var statusTotals: [String: Double] = [:]

    for appointment in history {
        serviceTotals[appointment.primaryServiceName, default: 0] += appointment.prices.finalTotal
        staffTotals[appointment.staff.name, default: 0] += 1
        statusTotals[localizedStatus(appointment.status), default: 0] += 1
    }

    return ClientAnalyticsSummary(
        client: client,
        appointments: history,
        totalVisits: history.count,
        totalRevenue: totalRevenue,
        totalPaid: totalPaid,
        averageDiscount: averageDiscount,
        averageCheck: history.isEmpty ? 0 : totalRevenue / Double(history.count),
        firstVisit: firstVisit,
        lastVisit: lastVisit,
        noShows: history.filter { normalizedStatus($0.status) == "NO_SHOW" }.count,
        confirmed: history.filter { normalizedStatus($0.status) == "CONFIRMED" }.count,
        upcoming: history.filter { normalizedStatus($0.status) == "PENDING" }.count,
        topServices: topDistribution(serviceTotals),
        topStaff: topDistribution(staffTotals),
        statusBreakdown: topDistribution(statusTotals)
    )
}

private func buildAppointmentLookup(
    appointments: [MariAPIClient.AppointmentRecord]
) -> (
    byClientID: [String: [MariAPIClient.AppointmentRecord]],
    byPhone: [String: [MariAPIClient.AppointmentRecord]]
) {
    var byClientID: [String: [MariAPIClient.AppointmentRecord]] = [:]
    var byPhone: [String: [MariAPIClient.AppointmentRecord]] = [:]

    for appointment in appointments {
        byClientID[appointment.client.id, default: []].append(appointment)
        let phone = normalizedPhone(appointment.client.phoneE164)
        if !phone.isEmpty {
            byPhone[phone, default: []].append(appointment)
        }
    }

    return (byClientID, byPhone)
}

private func linkedAppointments(
    for client: MariAPIClient.ClientRecord,
    lookup: (
        byClientID: [String: [MariAPIClient.AppointmentRecord]],
        byPhone: [String: [MariAPIClient.AppointmentRecord]]
    )
) -> [MariAPIClient.AppointmentRecord] {
    var unique: [String: MariAPIClient.AppointmentRecord] = [:]

    for appointment in lookup.byClientID[client.id] ?? [] {
        unique[appointment.id] = appointment
    }

    let phone = normalizedPhone(client.phoneE164)
    for appointment in lookup.byPhone[phone] ?? [] {
        unique[appointment.id] = appointment
    }

    return unique.values.sorted { $0.startAt > $1.startAt }
}

private func resolvedSegment(for summary: ClientAnalyticsSummary, now: Date) -> ClientSegment {
    guard summary.totalVisits > 0, let lastVisit = summary.lastVisit else {
        return .new
    }

    if now.timeIntervalSince(lastVisit) > 90 * 24 * 60 * 60 {
        return .lost
    }

    return .repeatClient
}

private func topDistribution(_ items: [String: Double]) -> [DistributionItem] {
    items
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        .prefix(6)
        .map { DistributionItem(label: $0.key, value: $0.value) }
}

private func buildRevenueSeries(
    appointments: [MariAPIClient.AppointmentRecord],
    from: Date,
    to: Date
) -> [RevenuePoint] {
    let calendar = Calendar.current
    let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: from)) ?? from
    let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: to)) ?? to

    var months: [Date] = []
    var cursor = startMonth
    while cursor <= endMonth {
        months.append(cursor)
        cursor = calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor
        if months.count > 120 {
            break
        }
    }

    var totals: [Date: Double] = Dictionary(uniqueKeysWithValues: months.map { ($0, 0) })
    for appointment in appointments where appointment.startAt >= startOfDay(from) && appointment.startAt <= endOfDay(to) {
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: appointment.startAt)) ?? appointment.startAt
        totals[month, default: 0] += appointment.prices.finalTotal
    }

    return months.map { month in
        RevenuePoint(
            month: month,
            label: month.formatted(.dateTime.month(.abbreviated).year(.twoDigits).locale(MariLocale.ru)),
            value: totals[month, default: 0]
        )
    }
}

private func normalizedStatus(_ status: String) -> String {
    status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private func localizedStatus(_ status: String) -> String {
    switch normalizedStatus(status) {
    case "ARRIVED", "DONE", "COMPLETED":
        "Завершен"
    case "CONFIRMED":
        "Подтвержден"
    case "NO_SHOW":
        "Не пришел"
    case "CANCELLED", "CANCELED":
        "Отменен"
    default:
        "Ожидание"
    }
}

private func statusAccentColor(_ status: String) -> Color {
    switch normalizedStatus(status) {
    case "ARRIVED", "DONE", "COMPLETED":
        MariPalette.mint
    case "CONFIRMED":
        MariPalette.sky
    case "NO_SHOW":
        Color(hex: 0xE5988B)
    case "CANCELLED", "CANCELED":
        Color(hex: 0xD2C9C3)
    default:
        MariPalette.accent
    }
}

private func discountPercent(for appointment: MariAPIClient.AppointmentRecord) -> Double {
    guard appointment.prices.baseTotal > 0 else { return 0 }
    return max(0, (appointment.prices.discountAmount / appointment.prices.baseTotal) * 100)
}

private func normalizedPhone(_ value: String?) -> String {
    (value ?? "").filter(\.isNumber)
}

private func normalizedSearch(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func formatMoney(_ value: Double) -> String {
    MariFormatters.money(Int(value.rounded()))
}

private func formatCount(_ value: Double) -> String {
    String(Int(value.rounded()))
}

private func historyDate(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.wide).hour().minute().locale(MariLocale.ru))
}

private func lastVisitLine(_ date: Date?) -> String {
    guard let date else { return "Визитов пока не было" }
    return "Последний визит \(date.formatted(.dateTime.day().month(.wide).year().locale(MariLocale.ru)))"
}

private func visitWindowLine(first: Date?, last: Date?) -> String {
    guard let first, let last else { return "История еще не сформирована" }
    return "\(first.formatted(.dateTime.day().month(.abbreviated).locale(MariLocale.ru))) – \(last.formatted(.dateTime.day().month(.abbreviated).locale(MariLocale.ru)))"
}

private func startOfDay(_ date: Date) -> Date {
    Calendar.current.startOfDay(for: date)
}

private func endOfDay(_ date: Date) -> Date {
    let start = startOfDay(date)
    return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
}

private func telegramURL(for phone: String) -> URL? {
    let digits = normalizedPhone(phone)
    guard !digits.isEmpty else { return nil }
    return URL(string: "tg://resolve?phone=\(digits)")
}

private func resolveMediaURL(_ rawValue: String?, relativeTo baseURL: String) -> URL? {
    guard let rawValue else { return nil }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let directURL = URL(string: trimmed), directURL.scheme != nil {
        return directURL
    }

    let normalizedBaseURL = AppConfigurationStore.resolvedBaseURL(from: baseURL)
    guard let baseURL = URL(string: normalizedBaseURL) else { return nil }
    return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
}

private extension ClientSegment {
    var accentColor: Color {
        switch self {
        case .all: MariPalette.sky
        case .new: MariPalette.accent
        case .repeatClient: MariPalette.mint
        case .lost: MariPalette.rose
        }
    }
}

private extension MariAPIClient.ClientRecord {
    var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Клиент без имени" : trimmed
    }

    var permanentDiscountString: String {
        guard discount.permanent.type == "PERCENT", let value = discount.permanent.value else {
            return ""
        }
        let rounded = value.rounded()
        if rounded == value {
            return String(Int(rounded))
        }
        return String(format: "%.1f", value)
    }
}

private extension MariAPIClient.AppointmentRecord {
    var primaryServiceName: String {
        services.first?.name ?? "Без услуги"
    }
}

#Preview {
    NavigationStack {
        ClientsScreen(sessionStore: AppSessionStore(configuration: AppConfigurationStore()))
    }
}
