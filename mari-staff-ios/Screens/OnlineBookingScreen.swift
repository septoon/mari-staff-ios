import Combine
import SwiftUI

private enum OnlineBookingSection: String, CaseIterable, Identifiable {
    case home
    case services
    case specialists
    case contacts
    case page
    case promo
    case legal
    case advanced
    case publish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Главная страница"
        case .services: "Услуги"
        case .specialists: "Специалисты"
        case .contacts: "Контакты"
        case .page: "Страница записи"
        case .promo: "Акции и предложения"
        case .legal: "Политика конфиденциальности"
        case .advanced: "Служебные настройки"
        case .publish: "Состояние сайта"
        }
    }

    var subtitle: String {
        switch self {
        case .home:
            "Hero, CTA и основные секции клиентской витрины."
        case .services:
            "Как услуги уже выглядят для клиента в онлайн-записи."
        case .specialists:
            "Карточки мастеров, видимость и клиентские тексты."
        case .contacts:
            "Публичный телефон, адрес, почта и сайт."
        case .page:
            "Тексты страницы /booking и шагов записи."
        case .promo:
            "Маркетинговые блоки и legacy-контент client-front."
        case .legal:
            "Политика, cookie и согласия."
        case .advanced:
            "Brand, maintenance и feature flags."
        case .publish:
            "Preview, версия и история публикаций."
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .services: "scissors"
        case .specialists: "person.2"
        case .contacts: "map"
        case .page: "doc.text"
        case .promo: "megaphone"
        case .legal: "shield"
        case .advanced: "slider.horizontal.3"
        case .publish: "rocket"
        }
    }
}

private enum OnlineBookingBannerStyle {
    case success
    case warning
    case error

    var tint: Color {
        switch self {
        case .success: Color(hex: 0xDDF4E4)
        case .warning: Color(hex: 0xFFF1D6)
        case .error: Color(hex: 0xF8E2DB)
        }
    }

    var foreground: Color {
        switch self {
        case .success: Color(hex: 0x18613A)
        case .warning: Color(hex: 0x8F5E14)
        case .error: Color(hex: 0x9A5447)
        }
    }
}

private struct OnlineBookingBanner: Identifiable {
    let id = UUID()
    let style: OnlineBookingBannerStyle
    let message: String
}

@MainActor
private final class OnlineBookingStore: ObservableObject {
    @Published private(set) var config: MariAPIClient.ClientFrontConfigRecord?
    @Published private(set) var blocks: [MariAPIClient.ClientFrontBlockRecord] = []
    @Published private(set) var specialists: [MariAPIClient.ClientFrontSpecialistRecord] = []
    @Published private(set) var services: [MariAPIClient.ServiceRecord] = []
    @Published private(set) var releases: [MariAPIClient.ClientFrontReleaseRecord] = []
    @Published private(set) var preview: MariAPIClient.ClientFrontPreviewRecord?
    @Published private(set) var privacyPolicyText = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage = ""
    @Published var banner: OnlineBookingBanner?

    private let apiClient: MariAPIClient
    private var hasLoaded = false

    init(apiClient: MariAPIClient) {
        self.apiClient = apiClient
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        await reload(silent: false)
    }

    func clearBanner() {
        banner = nil
    }

    func saveHomeDraft(_ draft: OnlineBookingHomeDraft) async {
        guard let config else { return }
        let extra = draft.merged(into: config.extra)
        await saveConfigPatch(
            successMessage: "Главная страница сохранена",
            operation: {
                try await self.apiClient.patchClientFrontConfig(extra: extra)
            }
        )
    }

    func savePageDraft(_ draft: OnlineBookingPageDraft) async {
        guard let config else { return }
        let extra = draft.merged(into: config.extra)
        await saveConfigPatch(
            successMessage: "Страница записи сохранена",
            operation: {
                try await self.apiClient.patchClientFrontConfig(extra: extra)
            }
        )
    }

    func saveGeneralDraft(_ draft: OnlineBookingGeneralDraft) async {
        await saveConfigPatch(
            successMessage: "Служебные настройки сохранены",
            operation: {
                try await self.apiClient.patchClientFrontConfig(
                    brandName: draft.brandName.nilIfBlank,
                    legalName: draft.legalName.nilIfBlank,
                    minAppVersionIos: draft.minAppVersionIos.nilIfBlank,
                    minAppVersionAndroid: draft.minAppVersionAndroid.nilIfBlank,
                    maintenanceMode: draft.maintenanceMode,
                    maintenanceMessage: draft.maintenanceMessage.nilIfBlank,
                    featureFlags: draft.featureFlagsObject()
                )
            }
        )
    }

    func saveContactDraft(_ draft: OnlineBookingContactDraft) async {
        let current = config?.contacts ?? []
        let updatedPrimary = draft.contactPoint(using: current.first)
        let rest = Array(current.dropFirst())
        await saveConfigPatch(
            successMessage: "Контакты сохранены",
            operation: {
                try await self.apiClient.patchClientFrontConfig(contacts: [updatedPrimary] + rest)
            }
        )
    }

    func saveSpecialistDraft(_ draft: OnlineBookingSpecialistDraft) async {
        await saveConfigPatch(
            successMessage: "Карточка специалиста сохранена",
            operation: {
                try await self.apiClient.patchClientFrontSpecialist(
                    staffId: draft.staffId,
                    specialty: draft.specialty.nilIfBlank,
                    info: draft.info.nilIfBlank,
                    ctaText: draft.ctaText.nilIfBlank,
                    isVisible: draft.isVisible,
                    sortOrder: draft.sortOrder
                )
            }
        )
    }

