import SwiftUI
import Combine

private struct ScheduleMonthTab: Identifiable, Hashable {
    let date: Date
    let isSelected: Bool

    var id: String { scheduleMonthKey(date) }
}

private struct ScheduleGridLayout {
    static let staffColumnWidth: CGFloat = 82
    static let dayColumnWidth: CGFloat = 46
    static let rowHeight: CGFloat = 64
    static let gap: CGFloat = 8
}

@MainActor
private final class ScheduleStore: ObservableObject {
    @Published private(set) var staff: [MariAPIClient.StaffRecord] = []
    @Published private(set) var scheduleByStaff: [String: [String: [MariAPIClient.WorkingHoursItem]]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""

    private let apiClient: MariAPIClient
    private let currentSession: StaffSession?
    private var loadedMonthKey: String?

    init(apiClient: MariAPIClient, session: StaffSession?) {
        self.apiClient = apiClient
        self.currentSession = session
    }

    func loadIfNeeded(for date: Date) async {
        let key = scheduleMonthKey(date)
        guard loadedMonthKey != key else { return }
        await load(for: date, force: false)
    }

    func reload(for date: Date) async {
        await load(for: date, force: true)
    }

    private func load(for date: Date, force: Bool) async {
        let key = scheduleMonthKey(date)
        if !force, loadedMonthKey == key, !staff.isEmpty {
            return
        }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let staffRows = try await fetchScheduleStaff()
            let monthStart = scheduleMonthStart(date)
            let monthEnd = scheduleMonthEnd(date)
            let from = scheduleISODate(monthStart)
            let to = scheduleISODate(monthEnd)

            let grouped = try await withThrowingTaskGroup(
                of: (String, [String: [MariAPIClient.WorkingHoursItem]]).self
            ) { group in
                for person in staffRows {
                    group.addTask { [apiClient] in
                        let response = try await apiClient.listWorkingHours(staffId: person.id, from: from, to: to)
                        let dates = Dictionary(grouping: response.items) { item in
                            item.date ?? from
                        }
                        return (person.id, dates)
                    }
                }

                var result: [String: [String: [MariAPIClient.WorkingHoursItem]]] = [:]
                for try await (staffID, items) in group {
                    result[staffID] = items
                }
                return result
            }

            staff = staffRows
            scheduleByStaff = grouped
            loadedMonthKey = key
        } catch {
            if staff.isEmpty {
                errorMessage = localizedMessage(for: error)
            } else {
                errorMessage = "Не удалось обновить график: \(localizedMessage(for: error))"
            }
        }
    }

