import Combine
import SwiftUI

private typealias SettingsNotificationSection = MariAPIClient.StaffSettingsPayload.NotificationsPayload.SectionPayload
private typealias SettingsNotificationItem = MariAPIClient.StaffSettingsPayload.NotificationsPayload.ItemPayload

private enum MoreAction: String, CaseIterable, Identifiable {
    case staff = "Сотрудники"
    case analytics = "Аналитика"
    case onlineBooking = "Онлайн-запись"
    case privacyPolicy = "Политика конфиденциальности"
    case settings = "Настройки"
    case support = "Поддержка"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .staff: "person"
        case .analytics: "chart.pie"
        case .onlineBooking: "clock"
        case .privacyPolicy: "shield"
        case .settings: "gearshape"
        case .support: "message"
        }
    }

    var description: String {
        switch self {
        case .staff:
            "Управление командой, ролями, услугами и доступами сотрудников."
        case .analytics:
            "Основные показатели салона, выручка, загрузка и клиентские сегменты."
        case .onlineBooking:
            "Настройка клиентского сайта, публичных услуг и сценариев записи."
        case .privacyPolicy:
            "Тексты политики конфиденциальности и согласий для онлайн-записи."
        case .settings:
            "Общие параметры студии и системные опции."
        case .support:
            "Связь с поддержкой Mari Staff."
        }
    }

    var permissionCode: String? {
        switch self {
        case .staff: "VIEW_STAFF"
        case .analytics: "VIEW_FINANCIAL_STATS"
        case .onlineBooking, .privacyPolicy: "MANAGE_CLIENT_FRONT"
        case .settings, .support: nil
        }
    }
}

private struct StaffListRowModel: Identifiable, Hashable {
    let staff: MariAPIClient.StaffRecord
    let servicesCount: Int?
    let isServicesLoading: Bool

    var id: String { staff.id }
}