    func saveBlockDraft(_ draft: OnlineBookingBlockDraft) async {
        guard let payload = draft.payloadObject() else {
            banner = OnlineBookingBanner(
                style: .error,
                message: "Некорректный JSON payload блока"
            )
            return
        }

        await saveConfigPatch(
            successMessage: "Блок сохранен",
            operation: {
                try await self.apiClient.patchClientFrontBlock(
                    id: draft.id,
                    payload: payload,
                    sortOrder: draft.sortOrder,
                    platform: draft.platform.nilIfBlank,
                    minAppVersion: draft.minAppVersion.nilIfBlank,
                    maxAppVersion: draft.maxAppVersion.nilIfBlank,
                    startAt: draft.startAt.nilIfBlank,
                    endAt: draft.endAt.nilIfBlank,
                    isEnabled: draft.isEnabled
                )
            }
        )
    }

    func publishNow() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await apiClient.publishClientFront()
            banner = OnlineBookingBanner(
                style: .success,
                message: "Опубликована версия v\(result.version)"
            )
            await reload(silent: true)
        } catch {
            banner = OnlineBookingBanner(
                style: .error,
                message: localizedMessage(for: error)
            )
        }
    }

    private func reload(silent: Bool) async {
        if !silent {
            isLoading = true
            errorMessage = ""
        }
        defer {
            if !silent {
                isLoading = false
            }
        }

        do {
            async let configTask = apiClient.getClientFrontStaffConfig()
            async let blocksTask = apiClient.listClientFrontBlocks()
            async let specialistsTask = apiClient.listClientFrontSpecialists()
            async let servicesTask = apiClient.listServices()
            async let releasesTask = apiClient.listClientFrontReleases()
            async let previewTask = apiClient.getClientFrontPreview(platform: "web")
            async let settingsTask = apiClient.getStaffSettings()

            let config = try await configTask
            let blocks = try await blocksTask
            let specialists = try await specialistsTask
            let services = try await servicesTask
            let releases = try await releasesTask
            let preview = try await previewTask
            let settings = try await settingsTask

            self.config = config
            self.blocks = blocks.items.sorted { $0.sortOrder < $1.sortOrder }
            self.specialists = specialists.items.sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            self.services = services.items.sorted { lhs, rhs in
                if lhs.category.name == rhs.category.name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.category.name.localizedCaseInsensitiveCompare(rhs.category.name) == .orderedAscending
            }
            self.releases = releases.items.sorted { $0.publishedAt > $1.publishedAt }
            self.preview = preview
            self.privacyPolicyText = settings.privacyPolicy.content
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    private func saveConfigPatch(
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await operation()
            do {
                let result = try await apiClient.publishClientFront()
                banner = OnlineBookingBanner(
                    style: .success,
                    message: "\(successMessage). Опубликована версия v\(result.version)"
                )
            } catch {
                banner = OnlineBookingBanner(
                    style: .warning,
                    message: "\(successMessage). Сохранено, но публикация не удалась: \(localizedMessage(for: error))"
                )
            }
            await reload(silent: true)
        } catch {
            banner = OnlineBookingBanner(
                style: .error,
                message: localizedMessage(for: error)
            )
        }
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct OnlineBookingScreen: View {
    let sessionStore: AppSessionStore

    @StateObject private var store: OnlineBookingStore

    init(sessionStore: AppSessionStore) {
        self.sessionStore = sessionStore
        _store = StateObject(wrappedValue: OnlineBookingStore(apiClient: sessionStore.api))
    }

    private var isInitialLoading: Bool {
        store.isLoading
            && store.config == nil
            && store.blocks.isEmpty
            && store.specialists.isEmpty
            && store.services.isEmpty
            && store.releases.isEmpty
            && store.preview == nil
            && store.privacyPolicyText.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isInitialLoading {
                    OnlineBookingInitialSkeleton()
                } else {
                    OnlineBookingHeader(
                        title: "Онлайн-запись",
                        isRefreshing: store.isLoading,
                        onRefresh: { Task { await store.reload() } }
                    )

                    if let banner = store.banner {
                        OnlineBookingBannerView(banner: banner)
                    }

                    if !store.errorMessage.isEmpty {
                        OnlineBookingBannerView(
                            banner: OnlineBookingBanner(style: .error, message: store.errorMessage)
                        )
                    }

                    OnlineBookingSummaryGrid(store: store)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Редактор клиентского сайта")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundStyle(MariPalette.ink)

                        ForEach(OnlineBookingSection.allCases) { section in
                            NavigationLink {
                                sectionDestination(for: section)
                            } label: {
                                OnlineBookingSectionCard(
                                    section: section,
                                    stat: stat(for: section),
                                    details: details(for: section)
                                )
                            }
                            .buttonStyle(.plain)
                        }
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
        .refreshable {
            await store.reload()
        }
    }

    @ViewBuilder
    private func sectionDestination(for section: OnlineBookingSection) -> some View {
        switch section {
        case .home:
            OnlineBookingHomeEditorScreen(store: store)
        case .services:
            OnlineBookingServicesScreen(store: store)
        case .specialists:
            OnlineBookingSpecialistsScreen(store: store)
        case .contacts:
            OnlineBookingContactsScreen(store: store)
        case .page:
            OnlineBookingPageEditorScreen(store: store)
        case .promo:
            OnlineBookingPromoScreen(store: store)
        case .legal:
            OnlineBookingLegalScreen(store: store)
        case .advanced:
            OnlineBookingAdvancedScreen(store: store)
        case .publish:
            OnlineBookingPublishScreen(store: store)
        }
    }

    private func stat(for section: OnlineBookingSection) -> String {
        switch section {
        case .home:
            guard let extra = store.config?.extra else { return "—" }
            let fields = OnlineBookingHomeDraft(extra: extra).configuredFieldsCount
            return "\(fields)/9"
        case .services:
            let active = store.services.filter(\.isActive).count
            return "\(active)/\(store.services.count)"
        case .specialists:
            let visible = store.specialists.filter(\.isVisible).count
            return "\(visible)/\(store.specialists.count)"
        case .contacts:
            return store.config?.contacts.isEmpty == false ? "заполнено" : "пусто"
        case .page:
            guard let extra = store.config?.extra else { return "—" }
            let fields = OnlineBookingPageDraft(extra: extra).configuredFieldsCount
            return "\(fields)/11"
        case .promo:
            return "\(store.blocks.count)"
        case .legal:
            return store.privacyPolicyText.nilIfBlank == nil ? "пусто" : "готово"
        case .advanced:
            return "v\(store.config?.publishedVersion ?? 0)"
        case .publish:
            return "v\(store.preview?.version ?? store.config?.publishedVersion ?? 0)"
        }
    }

    private func details(for section: OnlineBookingSection) -> [String] {
        switch section {
        case .home:
            return [
                "Hero, контакты и финальный CTA",
                "Данные берутся из extra.siteContent.homePage"
            ]
        case .services:
            return [
                "Категорий: \(Set(store.services.map(\.category.id)).count)",
                "С client-facing названием: \(store.services.filter { ($0.nameOnline ?? "").nilIfBlank != nil }.count)"
            ]
        case .specialists:
            return [
                "С фото: \(store.specialists.filter { $0.photoAssetId != nil }.count)",
                "С привязанными услугами: \(store.specialists.filter { !$0.services.isEmpty }.count)"
            ]
        case .contacts:
            let contact = store.config?.contacts.first
            return [
                contact?.phones.first?.display ?? contact?.phones.first?.e164 ?? "Телефон не задан",
                contact?.addresses.first?.line1 ?? "Адрес не задан"
            ]
        case .page:
            return [
                "Hero actions, panel, schedule, confirmation",
                "Данные берутся из extra.bookingPage"
            ]
        case .promo:
            return [
                "Legacy-блоков: \(store.blocks.count)",
                "Активных: \(store.blocks.filter(\.isEnabled).count)"
            ]
        case .legal:
            return [
                "Политика и согласия для client-front",
                "Редактирование связано с реальным staff settings"
            ]
        case .advanced:
            return [
                "Maintenance mode: \(store.config?.maintenanceMode == true ? "on" : "off")",
                "Feature flags: \(store.config?.featureFlags.count ?? 0)"
            ]
        case .publish:
            return [
                "Публикаций в истории: \(store.releases.count)",
                "Preview specialists: \(store.preview?.specialists.count ?? 0)"
            ]
        }
    }
}

private struct OnlineBookingSummaryGrid: View {
    @ObservedObject var store: OnlineBookingStore

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            OnlineBookingMetricCard(
                title: "Публикация",
                value: "v\(store.preview?.version ?? store.config?.publishedVersion ?? 0)",
                subtitle: formattedPublishedAt,
                accent: MariPalette.accent
            )
            OnlineBookingMetricCard(
                title: "Услуги",
                value: "\(store.services.filter(\.isActive).count)",
                subtitle: "Активные client-facing услуги",
                accent: Color(hex: 0xD4E9FF)
            )
            OnlineBookingMetricCard(
                title: "Специалисты",
                value: "\(store.specialists.filter(\.isVisible).count)",
                subtitle: "Видимые карточки мастеров",
                accent: Color(hex: 0xE8E2FC)
            )
            OnlineBookingMetricCard(
                title: "Блоки",
                value: "\(store.blocks.count)",
                subtitle: "Legacy promo/content blocks",
                accent: Color(hex: 0xFBE7D8)
            )
        }
    }

    private var formattedPublishedAt: String {
        guard let date = store.config?.publishedAt else { return "Пока не публиковалось" }
        return date.onlineBookingShortDateTime
    }
}

private struct OnlineBookingMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            Text(value)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(MariPalette.softInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )
        )
    }
}