    private func fetchScheduleStaff() async throws -> [MariAPIClient.StaffRecord] {
        let masters = try await apiClient.listStaff(
            page: 1,
            limit: 200,
            role: "MASTER",
            isActive: true,
            employmentStatus: "current"
        )

        var items = masters.items
            .filter(\.isActive)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if items.isEmpty {
            let fallback = try await apiClient.listStaff(
                page: 1,
                limit: 200,
                role: nil,
                isActive: true,
                employmentStatus: "current"
            )
            items = fallback.items
                .filter(\.isActive)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        if let session = currentSession?.staff, !items.contains(where: { $0.id == session.id }) {
            let current = MariAPIClient.StaffRecord(
                id: session.id,
                name: session.name,
                role: session.role,
                phoneE164: session.phoneE164,
                email: session.email,
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
            items.insert(current, at: 0)
        }

        return items
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct ScheduleScreen: View {
    let sessionStore: AppSessionStore

    @StateObject private var store: ScheduleStore
    @State private var selectedDate: Date
    @State private var isDatePickerPresented = false
    @State private var isEditAlertPresented = false

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        let initialDate = makeScheduleCalendar().startOfDay(for: .now)
        _selectedDate = State(initialValue: initialDate)
        _store = StateObject(
            wrappedValue: ScheduleStore(
                apiClient: sessionStore.api,
                session: sessionStore.currentSession
            )
        )
    }

    private var calendar: Calendar {
        makeScheduleCalendar()
    }

    private var weekDates: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start
            ?? calendar.startOfDay(for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var monthTabs: [ScheduleMonthTab] {
        (0..<5).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: scheduleMonthStart(selectedDate)) else {
                return nil
            }
            return ScheduleMonthTab(date: date, isSelected: calendar.isDate(date, equalTo: selectedDate, toGranularity: .month))
        }
    }

    private var visibleStaff: [MariAPIClient.StaffRecord] {
        store.staff
    }

    private var markedDates: Set<String> {
        Set(
            store.scheduleByStaff.values
                .flatMap(\.keys)
        )
    }

    private var gridWidth: CGFloat {
        ScheduleGridLayout.staffColumnWidth
        + CGFloat(weekDates.count) * ScheduleGridLayout.dayColumnWidth
        + CGFloat(weekDates.count - 1) * ScheduleGridLayout.gap
    }

    private var isInitialLoading: Bool {
        store.isLoading && store.staff.isEmpty
    }

    var body: some View {
        ZStack {
            MariBackground()
                .ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if isInitialLoading {
                        ScheduleInitialSkeleton(gridWidth: gridWidth)
                    } else {
                        weekGrid

                        if !store.errorMessage.isEmpty {
                            ScheduleInfoNote(text: store.errorMessage, tint: Color(hex: 0xE8C0B8))
                        }

                        if !store.isLoading && store.staff.isEmpty {
                            ScheduleEmptyState()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 10) {
            bottomControls
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isDatePickerPresented) {
            ScheduleDatePickerSheet(
                selectedDate: $selectedDate,
                markedDates: markedDates
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Редактор графика", isPresented: $isEditAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Редактирование графика на iOS еще не перенесено. Экран сейчас работает в read-only режиме с реальными данными сервера.")
        }
        .task(id: scheduleMonthKey(selectedDate)) {
            await store.loadIfNeeded(for: selectedDate)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("График работы")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(MariPalette.ink)

                Button {
                    isDatePickerPresented = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MariPalette.accent)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.72))
                        )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                Button {
                    Task { await store.reload(for: selectedDate) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Все")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(MariPalette.softInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.76))
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(Color.black.opacity(0.08))
        }
    }

    private var weekGrid: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 10) {
                weekHeaderRow

                ForEach(visibleStaff) { person in
                    ScheduleStaffWeekRow(
                        staff: person,
                        dates: weekDates,
                        selectedDate: selectedDate,
                        slotsProvider: { slots(for: person.id, date: $0) }
                    )
                }
            }
            .frame(width: gridWidth, alignment: .leading)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var weekHeaderRow: some View {
        HStack(alignment: .bottom, spacing: ScheduleGridLayout.gap) {
            Color.clear
                .frame(width: ScheduleGridLayout.staffColumnWidth, height: 40)

            ForEach(weekDates, id: \.self) { date in
                let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)

                VStack(spacing: 4) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.headline.weight(.black))
                        .foregroundStyle(isSelected ? MariPalette.ink : MariPalette.softInk)

                    Text(scheduleShortWeekday(date))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MariPalette.softInk.opacity(0.85))
                }
                .frame(width: ScheduleGridLayout.dayColumnWidth)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            Button {
                isEditAlertPresented = true
            } label: {
                Text("Редактировать график")
                    .font(.headline.weight(.black))
                    .foregroundStyle(Color(hex: 0xD2B85E))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(hex: 0xFFE98E))
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(monthTabs) { tab in
                    Button {
                        selectedDate = scheduleDateByChangingMonth(from: selectedDate, to: tab.date)
                    } label: {
                        VStack(spacing: 2) {
                            Text(scheduleMonthTabLabel(tab.date))
                                .font(.headline.weight(.black))
                            if tab.isSelected {
                                Text(tab.date.formatted(.dateTime.year()))
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .foregroundStyle(tab.isSelected ? MariPalette.ink : Color.white.opacity(0.74))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(tab.isSelected ? Color(hex: 0xF8CC47) : .clear)
                                .padding(4)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: 0x262B31))
            )
        }
    }

    private func slots(for staffID: String, date: Date) -> [MariAPIClient.WorkingHoursItem] {
        let key = scheduleISODate(date)
        return (store.scheduleByStaff[staffID]?[key] ?? [])
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
    }
}

private struct ScheduleStaffWeekRow: View {
    let staff: MariAPIClient.StaffRecord
    let dates: [Date]
    let selectedDate: Date
    let slotsProvider: (Date) -> [MariAPIClient.WorkingHoursItem]

    private var positionTitle: String {
        staff.position?.name ?? "Мастер"
    }

    var body: some View {
        HStack(alignment: .top, spacing: ScheduleGridLayout.gap) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color(hex: 0xEEE9FF))
                        .frame(width: 36, height: 36)

                    Text(initials(for: staff.name))
                        .font(.caption.weight(.black))
                        .foregroundStyle(MariPalette.softInk)

                    Circle()
                        .fill(MariPalette.accent)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Image(systemName: "pencil")
                                .font(.system(size: 6, weight: .black))
                                .foregroundStyle(.white)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(spacing: 2) {
                    Text(firstName(staff.name))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MariPalette.ink)
                        .lineLimit(1)

                    Text(positionTitle)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(MariPalette.softInk.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(width: ScheduleGridLayout.staffColumnWidth)

            ForEach(dates, id: \.self) { date in
                ScheduleDayCell(
                    slots: slotsProvider(date),
                    isSelectedDay: Calendar(identifier: .gregorian).isDate(date, inSameDayAs: selectedDate)
                )
            }
        }
    }
}

