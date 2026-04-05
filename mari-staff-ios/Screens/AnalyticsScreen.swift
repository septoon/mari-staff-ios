import Combine
import SwiftUI

private enum AnalyticsChartMode: String, CaseIterable, Identifiable {
    case revenue
    case appointments
    case occupancy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .revenue: "Выручка"
        case .appointments: "Записи"
        case .occupancy: "Заполненность"
        }
    }
}

private enum AnalyticsSyncState {
    case idle
    case loading
    case success
    case error
}

private struct AnalyticsFilters: Equatable {
    var from: Date
    var to: Date
    var position: String
    var staffID: String

    static func makeDefault(referenceDate: Date = .now) -> AnalyticsFilters {
        let day = Calendar.analytics.startOfDay(for: referenceDate)
        return AnalyticsFilters(
            from: Calendar.analytics.date(byAdding: .day, value: -69, to: day) ?? day,
            to: day,
            position: "all",
            staffID: ""
        )
    }
}

private struct AnalyticsBucket: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let value: Double
}

private struct AnalyticsDistributionItem: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let color: Color
}

private struct AnalyticsClientSegments {
    let newClients: Int
    let repeatClients: Int
    let lostClients: Int
}

private struct AnalyticsSnapshot {
    let filteredAppointments: [MariAPIClient.AppointmentRecord]
    let allRelevantAppointments: [MariAPIClient.AppointmentRecord]
    let filteredStaffCount: Int
    let totalRevenue: Double
    let totalPaid: Double
    let totalAppointments: Int
    let cancelledAppointments: Int
    let completedAppointments: Int
    let pendingAppointments: Int
    let averageCheck: Double
    let averageOccupancy: Double
    let serviceTotals: [AnalyticsDistributionItem]
    let staffTotals: [AnalyticsDistributionItem]
    let statusTotals: [AnalyticsDistributionItem]
    let clientSegments: AnalyticsClientSegments
    let chartSeries: [AnalyticsBucket]
}

@MainActor
private final class AnalyticsStore: ObservableObject {
    @Published var draftFilters: AnalyticsFilters
    @Published var appliedFilters: AnalyticsFilters
    @Published var chartMode: AnalyticsChartMode = .revenue
    @Published private(set) var staff: [MariAPIClient.StaffRecord] = []
    @Published private(set) var appointments: [MariAPIClient.AppointmentRecord] = []
    @Published private(set) var overview: MariAPIClient.AnalyticsOverviewPayload?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""
    @Published private(set) var syncState: AnalyticsSyncState = .idle
    @Published private(set) var syncMessage = ""

    private let apiClient: MariAPIClient
    private var hasLoaded = false

