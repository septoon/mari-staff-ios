import SwiftUI
import Combine
import UIKit

private enum JournalFilter: String, CaseIterable, Identifiable {
    case all
    case mine
    case vip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .mine: "Мои"
        case .vip: "VIP"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "person.2"
        case .mine: "person"
        case .vip: "star"
        }
    }
}

private struct JournalMonthSection: Identifiable, Hashable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }
}

private struct JournalLayout {
    static let timeColumnWidth: CGFloat = 62
    static let staffColumnWidth: CGFloat = 144
    static let hourRowHeight: CGFloat = 76
}

private let journalCreateStepMinutes = 10

private struct JournalCreateSheetContext: Identifiable {
    let id = UUID()
    let selectedDate: Date
}

private struct JournalCreateDraft {
    var clientName = ""
    var clientPhone = ""
    var appointmentDate: Date
    var startTime: Date
    var durationMinutes: Int
    var staffID = ""
    var serviceID = ""

    init(selectedDate: Date) {
        let calendar = makeJournalCalendar()
        let day = calendar.startOfDay(for: selectedDate)
        appointmentDate = day
        startTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
        durationMinutes = 60
    }
}

@MainActor
private final class JournalStore: ObservableObject {
    @Published private(set) var appointments: [MariAPIClient.AppointmentRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""

    let currentStaffID: String?
    private let apiClient: MariAPIClient
    private var loadedRange: ClosedRange<Date>?

    init(apiClient: MariAPIClient, currentStaffID: String?) {
        self.apiClient = apiClient
        self.currentStaffID = currentStaffID
    }

    func loadIfNeeded(around date: Date) async {
        let targetRange = fetchRange(around: date)
        if let loadedRange, loadedRange.contains(date), loadedRange.lowerBound <= targetRange.lowerBound, loadedRange.upperBound >= targetRange.upperBound {
            return
        }
        await load(around: date, force: false)
    }

    func reload(around date: Date) async {
        await load(around: date, force: true)
    }

    private func load(around date: Date, force: Bool) async {
        let targetRange = fetchRange(around: date)
        if !force, let loadedRange, loadedRange == targetRange, !appointments.isEmpty {
            return
        }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            appointments = try await fetchAllAppointments(from: targetRange.lowerBound, to: targetRange.upperBound)
            loadedRange = targetRange
        } catch {
            if appointments.isEmpty {
                errorMessage = localizedMessage(for: error)
            } else {
                errorMessage = "Не удалось обновить журнал: \(localizedMessage(for: error))"
            }
        }
    }

    private func fetchAllAppointments(from: Date, to: Date) async throws -> [MariAPIClient.AppointmentRecord] {
        var page = 1
        var result: [MariAPIClient.AppointmentRecord] = []
        let fromString = isoDate(from)
        let toString = isoDate(to)

        while true {
            let response = try await apiClient.listAppointments(
                page: page,
                limit: 200,
                from: fromString,
                to: toString
            )
            result.append(contentsOf: response.items)
            if response.items.count < 200 {
                break
            }
            page += 1
        }

        return result
    }

    private func fetchRange(around date: Date) -> ClosedRange<Date> {
        let calendar = makeJournalCalendar()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let rangeStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let rangeEndBase = calendar.date(byAdding: .month, value: 3, to: monthStart) ?? monthStart
        let rangeEnd = calendar.date(byAdding: .day, value: -1, to: rangeEndBase) ?? rangeEndBase
        return calendar.startOfDay(for: rangeStart)...calendar.startOfDay(for: rangeEnd)
    }

    private func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

@MainActor
private final class JournalAppointmentDetailsStore: ObservableObject {
    @Published private(set) var client: MariAPIClient.ClientRecord?
    @Published private(set) var isLoading = false

    private let apiClient: MariAPIClient
    private var loadedClientID: String?

    init(apiClient: MariAPIClient) {
        self.apiClient = apiClient
    }

    func loadClientIfNeeded(id: String?) async {
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedID.isEmpty else {
            client = nil
            loadedClientID = nil
            return
        }
        guard loadedClientID != trimmedID else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            client = try await apiClient.getClient(id: trimmedID)
            loadedClientID = trimmedID
        } catch {
            client = nil
        }
    }
}