private struct OnlineBookingSectionCard: View {
    let section: OnlineBookingSection
    let stat: String
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 48, height: 48)
                    Image(systemName: section.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MariPalette.ink)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(MariPalette.ink)
                    Text(section.subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MariPalette.softInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Text(stat)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(MariPalette.ink)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: 0xA4ACB8))
                }
            }

            ForEach(details, id: \.self) { detail in
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct OnlineBookingHeader<Trailing: View>: View {
    let title: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @ViewBuilder let trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        isRefreshing: Bool = false,
        onRefresh: @escaping () -> Void = {},
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.trailing = trailing()
    }

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

            HStack(spacing: 10) {
                Button {
                    onRefresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(MariPalette.ink)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MariPalette.ink)
                    }
                }
                .buttonStyle(.plain)

                trailing
            }
            .frame(minWidth: 28)
        }
        .padding(.top, 8)
    }
}

private struct OnlineBookingBannerView: View {
    let banner: OnlineBookingBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(banner.style.foreground)
            Text(banner.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(banner.style.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(banner.style.tint)
        )
    }
}

private struct OnlineBookingInitialSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MariSkeletonCircle(size: 28)
                MariSkeletonBlock(width: 168, height: 30, cornerRadius: 12)
                Spacer()
                MariSkeletonCircle(size: 42)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    MariSkeletonBlock(height: 118, cornerRadius: 24)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                MariSkeletonBlock(width: 210, height: 24, cornerRadius: 10)

                ForEach(0..<OnlineBookingSection.allCases.count, id: \.self) { _ in
                    MariSkeletonBlock(height: 88, cornerRadius: 22)
                }
            }
        }
    }
}

private struct OnlineBookingFormScreen<Content: View>: View {
    let title: String
    let isSaving: Bool
    let onRefresh: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OnlineBookingHeader(title: title, isRefreshing: false, onRefresh: onRefresh)
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(MariBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct OnlineBookingPanel: View {
    let title: String
    let subtitle: String?
    let content: AnyView

    init<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = AnyView(content())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(MariPalette.ink)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct OnlineBookingTextFieldRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            TextField(title, text: $text)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
        }
    }
}

private struct OnlineBookingTextAreaRow: View {
    let title: String
    @Binding var text: String
    let height: CGFloat

    init(title: String, text: Binding<String>, height: CGFloat = 120) {
        self.title = title
        _text = text
        self.height = height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(MariPalette.softInk)

            TextEditor(text: $text)
                .font(.body.weight(.medium))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: height)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}