    init(apiClient: MariAPIClient) {
        let defaults = AnalyticsFilters.makeDefault()
        self.apiClient = apiClient
        self.draftFilters = defaults
        self.appliedFilters = defaults
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            async let staffTask = fetchAllStaff()
            async let appointmentsTask = fetchAllAppointments()
            let (staffResponse, appointmentResponse) = try await (staffTask, appointmentsTask)

            staff = staffResponse
            appointments = appointmentResponse
            await syncOverview(filters: appliedFilters)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func applyFilters() async {
        appliedFilters = normalized(filters: draftFilters)
        await syncOverview(filters: appliedFilters)
    }

    private func fetchAllStaff() async throws -> [MariAPIClient.StaffRecord] {
        var page = 1
        let limit = 200
        var rows: [MariAPIClient.StaffRecord] = []

        while page <= 20 {
            let payload = try await apiClient.listStaff(
                page: page,
                limit: limit,
                role: nil,
                isActive: nil,
                employmentStatus: "all",
                search: nil
            )
            rows.append(contentsOf: payload.items)
            if payload.items.count < limit { break }
            page += 1
        }

        return rows
            .filter { $0.role != "OWNER" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fetchAllAppointments() async throws -> [MariAPIClient.AppointmentRecord] {
        var page = 1
        let limit = 200
        var rows: [MariAPIClient.AppointmentRecord] = []

        while page <= 40 {
            let payload = try await apiClient.listAppointments(page: page, limit: limit)
            rows.append(contentsOf: payload.items)
            if payload.items.count < limit { break }
            page += 1
        }

        return rows.sorted { $0.startAt < $1.startAt }
    }

    private func syncOverview(filters: AnalyticsFilters) async {
        syncState = .loading
        syncMessage = "Синхронизация API аналитики..."

        do {
            overview = try await apiClient.getAnalyticsOverview(
                from: filters.from.apiDateString,
                to: filters.to.apiDateString,
                masterId: filters.staffID.isEmpty ? nil : filters.staffID
            )
            syncState = .success
            syncMessage = "Серверная аналитика синхронизирована"
        } catch {
            overview = nil
            syncState = .error
            syncMessage = "API аналитики недоступен, расчеты построены локально"
        }
    }

    private func normalized(filters: AnalyticsFilters) -> AnalyticsFilters {
        let from = Calendar.analytics.startOfDay(for: min(filters.from, filters.to))
        let to = Calendar.analytics.startOfDay(for: max(filters.from, filters.to))
        return AnalyticsFilters(from: from, to: to, position: filters.position, staffID: filters.staffID)
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct AnalyticsScreen: View {
    let sessionStore: AppSessionStore

    @StateObject private var store: AnalyticsStore

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        _store = StateObject(wrappedValue: AnalyticsStore(apiClient: sessionStore.api))
    }

    private var activeStaff: [MariAPIClient.StaffRecord] {
        store.staff.filter { $0.isActive && $0.deletedAt == nil }
    }

    private var positionOptions: [String] {
        Array(Set(activeStaff.compactMap { $0.position?.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var staffOptions: [MariAPIClient.StaffRecord] {
        let base = store.draftFilters.position == "all"
            ? activeStaff
            : activeStaff.filter { ($0.position?.name ?? "") == store.draftFilters.position }
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var snapshot: AnalyticsSnapshot {
        buildSnapshot(
            appointments: store.appointments,
            staff: activeStaff,
            filters: store.appliedFilters,
            chartMode: store.chartMode
        )
    }

    private var isInitialLoading: Bool {
        store.isLoading && store.staff.isEmpty && store.appointments.isEmpty && store.overview == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isInitialLoading {
                    AnalyticsInitialSkeleton()
                } else {
                    AnalyticsHeader(
                        isRefreshing: store.isLoading,
                        onRefresh: { Task { await store.reload() } }
                    )

                    AnalyticsFiltersCard(
                        draftFilters: $store.draftFilters,
                        positions: positionOptions,
                        staff: staffOptions,
                        syncState: store.syncState,
                        syncMessage: store.syncMessage,
                        onApply: { Task { await store.applyFilters() } }
                    )

                    AnalyticsChartCard(
                        mode: $store.chartMode,
                        series: snapshot.chartSeries,
                        currencyMode: store.chartMode == .revenue
                    )

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                        AnalyticsMetricCard(
                            title: "Новые клиенты",
                            value: "\(snapshot.clientSegments.newClients)",
                            subtitle: "Первый визит в выбранном периоде",
                            accent: Color(hex: 0x9B7322)
                        )
                        AnalyticsMetricCard(
                            title: "Повторные",
                            value: "\(snapshot.clientSegments.repeatClients)",
                            subtitle: "Клиенты с повторными визитами",
                            accent: Color(hex: 0x20804A)
                        )
                        AnalyticsMetricCard(
                            title: "Потерянные",
                            value: "\(snapshot.clientSegments.lostClients)",
                            subtitle: "Без визитов больше 60 дней",
                            accent: Color(hex: 0xC06B54)
                        )
                        AnalyticsMetricCard(
                            title: "Всего записей",
                            value: "\(snapshot.totalAppointments)",
                            subtitle: "Записи в выбранном периоде",
                            accent: MariPalette.ink
                        )
                        AnalyticsMetricCard(
                            title: "Отмененные",
                            value: "\(snapshot.cancelledAppointments)",
                            subtitle: "Статусы отмены и отказов",
                            accent: Color(hex: 0xC06B54)
                        )
                        AnalyticsMetricCard(
                            title: "Завершенные",
                            value: "\(snapshot.completedAppointments)",
                            subtitle: "Arrived, Done, Completed",
                            accent: Color(hex: 0x20804A)
                        )
                        AnalyticsMetricCard(
                            title: "В ожидании",
                            value: "\(snapshot.pendingAppointments)",
                            subtitle: "Ожидание и подтвержденные",
                            accent: Color(hex: 0x2D5FD6)
                        )
                        AnalyticsMetricCard(
                            title: "Средняя загрузка",
                            value: "\(snapshot.averageOccupancy.formattedPercent)",
                            subtitle: "По рабочему окну 10:00–18:00",
                            accent: Color(hex: 0x2D5FD6)
                        )
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                        AnalyticsMetricCard(
                            title: "Выручка",
                            value: snapshot.totalRevenue.analyticsMoney,
                            subtitle: "Все услуги за период",
                            accent: Color(hex: 0x9B7322)
                        )
                        AnalyticsMetricCard(
                            title: "Оплачено",
                            value: snapshot.totalPaid.analyticsMoney,
                            subtitle: "Сумма оплаченных визитов",
                            accent: Color(hex: 0x20804A)
                        )
                        AnalyticsMetricCard(
                            title: "Средний чек",
                            value: snapshot.averageCheck.analyticsMoney,
                            subtitle: "Выручка / количество записей",
                            accent: MariPalette.ink
                        )
                        AnalyticsMetricCard(
                            title: "API overview",
                            value: overviewValue,
                            subtitle: overviewSubtitle,
                            accent: overviewAccent
                        )
                    }

                    AnalyticsDonutCard(
                        title: "Услуги",
                        total: snapshot.serviceTotals.reduce(0) { $0 + $1.value }.analyticsMoney,
                        items: snapshot.serviceTotals,
                        formatter: { $0.analyticsMoney }
                    )

                    AnalyticsDonutCard(
                        title: "Сотрудники",
                        total: snapshot.staffTotals.reduce(0) { $0 + $1.value }.analyticsMoney,
                        items: snapshot.staffTotals,
                        formatter: { $0.analyticsMoney }
                    )

                    AnalyticsDonutCard(
                        title: "Статусы визитов",
                        total: "\(Int(snapshot.statusTotals.reduce(0) { $0 + $1.value }))",
                        items: snapshot.statusTotals,
                        formatter: { "\(Int($0))" }
                    )

                    if !store.errorMessage.isEmpty {
                        AnalyticsErrorCard(message: store.errorMessage)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadIfNeeded()
        }
    }

    private var overviewValue: String {
        if let revenue = store.overview?.money?.revenue {
            return revenue.analyticsMoney
        }
        switch store.syncState {
        case .success: return "OK"
        case .loading: return "..."
        case .error, .idle: return "Локально"
        }
    }

    private var overviewSubtitle: String {
        store.syncMessage.isEmpty ? "Статус серверной аналитики" : store.syncMessage
    }

    private var overviewAccent: Color {
        switch store.syncState {
        case .success: return Color(hex: 0x20804A)
        case .loading: return Color(hex: 0x2D5FD6)
        case .error, .idle: return Color(hex: 0xC06B54)
        }
    }
}

private struct AnalyticsHeader: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Аналитика")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            Spacer()

            Button {
                onRefresh()
            } label: {
                Image(systemName: isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), value: isRefreshing)
            }
            .buttonStyle(.plain)
            .frame(width: 28)
        }
        .padding(.top, 8)
    }
}

private struct AnalyticsFiltersCard: View {
    @Binding var draftFilters: AnalyticsFilters
    let positions: [String]
    let staff: [MariAPIClient.StaffRecord]
    let syncState: AnalyticsSyncState
    let syncMessage: String
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Основные показатели")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            HStack(spacing: 10) {
                AnalyticsDateField(title: "С", date: $draftFilters.from)
                AnalyticsDateField(title: "По", date: $draftFilters.to)
            }

            VStack(spacing: 10) {
                AnalyticsPickerRow(
                    title: "Должность",
                    selection: $draftFilters.position,
                    options: [("all", "Все должности")] + positions.map { ($0, $0) }
                )

                AnalyticsPickerRow(
                    title: "Сотрудник",
                    selection: $draftFilters.staffID,
                    options: [("", "Все сотрудники")] + staff.map { ($0.id, $0.name) }
                )
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(syncTint.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: syncIcon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(syncTint)
                    }

                Text(syncMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onApply) {
                Text("Показать")
                    .font(.headline.weight(.black))
                    .foregroundStyle(MariPalette.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(MariPalette.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(AnalyticsCardBackground())
    }

    private var syncTint: Color {
        switch syncState {
        case .success: Color(hex: 0x20804A)
        case .loading: Color(hex: 0x2D5FD6)
        case .error, .idle: Color(hex: 0xC06B54)
        }
    }

    private var syncIcon: String {
        switch syncState {
        case .success: "checkmark"
        case .loading: "arrow.clockwise"
        case .error, .idle: "exclamationmark"
        }
    }
}

private struct AnalyticsInitialSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MariSkeletonCircle(size: 28)
                Spacer()
                MariSkeletonBlock(width: 142, height: 30, cornerRadius: 12)
                Spacer()
                MariSkeletonCircle(size: 42)
            }

            MariSkeletonBlock(height: 164, cornerRadius: 24)
            MariSkeletonBlock(height: 260, cornerRadius: 24)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(0..<8, id: \.self) { _ in
                    MariSkeletonBlock(height: 124, cornerRadius: 24)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    MariSkeletonBlock(height: 124, cornerRadius: 24)
                }
            }

            ForEach(0..<3, id: \.self) { _ in
                MariSkeletonBlock(height: 208, cornerRadius: 24)
            }
        }
    }
}

private struct AnalyticsDateField: View {
    let title: String
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            DatePicker(
                "",
                selection: $date,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalyticsPickerRow: View {
    let title: String
    @Binding var selection: String
    let options: [(value: String, label: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            Menu {
                ForEach(options, id: \.value) { option in
                    Button(option.label) {
                        selection = option.value
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(options.first(where: { $0.value == selection })?.label ?? options.first?.label ?? "Выбрать")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.ink)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MariPalette.softInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AnalyticsChartCard: View {
    @Binding var mode: AnalyticsChartMode
    let series: [AnalyticsBucket]
    let currencyMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Динамика")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            HStack(spacing: 8) {
                ForEach(AnalyticsChartMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(mode == item ? MariPalette.ink : MariPalette.softInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(mode == item ? MariPalette.accent : .white.opacity(0.8))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.black.opacity(mode == item ? 0 : 0.08), lineWidth: mode == item ? 0 : 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            AnalyticsLineChart(series: series, currencyMode: currencyMode)
                .frame(height: 220)
        }
        .padding(18)
        .background(AnalyticsCardBackground())
    }
}

private struct AnalyticsLineChart: View {
    let series: [AnalyticsBucket]
    let currencyMode: Bool

    var body: some View {
        GeometryReader { proxy in
            let points = polylinePoints(in: proxy.size)
            let visibleLabels = pickVisibleLabels()

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<4, id: \.self) { index in
                        let y = CGFloat(index) / 3 * (proxy.size.height - 42)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(Color.black.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                    }

                    if points.count > 1 {
                        Path { path in
                            path.move(to: points[0])
                            points.dropFirst().forEach { path.addLine(to: $0) }
                        }
                        .stroke(MariPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }

                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(MariPalette.accent)
                            .frame(width: 10, height: 10)
                            .position(point)
                            .overlay(alignment: .top) {
                                if series.indices.contains(index) {
                                    Text(formattedValue(series[index].value))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(MariPalette.ink)
                                        .offset(y: -18)
                                }
                            }
                    }
                }
                .frame(height: proxy.size.height - 42)

                HStack {
                    ForEach(visibleLabels) { item in
                        Text(item.shortLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MariPalette.softInk)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 42)
            }
        }
    }

    private func polylinePoints(in size: CGSize) -> [CGPoint] {
        guard !series.isEmpty else { return [] }
        let maxValue = max(series.map(\.value).max() ?? 0, 1)
        let innerHeight = max(1, size.height - 64)
        let verticalPadding: CGFloat = 18

        return series.enumerated().map { index, item in
            let x: CGFloat
            if series.count == 1 {
                x = size.width / 2
            } else {
                x = CGFloat(index) / CGFloat(series.count - 1) * max(size.width - 12, 1) + 6
            }

            let ratio = item.value / maxValue
            let y = verticalPadding + (1 - ratio) * max(innerHeight - verticalPadding * 2, 1)
            return CGPoint(x: x, y: y)
        }
    }

    private func pickVisibleLabels() -> [AnalyticsBucket] {
        if series.count <= 6 {
            return series
        }

        let step = max(1, (series.count - 1) / 5)
        var indices = Set([0, series.count - 1])
        var index = step
        while index < series.count - 1 {
            indices.insert(index)
            index += step
        }

        return indices.sorted().compactMap { series.indices.contains($0) ? series[$0] : nil }
    }

    private func formattedValue(_ value: Double) -> String {
        currencyMode ? value.analyticsMoney : "\(Int(value.rounded()))"
    }
}

private struct AnalyticsMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(MariPalette.softInk)

            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(accent)

            Text(subtitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
                .lineLimit(3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AnalyticsCardBackground())
    }
}

private struct AnalyticsDonutCard: View {
    let title: String
    let total: String
    let items: [AnalyticsDistributionItem]
    let formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(MariPalette.softInk)

                    Text(total)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(MariPalette.ink)
                }

                Spacer()

                AnalyticsDonutRing(items: items)
                    .frame(width: 88, height: 88)
            }

            if items.isEmpty {
                Text("Недостаточно данных")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 10, height: 10)

                            Text(item.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(MariPalette.softInk)
                                .lineLimit(1)

                            Spacer()

                            Text(formatter(item.value))
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(MariPalette.ink)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(AnalyticsCardBackground())
    }
}

private struct AnalyticsDonutRing: View {
    let items: [AnalyticsDistributionItem]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.06), lineWidth: 14)

            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 52, height: 52)
        }
    }