@MainActor
private final class JournalCreateStore: ObservableObject {
    @Published private(set) var staff: [MariAPIClient.StaffRecord] = []
    @Published private(set) var clients: [MariAPIClient.ClientRecord] = []
    @Published private(set) var servicesByStaffID: [String: [MariAPIClient.StaffServiceRecord]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage = ""

    private let apiClient: MariAPIClient
    private let session: StaffSession?
    private var isLoaded = false
    private var loadingServiceStaffIDs: Set<String> = []

    init(apiClient: MariAPIClient, session: StaffSession?) {
        self.apiClient = apiClient
        self.session = session
    }

    func loadIfNeeded(preferredStaffID: String?) async {
        guard !isLoaded else {
            if let preferredStaffID, !preferredStaffID.isEmpty {
                await ensureServicesLoaded(for: preferredStaffID)
            }
            return
        }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let staffRows = try await fetchCreateStaff()
            staff = staffRows
            clients = await fetchClients()
            isLoaded = true

            let trimmedPreferredStaffID = preferredStaffID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let initialStaffID = trimmedPreferredStaffID.isEmpty ? staffRows.first?.id : trimmedPreferredStaffID
            if let initialStaffID {
                await ensureServicesLoaded(for: initialStaffID)
            }
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func services(for staffID: String) -> [MariAPIClient.StaffServiceRecord] {
        servicesByStaffID[staffID] ?? []
    }

    func ensureServicesLoaded(for staffID: String) async {
        let trimmedStaffID = staffID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStaffID.isEmpty else { return }
        guard servicesByStaffID[trimmedStaffID] == nil else { return }
        guard !loadingServiceStaffIDs.contains(trimmedStaffID) else { return }

        loadingServiceStaffIDs.insert(trimmedStaffID)
        defer { loadingServiceStaffIDs.remove(trimmedStaffID) }

        do {
            let payload = try await apiClient.listStaffServices(id: trimmedStaffID)
            servicesByStaffID[trimmedStaffID] = payload.items
                .filter(\.isActive)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            servicesByStaffID[trimmedStaffID] = []
            if errorMessage.isEmpty {
                errorMessage = localizedMessage(for: error)
            }
        }
    }

    func createAppointment(draft: JournalCreateDraft) async throws -> MariAPIClient.AppointmentRecord {
        let startAt = journalCreateStartDate(for: draft)

        isSaving = true
        errorMessage = ""
        defer { isSaving = false }

        do {
            return try await apiClient.createAppointment(
                startAt: startAt,
                staffId: draft.staffID,
                serviceIDs: [draft.serviceID],
                clientName: draft.clientName.trimmingCharacters(in: .whitespacesAndNewlines),
                clientPhone: draft.clientPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            errorMessage = localizedMessage(for: error)
            throw error
        }
    }

    private func fetchCreateStaff() async throws -> [MariAPIClient.StaffRecord] {
        var items: [MariAPIClient.StaffRecord] = []

        if let masters = try? await apiClient.listStaff(
            page: 1,
            limit: 200,
            role: "MASTER",
            isActive: true,
            employmentStatus: "current"
        ) {
            items = masters.items
        }

        if items.isEmpty, let fallback = try? await apiClient.listStaff(
            page: 1,
            limit: 200,
            role: nil,
            isActive: true,
            employmentStatus: "current"
        ) {
            items = fallback.items
        }

        items = items
            .filter { $0.deletedAt == nil && $0.firedAt == nil && $0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let session = session?.staff, !items.contains(where: { $0.id == session.id }) {
            items.insert(makeCurrentStaffRecord(from: session), at: 0)
        }

        if items.isEmpty, let session = session?.staff {
            items = [makeCurrentStaffRecord(from: session)]
        }

        if items.isEmpty {
            throw MariAPIClient.APIClientError.invalidResponse
        }

        return items
    }

    private func fetchClients() async -> [MariAPIClient.ClientRecord] {
        guard let payload = try? await apiClient.listClients(page: 1, limit: 200) else {
            return []
        }

        return payload.items.sorted {
            ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }
    }

    private func makeCurrentStaffRecord(from session: StaffSession.StaffIdentity) -> MariAPIClient.StaffRecord {
        MariAPIClient.StaffRecord(
            id: session.id,
            name: session.name,
            role: session.role,
            phoneE164: session.phoneE164,
            email: session.email,
            receivesAllAppointmentNotifications: session.role == "OWNER",
            avatarUrl: nil,
            isActive: true,
            position: nil,
            hiredAt: nil,
            firedAt: nil,
            deletedAt: nil,
            permissions: session.permissions?.map {
                MariAPIClient.StaffRecord.PermissionSnapshot(code: $0, expiresAt: nil)
            }
        )
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct JournalScreen: View {
    let sessionStore: AppSessionStore

    @StateObject private var store: JournalStore
    @State private var filter: JournalFilter = .all
    @State private var selectedDate: Date
    @State private var isDatePickerPresented = false
    @State private var selectedAppointment: MariAPIClient.AppointmentRecord?
    @State private var createSheetContext: JournalCreateSheetContext?

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        let initialDate = makeJournalCalendar().startOfDay(for: .now)
        _selectedDate = State(initialValue: initialDate)
        _store = StateObject(
            wrappedValue: JournalStore(
                apiClient: sessionStore.api,
                currentStaffID: sessionStore.currentSession?.staff.id
            )
        )
    }

    private var calendar: Calendar {
        makeJournalCalendar()
    }

    private var filteredAppointments: [MariAPIClient.AppointmentRecord] {
        store.appointments
            .filter { appointment in
                guard calendar.isDate(appointment.startAt, inSameDayAs: selectedDate) else {
                    return false
                }
                switch filter {
                case .all:
                    return true
                case .mine:
                    return appointment.staff.id == store.currentStaffID
                case .vip:
                    return appointment.prices.finalTotal >= 4000
                }
            }
            .sorted { $0.startAt < $1.startAt }
    }

    private var visibleStaff: [MariAPIClient.AppointmentRecord.StaffSnapshot] {
        let dictionary = filteredAppointments.reduce(into: [String: MariAPIClient.AppointmentRecord.StaffSnapshot]()) { result, appointment in
            result[appointment.staff.id] = appointment.staff
        }

        return dictionary.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var appointmentsByDay: [Date: Int] {
        store.appointments.reduce(into: [:]) { result, appointment in
            let day = calendar.startOfDay(for: appointment.startAt)
            result[day, default: 0] += 1
        }
    }

    private var markedDays: [Date] {
        appointmentsByDay.keys.sorted()
    }

    private var gridStartHour: Int {
        guard let minDate = filteredAppointments.map(\.startAt).min() else { return 9 }
        return max(8, calendar.component(.hour, from: minDate))
    }

    private var gridEndHour: Int {
        guard let maxDate = filteredAppointments.map(\.endAt).max() else { return 20 }
        let hour = calendar.component(.hour, from: maxDate)
        let minute = calendar.component(.minute, from: maxDate)
        return min(23, max(gridStartHour + 7, minute == 0 ? hour : hour + 1))
    }

    private var hours: [Int] {
        Array(gridStartHour...gridEndHour)
    }

    private var weekDays: [Date] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start
            ?? calendar.startOfDay(for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var timelineWidth: CGFloat {
        CGFloat(max(visibleStaff.count, 1)) * JournalLayout.staffColumnWidth
    }

    private var isInitialLoading: Bool {
        store.isLoading && store.appointments.isEmpty
    }

    private var canViewClientPhone: Bool {
        mariHasPermissionAccess(sessionStore.currentSession, permissionCode: "VIEW_CLIENT_PHONE")
    }

    private var canCreateJournalAppointments: Bool {
        mariHasPermissionAccess(sessionStore.currentSession, permissionCode: "CREATE_JOURNAL_APPOINTMENTS")
    }

    private var timelineHeight: CGFloat {
        CGFloat(max(hours.count - 1, 0)) * JournalLayout.hourRowHeight
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MariBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .overlay(Color.black.opacity(0.08))

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if isInitialLoading {
                            JournalInitialSkeleton()
                        } else {
                            timeline
                        }
                    }
                    .padding(.bottom, 132)
                }
                .scrollIndicators(.hidden)
                .mariPullToRefresh {
                    await store.reload(around: selectedDate)
                }
            }

            VStack(alignment: .trailing, spacing: 12) {
                todayButton
                weekSwitcher
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadIfNeeded(around: selectedDate)
        }
        .task(id: selectedDate) {
            await store.loadIfNeeded(around: selectedDate)
        }
        .sheet(isPresented: $isDatePickerPresented) {
            JournalDatePickerSheet(
                selectedDate: $selectedDate,
                filter: filter,
                markedDates: markedDays,
                appointmentCountByDay: appointmentsByDay
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(item: $selectedAppointment) { appointment in
            JournalAppointmentDetailsSheet(
                appointment: appointment,
                appointments: store.appointments,
                apiClient: sessionStore.api,
                mediaBaseURL: sessionStore.configuration.baseURL,
                canViewClientPhone: canViewClientPhone
            ) { nextAppointment in
                selectedAppointment = nextAppointment
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(item: $createSheetContext) { context in
            JournalCreateSheet(
                apiClient: sessionStore.api,
                session: sessionStore.currentSession,
                selectedDate: context.selectedDate,
                preferredStaffID: store.currentStaffID
            ) { appointment in
                let nextDate = calendar.startOfDay(for: appointment.startAt)
                selectedDate = nextDate
                selectedAppointment = appointment
                Task {
                    await store.reload(around: nextDate)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                isDatePickerPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedDateLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MariPalette.ink)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MariPalette.accent)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Menu {
                Picker("Фильтр", selection: $filter) {
                    ForEach(JournalFilter.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: filter.systemImage)
                        .font(.footnote.weight(.bold))

                    Text(filter.title)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MariPalette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.black.opacity(0.06), lineWidth: 1)
                )
            }

            Button {
                Task { await store.reload(around: selectedDate) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MariPalette.ink)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.black.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var timeline: some View {
        HStack(alignment: .top, spacing: 0) {
            pinnedTimeColumn

            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    staffHeaderRow

                    ZStack(alignment: .topLeading) {
                        timelineGrid

                        ForEach(filteredAppointments) { appointment in
                            JournalAppointmentCard(
                                appointment: appointment,
                                x: xOffset(forStaffID: appointment.staff.id),
                                top: yPosition(for: appointment.startAt),
                                width: JournalLayout.staffColumnWidth,
                                height: appointmentHeight(for: appointment),
                                action: {
                                    selectedAppointment = appointment
                                }
                            )
                        }
                    }
                    .frame(width: timelineWidth, height: timelineHeight)
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.leading, 16)
    }

    private var staffHeaderRow: some View {
        HStack(spacing: 0) {
            if visibleStaff.isEmpty {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.42))
                    .overlay {
                        Text("Нет записей")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MariPalette.softInk)
                    }
                    .frame(width: JournalLayout.staffColumnWidth, height: 74)
            }

            ForEach(visibleStaff, id: \.id) { staff in
                JournalStaffColumnHeader(
                    staffName: staff.name,
                    isCurrentUser: staff.id == store.currentStaffID
                )
                .frame(width: JournalLayout.staffColumnWidth, height: 74)
            }
        }
        .padding(.top, 4)
    }

    private var pinnedTimeColumn: some View {
        VStack(spacing: 0) {
            createButtonCell

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hours.dropLast()), id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.body.weight(.medium))
                        .foregroundStyle(MariPalette.ink.opacity(0.82))
                        .frame(width: JournalLayout.timeColumnWidth, height: JournalLayout.hourRowHeight, alignment: .topLeading)
                }
            }
        }
    }

    private var createButtonCell: some View {
        Group {
            if canCreateJournalAppointments {
                Button {
                    MariHaptics.navigationTap()
                    createSheetContext = JournalCreateSheetContext(selectedDate: selectedDate)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(MariPalette.accent)
                        .frame(width: JournalLayout.timeColumnWidth, height: 74)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: JournalLayout.timeColumnWidth, height: 74)
            }
        }
        .padding(.top, 4)
    }

    private var timelineGrid: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(visibleStaff.count, 1), id: \.self) { _ in
                VStack(spacing: 0) {
                    ForEach(Array(hours.dropLast()), id: \.self) { _ in
                        Rectangle()
                            .fill(.clear)
                            .frame(height: JournalLayout.hourRowHeight)
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.08))
                                    .frame(height: 1)
                            }
                    }
                }
                .frame(width: JournalLayout.staffColumnWidth)
            }
        }
    }

    private var selectedDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = MariLocale.ru
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: selectedDate).lowercased()
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = MariLocale.ru
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date).lowercased()
    }

    private func xOffset(forStaffID staffID: String) -> CGFloat {
        guard let index = visibleStaff.firstIndex(where: { $0.id == staffID }) else {
            return 0
        }
        return CGFloat(index) * JournalLayout.staffColumnWidth
    }

    private func yPosition(for date: Date) -> CGFloat {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let hourDelta = CGFloat(hour - gridStartHour)
        return (hourDelta + CGFloat(minute) / 60) * JournalLayout.hourRowHeight
    }

    private func appointmentHeight(for appointment: MariAPIClient.AppointmentRecord) -> CGFloat {
        max(CGFloat(appointment.endAt.timeIntervalSince(appointment.startAt) / 3600) * JournalLayout.hourRowHeight - 4, 52)
    }
}