@MainActor
private final class MoreStore: ObservableObject {
    @Published private(set) var currentStaff: MariAPIClient.StaffRecord?
    @Published private(set) var allStaff: [MariAPIClient.StaffRecord] = []
    @Published private(set) var serviceCounts: [String: Int] = [:]
    @Published private(set) var servicesByStaff: [String: [MariAPIClient.StaffServiceRecord]] = [:]
    @Published private(set) var permissionsByStaff: [String: [MariAPIClient.StaffPermissionRecord]] = [:]
    @Published private(set) var loadingStaffServicesIDs: Set<String> = []
    @Published private(set) var loadingPermissionStaffIDs: Set<String> = []
    @Published private(set) var serviceCatalog: [MariAPIClient.ServiceRecord] = []
    @Published private(set) var permissionCatalog: [MariAPIClient.StaffPermissionCatalogItem] = []
    @Published private(set) var privacyPolicyText = ""
    @Published private(set) var notificationMinNoticeMinutes: Int?
    @Published private(set) var notificationSections: [SettingsNotificationSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSettingsLoading = false
    @Published private(set) var actionLoading = false
    @Published private(set) var savingNotificationMinNotice = false
    @Published private(set) var savingServicesStaffID: String?
    @Published private(set) var permissionBusyStaffID: String?
    @Published private(set) var permissionBusyCode: String?
    @Published private(set) var busyNotificationIDs: Set<String> = []
    @Published private(set) var errorMessage = ""

    let session: StaffSession?
    private let apiClient: MariAPIClient
    private var hasLoaded = false

    init(apiClient: MariAPIClient, session: StaffSession?) {
        self.apiClient = apiClient
        self.session = session
    }

    var visibleActions: [MoreAction] {
        return MoreAction.allCases.filter { action in
            switch action {
            case .settings:
                return session?.staff.role == "OWNER"
            case .support:
                return true
            default:
                return mariHasPermissionAccess(session, permissionCode: action.permissionCode)
            }
        }
    }

    var canEditPrivacyPolicy: Bool {
        mariHasPermissionAccess(session, permissionCode: "MANAGE_CLIENT_FRONT")
    }

    var canEditSettings: Bool {
        session?.staff.role == "OWNER"
    }

    var canEditStaffServices: Bool {
        mariHasPermissionAccess(session, permissionCode: "EDIT_STAFF")
    }

    var canEditStaffPermissions: Bool {
        session?.staff.role == "OWNER"
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func loadStaffDirectoryIfNeeded() async {
        guard !isLoading else { return }
        guard allStaff.isEmpty || serviceCounts.isEmpty else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let staffResponse = try await apiClient.listStaff(
                page: 1,
                limit: 200,
                role: nil,
                isActive: nil,
                employmentStatus: "all"
            )
            let filteredStaff = staffResponse.items
                .filter { $0.role != "OWNER" || $0.id == session?.staff.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            allStaff = filteredStaff
            currentStaff = filteredStaff.first(where: { $0.id == session?.staff.id }) ?? fallbackCurrentStaff()

            loadingStaffServicesIDs = Set(filteredStaff.map(\.id))
            let countPairs = try await loadStaffServices(for: filteredStaff)
            loadingStaffServicesIDs = []

            serviceCounts = Dictionary(uniqueKeysWithValues: countPairs.map { ($0.0, $0.1) })
            servicesByStaff = Dictionary(uniqueKeysWithValues: countPairs.map { ($0.0, $0.2) })

            try? await loadSettings()
        } catch {
            loadingStaffServicesIDs = []
            errorMessage = localizedMessage(for: error)
            if currentStaff == nil {
                currentStaff = fallbackCurrentStaff()
            }
        }
    }

    private func loadStaffServices(
        for staff: [MariAPIClient.StaffRecord]
    ) async throws -> [(String, Int, [MariAPIClient.StaffServiceRecord])] {
        try await withThrowingTaskGroup(of: (String, Int, [MariAPIClient.StaffServiceRecord]).self) { group in
            for person in staff {
                group.addTask { [apiClient] in
                    let response = try await apiClient.listStaffServices(id: person.id)
                    return (person.id, response.servicesCount, response.items)
                }
            }

            var rows: [(String, Int, [MariAPIClient.StaffServiceRecord])] = []
            for try await item in group {
                rows.append(item)
            }
            return rows
        }
    }

    func loadPermissions(for staffID: String, force: Bool = false) async {
        if !force, permissionsByStaff[staffID] != nil {
            return
        }

        loadingPermissionStaffIDs.insert(staffID)
        actionLoading = true
        defer {
            actionLoading = false
            loadingPermissionStaffIDs.remove(staffID)
        }

        do {
            let payload = try await apiClient.listStaffPermissions(id: staffID)
            permissionsByStaff[staffID] = payload.items
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func refreshStaffServices(for staffID: String) async {
        loadingStaffServicesIDs.insert(staffID)
        defer { loadingStaffServicesIDs.remove(staffID) }

        do {
            let payload = try await apiClient.listStaffServices(id: staffID)
            servicesByStaff[staffID] = payload.items
            serviceCounts[staffID] = payload.servicesCount
            errorMessage = ""
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func loadServiceCatalogIfNeeded() async {
        guard serviceCatalog.isEmpty else { return }

        do {
            let payload = try await apiClient.listServices(page: 1, limit: 500)
            serviceCatalog = payload.items
                .sorted {
                    let categoryCompare = $0.category.name.localizedCaseInsensitiveCompare($1.category.name)
                    if categoryCompare == .orderedSame {
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    return categoryCompare == .orderedAscending
                }
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func loadPermissionCatalogIfNeeded() async {
        guard permissionCatalog.isEmpty else { return }

        do {
            permissionCatalog = try await apiClient.listStaffPermissionCatalog()
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func staffRecord(id: String) -> MariAPIClient.StaffRecord? {
        if currentStaff?.id == id {
            return currentStaff
        }
        return allStaff.first(where: { $0.id == id })
    }

    func staffServices(for staffID: String) -> [MariAPIClient.StaffServiceRecord] {
        servicesByStaff[staffID] ?? []
    }

    func staffPermissions(for staffID: String) -> [MariAPIClient.StaffPermissionRecord] {
        permissionsByStaff[staffID] ?? []
    }

    func hasLoadedStaffServices(for staffID: String) -> Bool {
        servicesByStaff[staffID] != nil || serviceCounts[staffID] != nil
    }

    func isLoadingStaffServices(for staffID: String) -> Bool {
        loadingStaffServicesIDs.contains(staffID)
    }

    func hasLoadedPermissions(for staffID: String) -> Bool {
        permissionsByStaff[staffID] != nil
    }

    func isLoadingPermissions(for staffID: String) -> Bool {
        loadingPermissionStaffIDs.contains(staffID)
    }

    func isSavingServices(for staffID: String) -> Bool {
        savingServicesStaffID == staffID
    }

    func isTogglingPermission(for staffID: String, code: String) -> Bool {
        permissionBusyStaffID == staffID && permissionBusyCode == code
    }

    var notificationScenarioCount: Int {
        notificationSections.reduce(0) { sectionCount, section in
            sectionCount + section.groups.reduce(0) { groupCount, group in
                groupCount + group.items.count
            }
        }
    }

    func isTogglingNotification(_ id: String) -> Bool {
        busyNotificationIDs.contains(id)
    }

    func saveStaffServices(staffID: String, serviceIDs: [String]) async throws {
        savingServicesStaffID = staffID
        defer { savingServicesStaffID = nil }

        let payload = try await apiClient.updateStaffServices(id: staffID, serviceIDs: serviceIDs)
        servicesByStaff[staffID] = payload.items
        serviceCounts[staffID] = payload.servicesCount
        errorMessage = ""
    }

    func toggleStaffPermission(staffID: String, item: MariAPIClient.StaffPermissionCatalogItem, enabled: Bool) async throws {
        permissionBusyStaffID = staffID
        permissionBusyCode = item.code
        defer {
            permissionBusyStaffID = nil
            permissionBusyCode = nil
        }

        if enabled {
            _ = try await apiClient.grantStaffPermission(id: staffID, code: item.code)
        } else {
            try await apiClient.revokeStaffPermission(id: staffID, code: item.code)
        }

        var next = permissionsByStaff[staffID] ?? []
        if enabled {
            if let index = next.firstIndex(where: { $0.code == item.code }) {
                next[index] = MariAPIClient.StaffPermissionRecord(
                    code: item.code,
                    description: item.description,
                    expiresAt: next[index].expiresAt
                )
            } else {
                next.append(
                    MariAPIClient.StaffPermissionRecord(
                        code: item.code,
                        description: item.description,
                        expiresAt: nil
                    )
                )
            }
        } else {
            next.removeAll(where: { $0.code == item.code })
        }

        next.sort { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
        permissionsByStaff[staffID] = next
        mergePermissionCodes(staffID: staffID, codes: next.map(\.code))
        errorMessage = ""
    }

    func loadSettings() async throws {
        let settings = try await apiClient.getStaffSettings()
        privacyPolicyText = settings.privacyPolicy.content
        notificationMinNoticeMinutes = settings.notifications.minNoticeMinutes
        notificationSections = settings.notifications.sections
    }

    func refreshSettings() async {
        isSettingsLoading = true
        defer { isSettingsLoading = false }

        do {
            try await loadSettings()
            errorMessage = ""
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func refreshPrivacyPolicy() async {
        await refreshSettings()
    }

    func savePrivacyPolicy(_ value: String) async -> Bool {
        guard canEditPrivacyPolicy else {
            errorMessage = "Нет прав на редактирование политики"
            return false
        }

        actionLoading = true
        defer { actionLoading = false }

        do {
            let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            let settings = try await apiClient.patchPrivacyPolicy(content: normalized)
            privacyPolicyText = settings.privacyPolicy.content
            notificationMinNoticeMinutes = settings.notifications.minNoticeMinutes
            notificationSections = settings.notifications.sections
            errorMessage = ""
            return true
        } catch {
            errorMessage = localizedMessage(for: error)
            return false
        }
    }

    func saveNotificationMinNotice(_ value: Int) async -> Bool {
        guard canEditSettings else {
            errorMessage = "Нет доступа"
            return false
        }

        savingNotificationMinNotice = true
        defer { savingNotificationMinNotice = false }

        do {
            let settings = try await apiClient.patchNotificationSettings(minNoticeMinutes: value)
            notificationMinNoticeMinutes = settings.notifications.minNoticeMinutes
            notificationSections = settings.notifications.sections
            privacyPolicyText = settings.privacyPolicy.content
            errorMessage = ""
            return true
        } catch {
            errorMessage = localizedMessage(for: error)
            return false
        }
    }

    func toggleNotificationSetting(id: String, enabled: Bool) async -> Bool {
        guard canEditSettings else {
            errorMessage = "Нет доступа"
            return false
        }

        busyNotificationIDs.insert(id)
        defer { busyNotificationIDs.remove(id) }

        do {
            let settings = try await apiClient.patchNotificationSettings(toggles: [id: enabled])
            notificationMinNoticeMinutes = settings.notifications.minNoticeMinutes
            notificationSections = settings.notifications.sections
            privacyPolicyText = settings.privacyPolicy.content
            errorMessage = ""
            return true
        } catch {
            errorMessage = localizedMessage(for: error)
            return false
        }
    }

    func saveStaff(
        id: String,
        name: String,
        phone: String,
        email: String?,
        positionName: String?,
        role: String
    ) async throws {
        actionLoading = true
        defer { actionLoading = false }

        var updated = try await apiClient.updateStaffContact(
            id: id,
            name: name,
            phone: phone,
            email: email,
            positionName: positionName
        )
        if updated.role != role {
            updated = try await apiClient.updateStaffRole(id: id, role: role)
        }
        mergeStaff(updated)
    }

    private func mergeStaff(_ staff: MariAPIClient.StaffRecord) {
        if let index = allStaff.firstIndex(where: { $0.id == staff.id }) {
            allStaff[index] = mergedStaff(existing: allStaff[index], updated: staff)
        }
        if currentStaff?.id == staff.id {
            currentStaff = mergedStaff(existing: currentStaff, updated: staff)
        }
    }

    private func mergePermissionCodes(staffID: String, codes: [String]) {
        let snapshots = codes.map {
            MariAPIClient.StaffRecord.PermissionSnapshot(code: $0, expiresAt: nil)
        }

        if let index = allStaff.firstIndex(where: { $0.id == staffID }) {
            let existing = allStaff[index]
            allStaff[index] = MariAPIClient.StaffRecord(
                id: existing.id,
                name: existing.name,
                role: existing.role,
                phoneE164: existing.phoneE164,
                email: existing.email,
                avatarUrl: existing.avatarUrl,
                isActive: existing.isActive,
                position: existing.position,
                hiredAt: existing.hiredAt,
                firedAt: existing.firedAt,
                deletedAt: existing.deletedAt,
                permissions: snapshots
            )
        }

        if currentStaff?.id == staffID, let currentStaff {
            self.currentStaff = MariAPIClient.StaffRecord(
                id: currentStaff.id,
                name: currentStaff.name,
                role: currentStaff.role,
                phoneE164: currentStaff.phoneE164,
                email: currentStaff.email,
                avatarUrl: currentStaff.avatarUrl,
                isActive: currentStaff.isActive,
                position: currentStaff.position,
                hiredAt: currentStaff.hiredAt,
                firedAt: currentStaff.firedAt,
                deletedAt: currentStaff.deletedAt,
                permissions: snapshots
            )
        }
    }

    private func mergedStaff(existing: MariAPIClient.StaffRecord?, updated: MariAPIClient.StaffRecord) -> MariAPIClient.StaffRecord {
        MariAPIClient.StaffRecord(
            id: updated.id,
            name: updated.name,
            role: updated.role,
            phoneE164: updated.phoneE164,
            email: updated.email,
            avatarUrl: updated.avatarUrl ?? existing?.avatarUrl,
            isActive: updated.isActive,
            position: updated.position ?? existing?.position,
            hiredAt: updated.hiredAt ?? existing?.hiredAt,
            firedAt: updated.firedAt ?? existing?.firedAt,
            deletedAt: updated.deletedAt ?? existing?.deletedAt,
            permissions: updated.permissions ?? existing?.permissions
        )
    }

    private func fallbackCurrentStaff() -> MariAPIClient.StaffRecord? {
        guard let session else { return nil }
        return MariAPIClient.StaffRecord(
            id: session.staff.id,
            name: session.staff.name,
            role: session.staff.role,
            phoneE164: session.staff.phoneE164,
            email: session.staff.email,
            avatarUrl: nil,
            isActive: true,
            position: nil,
            hiredAt: nil,
            firedAt: nil,
            deletedAt: nil,
            permissions: session.staff.permissions?.map {
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

struct MoreScreen: View {
    let sessionStore: AppSessionStore
    let onLogout: () -> Void

    @Environment(\.openURL) private var openURL
    @StateObject private var store: MoreStore

    init(sessionStore: AppSessionStore, onLogout: @escaping () -> Void) {
        self.sessionStore = sessionStore
        self.onLogout = onLogout
        _store = StateObject(
            wrappedValue: MoreStore(
                apiClient: sessionStore.api,
                session: sessionStore.currentSession
            )
        )
    }

    private var isInitialLoading: Bool {
        store.isLoading && store.allStaff.isEmpty && store.currentStaff == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isInitialLoading {
                    MoreInitialSkeleton(actionCount: max(store.visibleActions.count, 4))
                } else {
                    Text("Еще")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(MariPalette.ink)
                        .padding(.top, 8)

                    if let currentStaff = store.currentStaff {
                        NavigationLink {
                            StaffDetailScreen(
                                store: store,
                                staffID: currentStaff.id,
                                initialStaff: currentStaff,
                                onSave: { draft in
                                    try await store.saveStaff(
                                        id: currentStaff.id,
                                        name: draft.name,
                                        phone: draft.phone,
                                        email: draft.email.isEmpty ? nil : draft.email,
                                        positionName: draft.positionName.isEmpty ? nil : draft.positionName,
                                        role: draft.role
                                    )
                                }
                            )
                        } label: {
                            MoreProfileRow(staff: currentStaff)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 0) {
                        ForEach(store.visibleActions) { action in
                            if action == .staff {
                                NavigationLink {
                                    StaffListScreen(
                                        store: store,
                                        detailBuilder: { person in
                                            StaffDetailScreen(
                                                store: store,
                                                staffID: person.id,
                                                initialStaff: person,
                                                onSave: { draft in
                                                    try await store.saveStaff(
                                                        id: person.id,
                                                        name: draft.name,
                                                        phone: draft.phone,
                                                        email: draft.email.isEmpty ? nil : draft.email,
                                                        positionName: draft.positionName.isEmpty ? nil : draft.positionName,
                                                        role: draft.role
                                                    )
                                                }
                                            )
                                        }
                                    )
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            } else if action == .privacyPolicy {
                                NavigationLink {
                                    PrivacyPolicyScreen(
                                        store: store
                                    )
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            } else if action == .settings {
                                NavigationLink {
                                    SettingsOverviewScreen(store: store)
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            } else if action == .analytics {
                                NavigationLink {
                                    AnalyticsScreen(sessionStore: sessionStore)
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            } else if action == .onlineBooking {
                                NavigationLink {
                                    OnlineBookingScreen(sessionStore: sessionStore)
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            } else if action == .support {
                                Button {
                                    if let url = URL(string: "mailto:support@mari-beauty.local?subject=Mari%20Staff%20Support") {
                                        openURL(url)
                                    }
                                } label: {
                                    MoreMenuRow(action: action)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.white.opacity(0.6))
                    )

                    Button {
                        onLogout()
                    } label: {
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MariPalette.softInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(.white.opacity(0.55))
                                    )
                            )
                    }
                    .buttonStyle(.plain)

                    if !store.errorMessage.isEmpty {
                        Text(store.errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(hex: 0x9A5447))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadIfNeeded()
        }
    }
}

private struct MoreInitialSkeleton: View {
    let actionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MariSkeletonBlock(width: 92, height: 34, cornerRadius: 12)
                .padding(.top, 8)

            HStack(spacing: 12) {
                MariSkeletonCircle(size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    MariSkeletonBlock(width: 140, height: 11, cornerRadius: 6)
                    MariSkeletonBlock(width: 176, height: 18, cornerRadius: 8)
                }
                Spacer()
                MariSkeletonCircle(size: 20)
            }
            .padding(.vertical, 12)

            VStack(spacing: 0) {
                ForEach(0..<actionCount, id: \.self) { index in
                    HStack(spacing: 14) {
                        MariSkeletonCircle(size: 24)
                        MariSkeletonBlock(width: 170, height: 16, cornerRadius: 8)
                        Spacer()
                        MariSkeletonCircle(size: 14)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)

                    if index != actionCount - 1 {
                        Divider()
                            .overlay(Color.black.opacity(0.06))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.6))
            )

            MariSkeletonBlock(width: 108, height: 42, cornerRadius: 12)
        }
    }
}

private struct MoreProfileRow: View {
    let staff: MariAPIClient.StaffRecord

    var body: some View {
        HStack(spacing: 12) {
            StaffAvatarView(name: staff.name, avatarURL: staff.avatarUrl, size: 40, iconSize: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(roleTitle(staff.role)) • \(staff.phoneE164)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
                Text(staff.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
        }
        .padding(.vertical, 12)
    }
}

private struct MoreMenuRow: View {
    let action: MoreAction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: action.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(MariPalette.ink)
                .frame(width: 24)

            Text(action.title)
                .font(.body.weight(.medium))
                .foregroundStyle(MariPalette.ink)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }
}

private struct MoreSubscreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

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

            Text(title)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            Spacer()

            trailing
                .frame(minWidth: 28)
        }
    }
}

private struct StaffListScreen<Detail: View>: View {
    @ObservedObject var store: MoreStore
    let detailBuilder: (MariAPIClient.StaffRecord) -> Detail

    @State private var search = ""
    @State private var filter: StaffEmploymentFilter = .current
    @State private var isRefreshing = false
    @State private var isSummaryPresented = false
    @State private var isCreateAlertPresented = false

    private var filteredStaff: [StaffListRowModel] {
        let lowercased = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.allStaff
            .filter { $0.role != "OWNER" }
            .filter { person in
                filter.matches(person)
            }
            .filter { person in
                guard !lowercased.isEmpty else { return true }
                return person.name.lowercased().contains(lowercased)
                    || person.phoneE164.lowercased().contains(lowercased)
                    || (person.email?.lowercased().contains(lowercased) ?? false)
            }
            .map {
                StaffListRowModel(
                    staff: $0,
                    servicesCount: store.serviceCounts[$0.id],
                    isServicesLoading: store.isLoadingStaffServices(for: $0.id) && !store.hasLoadedStaffServices(for: $0.id)
                )
            }
    }

    private var statusCounts: [StaffEmploymentFilter: Int] {
        Dictionary(uniqueKeysWithValues: StaffEmploymentFilter.allCases.map { filter in
            (
                filter,
                store.allStaff.filter { $0.role != "OWNER" }.filter { filter.matches($0) }.count
            )
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if store.isLoading && filteredStaff.isEmpty {
                    StaffListLoadingView()
                        .padding(.top, 8)
                } else {
                    ForEach(filteredStaff) { row in
                        NavigationLink {
                            detailBuilder(row.staff)
                        } label: {
                            StaffListRow(
                                staff: row.staff,
                                servicesCount: row.servicesCount,
                                isServicesLoading: row.isServicesLoading
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !store.errorMessage.isEmpty {
                    Text(store.errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                        .padding(.top, 4)
                }

                if filteredStaff.isEmpty && !store.isLoading {
                    Text("Сотрудники не найдены")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                        .padding(.top, 8)
                }

                if store.isLoading && !store.allStaff.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(MariPalette.ink)
                        Text("Обновляю сотрудников...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MariPalette.softInk)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadStaffDirectoryIfNeeded()
        }
        .sheet(isPresented: $isSummaryPresented) {
            StaffSummarySheet(
                totalCount: statusCounts[.all] ?? 0,
                currentCount: statusCounts[.current] ?? 0,
                withServicesCount: store.allStaff.filter { (store.serviceCounts[$0.id] ?? 0) > 0 && $0.role != "OWNER" }.count
            )
            .presentationDetents([.medium])
        }
        .alert("Создание сотрудника", isPresented: $isCreateAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Создание сотрудника на iOS еще не перенесено.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            MoreSubscreenHeader(title: "Сотрудники") {
                HStack(spacing: 8) {
                    Button {
                        isRefreshing = true
                        Task {
                            await store.reload()
                            isRefreshing = false
                        }
                    } label: {
                        Group {
                            if isRefreshing || store.isLoading {
                                ProgressView()
                                    .tint(MariPalette.ink)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(MariPalette.ink)
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isSummaryPresented = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MariPalette.ink)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isCreateAlertPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MariPalette.ink)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(hex: 0x97A0AD))
                TextField("Поиск", text: $search)
                    .font(.body.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.6))
                    )
            )

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(StaffEmploymentFilter.allCases) { option in
                        Button {
                            filter = option
                        } label: {
                            HStack(spacing: 6) {
                                Text(option.title)
                                Text("\(statusCounts[option] ?? 0)")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(filter == option ? MariPalette.ink : MariPalette.softInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(filter == option ? MariPalette.accent : .white.opacity(0.8))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.black.opacity(filter == option ? 0 : 0.08), lineWidth: filter == option ? 0 : 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct StaffListRow: View {
    let staff: MariAPIClient.StaffRecord
    let servicesCount: Int?
    let isServicesLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StaffAvatarView(name: staff.name, avatarURL: staff.avatarUrl, size: 42, iconSize: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(staff.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)

                Text(staff.position?.name ?? roleTitle(staff.role))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)

                HStack(spacing: 6) {
                    StaffTag(title: employmentStatusTitle(for: staff), tint: employmentStatusTint(for: staff))
                    if (servicesCount ?? 0) > 0 {
                        StaffTag(title: "Оказывает услуги", tint: Color(hex: 0xF2DC7E))
                    }
                    StaffTag(title: "\(servicesCount ?? 0) услуг", tint: Color(hex: 0xDDE2EA))
                }
                .redacted(reason: isServicesLoading ? .placeholder : [])
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
                .padding(.top, 8)
        }
        .padding(.vertical, 10)
    }
}

private struct StaffListLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    MariSkeletonCircle(size: 48)
                    VStack(alignment: .leading, spacing: 8) {
                        MariSkeletonBlock(width: 144, height: 16, cornerRadius: 8)
                        MariSkeletonBlock(width: 92, height: 12, cornerRadius: 6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.68))
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct StaffServicesLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 10) {
                    HStack {
                        MariSkeletonBlock(width: 160, height: 18, cornerRadius: 8)
                        Spacer()
                        MariSkeletonBlock(width: 64, height: 18, cornerRadius: 8)
                    }

                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 12) {
                            MariSkeletonCircle(size: 20)
                            VStack(alignment: .leading, spacing: 6) {
                                MariSkeletonBlock(width: 180, height: 14, cornerRadius: 6)
                                MariSkeletonBlock(width: 120, height: 12, cornerRadius: 6)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.66))
                )
            }
        }
    }
}

private struct StaffAvatarView: View {
    let name: String
    let avatarURL: String?
    let size: CGFloat
    let iconSize: CGFloat

    private var resolvedURL: URL? {
        guard let avatarURL else { return nil }
        let trimmed = avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: 0xE7E1FA))

            if let resolvedURL {
                AsyncImage(url: resolvedURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(Color(hex: 0x8C86E5))
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
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .accessibilityLabel("Аватар \(name)")
    }

    private var placeholder: some View {
        Image(systemName: "person")
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(Color(hex: 0x8C86E5))
    }
}

private struct StaffTag: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint))
    }
}

private struct StaffSummarySheet: View {
    let totalCount: Int
    let currentCount: Int
    let withServicesCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Сотрудники")
                .font(.title2.weight(.black))
                .foregroundStyle(MariPalette.ink)

            StaffSummaryMetric(title: "Всего", value: "\(totalCount)")
            StaffSummaryMetric(title: "С услугами", value: "\(withServicesCount)")
            StaffSummaryMetric(title: "Текущие", value: "\(currentCount)")

            Spacer()
        }
        .padding(20)
        .background(MariBackground().ignoresSafeArea())
    }
}

private struct StaffSummaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(MariPalette.softInk)
            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.68))
        )
    }
}

private struct StaffDraftValue {
    var name: String
    var role: String
    var positionName: String
    var phone: String
    var email: String
}

private struct StaffDetailScreen: View {
    @ObservedObject var store: MoreStore
    let staffID: String
    let initialStaff: MariAPIClient.StaffRecord
    let onSave: (StaffDraftValue) async throws -> Void

    @State private var draft: StaffDraftValue
    @State private var errorMessage = ""
    @State private var isSavedMessageVisible = false
    @State private var isDeleteAlertPresented = false
    @State private var isPhotoAlertPresented = false

    init(
        store: MoreStore,
        staffID: String,
        initialStaff: MariAPIClient.StaffRecord,
        onSave: @escaping (StaffDraftValue) async throws -> Void
    ) {
        self.store = store
        self.staffID = staffID
        self.initialStaff = initialStaff
        self.onSave = onSave
        _draft = State(
            initialValue: StaffDraftValue(
                name: initialStaff.name,
                role: initialStaff.role,
                positionName: initialStaff.position?.name ?? "",
                phone: initialStaff.phoneE164,
                email: initialStaff.email ?? ""
            )
        )
    }

    private var staff: MariAPIClient.StaffRecord {
        store.staffRecord(id: staffID) ?? initialStaff
    }

    private var services: [MariAPIClient.StaffServiceRecord] {
        store.staffServices(for: staffID)
    }

    private var permissions: [MariAPIClient.StaffPermissionRecord] {
        store.staffPermissions(for: staffID)
    }

    private var isSaving: Bool {
        store.actionLoading
    }

    private var isServicesLoading: Bool {
        store.isLoadingStaffServices(for: staffID) && !store.hasLoadedStaffServices(for: staffID)
    }

    private var isPermissionsLoading: Bool {
        store.isLoadingPermissions(for: staffID) && !store.hasLoadedPermissions(for: staffID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                VStack(spacing: 16) {
                    StaffAvatarView(name: staff.name, avatarURL: staff.avatarUrl, size: 104, iconSize: 40)

                    Button("Изменить фото") {
                        isPhotoAlertPresented = true
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(MariPalette.softInk)
                        .font(.headline.weight(.medium))
                }
                .padding(.top, 8)

                StaffFormField(title: "Статус") {
                    Text(employmentStatusTitle(for: staff))
                        .font(.headline.weight(.medium))
                        .foregroundStyle(MariPalette.ink)
                }

                StaffInputField(title: "Имя", text: $draft.name)
                StaffRoleField(title: "Должность", role: $draft.role)
                StaffInputField(title: "Специализация", text: $draft.positionName)

                NavigationLink {
                    StaffServicesScreen(
                        store: store,
                        staffID: staffID,
                        staffName: staff.name
                    )
                } label: {
                    StaffNavigationCard(
                        title: "Оказываемые услуги",
                        subtitle: services.isEmpty ? "Услуги не назначены" : "\(services.count) услуг",
                        symbol: "scissors",
                        tint: MariPalette.accentSecondary,
                        isLoading: isServicesLoading
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    StaffPermissionsScreen(
                        store: store,
                        staffID: staffID
                    )
                } label: {
                    StaffNavigationCard(
                        title: "Права доступа",
                        subtitle: permissions.isEmpty ? "Нет выданных прав" : "\(permissions.count) прав",
                        symbol: "lock.shield",
                        tint: MariPalette.sky.opacity(0.28),
                        isLoading: isPermissionsLoading
                    )
                }
                .buttonStyle(.plain)

                StaffInputField(title: "Номер телефона", text: $draft.phone, keyboardType: .phonePad)
                StaffInputField(title: "Email", text: $draft.email, keyboardType: .emailAddress)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task {
                        do {
                            try await onSave(draft)
                            errorMessage = ""
                            isSavedMessageVisible = true
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                } label: {
                    Text(isSaving ? "Сохраняю..." : "Сохранить")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(MariPalette.ink)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.refreshStaffServices(for: staffID)
            await store.loadPermissions(for: staffID, force: true)
        }
        .onChange(of: staff.id) { _, _ in syncDraftIfNeeded() }
        .alert("Удаление на iOS", isPresented: $isDeleteAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hard delete сотрудника еще не перенесен в iOS flow.")
        }
        .alert("Аватар сотрудника", isPresented: $isPhotoAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Загрузка аватара на iOS еще не перенесена.")
        }
        .alert("Сохранено", isPresented: $isSavedMessageVisible) {
            Button("OK", role: .cancel) {}
        }
    }

    private func syncDraftIfNeeded() {
        draft = StaffDraftValue(
            name: staff.name,
            role: staff.role,
            positionName: staff.position?.name ?? "",
            phone: staff.phoneE164,
            email: staff.email ?? ""
        )
    }

    private var header: some View {
        MoreSubscreenHeader(title: "Сотрудник") {
            Button {
                isDeleteAlertPresented = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.softInk)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StaffFormField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(0.64))
                    )
            )
        }
    }
}

private struct StaffInputField: View {
    let title: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)

            TextField("", text: $text)
                .font(.headline.weight(.medium))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.64))
                        )
                )
        }
    }
}

private struct StaffRoleField: View {
    let title: String
    @Binding var role: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)

            Menu {
                ForEach(["MASTER", "DEVELOPER", "SMM", "ADMIN"], id: \.self) { value in
                    Button(roleTitle(value)) {
                        role = value
                    }
                }
            } label: {
                HStack {
                    Text(roleTitle(role))
                        .font(.headline.weight(.medium))
                        .foregroundStyle(MariPalette.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MariPalette.softInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.64))
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StaffNavigationCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var isLoading = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint)
                    .frame(width: 48, height: 48)

                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.64))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .redacted(reason: isLoading ? .placeholder : [])
    }
}

private struct StaffServicesScreen: View {
    @ObservedObject var store: MoreStore
    let staffID: String
    let staffName: String

    @State private var search = ""
    @State private var selectedServiceIDs: Set<String>
    @State private var expandedCategoryIDs: Set<String> = []
    @State private var localErrorMessage = ""
    @State private var isSavedMessageVisible = false

    init(
        store: MoreStore,
        staffID: String,
        staffName: String
    ) {
        self.store = store
        self.staffID = staffID
        self.staffName = staffName
        _selectedServiceIDs = State(initialValue: [])
    }

    private var allGroups: [StaffServiceCategoryGroup] {
        Dictionary(grouping: store.serviceCatalog) { service in
            service.category.id
        }
        .compactMap { categoryID, items in
            guard let first = items.first else { return nil }
            return StaffServiceCategoryGroup(
                id: categoryID,
                name: first.category.name,
                items: items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleGroups: [StaffServiceCategoryGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allGroups }

        return allGroups.compactMap { group in
            if group.name.lowercased().contains(query) {
                return group
            }

            let filteredItems = group.items.filter { service in
                [service.name, service.nameOnline ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(query)
            }
            guard !filteredItems.isEmpty else { return nil }
            return StaffServiceCategoryGroup(id: group.id, name: group.name, items: filteredItems)
        }
    }

    private var selectedServices: [MariAPIClient.ServiceRecord] {
        store.serviceCatalog.filter { selectedServiceIDs.contains($0.id) }
    }

    private var isAssignmentsLoading: Bool {
        store.isLoadingStaffServices(for: staffID) && !store.hasLoadedStaffServices(for: staffID)
    }

    private var selectedTotalPrice: Int {
        Int(selectedServices.reduce(0) { $0 + max($1.priceMin, 0) }.rounded())
    }

    private var selectedTotalDurationMinutes: Int {
        selectedServices.reduce(0) { $0 + max(0, Int((Double($1.durationSec) / 60.0).rounded())) }
    }

    private var effectiveErrorMessage: String {
        localErrorMessage.isEmpty ? store.errorMessage : localErrorMessage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MoreSubscreenHeader(title: "Оказываемые услуги") {
                    Button {
                        Task { await save() }
                    } label: {
                        if store.isSavingServices(for: staffID) {
                            ProgressView()
                                .tint(MariPalette.ink)
                        } else {
                            Text("Сохранить")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(MariPalette.ink)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canEditStaffServices || store.isSavingServices(for: staffID))
                }

                Text(staffName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)

                StaffSearchField(
                    placeholder: "Поиск услуги или категории",
                    text: $search
                )

                HStack(spacing: 12) {
                    StaffMetricPill(title: "Выбрано", value: "\(selectedServiceIDs.count)")
                    StaffMetricPill(title: "Сумма цен", value: MariFormatters.money(selectedTotalPrice))
                    StaffMetricPill(title: "Длительность", value: "\(selectedTotalDurationMinutes) мин")
                }
                .redacted(reason: isAssignmentsLoading ? .placeholder : [])

                if !store.canEditStaffServices {
                    StaffEditorNotice(text: "У текущей сессии нет права `EDIT_STAFF`. Просмотр доступен, сохранение отключено.")
                }

                if store.serviceCatalog.isEmpty || isAssignmentsLoading {
                    StaffServicesLoadingView()
                } else if visibleGroups.isEmpty {
                    StaffEmptyCard(
                        title: "Услуги не найдены",
                        subtitle: "Измени поисковый запрос или очисти фильтр."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(visibleGroups) { group in
                            staffServicesCategory(group)
                        }
                    }
                }

                if !effectiveErrorMessage.isEmpty {
                    Text(effectiveErrorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            selectedServiceIDs = Set(store.staffServices(for: staffID).map(\.id))
            synchronizeExpandedCategories()
            await store.loadServiceCatalogIfNeeded()
            await store.refreshStaffServices(for: staffID)
            selectedServiceIDs = Set(store.staffServices(for: staffID).map(\.id))
            synchronizeExpandedCategories()
        }
        .onChange(of: store.staffServices(for: staffID).map(\.id).sorted()) { _, newValue in
            if !store.isSavingServices(for: staffID) {
                selectedServiceIDs = Set(newValue)
            }
        }
        .onChange(of: search) { _, _ in
            synchronizeExpandedCategories()
        }
        .onChange(of: allGroups.map(\.id)) { _, _ in
            synchronizeExpandedCategories()
        }
        .alert("Сохранено", isPresented: $isSavedMessageVisible) {
            Button("OK", role: .cancel) {}
        }
    }

    private func staffServicesCategory(_ group: StaffServiceCategoryGroup) -> some View {
        let sourceGroup = allGroups.first(where: { $0.id == group.id }) ?? group
        let totalCount = sourceGroup.items.count
        let selectedCount = sourceGroup.items.reduce(0) { partial, item in
            partial + (selectedServiceIDs.contains(item.id) ? 1 : 0)
        }
        let selectionState: StaffSelectionState = if selectedCount == 0 {
            .none
        } else if selectedCount == totalCount {
            .selected
        } else {
            .partial
        }
        let isExpanded = expandedCategoryIDs.contains(group.id)

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    toggleCategory(groupID: group.id)
                } label: {
                    StaffSelectionMark(state: selectionState)
                }
                .buttonStyle(.plain)
                .disabled(!store.canEditStaffServices)

                Button {
                    toggleExpanded(group.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(MariPalette.ink)
                            Text("\(selectedCount)/\(totalCount) услуг")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(MariPalette.softInk)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(MariPalette.softInk)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            if isExpanded {
                Divider()
                    .overlay(Color.black.opacity(0.08))

                VStack(spacing: 0) {
                    ForEach(group.items) { service in
                        Button {
                            toggleService(service.id)
                        } label: {
                            HStack(spacing: 12) {
                                StaffSelectionMark(state: selectedServiceIDs.contains(service.id) ? .selected : .none)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(MariPalette.ink)
                                        .multilineTextAlignment(.leading)
                                    Text("\(MariFormatters.money(Int(service.priceMin.rounded()))) • \(staffServiceDurationTitle(service.durationSec))")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(MariPalette.softInk)
                                }

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canEditStaffServices)

                        if service.id != group.items.last?.id {
                            Divider()
                                .overlay(Color.black.opacity(0.06))
                                .padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }

    private func synchronizeExpandedCategories() {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            expandedCategoryIDs = Set(visibleGroups.map(\.id))
            return
        }

        let existingIDs = Set(allGroups.map(\.id))
        expandedCategoryIDs = expandedCategoryIDs.intersection(existingIDs)
        if expandedCategoryIDs.isEmpty, let firstID = allGroups.first?.id {
            expandedCategoryIDs = [firstID]
        }
    }

    private func toggleExpanded(_ groupID: String) {
        if expandedCategoryIDs.contains(groupID) {
            expandedCategoryIDs.remove(groupID)
        } else {
            expandedCategoryIDs.insert(groupID)
        }
    }

    private func toggleCategory(groupID: String) {
        guard let group = allGroups.first(where: { $0.id == groupID }) else { return }
        let groupIDs = Set(group.items.map(\.id))
        let isFullySelected = group.items.allSatisfy { selectedServiceIDs.contains($0.id) }

        if isFullySelected {
            selectedServiceIDs.subtract(groupIDs)
        } else {
            selectedServiceIDs.formUnion(groupIDs)
        }
    }

    private func toggleService(_ serviceID: String) {
        if selectedServiceIDs.contains(serviceID) {
            selectedServiceIDs.remove(serviceID)
        } else {
            selectedServiceIDs.insert(serviceID)
        }
    }

    private func save() async {
        do {
            try await store.saveStaffServices(
                staffID: staffID,
                serviceIDs: selectedServiceIDs.sorted()
            )
            localErrorMessage = ""
            isSavedMessageVisible = true
        } catch {
            localErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct StaffPermissionsScreen: View {
    @ObservedObject var store: MoreStore
    let staffID: String

    @State private var localErrorMessage = ""
    @State private var pendingPermissionStates: [String: Bool] = [:]

    private var permissions: [MariAPIClient.StaffPermissionRecord] {
        store.staffPermissions(for: staffID)
    }

    private var enabledCodes: Set<String> {
        Set(permissions.map(\.code))
    }

    private var groupedCatalog: [MariAPIClient.StaffPermissionCatalogItem.Group: [MariAPIClient.StaffPermissionCatalogItem]] {
        Dictionary(grouping: store.permissionCatalog, by: \.group)
    }

    private var effectiveErrorMessage: String {
        localErrorMessage.isEmpty ? store.errorMessage : localErrorMessage
    }

    private var isPermissionsLoading: Bool {
        store.isLoadingPermissions(for: staffID) && !store.hasLoadedPermissions(for: staffID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MoreSubscreenHeader(title: "Права доступа") {
                    Color.clear
                }

                if !store.canEditStaffPermissions {
                    StaffEditorNotice(text: "Изменение прав доступа на сервере разрешено только владельцу. Просмотр оставлен доступным.")
                }

                if store.permissionCatalog.isEmpty || isPermissionsLoading {
                    StaffLoadingCard(text: "Загружаю каталог прав...")
                } else {
                    VStack(spacing: 12) {
                        ForEach(MariAPIClient.StaffPermissionCatalogItem.Group.allCases, id: \.self) { group in
                            let items = groupedCatalog[group] ?? []
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(staffPermissionGroupTitle(group))
                                        .font(.caption.weight(.bold))
                                        .tracking(1.2)
                                        .foregroundStyle(MariPalette.softInk)

                                    VStack(spacing: 0) {
                                        ForEach(items) { item in
                                            permissionRow(item)

                                            if item.id != items.last?.id {
                                                Divider()
                                                    .overlay(Color.black.opacity(0.06))
                                                    .padding(.leading, 16)
                                            }
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(.white.opacity(0.64))
                                    )
                                }
                            }
                        }
                    }
                }

                if permissions.isEmpty && !store.permissionCatalog.isEmpty && !isPermissionsLoading {
                    StaffEmptyCard(
                        title: "Нет выданных прав",
                        subtitle: "Права можно назначить переключателями выше."
                    )
                }

                if !effectiveErrorMessage.isEmpty {
                    Text(effectiveErrorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadPermissionCatalogIfNeeded()
            await store.loadPermissions(for: staffID, force: true)
        }
    }

    private func permissionRow(_ item: MariAPIClient.StaffPermissionCatalogItem) -> some View {
        let isEnabled = pendingPermissionStates[item.code] ?? enabledCodes.contains(item.code)
        let isBusy = store.isTogglingPermission(for: staffID, code: item.code)

        return Toggle(isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                pendingPermissionStates[item.code] = newValue
                Task { await togglePermission(item, enabled: newValue) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                Text(item.description)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)

                if isBusy {
                    Text("Сохраняю...")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MariPalette.softInk)
                }
            }
        }
        .padding(16)
        .tint(MariPalette.accent)
        .disabled(isBusy || !store.canEditStaffPermissions)
    }

    private func togglePermission(_ item: MariAPIClient.StaffPermissionCatalogItem, enabled: Bool) async {
        do {
            try await store.toggleStaffPermission(staffID: staffID, item: item, enabled: enabled)
            pendingPermissionStates[item.code] = nil
            localErrorMessage = ""
        } catch {
            pendingPermissionStates[item.code] = nil
            localErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct StaffServiceCategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let items: [MariAPIClient.ServiceRecord]
}

private enum StaffSelectionState {
    case none
    case partial
    case selected
}

private struct StaffSelectionMark: View {
    let state: StaffSelectionState

    var body: some View {
        ZStack {
            Circle()
                .fill(state == .none ? Color.white.opacity(0.88) : MariPalette.accent)
                .overlay(
                    Circle()
                        .stroke(state == .none ? Color.black.opacity(0.12) : MariPalette.accent, lineWidth: 1)
                )

            if state == .selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(MariPalette.ink)
            } else if state == .partial {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(MariPalette.ink)
                    .frame(width: 10, height: 3)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct StaffSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MariPalette.softInk)

            TextField(placeholder, text: $text)
                .font(.headline.weight(.medium))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(MariPalette.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.64))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StaffMetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(MariPalette.softInk)
            Text(value)
                .font(.subheadline.weight(.black))
                .foregroundStyle(MariPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct StaffLoadingCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(MariPalette.ink)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct StaffEmptyCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(MariPalette.ink)
            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct StaffEditorNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MariPalette.softInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: 0xFFF4D4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(hex: 0xF0D98B), lineWidth: 1)
            )
    }
}

private struct SettingsOverviewScreen: View {
    @ObservedObject var store: MoreStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MoreSubscreenHeader(title: "Настройки") {
                    Button {
                        Task { await store.refreshSettings() }
                    } label: {
                        if store.isSettingsLoading {
                            ProgressView()
                                .tint(MariPalette.ink)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(MariPalette.ink)
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsInfoCard(
                    title: "Сервис",
                    text: "Здесь собраны служебные настройки салона. Сейчас доступен раздел с уведомлениями по эл. почте для клиентов, администраторов и сотрудников."
                )

                NavigationLink {
                    SettingsNotificationsScreen(store: store)
                } label: {
                    SettingsEntryCard(
                        title: "Уведомления",
                        subtitle: "Какие письма получает клиент, администратор и сотрудник. Здесь же настраивается время отправки напоминания перед визитом.",
                        badge: store.notificationScenarioCount > 0 ? "\(store.notificationScenarioCount) сценариев" : nil,
                        footer: "Эл. почта"
                    )
                }
                .buttonStyle(.plain)

                Text(store.canEditSettings
                     ? "Изменения сохраняются сразу после переключения или после нажатия на кнопку сохранения."
                     : "Просмотр доступен всем сотрудникам, изменение только владельцу.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)

                if !store.errorMessage.isEmpty {
                    MoreErrorText(text: store.errorMessage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.refreshSettings()
        }
    }
}

private struct SettingsNotificationsScreen: View {
    @ObservedObject var store: MoreStore

    @State private var draftMinNotice = "120"
    @State private var expandedSectionIDs: Set<String> = []
    @State private var pendingToggleStates: [String: Bool] = [:]
    @State private var localErrorMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MoreSubscreenHeader(title: "Уведомления") {
                    Button {
                        Task { await store.refreshSettings() }
                    } label: {
                        if store.isSettingsLoading {
                            ProgressView()
                                .tint(MariPalette.ink)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(MariPalette.ink)
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsReminderCard(
                    value: $draftMinNotice,
                    isSaving: store.savingNotificationMinNotice,
                    canEdit: store.canEditSettings,
                    onSave: saveMinNotice
                )

                if !store.canEditSettings {
                    StaffEditorNotice(text: "Изменение настроек уведомлений доступно только владельцу.")
                }

                if store.isSettingsLoading && store.notificationSections.isEmpty {
                    StaffLoadingCard(text: "Загружаю сценарии уведомлений...")
                } else {
                    ForEach(store.notificationSections) { section in
                        SettingsSectionCard(
                            section: section,
                            isExpanded: expandedSectionIDs.contains(section.id),
                            pendingToggleStates: pendingToggleStates,
                            store: store,
                            onToggleExpanded: { toggleSection(section.id) },
                            onToggleItem: handleToggle(_:enabled:)
                        )
                    }
                }

                if !(localErrorMessage.isEmpty && store.errorMessage.isEmpty) {
                    MoreErrorText(text: localErrorMessage.isEmpty ? store.errorMessage : localErrorMessage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            expandSectionsIfNeeded()
            await store.refreshSettings()
        }
        .onChange(of: store.notificationMinNoticeMinutes) { _, newValue in
            draftMinNotice = String(newValue ?? 120)
        }
        .onChange(of: store.notificationSections) { _, _ in
            expandSectionsIfNeeded()
        }
    }

    private func expandSectionsIfNeeded() {
        guard expandedSectionIDs.isEmpty else { return }
        expandedSectionIDs = Set(store.notificationSections.map(\.id))
        draftMinNotice = String(store.notificationMinNoticeMinutes ?? 120)
    }

    private func toggleSection(_ id: String) {
        if expandedSectionIDs.contains(id) {
            expandedSectionIDs.remove(id)
        } else {
            expandedSectionIDs.insert(id)
        }
    }

    private func saveMinNotice() {
        localErrorMessage = ""
        let normalized = draftMinNotice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(normalized), value > 0 else {
            localErrorMessage = "Укажи корректное количество минут"
            return
        }

        Task {
            let saved = await store.saveNotificationMinNotice(value)
            if !saved {
                localErrorMessage = store.errorMessage.isEmpty ? "Не удалось сохранить время напоминания" : store.errorMessage
            }
        }
    }

    private func handleToggle(_ item: SettingsNotificationItem, enabled: Bool) {
        pendingToggleStates[item.id] = enabled
        localErrorMessage = ""

        Task {
            let saved = await store.toggleNotificationSetting(id: item.id, enabled: enabled)
            pendingToggleStates[item.id] = nil
            if !saved {
                localErrorMessage = store.errorMessage.isEmpty ? "Не удалось обновить уведомление" : store.errorMessage
            }
        }
    }
}

private struct PrivacyPolicyScreen: View {
    @ObservedObject var store: MoreStore

    @State private var isEditing = false
    @State private var draft = ""
    @State private var localErrorMessage = ""

    private var sections: [String] {
        store.privacyPolicyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MoreSubscreenHeader(title: "Политика конфиденциальности") {
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.refreshPrivacyPolicy() }
                        } label: {
                            if store.isSettingsLoading {
                                ProgressView()
                                    .tint(MariPalette.ink)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(MariPalette.ink)
                            }
                        }
                        .buttonStyle(.plain)

                        if store.canEditPrivacyPolicy {
                            Button {
                                if isEditing {
                                    isEditing = false
                                    draft = store.privacyPolicyText
                                    localErrorMessage = ""
                                } else {
                                    isEditing = true
                                    draft = store.privacyPolicyText
                                }
                            } label: {
                                Image(systemName: isEditing ? "xmark" : "pencil")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(MariPalette.ink)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.actionLoading)
                        }
                    }
                }

                SettingsInfoCard(
                    title: "Политика конфиденциальности",
                    text: "Этот текст хранится на сервере и используется клиентским приложением и публичной страницей политики конфиденциальности."
                )

                if !store.canEditPrivacyPolicy {
                    StaffEditorNotice(text: "Просмотр доступен, редактирование только сотрудникам с правом `MANAGE_CLIENT_FRONT`.")
                }

                VStack(alignment: .leading, spacing: 12) {
                    if isEditing {
                        TextEditor(text: $draft)
                            .font(.body.weight(.medium))
                            .foregroundStyle(MariPalette.ink)
                            .frame(minHeight: 320)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color.white.opacity(0.54))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    let saved = await store.savePrivacyPolicy(draft)
                                    if saved {
                                        isEditing = false
                                        localErrorMessage = ""
                                    } else {
                                        localErrorMessage = store.errorMessage.isEmpty ? "Не удалось сохранить политику" : store.errorMessage
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if store.actionLoading {
                                        ProgressView()
                                            .tint(MariPalette.ink)
                                    } else {
                                        Image(systemName: "checkmark")
                                    }
                                    Text("Сохранить")
                                }
                                .font(.subheadline.weight(.black))
                                .foregroundStyle(MariPalette.ink)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(MariPalette.accent)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(store.actionLoading)

                            Button {
                                isEditing = false
                                draft = store.privacyPolicyText
                                localErrorMessage = ""
                            } label: {
                                Text("Отмена")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(MariPalette.ink)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color.white.opacity(0.54))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(store.actionLoading)
                        }
                    } else if store.isSettingsLoading && store.privacyPolicyText.isEmpty {
                        StaffLoadingCard(text: "Загружаю политику конфиденциальности...")
                    } else if sections.isEmpty {
                        StaffEmptyCard(
                            title: "Политика конфиденциальности пока не заполнена",
                            subtitle: "После публикации этот текст используется клиентским приложением и публичной страницей."
                        )
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            Text(section)
                                .font(.body.weight(.medium))
                                .foregroundStyle(MariPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(Color.white.opacity(0.54))
                                )
                        }
                    }

                    if !(localErrorMessage.isEmpty && store.errorMessage.isEmpty) {
                        MoreErrorText(text: localErrorMessage.isEmpty ? store.errorMessage : localErrorMessage)
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.64))
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            draft = store.privacyPolicyText
            await store.refreshPrivacyPolicy()
        }
        .onChange(of: store.privacyPolicyText) { _, newValue in
            if !isEditing {
                draft = newValue
            }
        }
    }
}

private struct SettingsInfoCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(MariPalette.ink)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MariPalette.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct SettingsEntryCard: View {
    let title: String
    let subtitle: String
    let badge: String?
    let footer: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: 0xFFF4D4))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "bell")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(hex: 0x9E7B00))
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(MariPalette.ink)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.black))
                            .foregroundStyle(MariPalette.softInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(hex: 0xEEF2F7))
                            )
                    }
                }

                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)

                Text(footer)
                    .font(.caption.weight(.black))
                    .foregroundStyle(MariPalette.softInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(hex: 0xEEF2F7))
                    )
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct SettingsReminderCard: View {
    @Binding var value: String
    let isSaving: Bool
    let canEdit: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: 0xFFF4D4))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "clock")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color(hex: 0x9E7B00))
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Напоминание перед визитом")
                        .font(.caption.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(MariPalette.softInk)
                    Text("За сколько минут до записи отправлять клиенту письмо-напоминание.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MariPalette.softInk)
                }
            }

            HStack(spacing: 10) {
                TextField("120", text: $value)
                    .keyboardType(.numberPad)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )

                Button(action: onSave) {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(MariPalette.ink)
                        }
                        Text("Сохранить")
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(MariPalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(MariPalette.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canEdit || isSaving)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct SettingsSectionCard: View {
    let section: SettingsNotificationSection
    let isExpanded: Bool
    let pendingToggleStates: [String: Bool]
    @ObservedObject var store: MoreStore
    let onToggleExpanded: () -> Void
    let onToggleItem: (SettingsNotificationItem, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggleExpanded) {
                HStack {
                    Text(section.title)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(MariPalette.ink)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MariPalette.softInk)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(Color.black.opacity(0.06))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.groups) { group in
                        if !group.title.isEmpty {
                            Text(group.title)
                                .font(.caption.weight(.black))
                                .tracking(1.2)
                                .foregroundStyle(MariPalette.softInk)
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                        }

                        ForEach(group.items) { item in
                            SettingsToggleRow(
                                item: item,
                                isOn: pendingToggleStates[item.id] ?? item.enabled,
                                isBusy: store.isTogglingNotification(item.id),
                                canEdit: store.canEditSettings,
                                onToggle: { onToggleItem(item, $0) }
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.64))
        )
    }
}

private struct SettingsToggleRow: View {
    let item: SettingsNotificationItem
    let isOn: Bool
    let isBusy: Bool
    let canEdit: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: onToggle
        )) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MariPalette.ink)
                HStack(spacing: 8) {
                    Text(item.channelLabel)
                        .font(.caption.weight(.black))
                        .foregroundStyle(MariPalette.softInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(hex: 0xEEF2F7))
                        )
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(MariPalette.softInk)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(MariPalette.accent)
        .disabled(!canEdit || isBusy)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct MoreErrorText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(hex: 0x9A5447))
    }
}

