import Foundation

enum MariStaffTab: String, CaseIterable, Identifiable {
    case journal
    case schedule
    case clients
    case services
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: "Журнал"
        case .schedule: "График"
        case .clients: "Клиенты"
        case .services: "Услуги"
        case .more: "Еще"
        }
    }

    var symbol: String {
        switch self {
        case .journal: "calendar.day.timeline.leading"
        case .schedule: "calendar.badge.clock"
        case .clients: "person.3.sequence.fill"
        case .services: "sparkles"
        case .more: "square.grid.2x2.fill"
        }
    }

    var permissionCode: String? {
        switch self {
        case .journal: "VIEW_JOURNAL"
        case .schedule: "VIEW_SCHEDULE"
        case .clients: "VIEW_CLIENTS"
        case .services: "VIEW_SERVICES"
        case .more: nil
        }
    }
}

enum StaffRole: String, Hashable {
    case owner = "OWNER"
    case admin = "ADMIN"
    case master = "MASTER"
    case developer = "DEVELOPER"
    case smm = "SMM"

    var title: String {
        switch self {
        case .owner: "Владелец"
        case .admin: "Администратор"
        case .master: "Мастер"
        case .developer: "Разработчик"
        case .smm: "SMM"
        }
    }
}

enum AppointmentStatus: String, Hashable {
    case pending
    case confirmed
    case arrived
    case noShow
    case cancelled

    var title: String {
        switch self {
        case .pending: "Ожидание"
        case .confirmed: "Подтвержден"
        case .arrived: "Пришел"
        case .noShow: "Не пришел"
        case .cancelled: "Отменен"
        }
    }
}

enum ClientTier: String, Hashable {
    case vip
    case loyal
    case new

    var title: String {
        switch self {
        case .vip: "VIP"
        case .loyal: "Loyal"
        case .new: "New"
        }
    }
}

enum NotificationKind: Hashable {
    case booking
    case staff
    case client
    case system
}

struct StaffMember: Identifiable, Hashable {
    let id: String
    let name: String
    let role: StaffRole
    let position: String
    let phone: String
    let email: String
    let isCurrentUser: Bool

    var initials: String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct Appointment: Identifiable, Hashable {
    let id: String
    let clientName: String
    let serviceName: String
    let staffID: String
    let staffName: String
    let startsAt: Date
    let durationMinutes: Int
    let revenue: Int
    let status: AppointmentStatus
    let note: String?
}

struct ScheduleShift: Identifiable, Hashable {
    let id: String
    let staff: StaffMember
    let startsAt: Date
    let endsAt: Date
    let bookedSlots: Int
    let totalSlots: Int
}

struct ClientSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let phone: String
    let lastVisit: Date
    let visits: Int
    let revenue: Int
    let preferredService: String
    let tier: ClientTier
    let discountPercent: Int
}

struct StaffNotificationItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: Date
    let kind: NotificationKind
    let isUnread: Bool
}

struct MoreShortcut: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let systemImage: String

    var id: String { title }
}

struct MariStaffSnapshot: Hashable {
    let studioName: String
    let activeDate: Date
    let staff: [StaffMember]
    let appointments: [Appointment]
    let shifts: [ScheduleShift]
    let clients: [ClientSummary]
    let notifications: [StaffNotificationItem]
    let shortcuts: [MoreShortcut]
}

struct StaffSession: Codable, Hashable {
    struct StaffIdentity: Codable, Hashable {
        let id: String
        let name: String
        let role: String
        let phoneE164: String
        let email: String?
        let permissions: [String]?
    }

    struct Tokens: Codable, Hashable {
        let accessToken: String
        let refreshToken: String
        let expiresInSec: Int
    }

    let staff: StaffIdentity
    let tokens: Tokens
}