private extension JournalScreen {
    var todayButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                selectedDate = calendar.startOfDay(for: .now)
            }
        } label: {
            HStack(spacing: 10) {
                Text("Сегодня")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(MariPalette.ink)

                Image(systemName: "calendar")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    var weekSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(weekDays, id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
                let isWeekend = calendar.isDateInWeekend(day)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedDate = day
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(shortWeekday(day))
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(isSelected ? MariPalette.ink : (isWeekend ? Color(hex: 0xE46F16) : Color.white.opacity(0.7)))

                        Text("\(calendar.component(.day, from: day))")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(isSelected ? MariPalette.ink : (isWeekend ? Color(hex: 0xE46F16) : .white))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? MariPalette.accent : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct JournalStaffColumnHeader: View {
    let staffName: String
    let isCurrentUser: Bool

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(isCurrentUser ? MariPalette.plum.opacity(0.35) : Color(hex: 0xEEF2F8))
                .frame(width: 34, height: 34)
                .overlay {
                    Text(String(staffName.prefix(1)))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(MariPalette.softInk)
                }

            Text(staffName.components(separatedBy: " ").first ?? staffName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
                .lineLimit(1)
        }
    }
}

private struct JournalCreateSheet: View {
    let apiClient: MariAPIClient
    let session: StaffSession?
    let selectedDate: Date
    let preferredStaffID: String?
    let onCreated: (MariAPIClient.AppointmentRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: JournalCreateStore
    @State private var draft: JournalCreateDraft
    @State private var localErrorMessage = ""

    init(
        apiClient: MariAPIClient,
        session: StaffSession?,
        selectedDate: Date,
        preferredStaffID: String?,
        onCreated: @escaping (MariAPIClient.AppointmentRecord) -> Void
    ) {
        self.apiClient = apiClient
        self.session = session
        self.selectedDate = selectedDate
        self.preferredStaffID = preferredStaffID
        self.onCreated = onCreated
        _store = StateObject(wrappedValue: JournalCreateStore(apiClient: apiClient, session: session))
        _draft = State(initialValue: JournalCreateDraft(selectedDate: selectedDate))
    }

    private var availableServices: [MariAPIClient.StaffServiceRecord] {
        store.services(for: draft.staffID)
    }

    private var selectedStaff: MariAPIClient.StaffRecord? {
        store.staff.first(where: { $0.id == draft.staffID })
    }

    private var selectedService: MariAPIClient.StaffServiceRecord? {
        availableServices.first(where: { $0.id == draft.serviceID })
    }

    private var startAt: Date {
        journalCreateStartDate(for: draft)
    }

    private var endAt: Date {
        Calendar.current.date(byAdding: .minute, value: draft.durationMinutes, to: startAt) ?? startAt
    }

    private var isServicesLoading: Bool {
        !draft.staffID.isEmpty && store.servicesByStaffID[draft.staffID] == nil
    }

    private var durationOptions: [Int] {
        let presets = [30, 45, 60, 90, 120, 150, 180]
        let current = max(15, draft.durationMinutes)
        return (presets.contains(current) ? presets : (presets + [current])).sorted()
    }

    private var clientSuggestions: [MariAPIClient.ClientRecord] {
        let query = draft.clientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return store.clients
            .filter { ($0.name ?? "").lowercased().contains(query) }
            .sorted {
                let lhs = ($0.name ?? "").lowercased()
                let rhs = ($1.name ?? "").lowercased()
                let lhsStarts = lhs.hasPrefix(query)
                let rhsStarts = rhs.hasPrefix(query)
                if lhsStarts != rhsStarts {
                    return lhsStarts
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .prefix(5)
            .map { $0 }
    }

    private var createDisabledReason: String? {
        if isServicesLoading {
            return "Пока загружаются услуги выбранного сотрудника."
        }
        if draft.staffID.isEmpty {
            return "Нет доступных сотрудников для записи."
        }
        if availableServices.isEmpty {
            return "У выбранного сотрудника нет назначенных услуг."
        }
        return nil
    }

    private var errorMessage: String {
        localErrorMessage.isEmpty ? store.errorMessage : localErrorMessage
    }

    var body: some View {
        ZStack {
            MariBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if !errorMessage.isEmpty {
                        JournalCreateStatusCard(message: errorMessage, tint: Color(hex: 0xF3D0CA))
                    }

                    contactSection
                    sessionSection
                    serviceSection
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            await store.loadIfNeeded(preferredStaffID: preferredStaffID)
            await prepareInitialDraft()
        }
        .task(id: draft.staffID) {
            await syncServicesForSelectedStaff()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Журнал")
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk.opacity(0.9))
                .textCase(.uppercase)

            Text("Новая запись")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
        }
    }

    private var contactSection: some View {
        JournalCreateSectionCard(
            eyebrow: "Клиент",
            title: "Контакт для записи",
            description: "Минимальный набор для создания: имя и телефон. Остальное можно дополнить позже из карточки визита."
        ) {
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    JournalCreateTextField(
                        title: "Имя клиента",
                        placeholder: "Например, Анжелика",
                        text: $draft.clientName
                    )

                    if !clientSuggestions.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(clientSuggestions) { client in
                                Button {
                                    draft.clientName = client.name ?? draft.clientName
                                    draft.clientPhone = client.phoneE164
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(client.name ?? "Без имени")
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(MariPalette.ink)

                                            Text(client.phoneE164)
                                                .font(.footnote.weight(.medium))
                                                .foregroundStyle(MariPalette.softInk)
                                        }

                                        Spacer(minLength: 12)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(.white)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                JournalCreateTextField(
                    title: "Телефон",
                    placeholder: "+7 978 000 00 00",
                    text: $draft.clientPhone,
                    keyboardType: .phonePad
                )
            }
        }
    }

    private var sessionSection: some View {
        JournalCreateSectionCard(
            eyebrow: "Сеанс",
            title: "Дата, время и исполнитель",
            description: "Дата по умолчанию берётся из текущего дня журнала. При необходимости её можно поменять прямо здесь."
        ) {
            VStack(spacing: 14) {
                JournalCreateFieldShell(title: "Дата записи") {
                    DatePicker(
                        "",
                        selection: $draft.appointmentDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .environment(\.locale, MariLocale.ru)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(MariPalette.ink)
                }

                JournalCreateFieldShell(title: "Начало") {
                    DatePicker(
                        "",
                        selection: $draft.startTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .environment(\.locale, MariLocale.ru)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(MariPalette.ink)
                }

                JournalCreateFieldShell(title: "Сотрудник") {
                    Picker("", selection: $draft.staffID) {
                        ForEach(store.staff, id: \.id) { staff in
                            Text(staff.name).tag(staff.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(MariPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                JournalCreateFieldShell(title: "Длительность") {
                    Picker("", selection: $draft.durationMinutes) {
                        ForEach(durationOptions, id: \.self) { minutes in
                            Text("\(minutes) мин").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(MariPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var serviceSection: some View {
        JournalCreateSectionCard(
            eyebrow: "Услуга",
            title: "Что именно записываем",
            description: "Список пока общий. Если понадобится, следующим этапом можно ограничить услуги выбранным мастером."
        ) {
            VStack(spacing: 14) {
                if isServicesLoading {
                    JournalCreateStatusCard(message: "Загружаю услуги сотрудника...", tint: Color(hex: 0xEEF2F8))
                } else if availableServices.isEmpty {
                    JournalCreateStatusCard(message: "Для этого сотрудника услуги не назначены.", tint: Color(hex: 0xEEF2F8))
                } else {
                    JournalCreateFieldShell(title: "Услуга") {
                        Picker("", selection: $draft.serviceID) {
                            ForEach(availableServices, id: \.id) { service in
                                Text(service.name).tag(service.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(MariPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: draft.serviceID) { _, newValue in
                        guard let service = availableServices.first(where: { $0.id == newValue }) else { return }
                        draft.durationMinutes = max(15, Int(round(Double(service.durationSec) / 60)))
                    }
                }

                JournalCreatePreviewCard(
                    startAt: startAt,
                    endAt: endAt,
                    staffName: selectedStaff?.name ?? "Сотрудник не выбран",
                    serviceName: selectedService?.name ?? "Услуга не выбрана",
                    durationMinutes: draft.durationMinutes,
                    priceMax: selectedService?.priceMax
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                HStack(spacing: 8) {
                    if store.isSaving {
                        ProgressView()
                            .tint(MariPalette.ink)
                    } else {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                    }

                    Text(store.isSaving ? "Создаю запись..." : "Создать запись")
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(MariPalette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(createDisabledReason == nil ? MariPalette.accent : Color(hex: 0xE5E9F0))
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isSaving || createDisabledReason != nil)

            if let createDisabledReason {
                Text(createDisabledReason)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func prepareInitialDraft() async {
        guard draft.staffID.isEmpty else { return }

        let trimmedPreferredStaffID = preferredStaffID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialStaffID = trimmedPreferredStaffID.isEmpty ? (store.staff.first?.id ?? "") : trimmedPreferredStaffID
        guard !initialStaffID.isEmpty else { return }

        draft.staffID = initialStaffID
    }

    private func syncServicesForSelectedStaff() async {
        guard !draft.staffID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await store.ensureServicesLoaded(for: draft.staffID)
        let services = availableServices

        if services.isEmpty {
            draft.serviceID = ""
            return
        }

        guard services.contains(where: { $0.id == draft.serviceID }) else {
            let first = services[0]
            draft.serviceID = first.id
            draft.durationMinutes = max(15, Int(round(Double(first.durationSec) / 60)))
            return
        }
    }

    private func save() {
        localErrorMessage = ""

        let trimmedName = draft.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = draft.clientPhone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            localErrorMessage = "Укажите имя клиента."
            return
        }

        guard !trimmedPhone.isEmpty else {
            localErrorMessage = "Укажите телефон клиента."
            return
        }

        guard !draft.staffID.isEmpty, !draft.serviceID.isEmpty else {
            localErrorMessage = "Не выбраны сотрудник или услуга."
            return
        }

        guard journalCreateIsStartAligned(draft.startTime) else {
            localErrorMessage = "Время записи должно быть кратно \(journalCreateStepMinutes) минутам."
            return
        }

        Task {
            do {
                let created = try await store.createAppointment(draft: draft)
                onCreated(created)
                dismiss()
            } catch {
                localErrorMessage = store.errorMessage.isEmpty
                    ? ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    : store.errorMessage
            }
        }
    }
}

private struct JournalCreateSectionCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String

    private let content: Content

    init(
        eyebrow: String,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MariPalette.softInk.opacity(0.75))
                    .textCase(.uppercase)

                Text(title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(MariPalette.ink)

                Text(description)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.black.opacity(0.05), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

private struct JournalCreateFieldShell<Content: View>: View {
    let title: String

    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk.opacity(0.75))
                .textCase(.uppercase)

            content
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}

private struct JournalCreateTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        JournalCreateFieldShell(title: title) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(keyboardType == .phonePad ? .never : .words)
                .keyboardType(keyboardType)
                .foregroundStyle(MariPalette.ink)
        }
    }
}

private struct JournalCreateStatusCard: View {
    let message: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(MariPalette.softInk)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint)
        )
    }
}

private struct JournalCreatePreviewCard: View {
    let startAt: Date
    let endAt: Date
    let staffName: String
    let serviceName: String
    let durationMinutes: Int
    let priceMax: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Предпросмотр")
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk.opacity(0.75))
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar")
                        .foregroundStyle(MariPalette.softInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(startAt.formatted(.dateTime.day().month().year().locale(MariLocale.ru)))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)
                        Text("\(startAt.formatted(date: .omitted, time: .shortened))-\(endAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(MariPalette.softInk)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person")
                        .foregroundStyle(MariPalette.softInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(staffName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)
                        Text(serviceName)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(MariPalette.softInk)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock")
                        .foregroundStyle(MariPalette.softInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(durationMinutes) мин")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)
                        Text(previewPrice)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(MariPalette.softInk)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(hex: 0xF8FAFC))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }

    private var previewPrice: String {
        guard let priceMax, priceMax > 0 else {
            return "Стоимость можно уточнить позже"
        }
        return "До \(MariFormatters.money(Int(priceMax.rounded())))"
    }
}

private struct JournalInitialSkeleton: View {
    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MariSkeletonBlock(width: JournalLayout.timeColumnWidth, height: 74, cornerRadius: 16)

                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 6) {
                            MariSkeletonCircle(size: 34)
                            MariSkeletonBlock(width: 68, height: 12, cornerRadius: 6)
                        }
                        .frame(width: JournalLayout.staffColumnWidth, height: 74)
                    }
                }
                .padding(.top, 4)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<8, id: \.self) { _ in
                            MariSkeletonBlock(width: JournalLayout.timeColumnWidth - 10, height: 20, cornerRadius: 8)
                                .frame(width: JournalLayout.timeColumnWidth, height: JournalLayout.hourRowHeight, alignment: .topLeading)
                        }
                    }

                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(spacing: 10) {
                                ForEach(0..<4, id: \.self) { _ in
                                    MariSkeletonBlock(width: JournalLayout.staffColumnWidth - 16, height: 70, cornerRadius: 10)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 12)
                            .frame(width: JournalLayout.staffColumnWidth, height: 8 * JournalLayout.hourRowHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct JournalAppointmentCard: View {
    let appointment: MariAPIClient.AppointmentRecord
    let x: CGFloat
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    private var phoneText: String {
        appointment.client.phoneE164 ?? "Без телефона"
    }

    private var servicesText: String {
        appointment.services.map(\.name).joined(separator: "\n")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(timeRangeLabel(appointment.startAt, appointment.endAt))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 8, height: 8)
                }

                Text(appointment.client.name ?? "Без имени")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                    .lineLimit(2)

                Text(phoneText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MariPalette.ink.opacity(0.78))
                    .lineLimit(1)

                Text(servicesText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MariPalette.ink.opacity(0.74))
                    .lineLimit(4)
            }
            .padding(8)
            .frame(width: width - 8, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(statusAccentColor(appointment.status).opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .offset(x: x + 4, y: top + 2)
    }
}

private struct JournalAppointmentDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let appointment: MariAPIClient.AppointmentRecord
    let appointments: [MariAPIClient.AppointmentRecord]
    let mediaBaseURL: String
    let canViewClientPhone: Bool
    let onSelectAppointment: (MariAPIClient.AppointmentRecord) -> Void

    @StateObject private var detailStore: JournalAppointmentDetailsStore

    init(
        appointment: MariAPIClient.AppointmentRecord,
        appointments: [MariAPIClient.AppointmentRecord],
        apiClient: MariAPIClient,
        mediaBaseURL: String,
        canViewClientPhone: Bool,
        onSelectAppointment: @escaping (MariAPIClient.AppointmentRecord) -> Void
    ) {
        self.appointment = appointment
        self.appointments = appointments
        self.mediaBaseURL = mediaBaseURL
        self.canViewClientPhone = canViewClientPhone
        self.onSelectAppointment = onSelectAppointment
        _detailStore = StateObject(wrappedValue: JournalAppointmentDetailsStore(apiClient: apiClient))
    }

    private var clientName: String {
        resolvedClientName(detailStore.client, appointment: appointment)
    }

    private var clientPhone: String {
        detailStore.client?.phoneE164 ?? appointment.client.phoneE164 ?? ""
    }

    private var clientComment: String {
        let comment = detailStore.client?.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return comment.isEmpty ? "Комментарий не добавлен" : comment
    }

    private var clientEmail: String? {
        let email = detailStore.client?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? nil : email
    }

    private var clientAvatarURL: String? {
        detailStore.client?.avatarUrl
    }

    private var historyItems: [MariAPIClient.AppointmentRecord] {
        let key = appointmentClientKey(appointment)
        return appointments
            .filter { appointmentClientKey($0) == key }
            .sorted { lhs, rhs in
                if lhs.startAt == rhs.startAt {
                    return lhs.id > rhs.id
                }
                return lhs.startAt > rhs.startAt
            }
    }

    private var visitsCount: Int {
        historyItems.count
    }

    private var noShowCount: Int {
        historyItems.filter { normalizedJournalStatus($0.status) == "NO_SHOW" }.count
    }

    private var previousVisit: MariAPIClient.AppointmentRecord? {
        historyItems.first {
            $0.id != appointment.id && $0.startAt <= appointment.startAt
        }
    }

    private var daysSincePreviousVisit: Int? {
        guard let previousVisit else { return nil }
        let daySeconds: TimeInterval = 24 * 60 * 60
        return max(0, Int((appointment.startAt.timeIntervalSince(previousVisit.startAt) / daySeconds).rounded(.down)))
    }

    private var totalRevenue: Double {
        historyItems.reduce(0) { partial, item in
            partial + item.prices.finalTotal
        }
    }

    private var totalPaid: Double {
        historyItems.reduce(0) { partial, item in
            partial + max(item.payment.paidAmount, 0)
        }
    }

    private var appointmentDurationMinutes: Int {
        max(0, Int(appointment.endAt.timeIntervalSince(appointment.startAt) / 60))
    }

    private var remainingAmount: Double {
        max(appointment.prices.finalTotal - appointment.payment.paidAmount, 0)
    }

    private var paymentMethod: String {
        localizedPaymentMethod(appointment.payment.method)
    }

    private var paymentStatus: String {
        localizedPaymentStatus(appointment.payment.status)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    actionSection
                    appointmentSection
                    servicesSection
                    metricsSection
                    paymentSection
                    clientSection
                    historySection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Color(hex: 0xF7F4EF))
            .navigationTitle("Запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .task(id: appointment.id) {
            await detailStore.loadClientIfNeeded(id: appointment.client.id)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            JournalClientAvatarView(
                title: clientName,
                avatarURL: clientAvatarURL,
                mediaBaseURL: mediaBaseURL,
                size: 64
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(clientName)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(MariPalette.ink)
                    .lineLimit(2)

                if canViewClientPhone {
                    Text(clientPhone.isEmpty ? "Телефон не указан" : clientPhone)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                }

                HStack(spacing: 8) {
                    JournalStatusPill(title: localizedJournalStatus(appointment.status), tint: statusAccentColor(appointment.status))

                    if detailStore.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if canViewClientPhone, !clientPhone.isEmpty {
            HStack(spacing: 10) {
                if let callURL = URL(string: "tel:\(clientPhone)") {
                    Link(destination: callURL) {
                        JournalActionChip(title: "Позвонить", systemImage: "phone.fill")
                    }
                }
                if let smsURL = URL(string: "sms:\(clientPhone)") {
                    Link(destination: smsURL) {
                        JournalActionChip(title: "SMS", systemImage: "message.fill")
                    }
                }
                if let telegramURL = journalTelegramURL(for: clientPhone) {
                    Link(destination: telegramURL) {
                        JournalActionChip(title: "Telegram", systemImage: "paperplane.fill")
                    }
                }
            }
        }
    }

    private var appointmentSection: some View {
        JournalDetailSection(title: "Запись") {
            VStack(alignment: .leading, spacing: 12) {
                JournalDetailRow(title: "Дата", value: appointment.startAt.formatted(.dateTime.day().month(.wide).year().locale(MariLocale.ru)))
                JournalDetailRow(title: "Время", value: timeRangeLabel(appointment.startAt, appointment.endAt))
                JournalDetailRow(title: "Длительность", value: "\(appointmentDurationMinutes) мин")
                JournalDetailRow(title: "Мастер", value: appointment.staff.name)
                JournalDetailRow(title: "Создана", value: appointment.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(MariLocale.ru)))
                JournalDetailRow(title: "Обновлена", value: appointment.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(MariLocale.ru)))
            }
        }
    }

    private var servicesSection: some View {
        JournalDetailSection(title: "Услуги") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(appointment.services, id: \.id) { service in
                    JournalServiceRow(service: service)
                }
            }
        }
    }

    private var metricsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            JournalMetricTile(title: "Визиты", value: "\(visitsCount)", detail: noShowCount > 0 ? "\(noShowCount) неявок" : "Без неявок", tint: MariPalette.accent)
            JournalMetricTile(title: "Выручка", value: MariFormatters.money(Int(totalRevenue.rounded())), detail: "Оплачено \(MariFormatters.money(Int(totalPaid.rounded())))", tint: MariPalette.sky)
            JournalMetricTile(title: "К оплате", value: MariFormatters.money(Int(appointment.prices.finalTotal.rounded())), detail: "Осталось \(MariFormatters.money(Int(remainingAmount.rounded())))", tint: MariPalette.mint)
            JournalMetricTile(title: "С прошлого визита", value: daysSincePreviousVisit.map { "\($0) дн" } ?? "—", detail: previousVisit.map { $0.startAt.formatted(.dateTime.day().month(.abbreviated).locale(MariLocale.ru)) } ?? "Первый визит", tint: MariPalette.rose)
        }
    }

    private var paymentSection: some View {
        JournalDetailSection(title: "Оплата") {
            VStack(alignment: .leading, spacing: 12) {
                JournalDetailRow(title: "Статус", value: paymentStatus)
                JournalDetailRow(title: "Метод", value: paymentMethod)
                JournalDetailRow(title: "Оплачено", value: MariFormatters.money(Int(appointment.payment.paidAmount.rounded())))
                JournalDetailRow(title: "Скидка", value: MariFormatters.money(Int(appointment.prices.discountAmount.rounded())))
            }
        }
    }

    private var clientSection: some View {
        JournalDetailSection(title: "Клиент") {
            VStack(alignment: .leading, spacing: 12) {
                if let clientEmail {
                    JournalDetailRow(title: "Email", value: clientEmail)
                }
                JournalDetailRow(title: "Комментарий", value: clientComment, multiline: true)
            }
        }
    }

    private var historySection: some View {
        JournalDetailSection(title: "История клиента") {
            VStack(spacing: 10) {
                ForEach(historyItems) { item in
                    JournalHistoryRow(
                        appointment: item,
                        isActive: item.id == appointment.id,
                        canViewClientPhone: canViewClientPhone
                    ) {
                        onSelectAppointment(item)
                    }
                }
            }
        }
    }
}

private struct JournalClientAvatarView: View {
    let title: String
    let avatarURL: String?
    let mediaBaseURL: String
    let size: CGFloat

    private var resolvedURL: URL? {
        resolveJournalMediaURL(avatarURL, relativeTo: mediaBaseURL)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(Color(hex: 0xF0E8DA))

            if let resolvedURL {
                AsyncImage(url: resolvedURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(MariPalette.softInk)
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }

    private var placeholder: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: size * 0.36, weight: .black, design: .rounded))
            .foregroundStyle(MariPalette.ink)
    }
}

private struct JournalDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.black))
                .fontDesign(.rounded)
                .foregroundStyle(MariPalette.ink)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    )
            )
        }
    }
}

private struct JournalDetailRow: View {
    let title: String
    let value: String
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(MariPalette.softInk.opacity(0.72))
            Text(value)
                .font(.body.weight(.semibold))
                .foregroundStyle(MariPalette.ink)
                .lineLimit(multiline ? nil : 2)
        }
    }
}

private struct JournalMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(MariPalette.softInk.opacity(0.7))
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
            Text(detail)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint.opacity(0.22))
        )
    }
}