    private var segments: [(start: Double, end: Double, color: Color)] {
        let total = items.reduce(0) { $0 + max($1.value, 0) }
        guard total > 0 else { return [] }

        var current = 0.0
        return items.map { item in
            let start = current
            current += item.value / total
            return (start, min(current, 1), item.color)
        }
    }
}

private struct AnalyticsErrorCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(hex: 0xB56A58))

            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(hex: 0x8A5245))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: 0xF9E7E1))
        )
    }
}

private struct AnalyticsCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.white.opacity(0.84))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 8)
    }
}

private func buildSnapshot(
    appointments: [MariAPIClient.AppointmentRecord],
    staff: [MariAPIClient.StaffRecord],
    filters: AnalyticsFilters,
    chartMode: AnalyticsChartMode
) -> AnalyticsSnapshot {
    let staffByID = Dictionary(uniqueKeysWithValues: staff.map { ($0.id, $0) })
    let staffByName = Dictionary(uniqueKeysWithValues: staff.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0) })
    let from = Calendar.analytics.startOfDay(for: filters.from)
    let to = endOfDay(filters.to)

    func matchesStaffFilters(_ item: MariAPIClient.AppointmentRecord) -> Bool {
        let byID = staffByID[item.staff.id]
        let byName = staffByName[item.staff.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        let row = byID ?? byName

        if !filters.staffID.isEmpty, row?.id != filters.staffID, item.staff.id != filters.staffID {
            return false
        }

        if filters.position != "all" {
            let position = row?.position?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if position != filters.position {
                return false
            }
        }

        return true
    }

    let filteredAppointments = appointments.filter { item in
        item.startAt >= from && item.startAt <= to && matchesStaffFilters(item)
    }

    let allRelevantAppointments = appointments.filter { item in
        item.startAt <= to && matchesStaffFilters(item)
    }

    let filteredStaffCount: Int = {
        let base = filters.position == "all"
            ? staff.filter(\.isActive)
            : staff.filter { $0.isActive && ($0.position?.name ?? "") == filters.position }
        if !filters.staffID.isEmpty {
            return max(1, base.filter { $0.id == filters.staffID }.count)
        }
        return max(1, base.count)
    }()

    let totalRevenue = filteredAppointments.reduce(0.0) { $0 + appointmentAmount($1) }
    let totalPaid = filteredAppointments.reduce(0.0) { $0 + max($1.payment.paidAmount, 0) }
    let totalAppointments = filteredAppointments.count
    let cancelledAppointments = filteredAppointments.filter { isCancelledStatus($0.status) }.count
    let completedAppointments = filteredAppointments.filter { isCompletedStatus($0.status) }.count
    let pendingRaw = totalAppointments - cancelledAppointments - completedAppointments
    let pendingAppointments = pendingRaw > 0 ? pendingRaw : 0
    let averageCheck = totalAppointments > 0 ? totalRevenue / Double(totalAppointments) : 0

    let totalBookedMinutes = filteredAppointments.reduce(0.0) { $0 + appointmentDurationMinutes($1) }
    let occupancyDenominator = Double(daysBetweenInclusive(from: from, to: to) * filteredStaffCount * 8 * 60)
    let averageOccupancy = occupancyDenominator > 0 ? roundValue((totalBookedMinutes / occupancyDenominator) * 100.0, digits: 1) : 0

    let serviceTotals = buildDistribution(
        values: Dictionary(grouping: filteredAppointments, by: { $0.services.first?.name ?? "Без услуги" })
            .mapValues { $0.reduce(0) { $0 + appointmentAmount($1) } },
        moneyMode: true
    )

    let staffTotals = buildDistribution(
        values: Dictionary(grouping: filteredAppointments, by: { $0.staff.name.isEmpty ? "Без сотрудника" : $0.staff.name })
            .mapValues { $0.reduce(0) { $0 + appointmentAmount($1) } },
        moneyMode: true
    )

    let statusTotals = buildDistribution(
        values: Dictionary(grouping: filteredAppointments, by: { statusLabel($0.status) })
            .mapValues { Double($0.count) },
        moneyMode: false
    )

    let clientSegments = buildClientSegments(appointments: allRelevantAppointments, from: from, to: to)
    let chartSeries = buildBuckets(
        from: from,
        to: to,
        appointments: filteredAppointments,
        mode: chartMode,
        staffCount: filteredStaffCount
    )

    return AnalyticsSnapshot(
        filteredAppointments: filteredAppointments,
        allRelevantAppointments: allRelevantAppointments,
        filteredStaffCount: filteredStaffCount,
        totalRevenue: totalRevenue,
        totalPaid: totalPaid,
        totalAppointments: totalAppointments,
        cancelledAppointments: cancelledAppointments,
        completedAppointments: completedAppointments,
        pendingAppointments: pendingAppointments,
        averageCheck: averageCheck,
        averageOccupancy: averageOccupancy,
        serviceTotals: serviceTotals,
        staffTotals: staffTotals,
        statusTotals: statusTotals,
        clientSegments: clientSegments,
        chartSeries: chartSeries
    )
}