private struct ScheduleDayCell: View {
    let slots: [MariAPIClient.WorkingHoursItem]
    let isSelectedDay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slots.prefix(3)) { slot in
                Text("\(slot.startTime)-\n\(slot.endTime)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(MariPalette.softInk)
                    .lineSpacing(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: ScheduleGridLayout.dayColumnWidth, height: ScheduleGridLayout.rowHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(slots.isEmpty ? .white.opacity(0.32) : .white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelectedDay ? MariPalette.accent.opacity(0.9) : .white.opacity(0.28), lineWidth: isSelectedDay ? 1.5 : 1)
        )
    }
}

private struct ScheduleInitialSkeleton: View {
    let gridWidth: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: ScheduleGridLayout.gap) {
                    MariSkeletonBlock(width: ScheduleGridLayout.staffColumnWidth, height: 40, cornerRadius: 14)

                    ForEach(0..<7, id: \.self) { _ in
                        VStack(spacing: 4) {
                            MariSkeletonBlock(width: 26, height: 20, cornerRadius: 10)
                            MariSkeletonBlock(width: 22, height: 12, cornerRadius: 6)
                        }
                        .frame(width: ScheduleGridLayout.dayColumnWidth)
                    }
                }

                ForEach(0..<4, id: \.self) { _ in
                    HStack(alignment: .top, spacing: ScheduleGridLayout.gap) {
                        VStack(spacing: 8) {
                            MariSkeletonCircle(size: 36)
                            MariSkeletonBlock(width: 58, height: 12, cornerRadius: 6)
                            MariSkeletonBlock(width: 46, height: 10, cornerRadius: 6)
                        }
                        .frame(width: ScheduleGridLayout.staffColumnWidth)

                        ForEach(0..<7, id: \.self) { _ in
                            MariSkeletonBlock(
                                width: ScheduleGridLayout.dayColumnWidth,
                                height: ScheduleGridLayout.rowHeight,
                                cornerRadius: 14
                            )
                        }
                    }
                }
            }
            .frame(width: gridWidth, alignment: .leading)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ScheduleDatePickerSheet: View {
    @Binding var selectedDate: Date
    let markedDates: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "Дата",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()

                if !markedDates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Дни с графиком")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)

                        Text(markedDates.sorted().joined(separator: ", "))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MariPalette.softInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(0.7))
                    )
                }

                Spacer()
            }
            .padding(20)
            .background(MariBackground().ignoresSafeArea())
            .navigationTitle("Выберите дату")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

private struct ScheduleInfoNote: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color(hex: 0x4E5059))

            Text(text)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(hex: 0x343844))

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.75))
        )
    }
}

private struct ScheduleEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(MariPalette.softInk)

            Text("На выбранный период график не найден")
                .font(.headline.weight(.black))
                .foregroundStyle(MariPalette.ink)

            Text("Проверь месяц или загрузку working-hours на сервере.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private func makeScheduleCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "ru_RU")
    calendar.firstWeekday = 2
    return calendar
}

private func scheduleMonthStart(_ date: Date) -> Date {
    let calendar = makeScheduleCalendar()
    return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
}

private func scheduleMonthEnd(_ date: Date) -> Date {
    let calendar = makeScheduleCalendar()
    let start = scheduleMonthStart(date)
    let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
    return calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? nextMonth
}

private func scheduleMonthKey(_ date: Date) -> String {
    let calendar = makeScheduleCalendar()
    let components = calendar.dateComponents([.year, .month], from: date)
    return "\(components.year ?? 0)-\(components.month ?? 0)"
}

private func scheduleISODate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func scheduleShortWeekday(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = MariLocale.ru
    formatter.dateFormat = "EE"
    return formatter.string(from: date).capitalized
}

private func scheduleMonthTabLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = MariLocale.ru
    formatter.dateFormat = "LLL"
    return formatter.string(from: date).lowercased()
}

private func scheduleDateByChangingMonth(from source: Date, to targetMonth: Date) -> Date {
    let calendar = makeScheduleCalendar()
    let day = calendar.component(.day, from: source)
    let start = scheduleMonthStart(targetMonth)
    let upperBound = calendar.range(of: .day, in: .month, for: start)?.count ?? day
    let clamped = min(day, upperBound)
    return calendar.date(bySetting: .day, value: clamped, of: start) ?? start
}

private func initials(for name: String) -> String {
    let parts = name.split(separator: " ")
    return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
}

private func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}

#Preview {
    ScheduleScreen(sessionStore: AppSessionStore(configuration: AppConfigurationStore()))
}
