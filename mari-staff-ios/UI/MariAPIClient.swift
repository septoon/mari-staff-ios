import Foundation
import Network
import OSLog
import Security

private nonisolated(unsafe) extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}

private struct RawHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private enum RawHTTPTransportError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Сервер вернул некорректный HTTP-ответ"
        }
    }
}

private func parseRawHTTPResponse(_ data: Data) throws -> RawHTTPResponse {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headersRange = data.range(of: delimiter) else {
        throw RawHTTPTransportError.invalidResponse
    }

    let headersData = data[..<headersRange.lowerBound]
    let bodyStart = headersRange.upperBound
    let remainingBody = Data(data[bodyStart...])

    guard let headersString = String(data: headersData, encoding: .utf8) ??
        String(data: headersData, encoding: .isoLatin1)
    else {
        throw RawHTTPTransportError.invalidResponse
    }

    let lines = headersString.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
        throw RawHTTPTransportError.invalidResponse
    }

    let statusLineParts = statusLine.split(separator: " ")
    guard statusLineParts.count >= 2, let statusCode = Int(statusLineParts[1]) else {
        throw RawHTTPTransportError.invalidResponse
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let separator = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        headers[key] = value
    }

    let body: Data
    if let transferEncoding = headers.first(where: { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame })?.value,
       transferEncoding.localizedCaseInsensitiveContains("chunked")
    {
        body = try decodeChunkedHTTPBody(remainingBody)
    } else if let contentLengthValue = headers.first(where: { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame })?.value,
              let contentLength = Int(contentLengthValue),
              remainingBody.count >= contentLength
    {
        body = remainingBody.prefix(contentLength)
    } else {
        body = remainingBody
    }

    return RawHTTPResponse(statusCode: statusCode, headers: headers, body: body)
}

private func decodeChunkedHTTPBody(_ data: Data) throws -> Data {
    let crlf = Data("\r\n".utf8)
    var index = data.startIndex
    var body = Data()

    while index < data.endIndex {
        guard let lineRange = data.range(of: crlf, in: index..<data.endIndex) else {
            throw RawHTTPTransportError.invalidResponse
        }

        let sizeLine = String(decoding: data[index..<lineRange.lowerBound], as: UTF8.self)
        let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
        guard let chunkSize = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
            throw RawHTTPTransportError.invalidResponse
        }

        index = lineRange.upperBound

        if chunkSize == 0 {
            return body
        }

        guard data.distance(from: index, to: data.endIndex) >= chunkSize + 2 else {
            throw RawHTTPTransportError.invalidResponse
        }

        let chunkEnd = data.index(index, offsetBy: chunkSize)
        body.append(data[index..<chunkEnd])

        let trailingCRLFEnd = data.index(chunkEnd, offsetBy: 2)
        guard data[chunkEnd..<trailingCRLFEnd] == crlf[...] else {
            throw RawHTTPTransportError.invalidResponse
        }

        index = trailingCRLFEnd
    }

    throw RawHTTPTransportError.invalidResponse
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue] {
        if case let .object(value) = self { return value }
        return [:]
    }

    var arrayValue: [JSONValue] {
        if case let .array(value) = self { return value }
        return []
    }
}