private func buildDistribution(values: [String: Double], moneyMode: Bool) -> [AnalyticsDistributionItem] {
    let palette: [Color] = [
        MariPalette.accent,
        MariPalette.ink,
        Color(hex: 0x4C84FF),
        Color(hex: 0x79C8A8),
        Color(hex: 0xF39A5C),
        Color(hex: 0xC7CEDA),
    ]

    return values
        .sorted { $0.value > $1.value }
        .prefix(6)
        .enumerated()
        .map { index, item in
            AnalyticsDistributionItem(
                label: item.key,
                value: moneyMode ? roundValue(item.value, digits: 0) : item.value,
                color: palette[index % palette.count]
            )
        }
}

private func buildClientSegments(
    appointments: [MariAPIClient.AppointmentRecord],
    from: Date,
    to: Date
) -> AnalyticsClientSegments {
    let groups = Dictionary(grouping: appointments, by: clientKey)
    let lostBoundary = Calendar.analytics.date(byAdding: .day, value: -60, to: Calendar.analytics.startOfDay(for: to)) ?? to

    var newClients = 0
    var repeatClients = 0
    var lostClients = 0

    for items in groups.values {
        let sorted = items.sorted { $0.startAt < $1.startAt }
        let firstVisit = sorted.first?.startAt
        let lastVisit = sorted.last?.startAt
        let hasVisitInPeriod = sorted.contains { $0.startAt >= from && $0.startAt <= to }

        if hasVisitInPeriod {
            if let firstVisit, firstVisit >= from && firstVisit <= to {
                newClients += 1
            } else {
                repeatClients += 1
            }
        }

        if let lastVisit, lastVisit < lostBoundary {
            lostClients += 1
        }
    }

    return AnalyticsClientSegments(newClients: newClients, repeatClients: repeatClients, lostClients: lostClients)
}