private enum StaffEmploymentFilter: CaseIterable, Identifiable {
    case all
    case current
    case fired
    case deleted

    var id: String { title }

    var title: String {
        switch self {
        case .all: "Все"
        case .current: "Текущие"
        case .fired: "Уволенные"
        case .deleted: "Удаленные"
        }
    }

    func matches(_ staff: MariAPIClient.StaffRecord) -> Bool {
        switch self {
        case .all:
            true
        case .current:
            staff.deletedAt == nil && staff.firedAt == nil
        case .fired:
            staff.deletedAt == nil && staff.firedAt != nil
        case .deleted:
            staff.deletedAt != nil
        }
    }
}

private func roleTitle(_ role: String) -> String {
    switch role {
    case "OWNER": "Владелец"
    case "ADMIN": "Администратор"
    case "MASTER": "Мастер"
    case "DEVELOPER": "Разработчик"
    case "SMM": "SMM"
    default: role
    }
}

private func employmentStatusTitle(for staff: MariAPIClient.StaffRecord) -> String {
    if staff.deletedAt != nil {
        return "Удаленный"
    }
    if staff.firedAt != nil || !staff.isActive {
        return "Уволенный"
    }
    return "Текущий"
}

private func employmentStatusTint(for staff: MariAPIClient.StaffRecord) -> Color {
    if staff.deletedAt != nil {
        return Color(hex: 0xECEFF4)
    }
    if staff.firedAt != nil || !staff.isActive {
        return Color(hex: 0xF9EAD7)
    }
    return Color(hex: 0xE4F4E8)
}

private func staffServiceDurationTitle(_ durationSec: Int) -> String {
    let totalMinutes = max(0, Int((Double(durationSec) / 60.0).rounded()))
    if totalMinutes == 0 {
        return "0 мин"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
        return "\(hours) ч \(minutes) мин"
    }
    if hours > 0 {
        return "\(hours) ч"
    }
    return "\(minutes) мин"
}

private func staffPermissionGroupTitle(_ group: MariAPIClient.StaffPermissionCatalogItem.Group) -> String {
    switch group {
    case .workspace:
        "Разделы приложения"
    case .finance:
        "Финансы"
    case .marketing:
        "Маркетинг"
    case .content:
        "Контент и медиа"
    }
}

#Preview {
    MoreScreen(
        sessionStore: AppSessionStore(configuration: AppConfigurationStore()),
        onLogout: {}
    )
}