private nonisolated(unsafe) extension KeyedDecodingContainer {
    func decodeFlexibleDouble(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

actor MariAPIClient {
    struct StaffMutationEnvelope: Codable {
        let staff: StaffRecord
    }

    struct StaffAvatarMutationResponse: Codable {
        let staffId: String
        let avatarUrl: String?
        let avatarAssetId: String?
        let previousAvatarAssetId: String?
    }

    struct FireStaffMutationResponse: Codable {
        let staff: StaffRecord
        let cancelledFutureAppointments: Int
    }

    struct StaffPage: Codable {
        let items: [StaffRecord]
    }

    struct StaffRecord: Codable, Identifiable, Hashable {
        struct PositionSnapshot: Codable, Hashable {
            let id: String
            let name: String
        }

        struct PermissionSnapshot: Codable, Hashable, Identifiable {
            var id: String { code }

            let code: String
            let expiresAt: Date?
        }

        let id: String
        let name: String
        let role: String
        let phoneE164: String
        let email: String?
        let receivesAllAppointmentNotifications: Bool
        let avatarUrl: String?
        let isActive: Bool
        let position: PositionSnapshot?
        let hiredAt: Date?
        let firedAt: Date?
        let deletedAt: Date?
        let permissions: [PermissionSnapshot]?
    }

    struct ClientsPage: Codable {
        let items: [ClientRecord]
    }

    struct ClientMutationResponse: Codable {
        let client: ClientRecord
    }

    struct MediaAssetUploadResponse: Codable {
        let id: String
    }

    struct DeleteClientResponse: Codable {
        let deleted: Bool
        let clientId: String
    }

    struct AppointmentsPage: Codable {
        let items: [AppointmentRecord]
    }

    struct CreateAppointmentPayload: Encodable {
        struct ClientPayload: Encodable {
            let name: String
            let phone: String
        }

        let startAt: String
        let staffId: String
        let anyStaff: Bool
        let serviceIds: [String]
        let client: ClientPayload
    }

    struct ServicesPage: Codable {
        let items: [ServiceRecord]
    }

    struct ServiceCategoryPage: Codable {
        let items: [ServiceCategoryRecord]
    }

    struct ServiceMutationEnvelope: Codable {
        let item: ServiceRecord
    }

    struct ServiceCategoryMutationEnvelope: Codable {
        let item: ServiceCategoryRecord
    }

    struct DeleteMutationEnvelope: Codable {
        let deleted: Bool
        let id: String?
    }

    struct ServiceCategoryRecord: Codable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct ServiceRecord: Codable, Identifiable, Hashable {
        struct CategorySnapshot: Codable, Hashable {
            let id: String
            let name: String
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case nameOnline
            case description
            case isActive
            case durationSec
            case priceMin
            case priceMax
            case category
        }

        let id: String
        let name: String
        let nameOnline: String?
        let description: String?
        let isActive: Bool
        let durationSec: Int
        let priceMin: Double
        let priceMax: Double?
        let category: CategorySnapshot

        init(
            id: String,
            name: String,
            nameOnline: String?,
            description: String?,
            isActive: Bool,
            durationSec: Int,
            priceMin: Double,
            priceMax: Double?,
            category: CategorySnapshot
        ) {
            self.id = id
            self.name = name
            self.nameOnline = nameOnline
            self.description = description
            self.isActive = isActive
            self.durationSec = durationSec
            self.priceMin = priceMin
            self.priceMax = priceMax
            self.category = category
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            nameOnline = try container.decodeIfPresent(String.self, forKey: .nameOnline)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
            durationSec = try container.decodeFlexibleInt(forKey: .durationSec) ?? 0
            priceMin = try container.decodeFlexibleDouble(forKey: .priceMin) ?? 0
            priceMax = try container.decodeFlexibleDouble(forKey: .priceMax)
            category = try container.decode(CategorySnapshot.self, forKey: .category)
        }
    }

    struct AnalyticsOverviewPayload: Codable {
        struct Period: Codable {
            let from: String
            let to: String
        }

        struct StaffMoneyBreakdown: Codable, Hashable {
            let revenue: Double?
            let paid: Double?
            let debt: Double?
        }

        struct StaffBreakdown: Codable, Hashable, Identifiable {
            var id: String { staffId ?? staffName ?? "unknown-staff" }

            let staffId: String?
            let staffName: String?
            let appointmentsCount: Int?
            let arrivedCount: Int?
            let noShowCount: Int?
            let cancelledCount: Int?
            let money: StaffMoneyBreakdown?
        }

        struct MoneyBreakdown: Codable, Hashable {
            struct PaymentMethodBreakdown: Codable, Hashable, Identifiable {
                var id: String { method }

                let method: String
                let amount: Double
            }

            let revenue: Double?
            let paid: Double?
            let debt: Double?
            let byMethod: [PaymentMethodBreakdown]?
        }

        let period: Period?
        let appointmentsCount: Int?
        let arrivedCount: Int?
        let noShowCount: Int?
        let cancelledCount: Int?
        let byStaff: [StaffBreakdown]?
        let money: MoneyBreakdown?
    }

    struct WorkingHoursPage: Codable {
        let staffId: String
        let items: [WorkingHoursItem]
    }

    struct ClientFrontConfigRecord: Codable, Hashable {
        struct ContactPoint: Codable, Hashable, Identifiable {
            struct Address: Codable, Hashable, Identifiable {
                var id: String { "\(label)-\(line1)" }

                let label: String
                let line1: String
                let line2: String?
                let city: String?
                let region: String?
                let postalCode: String?
                let country: String?
                let latitude: Double?
                let longitude: Double?
                let comment: String?
            }

            struct Phone: Codable, Hashable, Identifiable {
                var id: String { e164 }

                let label: String
                let e164: String
                let display: String?
                let ext: String?
                let primary: Bool?
                let whatsapp: Bool?
                let telegram: Bool?
                let viber: Bool?
            }

            struct WorkingHoursSlot: Codable, Hashable, Identifiable {
                var id: String { "\(dayOfWeek)-\(open)-\(close)" }

                let dayOfWeek: Int
                let open: String
                let close: String
            }

            let id: String
            let name: String
            let publicName: String?
            let legalName: String?
            let aliases: [String]?
            let addresses: [Address]
            let phones: [Phone]
            let emails: [String]?
            let website: String?
            let mapUrl: String?
            let workingHours: [WorkingHoursSlot]?
            let orderIndex: Int
            let isPrimary: Bool
            let startAt: Date?
            let endAt: Date?
            let tags: [String]?
            let note: String?
        }

        let id: String?
        let singleton: String?
        let brandName: String?
        let legalName: String?
        let minAppVersionIos: String?
        let minAppVersionAndroid: String?
        let maintenanceMode: Bool
        let maintenanceMessage: String?
        let featureFlags: [String: JSONValue]
        let contacts: [ContactPoint]
        let extra: [String: JSONValue]
        let publishedVersion: Int
        let publishedAt: Date?
        let publishedReleaseId: String?
    }

    struct ClientFrontBlocksPage: Codable {
        let items: [ClientFrontBlockRecord]
    }

    struct ClientFrontBlockRecord: Codable, Identifiable, Hashable {
        let id: String
        let blockKey: String
        let blockType: String
        let payload: [String: JSONValue]
        let sortOrder: Int
        let isEnabled: Bool
        let platform: String?
        let minAppVersion: String?
        let maxAppVersion: String?
        let startAt: Date?
        let endAt: Date?
    }

    struct ClientFrontSpecialistsPage: Codable {
        let items: [ClientFrontSpecialistRecord]
    }

    struct ClientFrontSpecialistRecord: Codable, Identifiable, Hashable {
        struct PhotoRecord: Codable, Hashable {
            let assetId: String?
            let preferredUrl: String?
            let originalUrl: String?
        }

        struct ServiceSummary: Codable, Hashable, Identifiable {
            struct CategorySnapshot: Codable, Hashable {
                let id: String
                let name: String
            }

            let id: String
            let name: String
            let category: CategorySnapshot
        }

        var id: String { staffId }

        let staffId: String
        let name: String
        let specialty: String?
        let info: String?
        let ctaText: String?
        let isVisible: Bool
        let sortOrder: Int
        let photoAssetId: String?
        let photo: PhotoRecord?
        let services: [ServiceSummary]
        let isActive: Bool?
    }

    struct ClientFrontPreviewRecord: Codable, Hashable {
        struct ConfigRecord: Codable, Hashable {
            let brandName: String?
            let legalName: String?
            let maintenanceMode: Bool?
            let maintenanceMessage: String?
            let contacts: [ClientFrontConfigRecord.ContactPoint]?
            let featureFlags: [String: JSONValue]?
            let extra: [String: JSONValue]?
        }

        let stage: String
        let version: Int
        let config: ConfigRecord
        let blocks: [ClientFrontBlockRecord]
        let specialists: [ClientFrontSpecialistRecord]
    }

    struct ClientFrontReleasesPage: Codable {
        let items: [ClientFrontReleaseRecord]
    }

    struct ClientFrontReleaseRecord: Codable, Identifiable, Hashable {
        struct StaffSnapshot: Codable, Hashable {
            let id: String
            let name: String
            let role: String
        }

        let id: String
        let version: Int
        let etag: String?
        let blocksCount: Int
        let publishedAt: Date
        let publishedByStaff: StaffSnapshot?
    }

    struct PublishClientFrontResponse: Codable {
        let version: Int
        let etag: String
        let publishedAt: Date
        let blocksCount: Int
    }

    struct StaffServicesPage: Codable {
        let staffId: String
        let servicesCount: Int
        let items: [StaffServiceRecord]
    }

    struct StaffServiceRecord: Codable, Identifiable, Hashable {
        struct CategorySnapshot: Codable, Hashable {
            let id: String
            let name: String
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case category
            case durationSec
            case priceMin
            case priceMax
            case isActive
        }

        let id: String
        let name: String
        let category: CategorySnapshot
        let durationSec: Int
        let priceMin: Double
        let priceMax: Double
        let isActive: Bool

        init(
            id: String,
            name: String,
            category: CategorySnapshot,
            durationSec: Int,
            priceMin: Double,
            priceMax: Double,
            isActive: Bool
        ) {
            self.id = id
            self.name = name
            self.category = category
            self.durationSec = durationSec
            self.priceMin = priceMin
            self.priceMax = priceMax
            self.isActive = isActive
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            category = try container.decode(CategorySnapshot.self, forKey: .category)
            durationSec = try container.decodeFlexibleInt(forKey: .durationSec) ?? 0
            priceMin = try container.decodeFlexibleDouble(forKey: .priceMin) ?? 0
            priceMax = try container.decodeFlexibleDouble(forKey: .priceMax) ?? priceMin
            isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        }
    }

    struct StaffPermissionsPage: Codable {
        let staffId: String
        let items: [StaffPermissionRecord]
    }

    struct StaffPermissionCatalogPage: Codable {
        let items: [StaffPermissionCatalogItem]
    }

    struct StaffPermissionCatalogItem: Codable, Hashable, Identifiable {
        enum Group: String, Codable, CaseIterable, Hashable {
            case workspace
            case finance
            case marketing
            case content
        }

        var id: String { code }

        let code: String
        let title: String
        let description: String
        let group: Group
    }

    struct StaffPermissionRecord: Codable, Hashable, Identifiable {
        var id: String { code }

        let code: String
        let description: String
        let expiresAt: Date?
    }

    struct StaffPermissionMutationResponse: Codable {
        struct PermissionRecord: Codable {
            let staffId: String
            let code: String
            let expiresAt: Date?
        }

        let permission: PermissionRecord
    }

    struct StaffSettingsPayload: Codable {
        struct NotificationsPayload: Codable {
            struct ItemPayload: Codable, Identifiable, Hashable {
                let id: String
                let title: String
                let enabled: Bool
                let channel: String
                let channelLabel: String
            }

            struct GroupPayload: Codable, Identifiable, Hashable {
                let id: String
                let title: String
                let items: [ItemPayload]
            }

            struct SectionPayload: Codable, Identifiable, Hashable {
                let id: String
                let title: String
                let groups: [GroupPayload]
            }

            private enum CodingKeys: String, CodingKey {
                case minNoticeMinutes
                case sections
            }

            let minNoticeMinutes: Int
            let sections: [SectionPayload]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                minNoticeMinutes = try container.decodeFlexibleInt(forKey: .minNoticeMinutes) ?? 120
                sections = try container.decodeIfPresent([SectionPayload].self, forKey: .sections) ?? []
            }
        }

        struct PrivacyPolicyPayload: Codable {
            let content: String

            init(content: String) {
                self.content = content
            }

            private enum CodingKeys: String, CodingKey {
                case content
            }

            init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let rawValue = try? container.decode(String.self) {
                    content = rawValue
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            }
        }

        let notifications: NotificationsPayload
        let privacyPolicy: PrivacyPolicyPayload
    }

    struct WorkingHoursItem: Codable, Identifiable, Hashable {
        let id: String
        let dayOfWeek: Int?
        let date: String?
        let startTime: String
        let endTime: String
    }

    struct ClientRecord: Codable, Identifiable, Hashable {
        struct DiscountSnapshot: Codable, Hashable {
            struct DiscountValue: Codable, Hashable {
                let type: String
                let value: Double?
            }

            let permanent: DiscountValue
            let temporary: TemporaryDiscountValue
        }

        struct TemporaryDiscountValue: Codable, Hashable {
            let type: String
            let value: Double?
            let from: Date?
            let to: Date?
        }

        let id: String
        let name: String?
        let phoneE164: String
        let phone10: String
        let email: String?
        let avatarUrl: String?
        let comment: String?
        let discount: DiscountSnapshot
    }

    struct AppointmentRecord: Codable, Identifiable, Hashable {
        struct StaffSnapshot: Codable, Hashable {
            let id: String
            let name: String
        }

        struct ClientSnapshot: Codable, Hashable {
            let id: String
            let name: String?
            let phoneE164: String?
        }

        struct ServiceSnapshot: Codable, Hashable {
            private enum CodingKeys: String, CodingKey {
                case id
                case serviceId
                case name
                case durationSec
                case price
                case priceWithDiscount
                case sortOrder
            }

            let id: String
            let serviceId: String?
            let name: String
            let durationSec: Int
            let price: Double
            let priceWithDiscount: Double
            let sortOrder: Int

            init(
                id: String,
                serviceId: String?,
                name: String,
                durationSec: Int,
                price: Double,
                priceWithDiscount: Double,
                sortOrder: Int
            ) {
                self.id = id
                self.serviceId = serviceId
                self.name = name
                self.durationSec = durationSec
                self.price = price
                self.priceWithDiscount = priceWithDiscount
                self.sortOrder = sortOrder
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                serviceId = try container.decodeIfPresent(String.self, forKey: .serviceId)
                name = try container.decode(String.self, forKey: .name)
                durationSec = try container.decodeFlexibleInt(forKey: .durationSec) ?? 0
                price = try container.decodeFlexibleDouble(forKey: .price) ?? 0
                priceWithDiscount = try container.decodeFlexibleDouble(forKey: .priceWithDiscount) ?? 0
                sortOrder = try container.decodeFlexibleInt(forKey: .sortOrder) ?? 0
            }
        }

        struct PricesSnapshot: Codable, Hashable {
            private enum CodingKeys: String, CodingKey {
                case baseTotal
                case discountAmount
                case finalTotal
            }

            let baseTotal: Double
            let discountAmount: Double
            let finalTotal: Double

            init(baseTotal: Double, discountAmount: Double, finalTotal: Double) {
                self.baseTotal = baseTotal
                self.discountAmount = discountAmount
                self.finalTotal = finalTotal
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                baseTotal = try container.decodeFlexibleDouble(forKey: .baseTotal) ?? 0
                discountAmount = try container.decodeFlexibleDouble(forKey: .discountAmount) ?? 0
                finalTotal = try container.decodeFlexibleDouble(forKey: .finalTotal) ?? 0
            }
        }

        struct PaymentSnapshot: Codable, Hashable {
            private enum CodingKeys: String, CodingKey {
                case status
                case method
                case paidAmount
            }

            let status: String
            let method: String?
            let paidAmount: Double

            init(status: String, method: String?, paidAmount: Double) {
                self.status = status
                self.method = method
                self.paidAmount = paidAmount
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                status = try container.decode(String.self, forKey: .status)
                method = try container.decodeIfPresent(String.self, forKey: .method)
                paidAmount = try container.decodeFlexibleDouble(forKey: .paidAmount) ?? 0
            }
        }

        let id: String
        let externalId: String?
        let status: String
        let startAt: Date
        let endAt: Date
        let staff: StaffSnapshot
        let client: ClientSnapshot
        let services: [ServiceSnapshot]
        let prices: PricesSnapshot
        let payment: PaymentSnapshot
        let createdAt: Date
        let updatedAt: Date
    }

    struct HealthProbeResult {
        let summary: String
    }

    private struct HostOverride {
        let hostname: String
        let ipAddress: String
    }

    private struct TransportResult {
        let data: Data
        let response: URLResponse
        let usedHostOverride: HostOverride?
    }

    private struct APIEnvelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: APIErrorPayload?
    }

    private struct PlainPayloadEnvelope<T: Decodable>: Decodable {
        let ok: Bool?
        let data: T?
        let error: APIErrorPayload?
    }

    private struct APIErrorPayload: Decodable {
        let code: String?
        let message: String?
    }

    private struct EmptyResponse: Decodable {}

    enum APIClientError: LocalizedError {
        case invalidURL
        case invalidResponse
        case hostNotFound(host: String)
        case network(message: String)
        case serverUnavailable(statusCode: Int)
        case unauthorized
        case forbidden(message: String?)
        case server(message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Некорректный URL API"
            case .invalidResponse:
                return "Сервер вернул некорректный ответ"
            case .hostNotFound(let host):
                return "DNS не нашел хост `\(host)`. Проверь API endpoint."
            case .network(let message):
                return message
            case .serverUnavailable(let statusCode):
                return "Сервер Mari временно недоступен (\(statusCode))"
            case .unauthorized:
                return "Неверный телефон или PIN"
            case .forbidden(let message):
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "Нет доступа"
            case .server(let message):
                return message
            }
        }
    }

    private var baseURL: String
    private var session: StaffSession?
    private var activeHostOverrides: [String: HostOverride] = [:]
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "septon.mari-staff-ios", category: "network")

    init(baseURL: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func updateBaseURL(_ value: String) {
        baseURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hydrate(session: StaffSession?) {
        self.session = session
    }

    func login(phone: String, pin: String) async throws -> StaffSession {
        let payload = try await request(
            path: "/auth/staff/login",
            method: "POST",
            body: ["phone": phone, "pin": pin],
            requiresAuth: false,
            allowRefresh: false,
            as: StaffSession.self
        )
        session = payload
        return payload
    }

    func refresh() async throws -> StaffSession {
        guard let refreshToken = session?.tokens.refreshToken else {
            throw APIClientError.unauthorized
        }
        let payload = try await request(
            path: "/auth/staff/refresh",
            method: "POST",
            body: ["refreshToken": refreshToken],
            requiresAuth: false,
            allowRefresh: false,
            as: StaffSession.self
        )
        session = payload
        return payload
    }

    func me() async throws -> StaffSession.StaffIdentity {
        struct MePayload: Decodable {
            let staff: StaffSession.StaffIdentity
        }

        let payload = try await request(
            path: "/auth/staff/me",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: MePayload.self
        )
        return payload.staff
    }

    func logout() async throws {
        guard let refreshToken = session?.tokens.refreshToken else {
            session = nil
            return
        }

        _ = try await request(
            path: "/auth/staff/logout",
            method: "POST",
            body: ["refreshToken": refreshToken],
            requiresAuth: false,
            allowRefresh: false,
            as: EmptyResponse.self
        )
        session = nil
    }

    func listClients(page: Int = 1, limit: Int = 200, search: String? = nil) async throws -> ClientsPage {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }

        return try await request(
            path: "/clients" + queryString(items),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientsPage.self
        )
    }

    func listStaff(
        page: Int = 1,
        limit: Int = 200,
        role: String? = nil,
        isActive: Bool? = nil,
        employmentStatus: String? = nil,
        search: String? = nil
    ) async throws -> StaffPage {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let role, !role.isEmpty {
            items.append(URLQueryItem(name: "role", value: role))
        }
        if let isActive {
            items.append(URLQueryItem(name: "isActive", value: isActive ? "true" : "false"))
        }
        if let employmentStatus, !employmentStatus.isEmpty {
            items.append(URLQueryItem(name: "employmentStatus", value: employmentStatus))
        }
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }

        return try await request(
            path: "/staff" + queryString(items),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: StaffPage.self
        )
    }

    func getCurrentStaffProfile() async throws -> StaffRecord {
        do {
            let payload = try await request(
                path: "/staff/me",
                method: "GET",
                body: Optional<String>.none,
                requiresAuth: true,
                allowRefresh: true,
                as: StaffMutationEnvelope.self
            )
            return payload.staff
        } catch {
            let identity = try await me()
            return StaffRecord(
                id: identity.id,
                name: identity.name,
                role: identity.role,
                phoneE164: identity.phoneE164,
                email: identity.email,
                receivesAllAppointmentNotifications: identity.role == "OWNER",
                avatarUrl: nil,
                isActive: true,
                position: nil,
                hiredAt: nil,
                firedAt: nil,
                deletedAt: nil,
                permissions: identity.permissions?.map {
                    StaffRecord.PermissionSnapshot(code: $0, expiresAt: nil)
                }
            )
        }
    }

    func getClient(id: String) async throws -> ClientRecord {
        try await request(
            path: "/clients/\(id)",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientRecord.self
        )
    }

    func updateStaffContact(
        id: String,
        name: String,
        phone: String,
        email: String?,
        positionName: String?
    ) async throws -> StaffRecord {
        struct ContactPayload: Encodable {
            let name: String
            let phone: String
            let email: String?
            let positionName: String?
        }

        let payload = try await request(
            path: "/staff/\(id)/contact",
            method: "PATCH",
            body: ContactPayload(name: name, phone: phone, email: email, positionName: positionName),
            requiresAuth: true,
            allowRefresh: true,
            as: StaffMutationEnvelope.self
        )
        return payload.staff
    }

    func updateStaffRole(id: String, role: String) async throws -> StaffRecord {
        let payload = try await request(
            path: "/staff/\(id)/role",
            method: "PATCH",
            body: ["role": role],
            requiresAuth: true,
            allowRefresh: true,
            as: StaffMutationEnvelope.self
        )
        return payload.staff
    }

    func updateStaffAppointmentNotifications(
        id: String,
        receivesAllAppointmentNotifications: Bool
    ) async throws -> StaffRecord {
        let payload = try await request(
            path: "/staff/\(id)/appointment-notifications",
            method: "PATCH",
            body: ["receivesAllAppointmentNotifications": receivesAllAppointmentNotifications],
            requiresAuth: true,
            allowRefresh: true,
            as: StaffMutationEnvelope.self
        )
        return payload.staff
    }

    func fireStaff(id: String, firedAt: Date = Date()) async throws -> FireStaffMutationResponse {
        struct Payload: Encodable {
            let firedAt: String
        }

        return try await request(
            path: "/staff/\(id)/fire",
            method: "POST",
            body: Payload(firedAt: makeISOString(from: firedAt)),
            requiresAuth: true,
            allowRefresh: true,
            as: FireStaffMutationResponse.self
        )
    }

    func uploadStaffAvatarAsset(image: MariPreparedUploadImage) async throws -> MediaAssetUploadResponse {
        try await requestMultipart(
            path: "/client-front/staff/media/upload",
            method: "POST",
            formFields: ["entity": "specialists"],
            fileFieldName: "file",
            fileName: image.fileName,
            mimeType: image.mimeType,
            fileData: image.data,
            requiresAuth: true,
            allowRefresh: true,
            as: MediaAssetUploadResponse.self
        )
    }

    func updateStaffAvatar(id: String, photoAssetId: String?) async throws -> StaffAvatarMutationResponse {
        try await request(
            path: "/staff/\(id)/avatar",
            method: "PATCH",
            body: ["photoAssetId": photoAssetId],
            requiresAuth: true,
            allowRefresh: true,
            as: StaffAvatarMutationResponse.self
        )
    }

    func deleteStaffMediaAsset(id: String) async throws {
        _ = try await request(
            path: "/client-front/staff/media/\(id)",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: DeleteMutationEnvelope.self
        )
    }

    func listStaffServices(id: String) async throws -> StaffServicesPage {
        try await request(
            path: "/staff/\(id)/services",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: StaffServicesPage.self
        )
    }

    func updateStaffServices(id: String, serviceIDs: [String]) async throws -> StaffServicesPage {
        struct Payload: Encodable {
            let serviceIds: [String]
        }

        return try await request(
            path: "/staff/\(id)/services",
            method: "PUT",
            body: Payload(serviceIds: serviceIDs),
            requiresAuth: true,
            allowRefresh: true,
            as: StaffServicesPage.self
        )
    }

    func listStaffPermissions(id: String) async throws -> StaffPermissionsPage {
        try await request(
            path: "/staff/\(id)/permissions",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: StaffPermissionsPage.self
        )
    }

    func listStaffPermissionCatalog() async throws -> [StaffPermissionCatalogItem] {
        let payload = try await request(
            path: "/staff/permissions/catalog",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: StaffPermissionCatalogPage.self
        )
        return payload.items
    }

    func grantStaffPermission(id: String, code: String) async throws -> StaffPermissionRecord {
        let payload = try await request(
            path: "/staff/\(id)/permissions",
            method: "POST",
            body: ["code": code],
            requiresAuth: true,
            allowRefresh: true,
            as: StaffPermissionMutationResponse.self
        )

        return StaffPermissionRecord(
            code: payload.permission.code,
            description: payload.permission.code,
            expiresAt: payload.permission.expiresAt
        )
    }

    func revokeStaffPermission(id: String, code: String) async throws {
        struct Response: Decodable {
            let revoked: Bool
        }

        _ = try await request(
            path: "/staff/\(id)/permissions/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: Response.self
        )
    }

    func getStaffSettings() async throws -> StaffSettingsPayload {
        try await request(
            path: "/settings/staff",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: StaffSettingsPayload.self
        )
    }

    func patchPrivacyPolicy(content: String) async throws -> StaffSettingsPayload {
        try await request(
            path: "/settings/privacy-policy",
            method: "PATCH",
            body: ["content": content],
            requiresAuth: true,
            allowRefresh: true,
            as: StaffSettingsPayload.self
        )
    }

    func patchNotificationSettings(
        minNoticeMinutes: Int? = nil,
        toggles: [String: Bool]? = nil
    ) async throws -> StaffSettingsPayload {
        struct Payload: Encodable {
            let minNoticeMinutes: Int?
            let toggles: [String: Bool]?
        }

        return try await request(
            path: "/settings/notifications",
            method: "PATCH",
            body: Payload(minNoticeMinutes: minNoticeMinutes, toggles: toggles),
            requiresAuth: true,
            allowRefresh: true,
            as: StaffSettingsPayload.self
        )
    }

    func updateClient(
        id: String,
        name: String,
        phone: String,
        email: String?,
        comment: String?
    ) async throws -> ClientRecord {
        let payload = try await request(
            path: "/clients/\(id)",
            method: "PATCH",
            body: [
                "name": name,
                "phone": phone,
                "email": email ?? "",
                "comment": comment ?? "",
            ],
            requiresAuth: true,
            allowRefresh: true,
            as: ClientMutationResponse.self
        )
        return payload.client
    }

    func uploadClientAvatar(id: String, image: MariPreparedUploadImage) async throws -> ClientRecord {
        let payload = try await requestMultipart(
            path: "/clients/\(id)/avatar",
            method: "POST",
            formFields: [:],
            fileFieldName: "file",
            fileName: image.fileName,
            mimeType: image.mimeType,
            fileData: image.data,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientMutationResponse.self
        )
        return payload.client
    }

    func deleteClientAvatar(id: String) async throws -> ClientRecord {
        let payload = try await request(
            path: "/clients/\(id)/avatar",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientMutationResponse.self
        )
        return payload.client
    }

    func updateClientPermanentDiscount(id: String, percent: Double?) async throws -> ClientRecord {
        struct DiscountPayload: Encodable {
            struct Payload: Encodable {
                let mode: String
                let type: String
                let value: Double?
            }

            let discount: Payload
        }

        let payload = try await request(
            path: "/clients/\(id)/discount",
            method: "PATCH",
            body: DiscountPayload(
                discount: .init(
                    mode: "PERMANENT",
                    type: percent == nil ? "NONE" : "PERCENT",
                    value: percent
                )
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: ClientMutationResponse.self
        )
        return payload.client
    }

    func deleteClient(id: String) async throws -> DeleteClientResponse {
        try await request(
            path: "/clients/\(id)",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: DeleteClientResponse.self
        )
    }

    func listAppointments(
        page: Int = 1,
        limit: Int = 200,
        from: String? = nil,
        to: String? = nil,
        staffId: String? = nil,
        clientId: String? = nil,
        status: String? = nil
    ) async throws -> AppointmentsPage {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let from, !from.isEmpty {
            items.append(URLQueryItem(name: "from", value: from))
        }
        if let to, !to.isEmpty {
            items.append(URLQueryItem(name: "to", value: to))
        }
        if let staffId, !staffId.isEmpty {
            items.append(URLQueryItem(name: "staffId", value: staffId))
        }
        if let clientId, !clientId.isEmpty {
            items.append(URLQueryItem(name: "clientId", value: clientId))
        }
        if let status, !status.isEmpty {
            items.append(URLQueryItem(name: "status", value: status))
        }

        return try await request(
            path: "/appointments" + queryString(items),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: AppointmentsPage.self
        )
    }

    func createAppointment(
        startAt: Date,
        staffId: String,
        serviceIDs: [String],
        clientName: String,
        clientPhone: String
    ) async throws -> AppointmentRecord {
        try await request(
            path: "/appointments",
            method: "POST",
            body: CreateAppointmentPayload(
                startAt: makeISOString(from: startAt),
                staffId: staffId,
                anyStaff: false,
                serviceIds: serviceIDs,
                client: CreateAppointmentPayload.ClientPayload(
                    name: clientName,
                    phone: clientPhone
                )
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: AppointmentRecord.self
        )
    }

    func listServices(page: Int = 1, limit: Int = 500) async throws -> ServicesPage {
        try await request(
            path: "/services" + queryString([
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ServicesPage.self
        )
    }

    func listServiceCategories() async throws -> [ServiceCategoryRecord] {
        let payload = try await request(
            path: "/services/categories",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ServiceCategoryPage.self
        )
        return payload.items
    }

    func createServiceCategory(name: String) async throws -> ServiceCategoryRecord {
        let payload = try await request(
            path: "/services/categories",
            method: "POST",
            body: ["name": name],
            requiresAuth: true,
            allowRefresh: true,
            as: ServiceCategoryMutationEnvelope.self
        )
        return payload.item
    }

    func updateServiceCategory(id: String, name: String) async throws -> ServiceCategoryRecord {
        let payload = try await request(
            path: "/services/categories/\(id)",
            method: "PATCH",
            body: ["name": name],
            requiresAuth: true,
            allowRefresh: true,
            as: ServiceCategoryMutationEnvelope.self
        )
        return payload.item
    }

    func deleteServiceCategory(id: String) async throws {
        _ = try await request(
            path: "/services/categories/\(id)",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: DeleteMutationEnvelope.self
        )
    }

    func createService(
        name: String,
        nameOnline: String?,
        categoryID: String,
        description: String?,
        durationSec: Int,
        priceMin: Double,
        priceMax: Double?,
        isActive: Bool
    ) async throws -> ServiceRecord {
        struct Payload: Encodable {
            let name: String
            let nameOnline: String?
            let categoryId: String
            let description: String?
            let durationSec: Int
            let priceMin: Double
            let priceMax: Double?
            let isActive: Bool
        }

        let payload = try await request(
            path: "/services",
            method: "POST",
            body: Payload(
                name: name,
                nameOnline: nameOnline,
                categoryId: categoryID,
                description: description,
                durationSec: durationSec,
                priceMin: priceMin,
                priceMax: priceMax,
                isActive: isActive
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: ServiceMutationEnvelope.self
        )
        return payload.item
    }

    func updateService(
        id: String,
        name: String,
        nameOnline: String?,
        categoryID: String,
        description: String?,
        durationSec: Int,
        priceMin: Double,
        priceMax: Double?,
        isActive: Bool
    ) async throws -> ServiceRecord {
        struct Payload: Encodable {
            let name: String
            let nameOnline: String?
            let categoryId: String
            let description: String?
            let durationSec: Int
            let priceMin: Double
            let priceMax: Double?
            let isActive: Bool
        }

        let payload = try await request(
            path: "/services/\(id)",
            method: "PATCH",
            body: Payload(
                name: name,
                nameOnline: nameOnline,
                categoryId: categoryID,
                description: description,
                durationSec: durationSec,
                priceMin: priceMin,
                priceMax: priceMax,
                isActive: isActive
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: ServiceMutationEnvelope.self
        )
        return payload.item
    }

    func deleteService(id: String) async throws {
        _ = try await request(
            path: "/services/\(id)",
            method: "DELETE",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: DeleteMutationEnvelope.self
        )
    }

    func listWorkingHours(staffId: String, from: String, to: String) async throws -> WorkingHoursPage {
        try await request(
            path: "/schedule/staff/\(staffId)/working-hours" + queryString([
                URLQueryItem(name: "from", value: from),
                URLQueryItem(name: "to", value: to),
            ]),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: WorkingHoursPage.self
        )
    }

    func getClientFrontStaffConfig() async throws -> ClientFrontConfigRecord {
        try await request(
            path: "/client-front/staff/config",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientFrontConfigRecord.self
        )
    }

    func patchClientFrontConfig(
        brandName: String? = nil,
        legalName: String? = nil,
        minAppVersionIos: String? = nil,
        minAppVersionAndroid: String? = nil,
        maintenanceMode: Bool? = nil,
        maintenanceMessage: String? = nil,
        featureFlags: [String: JSONValue]? = nil,
        contacts: [ClientFrontConfigRecord.ContactPoint]? = nil,
        extra: [String: JSONValue]? = nil
    ) async throws {
        struct Payload: Encodable {
            let brandName: String?
            let legalName: String?
            let minAppVersionIos: String?
            let minAppVersionAndroid: String?
            let maintenanceMode: Bool?
            let maintenanceMessage: String?
            let featureFlags: [String: JSONValue]?
            let contacts: [ClientFrontConfigRecord.ContactPoint]?
            let extra: [String: JSONValue]?
        }

        _ = try await request(
            path: "/client-front/staff/config",
            method: "PATCH",
            body: Payload(
                brandName: brandName,
                legalName: legalName,
                minAppVersionIos: minAppVersionIos,
                minAppVersionAndroid: minAppVersionAndroid,
                maintenanceMode: maintenanceMode,
                maintenanceMessage: maintenanceMessage,
                featureFlags: featureFlags,
                contacts: contacts,
                extra: extra
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: EmptyResponse.self
        )
    }

    func listClientFrontBlocks() async throws -> ClientFrontBlocksPage {
        try await request(
            path: "/client-front/staff/blocks",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientFrontBlocksPage.self
        )
    }

    func patchClientFrontBlock(
        id: String,
        payload: [String: JSONValue]? = nil,
        sortOrder: Int? = nil,
        platform: String? = nil,
        minAppVersion: String? = nil,
        maxAppVersion: String? = nil,
        startAt: String? = nil,
        endAt: String? = nil,
        isEnabled: Bool? = nil
    ) async throws {
        struct Payload: Encodable {
            let payload: [String: JSONValue]?
            let sortOrder: Int?
            let platform: String?
            let minAppVersion: String?
            let maxAppVersion: String?
            let startAt: String?
            let endAt: String?
            let isEnabled: Bool?
        }

        _ = try await request(
            path: "/client-front/staff/blocks/\(id)",
            method: "PATCH",
            body: Payload(
                payload: payload,
                sortOrder: sortOrder,
                platform: platform,
                minAppVersion: minAppVersion,
                maxAppVersion: maxAppVersion,
                startAt: startAt,
                endAt: endAt,
                isEnabled: isEnabled
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: EmptyResponse.self
        )
    }

    func listClientFrontSpecialists() async throws -> ClientFrontSpecialistsPage {
        try await request(
            path: "/client-front/staff/specialists",
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientFrontSpecialistsPage.self
        )
    }

    func patchClientFrontSpecialist(
        staffId: String,
        specialty: String? = nil,
        info: String? = nil,
        ctaText: String? = nil,
        isVisible: Bool? = nil,
        sortOrder: Int? = nil
    ) async throws {
        struct Payload: Encodable {
            let specialty: String?
            let info: String?
            let ctaText: String?
            let isVisible: Bool?
            let sortOrder: Int?
        }

        _ = try await request(
            path: "/client-front/staff/specialists/\(staffId)",
            method: "PATCH",
            body: Payload(
                specialty: specialty,
                info: info,
                ctaText: ctaText,
                isVisible: isVisible,
                sortOrder: sortOrder
            ),
            requiresAuth: true,
            allowRefresh: true,
            as: EmptyResponse.self
        )
    }

    func getClientFrontPreview(platform: String = "web") async throws -> ClientFrontPreviewRecord {
        try await request(
            path: "/client-front/staff/preview" + queryString([
                URLQueryItem(name: "platform", value: platform)
            ]),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientFrontPreviewRecord.self
        )
    }

    func listClientFrontReleases(page: Int = 1, limit: Int = 20) async throws -> ClientFrontReleasesPage {
        try await request(
            path: "/client-front/staff/releases" + queryString([
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]),
            method: "GET",
            body: Optional<String>.none,
            requiresAuth: true,
            allowRefresh: true,
            as: ClientFrontReleasesPage.self
        )
    }

    func publishClientFront() async throws -> PublishClientFrontResponse {
        try await request(
            path: "/client-front/staff/publish",
            method: "POST",
            body: [String: String](),
            requiresAuth: true,
            allowRefresh: true,
            as: PublishClientFrontResponse.self
        )
    }

    func getAnalyticsOverview(
        from: String,
        to: String,
        masterId: String? = nil,
        positionId: String? = nil,
        userId: String? = nil
    ) async throws -> AnalyticsOverviewPayload {
        let variants: [[URLQueryItem]] = [
            compactAnalyticsQueryItems(
                ("from", from),
                ("to", to),
                ("masterId", masterId),
                ("positionId", positionId),
                ("userId", userId)
            ),
            compactAnalyticsQueryItems(
                ("start_date", from),
                ("end_date", to),
                ("master_id", masterId ?? "0"),
                ("position_id", positionId ?? "0"),
                ("user_id", userId ?? "0")
            ),
            compactAnalyticsQueryItems(
                ("from", from),
                ("to", to),
                ("master_id", masterId ?? "0"),
                ("position_id", positionId ?? "0")
            ),
        ]

        var lastError: Error?
        for items in variants where !items.isEmpty {
            do {
                return try await request(
                    path: "/reports/overview" + queryString(items),
                    method: "GET",
                    body: Optional<String>.none,
                    requiresAuth: true,
                    allowRefresh: true,
                    as: AnalyticsOverviewPayload.self
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? APIClientError.server(message: "Не удалось загрузить аналитику")
    }

    func clearSession() {
        session = nil
    }

    private func compactAnalyticsQueryItems(_ pairs: (String, String?)...) -> [URLQueryItem] {
        pairs.compactMap { key, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return URLQueryItem(name: key, value: value)
        }
    }

    func probeHealth() async -> HealthProbeResult {
        do {
            let baseURL = try resolvedBaseURL()
            guard let url = URL(string: "\(baseURL)/health") else {
                return HealthProbeResult(summary: "Некорректный health URL: \(baseURL)/health")
            }

            do {
                let result = try await performRequest(URLRequest(url: url))
                guard let httpResponse = result.response as? HTTPURLResponse else {
                    return HealthProbeResult(
                        summary: """
                        GET \(url.absoluteString)
                        Некорректный URLResponse
                        """
                    )
                }

                let body = String(data: result.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<empty>"
                let fallbackLine = result.usedHostOverride.map { "Fallback IP \($0.ipAddress) для \($0.hostname)" }

                return HealthProbeResult(
                    summary: [
                        "GET \(url.absoluteString)",
                        fallbackLine,
                        "HTTP \(httpResponse.statusCode)",
                        body,
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                )
            } catch let error as APIClientError {
                return HealthProbeResult(summary: error.errorDescription ?? "Ошибка API")
            } catch let error as URLError {
                return HealthProbeResult(
                    summary: """
                    GET \(url.absoluteString)
                    URLError \(error.code.rawValue): \(error.localizedDescription)
                    """
                )
            } catch {
                return HealthProbeResult(
                    summary: """
                    GET \(url.absoluteString)
                    \(error.localizedDescription)
                    """
                )
            }

        } catch {
            return HealthProbeResult(summary: localizedNetworkMessage(for: error))
        }
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        requiresAuth: Bool,
        allowRefresh: Bool,
        as _: Response.Type
    ) async throws -> Response {
        let baseURL = try resolvedBaseURL()

        guard let url = URL(string: baseURL + path) else {
            throw APIClientError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            urlRequest.httpBody = try JSONEncoder().encode(body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if requiresAuth, let accessToken = session?.tokens.accessToken {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let transport: TransportResult
        do {
            transport = try await performRequest(urlRequest)
        } catch let error as URLError {
            throw apiError(for: error, url: url)
        }

        let data = transport.data
        let response = transport.response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        if httpResponse.statusCode == 401, requiresAuth, allowRefresh {
            _ = try await refresh()
            return try await request(
                path: path,
                method: method,
                body: body,
                requiresAuth: requiresAuth,
                allowRefresh: false,
                as: Response.self
            )
        }

        if httpResponse.statusCode >= 500 {
            throw APIClientError.serverUnavailable(statusCode: httpResponse.statusCode)
        }

        return try decodeResponse(Response.self, from: data, httpResponse: httpResponse)
    }

    private func requestMultipart<Response: Decodable>(
        path: String,
        method: String,
        formFields: [String: String],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data,
        requiresAuth: Bool,
        allowRefresh: Bool,
        as _: Response.Type
    ) async throws -> Response {
        let baseURL = try resolvedBaseURL()

        guard let url = URL(string: baseURL + path) else {
            throw APIClientError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = buildMultipartBody(
            boundary: boundary,
            formFields: formFields,
            fileFieldName: fileFieldName,
            fileName: fileName,
            mimeType: mimeType,
            fileData: fileData
        )

        if requiresAuth, let accessToken = session?.tokens.accessToken {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let transport: TransportResult
        do {
            transport = try await performRequest(urlRequest)
        } catch let error as URLError {
            throw apiError(for: error, url: url)
        }

        let data = transport.data
        let response = transport.response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        if httpResponse.statusCode == 401, requiresAuth, allowRefresh {
            _ = try await refresh()
            return try await requestMultipart(
                path: path,
                method: method,
                formFields: formFields,
                fileFieldName: fileFieldName,
                fileName: fileName,
                mimeType: mimeType,
                fileData: fileData,
                requiresAuth: requiresAuth,
                allowRefresh: false,
                as: Response.self
            )
        }

        if httpResponse.statusCode >= 500 {
            throw APIClientError.serverUnavailable(statusCode: httpResponse.statusCode)
        }

        return try decodeResponse(Response.self, from: data, httpResponse: httpResponse)
    }

    private func buildMultipartBody(
        boundary: String,
        formFields: [String: String],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()

        for key in formFields.keys.sorted() {
            guard let value = formFields[key] else { continue }
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n"
        )
        body.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n")
        body.appendUTF8("--\(boundary)--\r\n")

        return body
    }

    private func decodeResponse<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        httpResponse: HTTPURLResponse
    ) throws -> Response {
        if Response.self == EmptyResponse.self, httpResponse.statusCode == 204 {
            return EmptyResponse() as! Response
        }

        do {
            let envelope = try Self.jsonDecoder.decode(APIEnvelope<Response>.self, from: data)
            if (200..<300).contains(httpResponse.statusCode), let payload = envelope.data {
                return payload
            }
            if httpResponse.statusCode == 401 {
                throw APIClientError.unauthorized
            }
            if httpResponse.statusCode == 403 {
                throw APIClientError.forbidden(message: envelope.error?.message)
            }
            throw APIClientError.server(message: envelope.error?.message ?? "Ошибка API")
        } catch let envelopeError {
            logger.error("Envelope decode failed for status \(httpResponse.statusCode, privacy: .public): \(String(describing: envelopeError), privacy: .public)")
            logResponseBody(data, statusCode: httpResponse.statusCode)

            do {
                let payload = try Self.jsonDecoder.decode(Response.self, from: data)
                if (200..<300).contains(httpResponse.statusCode) {
                    logger.info("Decoded direct payload response for status \(httpResponse.statusCode, privacy: .public)")
                    return payload
                }
                if httpResponse.statusCode == 403 {
                    throw APIClientError.forbidden(message: nil)
                }
                throw APIClientError.server(message: "Ошибка API")
            } catch let directDecodeError {
                logger.error("Direct payload decode failed for status \(httpResponse.statusCode, privacy: .public): \(String(describing: directDecodeError), privacy: .public)")
                logResponseBody(data, statusCode: httpResponse.statusCode)
                if httpResponse.statusCode == 403 {
                    throw APIClientError.forbidden(message: nil)
                }
                throw APIClientError.invalidResponse
            }
        }
    }

    private func logResponseBody(_ data: Data, statusCode: Int) {
        guard !data.isEmpty else {
            logger.info("Response body is empty for status \(statusCode, privacy: .public)")
            return
        }

        if let text = String(data: data, encoding: .utf8) {
            logger.info("Response body for status \(statusCode, privacy: .public): \(text, privacy: .public)")
        } else {
            logger.info("Response body for status \(statusCode, privacy: .public) is \(data.count, privacy: .public) bytes and is not valid UTF-8")
        }
    }

    private func resolvedBaseURL() throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIClientError.invalidURL
        }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        candidate = candidate.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty
        else {
            throw APIClientError.invalidURL
        }

        return components.url?.absoluteString ?? candidate
    }

    private func performRequest(_ request: URLRequest) async throws -> TransportResult {
        guard let url = request.url else {
            throw APIClientError.invalidURL
        }

        logger.info("Request \(request.httpMethod ?? "GET", privacy: .public) \(url.absoluteString, privacy: .public)")

        if let override = cachedHostOverride(for: url) {
            do {
                let (data, response) = try await performRequestWithHostOverride(request, override: override)
                return TransportResult(data: data, response: response, usedHostOverride: override)
            } catch {
                activeHostOverrides.removeValue(forKey: override.hostname)
                logger.error("Host override request failed for \(override.hostname, privacy: .public) via \(override.ipAddress, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            return TransportResult(data: data, response: response, usedHostOverride: nil)
        } catch let error as URLError {
            guard isDNSFailure(error), let override = hostOverride(for: url) else {
                logger.error("Network error \(error.code.rawValue): \(error.localizedDescription, privacy: .public)")
                throw error
            }

            logger.warning("DNS failed for \(override.hostname, privacy: .public). Retrying via \(override.ipAddress, privacy: .public)")
            do {
                let (data, response) = try await performRequestWithHostOverride(request, override: override)
                activeHostOverrides[override.hostname] = override
                return TransportResult(data: data, response: response, usedHostOverride: override)
            } catch {
                logger.error("Host override retry failed for \(override.hostname, privacy: .public) via \(override.ipAddress, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    private func performRequestWithHostOverride(
        _ request: URLRequest,
        override hostOverride: HostOverride
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https"
        else {
            throw APIClientError.invalidURL
        }

        let requestData = try serializedHostOverrideRequest(request, hostOverride: hostOverride)
        let logger = self.logger

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RawHTTPResponse, Error>) in
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, hostOverride.hostname)
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    let policy = SecPolicyCreateSSL(true, hostOverride.hostname as CFString)
                    SecTrustSetPolicies(trust, policy)
                    complete(SecTrustEvaluateWithError(trust, nil))
                },
                DispatchQueue.global(qos: .userInitiated)
            )

            let parameters = NWParameters(tls: tlsOptions)
            let connection = NWConnection(
                host: NWEndpoint.Host(hostOverride.ipAddress),
                port: 443,
                using: parameters
            )
            let queue = DispatchQueue(label: "septon.mari-staff-ios.host-override")
            var responseBuffer = Data()
            var didResume = false

            func finish(_ result: Result<RawHTTPResponse, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
                connection.cancel()
            }

            func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        responseBuffer.append(data)
                    }

                    if let error {
                        finish(.failure(APIClientError.network(message: error.localizedDescription)))
                        return
                    }

                    if isComplete {
                        do {
                            finish(.success(try parseRawHTTPResponse(responseBuffer)))
                        } catch {
                            finish(.failure(error))
                        }
                        return
                    }

                    receiveNextChunk()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    logger.info("Host override tunnel ready \(hostOverride.ipAddress, privacy: .public) for \(hostOverride.hostname, privacy: .public)")
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(APIClientError.network(message: error.localizedDescription)))
                            return
                        }
                        receiveNextChunk()
                    })
                case .failed(let error):
                    finish(.failure(APIClientError.network(message: error.localizedDescription)))
                case .cancelled:
                    finish(.failure(APIClientError.network(message: "Соединение с API было отменено.")))
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }

        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            throw APIClientError.invalidResponse
        }

        return (response.body, httpResponse)
    }

    private func serializedHostOverrideRequest(
        _ request: URLRequest,
        hostOverride: HostOverride
    ) throws -> Data {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw APIClientError.invalidURL
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Data()

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = hostOverride.hostname
        headers["Connection"] = "close"

        if !body.isEmpty {
            headers["Content-Length"] = String(body.count)
        }

        let headerLines = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")

        var requestString = "\(method) \(path)\(query) HTTP/1.1\r\n"
        requestString += headerLines
        requestString += "\r\n\r\n"

        var serialized = Data(requestString.utf8)
        serialized.append(body)
        return serialized
    }

    private func hostOverride(for url: URL) -> HostOverride? {
        guard let host = url.host?.lowercased() else {
            return nil
        }

        if host == "api.maribeauty.ru" {
            return HostOverride(hostname: host, ipAddress: "217.114.3.7")
        }

        return nil
    }

    private func cachedHostOverride(for url: URL) -> HostOverride? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        return activeHostOverrides[host]
    }

    private func isDNSFailure(_ error: URLError) -> Bool {
        error.code == .cannotFindHost || error.code == .dnsLookupFailed
    }

    private func apiError(for error: URLError, url: URL) -> APIClientError {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound(host: url.host ?? url.absoluteString)
        case .cannotConnectToHost:
            return .network(message: "Нет соединения с `\(url.host ?? url.absoluteString)`.")
        case .timedOut:
            return .network(message: "Сервер Mari не ответил вовремя.")
        case .notConnectedToInternet:
            return .network(message: "Нет подключения к интернету.")
        default:
            return .network(message: error.localizedDescription)
        }
    }

    private func localizedNetworkMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func queryString(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery.map { "?\($0)" } ?? ""
    }

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let singleValue = try container.singleValueContainer()
            let value = try singleValue.decode(String.self)
            if let date = parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: singleValue, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let date = plainFormatter.date(from: trimmed) {
            return date
        }

        let formatters: [DateFormatter] = {
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd"
            ]

            return formats.map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                return formatter
            }
        }()

        for formatter in formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private func makeISOString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