private func buildBuckets(
    from: Date,
    to: Date,
    appointments: [MariAPIClient.AppointmentRecord],
    mode: AnalyticsChartMode,
    staffCount: Int
) -> [AnalyticsBucket] {
    let totalDays = daysBetweenInclusive(from: from, to: to)
    let bucketType: String = totalDays > 62 ? "month" : (totalDays > 24 ? "week" : "day")
    var buckets: [(id: String, label: String, shortLabel: String, start: Date, end: Date, days: Int, raw: Double)] = []

    if bucketType == "month" {
        var cursor = Calendar.analytics.date(from: Calendar.analytics.dateComponents([.year, .month], from: from)) ?? from
        while cursor <= to {
            let start = Calendar.analytics.date(from: Calendar.analytics.dateComponents([.year, .month], from: cursor)) ?? cursor
            let monthRange = Calendar.analytics.range(of: .day, in: .month, for: cursor)
            let end = Calendar.analytics.date(bySettingHour: 23, minute: 59, second: 59, of: Calendar.analytics.date(byAdding: .day, value: (monthRange?.count ?? 1) - 1, to: start) ?? start) ?? start
            let boundedStart = max(start, from)
            let boundedEnd = min(end, to)
            buckets.append((
                id: "\(Calendar.analytics.component(.year, from: cursor))-\(Calendar.analytics.component(.month, from: cursor))",
                label: cursor.formatted(.dateTime.month(.wide).year().locale(MariLocale.ru)),
                shortLabel: cursor.formatted(.dateTime.month(.abbreviated).locale(MariLocale.ru)),
                start: boundedStart,
                end: boundedEnd,
                days: daysBetweenInclusive(from: boundedStart, to: boundedEnd),
                raw: 0
            ))
            cursor = Calendar.analytics.date(byAdding: .month, value: 1, to: start) ?? to.addingTimeInterval(1)
        }
    } else if bucketType == "week" {
        var cursor = startOfWeek(from)
        while cursor <= to {
            let boundedStart = max(cursor, from)
            let rawEnd = Calendar.analytics.date(byAdding: .day, value: 6, to: cursor) ?? cursor
            let boundedEnd = min(endOfDay(rawEnd), to)
            buckets.append((
                id: boundedStart.apiDateString,
                label: boundedStart.formatted(.dateTime.day().month(.abbreviated).locale(MariLocale.ru)),
                shortLabel: boundedStart.formatted(.dateTime.day().month(.twoDigits)),
                start: boundedStart,
                end: boundedEnd,
                days: daysBetweenInclusive(from: boundedStart, to: boundedEnd),
                raw: 0
            ))
            cursor = Calendar.analytics.date(byAdding: .day, value: 7, to: cursor) ?? to.addingTimeInterval(1)
        }
    } else {
        var cursor = Calendar.analytics.startOfDay(for: from)
        while cursor <= to {
            buckets.append((
                id: cursor.apiDateString,
                label: cursor.formatted(.dateTime.day().month(.abbreviated).locale(MariLocale.ru)),
                shortLabel: cursor.formatted(.dateTime.day().month(.twoDigits)),
                start: cursor,
                end: endOfDay(cursor),
                days: 1,
                raw: 0
            ))
            cursor = Calendar.analytics.date(byAdding: .day, value: 1, to: cursor) ?? to.addingTimeInterval(1)
        }
    }

    for item in appointments {
        guard let index = buckets.firstIndex(where: { item.startAt >= $0.start && item.startAt <= $0.end }) else {
            continue
        }
        switch mode {
        case .revenue:
            buckets[index].raw += appointmentAmount(item)
        case .appointments:
            buckets[index].raw += 1
        case .occupancy:
            buckets[index].raw += appointmentDurationMinutes(item)
        }
    }

    return buckets.map { bucket in
        let value: Double
        switch mode {
        case .occupancy:
            let denominator = Double(max(1, bucket.days * staffCount * 8 * 60))
            value = denominator > 0 ? roundValue((bucket.raw / denominator) * 100, digits: 1) : 0
        case .revenue:
            value = roundValue(bucket.raw, digits: 0)
        case .appointments:
            value = roundValue(bucket.raw, digits: 1)
        }
        return AnalyticsBucket(id: bucket.id, label: bucket.label, shortLabel: bucket.shortLabel, value: value)
    }
}