private struct JournalServiceRow: View {
    let service: MariAPIClient.AppointmentRecord.ServiceSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                Text("\(Int(service.durationSec / 60)) мин")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(MariFormatters.money(Int(service.priceWithDiscount.rounded())))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)

                if service.priceWithDiscount != service.price {
                    Text("без скидки \(MariFormatters.money(Int(service.price.rounded())))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                }
            }
        }
    }
}

private struct JournalActionChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.94))
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
            )
    }
}

private struct JournalStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.2))
            )
    }
}

private struct JournalHistoryRow: View {
    let appointment: MariAPIClient.AppointmentRecord
    let isActive: Bool
    let canViewClientPhone: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appointment.startAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(MariLocale.ru)))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MariPalette.ink)
                    Text(appointment.services.first?.name ?? "Без услуги")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                    if canViewClientPhone, let phone = appointment.client.phoneE164, !phone.isEmpty {
                        Text(phone)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MariPalette.softInk.opacity(0.88))
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(MariFormatters.money(Int(appointment.prices.finalTotal.rounded())))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MariPalette.ink)
                    JournalStatusPill(title: localizedJournalStatus(appointment.status), tint: statusAccentColor(appointment.status))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isActive ? MariPalette.accent.opacity(0.18) : Color(hex: 0xF7F8FB))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? MariPalette.accent.opacity(0.55) : Color.black.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct JournalDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedDate: Date
    let filter: JournalFilter
    let markedDates: [Date]
    let appointmentCountByDay: [Date: Int]

    private var calendar: Calendar {
        makeJournalCalendar()
    }

    private var months: [JournalMonthSection] {
        let referenceDates = markedDates + [selectedDate, .now]
        guard
            let minDate = referenceDates.min(),
            let maxDate = referenceDates.max()
        else {
            return []
        }

        let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: calendar.date(byAdding: .month, value: -1, to: minDate) ?? minDate)) ?? minDate
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: calendar.date(byAdding: .month, value: 3, to: maxDate) ?? maxDate)) ?? maxDate

        var result: [JournalMonthSection] = []
        var month = startMonth

        while month <= endMonth {
            result.append(
                JournalMonthSection(
                    year: calendar.component(.year, from: month),
                    month: calendar.component(.month, from: month) - 1
                )
            )
            month = calendar.date(byAdding: .month, value: 1, to: month) ?? endMonth.addingTimeInterval(1)
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(months) { month in
                            JournalCalendarMonthSection(
                                month: month,
                                selectedDate: selectedDate,
                                appointmentCountByDay: appointmentCountByDay,
                                calendar: calendar
                            ) { date in
                                selectedDate = date
                                dismiss()
                            }
                            .id(month.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .background(Color(hex: 0xF4F4F5))
                .onAppear {
                    DispatchQueue.main.async {
                        let monthID = JournalMonthSection(
                            year: calendar.component(.year, from: selectedDate),
                            month: calendar.component(.month, from: selectedDate) - 1
                        ).id
                        proxy.scrollTo(monthID, anchor: .top)
                    }
                }
            }
        }
        .background(Color(hex: 0xF4F4F5))
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MariPalette.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Text("Выберите дату")
                .font(.title3.weight(.bold))
                .foregroundStyle(MariPalette.ink)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Image(systemName: filter.systemImage)
                    .font(.footnote.weight(.bold))

                Text(filter.title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0xE9ECF1))
            )

            Image(systemName: "info.circle")
                .font(.headline)
                .foregroundStyle(MariPalette.softInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(hex: 0xF4F4F5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct JournalCalendarMonthSection: View {
    let month: JournalMonthSection
    let selectedDate: Date
    let appointmentCountByDay: [Date: Int]
    let calendar: Calendar
    let onSelect: (Date) -> Void

    private let weekSymbols = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]

    private var monthDate: Date {
        calendar.date(from: DateComponents(year: month.year, month: month.month + 1, day: 1)) ?? .now
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = MariLocale.ru
        formatter.setLocalizedDateFormatFromTemplate("LLLL")
        return formatter.string(from: monthDate).capitalized
    }

    private var monthGrid: [Date?] {
        let firstDay = monthDate
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstDay)?.count ?? 30
        let offset = (calendar.component(.weekday, from: firstDay) + 5) % 7
        var values = Array(repeating: Optional<Date>.none, count: offset)
        values += (1...daysInMonth).compactMap {
            calendar.date(from: DateComponents(year: month.year, month: month.month + 1, day: $0))
        }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(monthTitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 12) {
                ForEach(weekSymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk.opacity(0.58))
                }

                ForEach(Array(monthGrid.enumerated()), id: \.offset) { _, value in
                    if let value {
                        JournalCalendarDayButton(
                            date: value,
                            isSelected: calendar.isDate(value, inSameDayAs: selectedDate),
                            count: appointmentCountByDay[calendar.startOfDay(for: value), default: 0]
                        ) {
                            onSelect(value)
                        }
                    } else {
                        Color.clear
                            .frame(height: 38)
                    }
                }
            }
        }
    }
}