private struct OnlineBookingPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView()
                        .tint(MariPalette.ink)
                } else {
                    Text(title)
                        .font(.body.weight(.black))
                        .foregroundStyle(MariPalette.ink)
                }
                Spacer()
            }
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(MariPalette.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.8 : 1)
    }
}

private struct OnlineBookingHomeEditorScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingHomeDraft

    init(store: OnlineBookingStore) {
        self.store = store
        _draft = State(initialValue: OnlineBookingHomeDraft(extra: store.config?.extra ?? [:]))
    }

    var body: some View {
        OnlineBookingFormScreen(title: "Главная страница", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Hero") {
                OnlineBookingTextFieldRow(title: "Eyebrow", text: $draft.heroEyebrow)
                OnlineBookingTextFieldRow(title: "Заголовок", text: $draft.heroTitle)
                OnlineBookingTextAreaRow(title: "Описание", text: $draft.heroDescription)
                OnlineBookingTextFieldRow(title: "Primary CTA", text: $draft.heroPrimaryCTA)
                OnlineBookingTextFieldRow(title: "Secondary CTA", text: $draft.heroSecondaryCTA)
            }

            OnlineBookingPanel(title: "Контакты на главной") {
                OnlineBookingTextFieldRow(title: "Заголовок", text: $draft.contactsTitle)
                OnlineBookingTextAreaRow(title: "Описание", text: $draft.contactsDescription)
            }

            OnlineBookingPanel(title: "Нижний CTA") {
                OnlineBookingTextFieldRow(title: "Заголовок", text: $draft.bottomTitle)
                OnlineBookingTextAreaRow(title: "Описание", text: $draft.bottomDescription)
            }

            OnlineBookingPrimaryButton(title: "Сохранить главную", isLoading: store.isSaving) {
                Task { await store.saveHomeDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingPageEditorScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingPageDraft

    init(store: OnlineBookingStore) {
        self.store = store
        _draft = State(initialValue: OnlineBookingPageDraft(extra: store.config?.extra ?? [:]))
    }

    var body: some View {
        OnlineBookingFormScreen(title: "Страница записи", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Hero actions") {
                OnlineBookingTextFieldRow(title: "Телефон", text: $draft.phoneLabel)
                OnlineBookingTextFieldRow(title: "Услуги", text: $draft.servicesLabel)
                OnlineBookingTextFieldRow(title: "Контакты", text: $draft.contactsLabel)
            }

            OnlineBookingPanel(title: "Panel") {
                OnlineBookingTextFieldRow(title: "Заголовок панели", text: $draft.panelTitle)
                OnlineBookingTextAreaRow(title: "Описание панели", text: $draft.panelDescription)
                OnlineBookingTextFieldRow(title: "Поиск услуг", text: $draft.searchPlaceholder)
                OnlineBookingTextAreaRow(title: "Пустая корзина", text: $draft.emptyCartMessage, height: 90)
            }

            OnlineBookingPanel(title: "Schedule") {
                OnlineBookingTextFieldRow(title: "Заголовок", text: $draft.scheduleTitle)
                OnlineBookingTextAreaRow(title: "Описание", text: $draft.scheduleDescription)
                OnlineBookingTextFieldRow(title: "Любой мастер", text: $draft.anyMasterLabel)
                OnlineBookingTextFieldRow(title: "Нет окон", text: $draft.slotsEmptyResults)
            }

            OnlineBookingPanel(title: "Confirmation") {
                OnlineBookingTextFieldRow(title: "Заголовок", text: $draft.confirmationTitle)
                OnlineBookingTextAreaRow(title: "Текст для гостя", text: $draft.guestDescription)
                OnlineBookingTextFieldRow(title: "Кнопка подтверждения", text: $draft.submitLabel)
            }

            OnlineBookingPrimaryButton(title: "Сохранить страницу записи", isLoading: store.isSaving) {
                Task { await store.savePageDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingContactsScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingContactDraft

    init(store: OnlineBookingStore) {
        self.store = store
        _draft = State(initialValue: OnlineBookingContactDraft(contact: store.config?.contacts.first))
    }

    var body: some View {
        OnlineBookingFormScreen(title: "Контакты", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Основные данные") {
                OnlineBookingTextFieldRow(title: "ID", text: $draft.id)
                OnlineBookingTextFieldRow(title: "Название", text: $draft.name)
                OnlineBookingTextFieldRow(title: "Public name", text: $draft.publicName)
                OnlineBookingTextFieldRow(title: "Legal name", text: $draft.legalName)
            }

            OnlineBookingPanel(title: "Канал связи") {
                OnlineBookingTextFieldRow(title: "Телефон E.164", text: $draft.phoneE164)
                OnlineBookingTextFieldRow(title: "Телефон display", text: $draft.phoneDisplay)
                OnlineBookingTextFieldRow(title: "Email", text: $draft.email)
                OnlineBookingTextFieldRow(title: "Website", text: $draft.website)
                OnlineBookingTextFieldRow(title: "Map URL", text: $draft.mapURL)
            }

            OnlineBookingPanel(title: "Адрес") {
                OnlineBookingTextFieldRow(title: "Label", text: $draft.addressLabel)
                OnlineBookingTextFieldRow(title: "Line 1", text: $draft.addressLine1)
                OnlineBookingTextFieldRow(title: "City", text: $draft.addressCity)
                OnlineBookingTextFieldRow(title: "Region", text: $draft.addressRegion)
                OnlineBookingTextAreaRow(title: "Комментарий", text: $draft.note, height: 90)
            }

            OnlineBookingPrimaryButton(title: "Сохранить контакты", isLoading: store.isSaving) {
                Task { await store.saveContactDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingSpecialistsScreen: View {
    @ObservedObject var store: OnlineBookingStore

    var body: some View {
        OnlineBookingFormScreen(title: "Специалисты", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            if store.specialists.isEmpty {
                OnlineBookingPanel(title: "Нет данных") {
                    Text("Сервер не вернул карточки специалистов.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                }
            } else {
                ForEach(store.specialists) { specialist in
                    NavigationLink {
                        OnlineBookingSpecialistEditorScreen(
                            store: store,
                            specialist: specialist
                        )
                    } label: {
                        OnlineBookingSpecialistRow(specialist: specialist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct OnlineBookingSpecialistEditorScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingSpecialistDraft

    init(store: OnlineBookingStore, specialist: MariAPIClient.ClientFrontSpecialistRecord) {
        self.store = store
        _draft = State(initialValue: OnlineBookingSpecialistDraft(specialist: specialist))
    }

    var body: some View {
        OnlineBookingFormScreen(title: draft.name, isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Карточка мастера") {
                Toggle("Показывать клиенту", isOn: $draft.isVisible)
                    .font(.body.weight(.semibold))
                    .tint(MariPalette.accent)
                Stepper(value: $draft.sortOrder, in: 0...999) {
                    Text("Порядок: \(draft.sortOrder)")
                        .font(.body.weight(.semibold))
                }
                OnlineBookingTextFieldRow(title: "Специализация", text: $draft.specialty)
                OnlineBookingTextFieldRow(title: "CTA", text: $draft.ctaText)
                OnlineBookingTextAreaRow(title: "Информация", text: $draft.info, height: 160)
            }

            OnlineBookingPanel(title: "Связанные услуги") {
                if draft.services.isEmpty {
                    Text("У специалиста пока нет привязанных услуг.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                } else {
                    ForEach(draft.services, id: \.id) { service in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(MariPalette.ink)
                                Text(service.category.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(MariPalette.softInk)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            OnlineBookingPrimaryButton(title: "Сохранить специалиста", isLoading: store.isSaving) {
                Task { await store.saveSpecialistDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingSpecialistRow: View {
    let specialist: MariAPIClient.ClientFrontSpecialistRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(hex: 0xE7E1FA))
                    .frame(width: 42, height: 42)

                Image(systemName: "person")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(hex: 0x8C86E5))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(specialist.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)

                Text(specialist.specialty ?? "Без специализации")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)

                HStack(spacing: 6) {
                    OnlineBookingTag(title: specialist.isVisible ? "Видим" : "Скрыт", tint: specialist.isVisible ? Color(hex: 0xDDF4E4) : Color(hex: 0xECEFF5))
                    OnlineBookingTag(title: "\(specialist.services.count) услуг", tint: Color(hex: 0xECEFF5))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
                .padding(.top, 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.72))
        )
    }
}

private struct OnlineBookingTag: View {
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

private struct OnlineBookingServicesScreen: View {
    @ObservedObject var store: OnlineBookingStore

    private var groupedServices: [(String, [MariAPIClient.ServiceRecord])] {
        Dictionary(grouping: store.services, by: { $0.category.name })
            .map { ($0.key, $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        OnlineBookingFormScreen(title: "Услуги", isSaving: store.isSaving, onRefresh: {}) {
            OnlineBookingPanel(
                title: "Витрина онлайн-записи",
                subtitle: "Реальные услуги берутся из /services. Полное редактирование самих услуг остается в отдельном модуле."
            ) {
                ForEach(groupedServices, id: \.0) { categoryName, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(categoryName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(MariPalette.ink)

                        ForEach(items) { service in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.nameOnline ?? service.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(MariPalette.ink)
                                Text(service.nameOnline.nilIfBlank == nil ? service.name : service.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(MariPalette.softInk)
                                Text("\(service.durationSec / 60) мин • \(service.priceMin.onlineMoney)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MariPalette.softInk)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct OnlineBookingPromoScreen: View {
    @ObservedObject var store: OnlineBookingStore

    var body: some View {
        OnlineBookingFormScreen(title: "Акции и предложения", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            if store.blocks.isEmpty {
                OnlineBookingPanel(title: "Нет блоков") {
                    Text("Legacy-блоки пока отсутствуют. Это нормальная ситуация, если client-front уже собран через новую структуру extra.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                }
            } else {
                ForEach(store.blocks) { block in
                    NavigationLink {
                        OnlineBookingBlockEditorScreen(store: store, block: block)
                    } label: {
                        OnlineBookingBlockRow(block: block)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct OnlineBookingBlockEditorScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingBlockDraft

    init(store: OnlineBookingStore, block: MariAPIClient.ClientFrontBlockRecord) {
        self.store = store
        _draft = State(initialValue: OnlineBookingBlockDraft(block: block))
    }

    var body: some View {
        OnlineBookingFormScreen(title: draft.blockKey, isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Параметры блока") {
                Toggle("Активен", isOn: $draft.isEnabled)
                    .font(.body.weight(.semibold))
                    .tint(MariPalette.accent)
                Stepper(value: $draft.sortOrder, in: 0...100_000) {
                    Text("Порядок: \(draft.sortOrder)")
                        .font(.body.weight(.semibold))
                }
                OnlineBookingTextFieldRow(title: "Платформа", text: $draft.platform)
                OnlineBookingTextFieldRow(title: "Min version", text: $draft.minAppVersion)
                OnlineBookingTextFieldRow(title: "Max version", text: $draft.maxAppVersion)
            }

            OnlineBookingPanel(title: "Payload JSON", subtitle: "Редактируется реальный payload блока из client-front.") {
                OnlineBookingTextAreaRow(title: "Payload", text: $draft.payloadText, height: 240)
            }

            OnlineBookingPrimaryButton(title: "Сохранить блок", isLoading: store.isSaving) {
                Task { await store.saveBlockDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingBlockRow: View {
    let block: MariAPIClient.ClientFrontBlockRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(block.blockKey)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                Text(block.blockType)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
                HStack(spacing: 6) {
                    OnlineBookingTag(title: block.isEnabled ? "Активен" : "Выключен", tint: block.isEnabled ? Color(hex: 0xDDF4E4) : Color(hex: 0xECEFF5))
                    OnlineBookingTag(title: "sort \(block.sortOrder)", tint: Color(hex: 0xECEFF5))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xA4ACB8))
                .padding(.top, 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.72))
        )
    }
}

private struct OnlineBookingLegalScreen: View {
    @ObservedObject var store: OnlineBookingStore

    var body: some View {
        OnlineBookingFormScreen(title: "Политика", isSaving: store.isSaving, onRefresh: {}) {
            OnlineBookingPanel(
                title: "Privacy policy",
                subtitle: "В web этот контент связан с client-front и privacy settings."
            ) {
                Text(store.privacyPolicyText.nilIfBlank ?? "Политика пока не заполнена.")
                    .font(.body.weight(.medium))
                    .foregroundStyle(MariPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnlineBookingAdvancedScreen: View {
    @ObservedObject var store: OnlineBookingStore
    @State private var draft: OnlineBookingGeneralDraft

    init(store: OnlineBookingStore) {
        self.store = store
        _draft = State(initialValue: OnlineBookingGeneralDraft(config: store.config))
    }

    var body: some View {
        OnlineBookingFormScreen(title: "Служебные настройки", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Brand и maintenance") {
                OnlineBookingTextFieldRow(title: "Brand name", text: $draft.brandName)
                OnlineBookingTextFieldRow(title: "Legal name", text: $draft.legalName)
                OnlineBookingTextFieldRow(title: "Min iOS", text: $draft.minAppVersionIos)
                OnlineBookingTextFieldRow(title: "Min Android", text: $draft.minAppVersionAndroid)
                Toggle("Maintenance mode", isOn: $draft.maintenanceMode)
                    .font(.body.weight(.semibold))
                    .tint(MariPalette.accent)
                OnlineBookingTextAreaRow(title: "Maintenance message", text: $draft.maintenanceMessage, height: 90)
            }

            OnlineBookingPanel(title: "Feature flags JSON") {
                OnlineBookingTextAreaRow(title: "Feature flags", text: $draft.featureFlagsText, height: 220)
            }

            OnlineBookingPrimaryButton(title: "Сохранить настройки", isLoading: store.isSaving) {
                Task { await store.saveGeneralDraft(draft) }
            }
        }
    }
}

private struct OnlineBookingPublishScreen: View {
    @ObservedObject var store: OnlineBookingStore

    var body: some View {
        OnlineBookingFormScreen(title: "Состояние сайта", isSaving: store.isSaving, onRefresh: {}) {
            if let banner = store.banner {
                OnlineBookingBannerView(banner: banner)
            }

            OnlineBookingPanel(title: "Preview") {
                Text("Версия: v\(store.preview?.version ?? 0)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MariPalette.ink)
                Text("Специалистов в preview: \(store.preview?.specialists.count ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
                Text("Legacy-блоков в preview: \(store.preview?.blocks.count ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
                Text("Опубликованная версия: v\(store.config?.publishedVersion ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MariPalette.softInk)
            }

            OnlineBookingPanel(title: "История публикаций") {
                if store.releases.isEmpty {
                    Text("История публикаций пока пуста.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                } else {
                    ForEach(store.releases) { release in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("v\(release.version)")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(MariPalette.ink)
                            Text(release.publishedAt.onlineBookingShortDateTime)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MariPalette.softInk)
                            if let author = release.publishedByStaff {
                                Text("\(author.name) • \(author.role)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(MariPalette.softInk)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }

            OnlineBookingPrimaryButton(title: "Опубликовать сейчас", isLoading: store.isSaving) {
                Task { await store.publishNow() }
            }
        }
    }
}

private struct OnlineBookingHomeDraft {
    var heroEyebrow: String
    var heroTitle: String
    var heroDescription: String
    var heroPrimaryCTA: String
    var heroSecondaryCTA: String
    var contactsTitle: String
    var contactsDescription: String
    var bottomTitle: String
    var bottomDescription: String

    init(extra: [String: JSONValue]) {
        heroEyebrow = jsonString(extra, path: "siteContent.homePage.hero.eyebrow")
        heroTitle = jsonString(extra, path: "siteContent.homePage.hero.title")
        heroDescription = jsonString(extra, path: "siteContent.homePage.hero.description")
        heroPrimaryCTA = jsonString(extra, path: "siteContent.homePage.hero.primaryCtaLabel")
        heroSecondaryCTA = jsonString(extra, path: "siteContent.homePage.hero.secondaryCtaLabel")
        contactsTitle = jsonString(extra, path: "siteContent.homePage.contacts.title")
        contactsDescription = jsonString(extra, path: "siteContent.homePage.contacts.description")
        bottomTitle = jsonString(extra, path: "siteContent.homePage.bottomCta.title")
        bottomDescription = jsonString(extra, path: "siteContent.homePage.bottomCta.description")
    }

    var configuredFieldsCount: Int {
        [
            heroEyebrow, heroTitle, heroDescription, heroPrimaryCTA, heroSecondaryCTA,
            contactsTitle, contactsDescription, bottomTitle, bottomDescription,
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    func merged(into extra: [String: JSONValue]) -> [String: JSONValue] {
        var next = extra
        setJSONString(&next, path: "siteContent.homePage.hero.eyebrow", value: heroEyebrow)
        setJSONString(&next, path: "siteContent.homePage.hero.title", value: heroTitle)
        setJSONString(&next, path: "siteContent.homePage.hero.description", value: heroDescription)
        setJSONString(&next, path: "siteContent.homePage.hero.primaryCtaLabel", value: heroPrimaryCTA)
        setJSONString(&next, path: "siteContent.homePage.hero.secondaryCtaLabel", value: heroSecondaryCTA)
        setJSONString(&next, path: "siteContent.homePage.contacts.title", value: contactsTitle)
        setJSONString(&next, path: "siteContent.homePage.contacts.description", value: contactsDescription)
        setJSONString(&next, path: "siteContent.homePage.bottomCta.title", value: bottomTitle)
        setJSONString(&next, path: "siteContent.homePage.bottomCta.description", value: bottomDescription)
        return next
    }
}

private struct OnlineBookingPageDraft {
    var phoneLabel: String
    var servicesLabel: String
    var contactsLabel: String
    var panelTitle: String
    var panelDescription: String
    var searchPlaceholder: String
    var emptyCartMessage: String
    var scheduleTitle: String
    var scheduleDescription: String
    var anyMasterLabel: String
    var slotsEmptyResults: String
    var confirmationTitle: String
    var guestDescription: String
    var submitLabel: String

    init(extra: [String: JSONValue]) {
        phoneLabel = jsonString(extra, path: "bookingPage.heroActions.phoneLabel")
        servicesLabel = jsonString(extra, path: "bookingPage.heroActions.servicesLabel")
        contactsLabel = jsonString(extra, path: "bookingPage.heroActions.contactsLabel")
        panelTitle = jsonString(extra, path: "bookingPage.panel.title")
        panelDescription = jsonString(extra, path: "bookingPage.panel.description")
        searchPlaceholder = jsonString(extra, path: "bookingPage.panel.searchPlaceholder")
        emptyCartMessage = jsonString(extra, path: "bookingPage.panel.emptyCartMessage")
        scheduleTitle = jsonString(extra, path: "bookingPage.schedule.title")
        scheduleDescription = jsonString(extra, path: "bookingPage.schedule.description")
        anyMasterLabel = jsonString(extra, path: "bookingPage.schedule.anyMasterLabel")
        slotsEmptyResults = jsonString(extra, path: "bookingPage.schedule.slotsEmptyResults")
        confirmationTitle = jsonString(extra, path: "bookingPage.confirmation.title")
        guestDescription = jsonString(extra, path: "bookingPage.confirmation.guestDescription")
        submitLabel = jsonString(extra, path: "bookingPage.confirmation.submitLabel")
    }

    var configuredFieldsCount: Int {
        [
            phoneLabel, servicesLabel, contactsLabel, panelTitle, panelDescription,
            searchPlaceholder, emptyCartMessage, scheduleTitle, scheduleDescription,
            anyMasterLabel, slotsEmptyResults,
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    func merged(into extra: [String: JSONValue]) -> [String: JSONValue] {
        var next = extra
        setJSONString(&next, path: "bookingPage.heroActions.phoneLabel", value: phoneLabel)
        setJSONString(&next, path: "bookingPage.heroActions.servicesLabel", value: servicesLabel)
        setJSONString(&next, path: "bookingPage.heroActions.contactsLabel", value: contactsLabel)
        setJSONString(&next, path: "bookingPage.panel.title", value: panelTitle)
        setJSONString(&next, path: "bookingPage.panel.description", value: panelDescription)
        setJSONString(&next, path: "bookingPage.panel.searchPlaceholder", value: searchPlaceholder)
        setJSONString(&next, path: "bookingPage.panel.emptyCartMessage", value: emptyCartMessage)
        setJSONString(&next, path: "bookingPage.schedule.title", value: scheduleTitle)
        setJSONString(&next, path: "bookingPage.schedule.description", value: scheduleDescription)
        setJSONString(&next, path: "bookingPage.schedule.anyMasterLabel", value: anyMasterLabel)
        setJSONString(&next, path: "bookingPage.schedule.slotsEmptyResults", value: slotsEmptyResults)
        setJSONString(&next, path: "bookingPage.confirmation.title", value: confirmationTitle)
        setJSONString(&next, path: "bookingPage.confirmation.guestDescription", value: guestDescription)
        setJSONString(&next, path: "bookingPage.confirmation.submitLabel", value: submitLabel)
        return next
    }
}

private struct OnlineBookingGeneralDraft {
    var brandName: String
    var legalName: String
    var minAppVersionIos: String
    var minAppVersionAndroid: String
    var maintenanceMode: Bool
    var maintenanceMessage: String
    var featureFlagsText: String

    init(config: MariAPIClient.ClientFrontConfigRecord?) {
        brandName = config?.brandName ?? ""
        legalName = config?.legalName ?? ""
        minAppVersionIos = config?.minAppVersionIos ?? ""
        minAppVersionAndroid = config?.minAppVersionAndroid ?? ""
        maintenanceMode = config?.maintenanceMode ?? false
        maintenanceMessage = config?.maintenanceMessage ?? ""
        featureFlagsText = prettyJSONString(from: config?.featureFlags ?? [:]) ?? "{}"
    }

    func featureFlagsObject() -> [String: JSONValue]? {
        jsonObject(from: featureFlagsText)
    }
}

private struct OnlineBookingContactDraft {
    var id: String
    var name: String
    var publicName: String
    var legalName: String
    var phoneE164: String
    var phoneDisplay: String
    var email: String
    var website: String
    var mapURL: String
    var addressLabel: String
    var addressLine1: String
    var addressCity: String
    var addressRegion: String
    var note: String

    init(contact: MariAPIClient.ClientFrontConfigRecord.ContactPoint?) {
        id = contact?.id ?? "primary"
        name = contact?.name ?? "MARI"
        publicName = contact?.publicName ?? ""
        legalName = contact?.legalName ?? ""
        phoneE164 = contact?.phones.first?.e164 ?? "+7"
        phoneDisplay = contact?.phones.first?.display ?? ""
        email = contact?.emails?.first ?? ""
        website = contact?.website ?? ""
        mapURL = contact?.mapUrl ?? ""
        addressLabel = contact?.addresses.first?.label ?? "Основной"
        addressLine1 = contact?.addresses.first?.line1 ?? ""
        addressCity = contact?.addresses.first?.city ?? ""
        addressRegion = contact?.addresses.first?.region ?? ""
        note = contact?.note ?? ""
    }

    func contactPoint(using source: MariAPIClient.ClientFrontConfigRecord.ContactPoint?) -> MariAPIClient.ClientFrontConfigRecord.ContactPoint {
        let address = MariAPIClient.ClientFrontConfigRecord.ContactPoint.Address(
            label: addressLabel.nilIfBlank ?? "Основной",
            line1: addressLine1.nilIfBlank ?? "Адрес не указан",
            line2: source?.addresses.first?.line2,
            city: addressCity.nilIfBlank,
            region: addressRegion.nilIfBlank,
            postalCode: source?.addresses.first?.postalCode,
            country: source?.addresses.first?.country,
            latitude: source?.addresses.first?.latitude,
            longitude: source?.addresses.first?.longitude,
            comment: source?.addresses.first?.comment
        )
        let phone = MariAPIClient.ClientFrontConfigRecord.ContactPoint.Phone(
            label: source?.phones.first?.label ?? "Основной",
            e164: phoneE164.nilIfBlank ?? (source?.phones.first?.e164 ?? "+7"),
            display: phoneDisplay.nilIfBlank,
            ext: source?.phones.first?.ext,
            primary: true,
            whatsapp: source?.phones.first?.whatsapp,
            telegram: source?.phones.first?.telegram,
            viber: source?.phones.first?.viber
        )

        return MariAPIClient.ClientFrontConfigRecord.ContactPoint(
            id: id.nilIfBlank ?? (source?.id ?? "primary"),
            name: name.nilIfBlank ?? "MARI",
            publicName: publicName.nilIfBlank,
            legalName: legalName.nilIfBlank,
            aliases: source?.aliases,
            addresses: [address],
            phones: [phone],
            emails: email.nilIfBlank.map { [$0] },
            website: website.nilIfBlank,
            mapUrl: mapURL.nilIfBlank,
            workingHours: source?.workingHours,
            orderIndex: source?.orderIndex ?? 0,
            isPrimary: true,
            startAt: source?.startAt,
            endAt: source?.endAt,
            tags: source?.tags,
            note: note.nilIfBlank
        )
    }
}

private struct OnlineBookingSpecialistDraft {
    let staffId: String
    let name: String
    var specialty: String
    var info: String
    var ctaText: String
    var isVisible: Bool
    var sortOrder: Int
    let services: [MariAPIClient.ClientFrontSpecialistRecord.ServiceSummary]

    init(specialist: MariAPIClient.ClientFrontSpecialistRecord) {
        staffId = specialist.staffId
        name = specialist.name
        specialty = specialist.specialty ?? ""
        info = specialist.info ?? ""
        ctaText = specialist.ctaText ?? ""
        isVisible = specialist.isVisible
        sortOrder = specialist.sortOrder
        services = specialist.services
    }
}

private struct OnlineBookingBlockDraft {
    let id: String
    let blockKey: String
    var sortOrder: Int
    var platform: String
    var minAppVersion: String
    var maxAppVersion: String
    var startAt: String
    var endAt: String
    var isEnabled: Bool
    var payloadText: String

    init(block: MariAPIClient.ClientFrontBlockRecord) {
        id = block.id
        blockKey = block.blockKey
        sortOrder = block.sortOrder
        platform = block.platform ?? "all"
        minAppVersion = block.minAppVersion ?? ""
        maxAppVersion = block.maxAppVersion ?? ""
        startAt = block.startAt?.iso8601String ?? ""
        endAt = block.endAt?.iso8601String ?? ""
        isEnabled = block.isEnabled
        payloadText = prettyJSONString(from: block.payload) ?? "{}"
    }

    func payloadObject() -> [String: JSONValue]? {
        jsonObject(from: payloadText)
    }
}

private func jsonString(_ object: [String: JSONValue], path: String) -> String {
    let components = path.split(separator: ".").map(String.init)
    guard let value = jsonValue(object, path: components) else { return "" }
    return value.stringValue ?? ""
}

private func jsonValue(_ object: [String: JSONValue], path: [String]) -> JSONValue? {
    guard let first = path.first else { return .object(object) }
    guard let value = object[first] else { return nil }
    if path.count == 1 {
        return value
    }
    guard case let .object(next) = value else { return nil }
    return jsonValue(next, path: Array(path.dropFirst()))
}

private func setJSONString(_ object: inout [String: JSONValue], path: String, value: String) {
    let components = path.split(separator: ".").map(String.init)
    guard let first = components.first else { return }
    if components.count == 1 {
        object[first] = .string(value)
        return
    }
    var child = object[first]?.objectValue ?? [:]
    setJSONString(&child, path: components.dropFirst().joined(separator: "."), value: value)
    object[first] = .object(child)
}

private func prettyJSONString(from object: [String: JSONValue]) -> String? {
    guard JSONSerialization.isValidJSONObject(jsonAny(from: .object(object))) else { return nil }
    do {
        let data = try JSONSerialization.data(withJSONObject: jsonAny(from: .object(object)), options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

private func jsonObject(from text: String) -> [String: JSONValue]? {
    guard let data = text.data(using: .utf8) else { return nil }
    do {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = raw as? [String: Any] else { return nil }
        return dictionary.compactMapValues(jsonValue(from:))
    } catch {
        return nil
    }
}

private func jsonAny(from value: JSONValue) -> Any {
    switch value {
    case .string(let string):
        return string
    case .number(let number):
        return number
    case .bool(let bool):
        return bool
    case .object(let object):
        return object.mapValues(jsonAny(from:))
    case .array(let array):
        return array.map(jsonAny(from:))
    case .null:
        return NSNull()
    }
}

private func jsonValue(from any: Any) -> JSONValue? {
    switch any {
    case let value as String:
        return .string(value)
    case let value as NSNumber:
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return .bool(value.boolValue)
        }
        return .number(value.doubleValue)
    case let value as [String: Any]:
        return .object(value.compactMapValues(jsonValue(from:)))
    case let value as [Any]:
        return .array(value.compactMap { jsonValue(from: $0) })
    case _ as NSNull:
        return .null
    default:
        return nil
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Double {
    var onlineMoney: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "RUB"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? "\(Int(self)) ₽"
    }
}

private extension Date {
    var onlineBookingShortDateTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}