private func appointmentAmount(_ item: MariAPIClient.AppointmentRecord) -> Double {
    item.prices.finalTotal
}

private func appointmentDurationMinutes(_ item: MariAPIClient.AppointmentRecord) -> Double {
    max(0, item.endAt.timeIntervalSince(item.startAt) / 60)
}

private func isCancelledStatus(_ status: String) -> Bool {
    status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("CANCEL")
}

private func isCompletedStatus(_ status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalized == "ARRIVED" || normalized == "DONE" || normalized == "COMPLETED"
}

private func statusLabel(_ status: String) -> String {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if isCompletedStatus(normalized) {
        return "Завершен"
    }
    if normalized == "CONFIRMED" {
        return "Подтвержден"
    }
    if normalized == "NO_SHOW" {
        return "Не пришел"
    }
    if isCancelledStatus(normalized) {
        return "Отменен"
    }
    return "Ожидание"
}

private func clientKey(_ item: MariAPIClient.AppointmentRecord) -> String {
    if !item.client.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return item.client.id
    }
    let phone = normalizedPhone(item.client.phoneE164 ?? "")
    if !phone.isEmpty {
        return phone
    }
    return (item.client.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty
        ? item.id
        : (item.client.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func normalizedPhone(_ value: String) -> String {
    value.filter(\.isNumber)
}

private func daysBetweenInclusive(from: Date, to: Date) -> Int {
    max(1, Calendar.analytics.dateComponents([.day], from: Calendar.analytics.startOfDay(for: from), to: Calendar.analytics.startOfDay(for: to)).day ?? 0 + 1)
}

private func roundValue(_ value: Double, digits: Int) -> Double {
    let power = pow(10.0, Double(digits))
    return (value * power).rounded() / power
}

private func startOfWeek(_ date: Date) -> Date {
    let start = Calendar.analytics.startOfDay(for: date)
    let weekday = Calendar.analytics.component(.weekday, from: start)
    let isoWeekday = weekday == 1 ? 7 : weekday - 1
    return Calendar.analytics.date(byAdding: .day, value: -(isoWeekday - 1), to: start) ?? start
}

private func endOfDay(_ date: Date) -> Date {
    let start = Calendar.analytics.startOfDay(for: date)
    return Calendar.analytics.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
}

private extension Calendar {
    static var analytics: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.timeZone = .current
        return calendar
    }
}

private extension Date {
    var apiDateString: String {
        Self.analyticsDateFormatter.string(from: self)
    }

    private static let analyticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .analytics
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension Double {
    var analyticsMoney: String {
        MariFormatters.currency.string(from: NSNumber(value: self)) ?? "\(Int(self.rounded())) ₽"
    }

    var formattedPercent: String {
        "\(roundValue(self, digits: 1).formatted(.number.precision(.fractionLength(0...1))))%"
    }
}