private struct JournalCalendarDayButton: View {
    let date: Date
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    private var markerColor: Color {
        switch count {
        case 0:
            return .clear
        case 1:
            return Color(hex: 0x38C95E)
        case 2:
            return Color(hex: 0xF0C63B)
        default:
            return Color(hex: 0xFF6B57)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? MariPalette.accent : .white)
                    .overlay {
                        Circle()
                            .stroke(Color(hex: 0xD4D8E0), lineWidth: isSelected ? 0 : 1.5)
                    }

                if count > 0 && !isSelected {
                    Circle()
                        .trim(from: 0.04, to: 0.28)
                        .stroke(
                            markerColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-48))
                }

                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? MariPalette.ink : MariPalette.softInk)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
    }
}

private func makeJournalCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "ru_RU")
    calendar.firstWeekday = 2
    return calendar
}

private func normalizedJournalStatus(_ status: String) -> String {
    status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private func statusAccentColor(_ status: String) -> Color {
    switch normalizedJournalStatus(status) {
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

private func timeRangeLabel(_ start: Date, _ end: Date) -> String {
    "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
}

private func localizedJournalStatus(_ status: String) -> String {
    switch normalizedJournalStatus(status) {
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

private func localizedPaymentStatus(_ status: String) -> String {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    switch normalized {
    case "PAID":
        return "Оплачено"
    case "PARTIAL", "PARTIALLY_PAID":
        return "Частично оплачено"
    case "REFUNDED":
        return "Возврат"
    case "PENDING", "UNPAID":
        return "Ожидает оплаты"
    default:
        return normalized.isEmpty ? "Не указан" : status
    }
}

private func localizedPaymentMethod(_ method: String?) -> String {
    let normalized = method?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    switch normalized {
    case "CASH":
        return "Наличные"
    case "CARD":
        return "Карта"
    case "SBP":
        return "СБП"
    case "TRANSFER":
        return "Перевод"
    default:
        return normalized.isEmpty ? "Не указан" : (method ?? "Не указан")
    }
}

private func appointmentClientKey(_ appointment: MariAPIClient.AppointmentRecord) -> String {
    let clientID = appointment.client.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clientID.isEmpty {
        return clientID
    }

    let phone = (appointment.client.phoneE164 ?? "").filter(\.isNumber)
    if !phone.isEmpty {
        return phone
    }

    let name = (appointment.client.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return name.isEmpty ? appointment.id : name
}

private func resolvedClientName(
    _ client: MariAPIClient.ClientRecord?,
    appointment: MariAPIClient.AppointmentRecord
) -> String {
    let detailedName = client?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !detailedName.isEmpty {
        return detailedName
    }

    let snapshotName = appointment.client.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return snapshotName.isEmpty ? "Клиент" : snapshotName
}

private func resolveJournalMediaURL(_ rawValue: String?, relativeTo baseURL: String) -> URL? {
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

private func journalTelegramURL(for phone: String) -> URL? {
    let digits = phone.filter(\.isNumber)
    guard !digits.isEmpty else { return nil }
    return URL(string: "tg://resolve?phone=\(digits)")
}

private func journalCreateStartDate(for draft: JournalCreateDraft) -> Date {
    let calendar = makeJournalCalendar()
    let dateComponents = calendar.dateComponents([.year, .month, .day], from: draft.appointmentDate)
    let timeComponents = calendar.dateComponents([.hour, .minute], from: draft.startTime)
    var components = DateComponents()
    components.year = dateComponents.year
    components.month = dateComponents.month
    components.day = dateComponents.day
    components.hour = timeComponents.hour
    components.minute = timeComponents.minute
    components.second = 0
    return calendar.date(from: components) ?? draft.appointmentDate
}

private func journalCreateIsStartAligned(_ date: Date) -> Bool {
    let calendar = makeJournalCalendar()
    let minute = calendar.component(.minute, from: date)
    return minute % journalCreateStepMinutes == 0
}

#Preview {
    JournalScreen(sessionStore: AppSessionStore(configuration: AppConfigurationStore()))
}