private let mariPermissionEquivalents: [String: [String]] = [
    "VIEW_JOURNAL": ["VIEW_JOURNAL", "EDIT_JOURNAL", "ACCESS_JOURNAL"],
    "VIEW_ALL_JOURNAL_APPOINTMENTS": ["VIEW_ALL_JOURNAL_APPOINTMENTS", "EDIT_JOURNAL", "ACCESS_JOURNAL"],
    "EDIT_JOURNAL": ["EDIT_JOURNAL", "ACCESS_JOURNAL"],
    "CREATE_JOURNAL_APPOINTMENTS": ["CREATE_JOURNAL_APPOINTMENTS", "EDIT_JOURNAL", "ACCESS_JOURNAL"],
    "VIEW_SCHEDULE": ["VIEW_SCHEDULE", "EDIT_SCHEDULE", "ACCESS_SCHEDULE"],
    "EDIT_SCHEDULE": ["EDIT_SCHEDULE", "ACCESS_SCHEDULE"],
    "VIEW_CLIENTS": ["VIEW_CLIENTS", "EDIT_CLIENTS", "ACCESS_CLIENTS"],
    "EDIT_CLIENTS": ["EDIT_CLIENTS", "ACCESS_CLIENTS"],
    "VIEW_CLIENT_PHONE": ["VIEW_CLIENT_PHONE", "VIEW_CLIENTS", "EDIT_CLIENTS", "ACCESS_CLIENTS"],
    "VIEW_FINANCIAL_STATS": ["VIEW_FINANCIAL_STATS", "ACCESS_FINANCIAL_STATS", "VIEW_REPORTS"],
    "EDIT_STAFF": ["EDIT_STAFF", "ACCESS_STAFF"],
    "VIEW_STAFF": ["VIEW_STAFF", "EDIT_STAFF", "ACCESS_STAFF"],
    "VIEW_SERVICES": ["VIEW_SERVICES", "EDIT_SERVICES", "ACCESS_SERVICES"],
    "EDIT_SERVICES": ["EDIT_SERVICES", "ACCESS_SERVICES"],
]

func mariResolvePermissionCandidates(_ permissionCode: String) -> [String] {
    mariPermissionEquivalents[permissionCode] ?? [permissionCode]
}

func mariHasPermissionAccess(_ session: StaffSession?, permissionCode: String?) -> Bool {
    guard let session else { return true }
    guard let permissionCode else { return true }

    if session.staff.role == "OWNER" {
        return true
    }

    if session.staff.role == "MASTER" && permissionCode == "VIEW_JOURNAL" {
        return true
    }

    guard let permissionCodes = session.staff.permissions else {
        return session.staff.role != "MASTER"
    }

    let candidates = mariResolvePermissionCandidates(permissionCode)
    return candidates.contains { permissionCodes.contains($0) }
}

func mariAllowedTabs(for session: StaffSession?) -> [MariStaffTab] {
    guard let session else { return MariStaffTab.allCases }
    if session.staff.role == "OWNER" {
        return MariStaffTab.allCases
    }

    let tabs = MariStaffTab.allCases.filter { tab in
        mariHasPermissionAccess(session, permissionCode: tab.permissionCode)
    }

    return tabs.isEmpty ? [.more] : tabs
}

extension MariStaffSnapshot {
    func replacingCurrentStaff(with session: StaffSession?) -> MariStaffSnapshot {
        guard let session else { return self }
        guard let role = StaffRole(rawValue: session.staff.role) else { return self }

        let updatedStaff = staff.map { member in
            guard member.isCurrentUser else { return member }
            return StaffMember(
                id: session.staff.id,
                name: session.staff.name,
                role: role,
                position: member.position,
                phone: session.staff.phoneE164,
                email: session.staff.email ?? member.email,
                isCurrentUser: true
            )
        }

        return MariStaffSnapshot(
            studioName: studioName,
            activeDate: activeDate,
            staff: updatedStaff,
            appointments: appointments,
            shifts: shifts,
            clients: clients,
            notifications: notifications,
            shortcuts: shortcuts
        )
    }
}
