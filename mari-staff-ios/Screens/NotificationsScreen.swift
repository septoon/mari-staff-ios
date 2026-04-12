import Combine
import SwiftUI

@MainActor
private final class ServicesStore: ObservableObject {
    @Published private(set) var services: [MariAPIClient.ServiceRecord] = []
    @Published private(set) var categories: [MariAPIClient.ServiceCategoryRecord] = []
    @Published private(set) var masters: [MariAPIClient.StaffRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage = ""

    let session: StaffSession?
    private let apiClient: MariAPIClient
    private var hasLoaded = false

    init(apiClient: MariAPIClient, session: StaffSession?) {
        self.apiClient = apiClient
        self.session = session
    }

    var canViewServices: Bool {
        mariHasPermissionAccess(session, permissionCode: "VIEW_SERVICES")
    }

    var canEditServices: Bool {
        mariHasPermissionAccess(session, permissionCode: "EDIT_SERVICES")
    }

    var canEditStaffAssignments: Bool {
        mariHasPermissionAccess(session, permissionCode: "EDIT_STAFF")
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        guard canViewServices else { return }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        let servicesTask = Task { try await apiClient.listServices(page: 1, limit: 500) }
        let categoriesTask = Task { try await apiClient.listServiceCategories() }
        let mastersTask = canEditStaffAssignments
            ? Task {
                try await apiClient.listStaff(
                    page: 1,
                    limit: 200,
                    role: "MASTER",
                    isActive: true,
                    employmentStatus: "current"
                )
            }
            : nil

        do {
            let servicesPayload = try await servicesTask.value
            let categoriesPayload = try await categoriesTask.value

            services = servicesPayload.items.sorted { lhs, rhs in
                let categoryCompare = lhs.category.name.localizedCaseInsensitiveCompare(rhs.category.name)
                if categoryCompare == .orderedSame {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return categoryCompare == .orderedAscending
            }
            categories = categoriesPayload.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if let mastersTask {
                let mastersPayload = try await mastersTask.value
                masters = mastersPayload.items
                    .filter { $0.role == "MASTER" && $0.deletedAt == nil && $0.firedAt == nil && $0.isActive }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func loadMastersIfNeeded() async throws {
        guard canEditStaffAssignments else { return }
        guard masters.isEmpty else { return }

        let payload = try await apiClient.listStaff(
            page: 1,
            limit: 200,
            role: "MASTER",
            isActive: true,
            employmentStatus: "current"
        )
        masters = payload.items
            .filter { $0.role == "MASTER" && $0.deletedAt == nil && $0.firedAt == nil && $0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func category(id: String) -> MariAPIClient.ServiceCategoryRecord? {
        categories.first(where: { $0.id == id })
    }

    func service(id: String) -> MariAPIClient.ServiceRecord? {
        services.first(where: { $0.id == id })
    }

    func servicesCount(for categoryID: String) -> Int {
        services.filter { $0.category.id == categoryID }.count
    }

    func services(in categoryID: String) -> [MariAPIClient.ServiceRecord] {
        services
            .filter { $0.category.id == categoryID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadProviderIDs(for serviceID: String) async throws -> Set<String> {
        guard canEditStaffAssignments else { return [] }
        try await loadMastersIfNeeded()

        return try await withThrowingTaskGroup(of: String?.self) { group in
            for master in masters {
                group.addTask { [apiClient] in
                    let payload = try await apiClient.listStaffServices(id: master.id)
                    return payload.items.contains(where: { $0.id == serviceID }) ? master.id : nil
                }
            }

            var ids = Set<String>()
            for try await result in group {
                if let result {
                    ids.insert(result)
                }
            }
            return ids
        }
    }

    func saveCategory(id: String?, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MariAPIClient.APIClientError.server(message: "Название категории обязательно")
        }

        isSaving = true
        defer { isSaving = false }

        if let id {
            let updated = try await apiClient.updateServiceCategory(id: id, name: trimmed)
            if let index = categories.firstIndex(where: { $0.id == id }) {
                categories[index] = updated
            }
        } else {
            let created = try await apiClient.createServiceCategory(name: trimmed)
            categories.append(created)
            categories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        errorMessage = ""
    }

    func deleteCategory(id: String) async throws {
        isSaving = true
        defer { isSaving = false }

        try await apiClient.deleteServiceCategory(id: id)
        categories.removeAll(where: { $0.id == id })
        services.removeAll(where: { $0.category.id == id })
        errorMessage = ""
    }

    func saveService(
        id: String?,
        name: String,
        categoryID: String,
        description: String?,
        durationMinutes: Int,
        priceMin: Double,
        isActive: Bool,
        providerIDs: Set<String>
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MariAPIClient.APIClientError.server(message: "Название услуги обязательно")
        }
        guard !categoryID.isEmpty else {
            throw MariAPIClient.APIClientError.server(message: "Выберите категорию")
        }

        isSaving = true
        defer { isSaving = false }

        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDuration = max(10, durationMinutes) * 60
        let normalizedPrice = max(0, priceMin)

        let saved: MariAPIClient.ServiceRecord
        if let id {
            saved = try await apiClient.updateService(
                id: id,
                name: trimmedName,
                nameOnline: trimmedName,
                categoryID: categoryID,
                description: trimmedDescription?.isEmpty == true ? nil : trimmedDescription,
                durationSec: normalizedDuration,
                priceMin: normalizedPrice,
                priceMax: normalizedPrice,
                isActive: isActive
            )
        } else {
            saved = try await apiClient.createService(
                name: trimmedName,
                nameOnline: trimmedName,
                categoryID: categoryID,
                description: trimmedDescription?.isEmpty == true ? nil : trimmedDescription,
                durationSec: normalizedDuration,
                priceMin: normalizedPrice,
                priceMax: normalizedPrice,
                isActive: isActive
            )
        }

        upsertService(saved)

        if canEditStaffAssignments {
            try await syncProviders(serviceID: saved.id, targetProviderIDs: providerIDs)
        }

        errorMessage = ""
    }

    func deleteService(id: String) async throws {
        isSaving = true
        defer { isSaving = false }

        try await apiClient.deleteService(id: id)
        services.removeAll(where: { $0.id == id })
        errorMessage = ""
    }

    private func syncProviders(serviceID: String, targetProviderIDs: Set<String>) async throws {
        try await loadMastersIfNeeded()

        for master in masters {
            let payload = try await apiClient.listStaffServices(id: master.id)
            let currentIDs = payload.items.map(\.id)
            let hasService = currentIDs.contains(serviceID)
            let shouldHaveService = targetProviderIDs.contains(master.id)

            guard hasService != shouldHaveService else { continue }

            let nextIDs: [String]
            if shouldHaveService {
                nextIDs = Array(Set(currentIDs + [serviceID])).sorted()
            } else {
                nextIDs = currentIDs.filter { $0 != serviceID }
            }

            _ = try await apiClient.updateStaffServices(id: master.id, serviceIDs: nextIDs)
        }
    }

    private func upsertService(_ service: MariAPIClient.ServiceRecord) {
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        } else {
            services.append(service)
        }

        services.sort { lhs, rhs in
            let categoryCompare = lhs.category.name.localizedCaseInsensitiveCompare(rhs.category.name)
            if categoryCompare == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return categoryCompare == .orderedAscending
        }
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private struct ServiceCategoryEditorContext: Identifiable {
    let category: MariAPIClient.ServiceCategoryRecord?
    var id: String { category?.id ?? "new-category" }
}

private struct ServiceEditorContext: Identifiable {
    let service: MariAPIClient.ServiceRecord?
    let defaultCategoryID: String?
    var id: String { service?.id ?? "new-service-\(defaultCategoryID ?? "none")" }
}

private struct ServiceEditorDraftValue {
    let id: String?
    var name: String
    var categoryID: String
    var description: String
    var durationMinutesText: String
    var priceText: String
    var isActive: Bool

    init(service: MariAPIClient.ServiceRecord?, defaultCategoryID: String?) {
        id = service?.id
        name = service?.name ?? ""
        categoryID = service?.category.id ?? (defaultCategoryID ?? "")
        description = service?.description ?? ""
        durationMinutesText = String(max(10, Int(((Double(service?.durationSec ?? 600)) / 60.0).rounded())))
        priceText = String(Int((service?.priceMin ?? 0).rounded()))
        isActive = service?.isActive ?? true
    }
}

struct ServicesScreen: View {
    let sessionStore: AppSessionStore

    @StateObject private var store: ServicesStore
    @State private var search = ""
    @State private var categoryEditorContext: ServiceCategoryEditorContext?

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        _store = StateObject(
            wrappedValue: ServicesStore(
                apiClient: sessionStore.api,
                session: sessionStore.currentSession
            )
        )
    }

    private var filteredCategories: [MariAPIClient.ServiceCategoryRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.categories }

        return store.categories.filter { category in
            category.name.lowercased().contains(query)
                || store.services(in: category.id).contains { service in
                    [service.name, service.nameOnline ?? "", service.description ?? ""]
                        .joined(separator: " ")
                        .lowercased()
                        .contains(query)
                }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ServicesHeader(
                    title: "Услуги",
                    trailing: {
                        HStack(spacing: 10) {
                            Button {
                                Task { await store.reload() }
                            } label: {
                                if store.isLoading {
                                    ProgressView()
                                        .tint(MariPalette.ink)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(MariPalette.ink)
                                }
                            }
                            .buttonStyle(.plain)

                            if store.canEditServices {
                                Button {
                                    categoryEditorContext = .init(category: nil)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(MariPalette.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                )

                if !store.canViewServices {
                    ServicesEmptyState(
                        title: "Нет доступа",
                        subtitle: "Для просмотра услуг нужен `VIEW_SERVICES` или `EDIT_SERVICES`."
                    )
                } else {
                    ServicesSearchField(text: $search, placeholder: "Поиск")

                    if store.isLoading && store.categories.isEmpty {
                        ServicesLoadingCard(text: "Загружаю категории и услуги...")
                    } else if filteredCategories.isEmpty {
                        ServicesEmptyState(
                            title: "Категории не найдены",
                            subtitle: "Попробуй другой запрос или создай новую категорию."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(filteredCategories) { category in
                                ServicesCategoryRow(
                                    category: category,
                                    count: store.servicesCount(for: category.id),
                                    canEdit: store.canEditServices,
                                    onEdit: {
                                        categoryEditorContext = .init(category: category)
                                    },
                                    destination: ServicesCategoryScreen(
                                        store: store,
                                        categoryID: category.id
                                    )
                                )
                            }
                        }
                    }

                    Text("Всего услуг: \(store.services.count)")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(MariPalette.softInk)
                        .padding(.top, 6)
                }

                if !store.errorMessage.isEmpty {
                    Text(store.errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .mariPullToRefresh {
            await store.reload()
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadIfNeeded()
        }
        .fullScreenCover(item: $categoryEditorContext) { context in
            ServiceCategoryEditorScreen(store: store, category: context.category)
        }
    }
}

private struct ServicesCategoryScreen: View {
    @ObservedObject var store: ServicesStore
    let categoryID: String

    @State private var search = ""
    @State private var editorContext: ServiceEditorContext?
    @State private var categoryEditorContext: ServiceCategoryEditorContext?
    @Environment(\.dismiss) private var dismiss

    private var category: MariAPIClient.ServiceCategoryRecord? {
        store.category(id: categoryID)
    }

    private var filteredServices: [MariAPIClient.ServiceRecord] {
        let services = store.services(in: categoryID)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return services }

        return services.filter { service in
            [service.name, service.nameOnline ?? "", service.description ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ServicesHeader(
                    title: category?.name ?? "Категория",
                    leadingMode: .back,
                    trailing: {
                        HStack(spacing: 10) {
                            if store.canEditServices {
                                Button {
                                    if let category {
                                        categoryEditorContext = .init(category: category)
                                    }
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(MariPalette.ink)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    editorContext = .init(service: nil, defaultCategoryID: categoryID)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(MariPalette.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                )

                ServicesSearchField(text: $search, placeholder: "Поиск")

                if filteredServices.isEmpty {
                    ServicesEmptyState(
                        title: "Услуги не найдены",
                        subtitle: "В этой категории пока нет совпадений."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(filteredServices) { service in
                            Button {
                                editorContext = .init(service: service, defaultCategoryID: categoryID)
                            } label: {
                                ServiceRow(service: service)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .mariPullToRefresh {
            await store.reload()
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: category?.id) { _, newValue in
            if newValue == nil {
                dismiss()
            }
        }
        .fullScreenCover(item: $editorContext) { context in
            ServiceEditorScreen(
                store: store,
                service: context.service,
                defaultCategoryID: context.defaultCategoryID
            )
        }
        .fullScreenCover(item: $categoryEditorContext) { context in
            ServiceCategoryEditorScreen(store: store, category: context.category)
        }
    }
}

private struct ServiceEditorScreen: View {
    @ObservedObject var store: ServicesStore
    let service: MariAPIClient.ServiceRecord?
    let defaultCategoryID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServiceEditorDraftValue
    @State private var selectedProviderIDs: Set<String> = []
    @State private var isAssignSheetPresented = false
    @State private var errorMessage = ""
    @State private var isDeleteAlertPresented = false
    @State private var isProvidersLoading: Bool

    init(
        store: ServicesStore,
        service: MariAPIClient.ServiceRecord?,
        defaultCategoryID: String?
    ) {
        self.store = store
        self.service = service
        self.defaultCategoryID = defaultCategoryID
        _draft = State(initialValue: ServiceEditorDraftValue(service: service, defaultCategoryID: defaultCategoryID))
        _isProvidersLoading = State(initialValue: service != nil && store.canEditStaffAssignments)
    }

    private var assignedProviders: [MariAPIClient.StaffRecord] {
        store.masters.filter { selectedProviderIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServicesHeader(
                    title: "Услуга",
                    leadingMode: .close,
                    trailing: {
                        if draft.id != nil && store.canEditServices {
                            Button {
                                isDeleteAlertPresented = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xA05A53))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                )

                ServicesEditorField(title: "Название услуги") {
                    TextField("", text: $draft.name)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(MariPalette.ink)
                }

                ServicesEditorField(title: "Категория") {
                    Picker("", selection: $draft.categoryID) {
                        Text("Выберите категорию").tag("")
                        ForEach(store.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(MariPalette.ink)
                }

                ServicesToggleRow(
                    title: "Доступна для онлайн-записи",
                    isOn: $draft.isActive
                )

                ServicesEditorField(title: "Описание") {
                    TextEditor(text: $draft.description)
                        .frame(minHeight: 120)
                        .font(.body.weight(.medium))
                        .foregroundStyle(MariPalette.ink)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                }

                Text("Параметры услуги")
                    .font(.title3.weight(.black))
                    .foregroundStyle(MariPalette.ink)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    ServicesEditorField(title: "Базовая цена, ₽") {
                        TextField("", text: $draft.priceText)
                            .keyboardType(.numberPad)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(MariPalette.ink)
                    }

                    ServicesEditorField(title: "Длительность, мин") {
                        TextField("", text: $draft.durationMinutesText)
                            .keyboardType(.numberPad)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(MariPalette.ink)
                    }
                }

                if draft.id != nil {
                    providersSection
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                }

                Button {
                    Task { await save() }
                } label: {
                    Text(store.isSaving ? "Сохраняю..." : "Сохранить")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(MariPalette.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(store.isSaving || !store.canEditServices)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .mariPullToRefresh {
            await store.reload()
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if store.canEditStaffAssignments {
                isProvidersLoading = true
                defer { isProvidersLoading = false }
                try? await store.loadMastersIfNeeded()
                if let id = draft.id {
                    selectedProviderIDs = (try? await store.loadProviderIDs(for: id)) ?? []
                }
            }
        }
        .sheet(isPresented: $isAssignSheetPresented) {
            ServiceProvidersSheet(
                staff: store.masters,
                selectedIDs: selectedProviderIDs,
                onApply: { selectedProviderIDs = $0 }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Удалить услугу?", isPresented: $isDeleteAlertPresented) {
            Button("Удалить", role: .destructive) {
                Task { await deleteService() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Изменение сохранится на сервере.")
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Услугу оказывают")
                    .font(.title3.weight(.black))
                    .foregroundStyle(MariPalette.ink)

                Spacer()

                if store.canEditStaffAssignments {
                    Button("Назначить") {
                        isAssignSheetPresented = true
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                }
            }

            if !store.canEditStaffAssignments {
                ServicesEmptyState(
                    title: "Назначение сотрудников недоступно",
                    subtitle: "Для обратной привязки услуги к мастерам нужен `EDIT_STAFF`."
                )
            } else if isProvidersLoading {
                ServicesLoadingCard(text: "Загружаю привязки сотрудников...")
            } else if assignedProviders.isEmpty {
                ServicesEmptyState(
                    title: "Нет назначенных мастеров",
                    subtitle: "Добавь сотрудников, которые оказывают эту услугу."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(assignedProviders) { staff in
                        HStack(spacing: 12) {
                            ServicesPersonBadge(name: staff.name)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(staff.name)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(MariPalette.ink)
                                Text(staff.position?.name ?? servicesRoleTitle(staff.role))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(MariPalette.softInk)
                            }

                            Spacer()

                            Button {
                                selectedProviderIDs.remove(staff.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xA05A53))
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(.white.opacity(0.7))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.64))
                        )
                    }
                }
            }
        }
    }

    private func save() async {
        guard let durationMinutes = Int(draft.durationMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
              durationMinutes > 0 else {
            errorMessage = "Введите корректную длительность"
            return
        }

        guard let price = Double(draft.priceText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Введите корректную цену"
            return
        }

        do {
            try await store.saveService(
                id: draft.id,
                name: draft.name,
                categoryID: draft.categoryID,
                description: draft.description,
                durationMinutes: durationMinutes,
                priceMin: price,
                isActive: draft.isActive,
                providerIDs: selectedProviderIDs
            )
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteService() async {
        guard let id = draft.id else { return }

        do {
            try await store.deleteService(id: id)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ServiceCategoryEditorScreen: View {
    @ObservedObject var store: ServicesStore
    let category: MariAPIClient.ServiceCategoryRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage = ""
    @State private var isDeleteAlertPresented = false

    init(store: ServicesStore, category: MariAPIClient.ServiceCategoryRecord?) {
        self.store = store
        self.category = category
        _name = State(initialValue: category?.name ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServicesHeader(
                    title: category == nil ? "Новая категория" : "Категория",
                    leadingMode: .close,
                    trailing: {
                        if category != nil && store.canEditServices {
                            Button {
                                isDeleteAlertPresented = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color(hex: 0xA05A53))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                )

                ServicesEditorField(title: "Название категории") {
                    TextField("", text: $name)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(MariPalette.ink)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x9A5447))
                }

                Button {
                    Task { await save() }
                } label: {
                    Text(store.isSaving ? "Сохраняю..." : "Сохранить")
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
                .disabled(store.isSaving || !store.canEditServices)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .mariPullToRefresh {
            await store.reload()
        }
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("Удалить категорию?", isPresented: $isDeleteAlertPresented) {
            Button("Удалить", role: .destructive) {
                Task { await deleteCategory() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удаление сработает только если в категории нет услуг.")
        }
    }

    private func save() async {
        do {
            try await store.saveCategory(id: category?.id, name: name)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteCategory() async {
        guard let category else { return }

        do {
            try await store.deleteCategory(id: category.id)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ServiceProvidersSheet: View {
    let staff: [MariAPIClient.StaffRecord]
    let selectedIDs: Set<String>
    let onApply: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftSelection: Set<String>

    init(
        staff: [MariAPIClient.StaffRecord],
        selectedIDs: Set<String>,
        onApply: @escaping (Set<String>) -> Void
    ) {
        self.staff = staff
        self.selectedIDs = selectedIDs
        self.onApply = onApply
        _draftSelection = State(initialValue: selectedIDs)
    }

    var body: some View {
        NavigationStack {
            List(staff) { member in
                Button {
                    if draftSelection.contains(member.id) {
                        draftSelection.remove(member.id)
                    } else {
                        draftSelection.insert(member.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ServicesPersonBadge(name: member.name)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MariPalette.ink)
                            Text(member.position?.name ?? servicesRoleTitle(member.role))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(MariPalette.softInk)
                        }

                        Spacer()

                        Image(systemName: draftSelection.contains(member.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(draftSelection.contains(member.id) ? MariPalette.accent : Color.black.opacity(0.16))
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(MariBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Назначить сотрудников")
                        .font(.headline.weight(.black))
                        .foregroundStyle(MariPalette.ink)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        onApply(draftSelection)
                        dismiss()
                    }
                    .font(.headline.weight(.bold))
                }
            }
        }
    }
}

private struct ServicesCategoryRow<Destination: View>: View {
    let category: MariAPIClient.ServiceCategoryRecord
    let count: Int
    let canEdit: Bool
    let onEdit: () -> Void
    let destination: Destination

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                destination
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(count) услуг")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MariPalette.softInk)
                    }

                    Spacer()

                    Text("\(count)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(MariPalette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.06)))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MariPalette.softInk)
                }
            }
            .buttonStyle(.plain)

            if canEdit {
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MariPalette.softInk)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ServiceRow: View {
    let service: MariAPIClient.ServiceRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(service.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Label(MariFormatters.money(Int(service.priceMin.rounded())), systemImage: "banknote")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)

                    Label(serviceDurationText(service.durationSec), systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                }
            }

            Spacer()

            if !service.isActive {
                Text("OFF")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color(hex: 0x9A5447))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: 0xF7E0DB)))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MariPalette.softInk)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ServicesHeader<Trailing: View>: View {
    enum LeadingMode {
        case none
        case back
        case close
    }

    let title: String
    var leadingMode: LeadingMode = .none
    @ViewBuilder let trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 28, alignment: .leading)

            Spacer()

            Text(title)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)
                .multilineTextAlignment(.center)

            Spacer()

            trailing
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var leading: some View {
        switch leadingMode {
        case .none:
            Color.clear
        case .back:
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
            }
            .buttonStyle(.plain)
        case .close:
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MariPalette.ink)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ServicesSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MariPalette.softInk)

            TextField(placeholder, text: $text)
                .font(.headline.weight(.medium))
                .foregroundStyle(MariPalette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ServicesEditorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            content
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

private struct ServicesToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(MariPalette.ink)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(MariPalette.accent)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ServicesLoadingCard: View {
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
                .fill(.white.opacity(0.66))
        )
    }
}

private struct ServicesEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(MariPalette.ink)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.66))
        )
    }
}

private struct ServicesPersonBadge: View {
    let name: String

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: 0xE8EDF5))

            Text(initial.isEmpty ? "•" : initial)
                .font(.headline.weight(.black))
                .foregroundStyle(MariPalette.ink)
        }
        .frame(width: 42, height: 42)
    }
}

private func serviceDurationText(_ durationSec: Int) -> String {
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

private func servicesRoleTitle(_ role: String) -> String {
    StaffRole(rawValue: role)?.title ?? role
}

#Preview {
    ServicesScreen(
        sessionStore: AppSessionStore(configuration: AppConfigurationStore())
    )
}
