import SwiftUI

enum MariLocale {
    static let ru = Locale(identifier: "ru_RU")
}

enum MariPalette {
    static let ink = Color(hex: 0x1E232C)
    static let softInk = Color(hex: 0x56606E)
    static let accent = Color(hex: 0xF2B706)
    static let accentSecondary = Color(hex: 0xF4D67A)
    static let rose = Color(hex: 0xE6B6A9)
    static let mint = Color(hex: 0x8FC7B1)
    static let sky = Color(hex: 0x90B6F5)
    static let plum = Color(hex: 0xC5B5E8)
    static let canvasTop = Color(hex: 0xFFF7EC)
    static let canvasBottom = Color(hex: 0xF8EDE7)
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum MariFormatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "RUB"
        formatter.locale = MariLocale.ru
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func money(_ value: Int) -> String {
        currency.string(from: NSNumber(value: value)) ?? "\(value) ₽"
    }

    static func timeRange(start: Date, durationMinutes: Int) -> String {
        let end = Calendar.current.date(byAdding: .minute, value: durationMinutes, to: start) ?? start
        return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func shiftRange(start: Date, end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func heroDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(MariLocale.ru))
    }
}

struct MariScrollContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            MariBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct MariBackground: View {
    var body: some View {
        LinearGradient(
            colors: [MariPalette.canvasTop, MariPalette.canvasBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(MariPalette.accentSecondary.opacity(0.45))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: -50, y: -20)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(MariPalette.rose.opacity(0.28))
                .frame(width: 240, height: 240)
                .blur(radius: 28)
                .offset(x: 70, y: -30)
        }
        .overlay(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .fill(MariPalette.sky.opacity(0.18))
                .frame(width: 210, height: 210)
                .rotationEffect(.degrees(18))
                .blur(radius: 18)
                .offset(x: -30, y: 50)
        }
    }
}

struct MariSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 16
    var baseColor: Color = .white.opacity(0.52)
    var highlightColor: Color = .white.opacity(0.82)

    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseColor)
            .overlay {
                GeometryReader { proxy in
                    let shimmerWidth = max(proxy.size.width * 0.7, 60)
                    let travel = proxy.size.width + shimmerWidth * 2

                    LinearGradient(
                        colors: [.clear, highlightColor, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: shimmerWidth, height: proxy.size.height * 1.9)
                    .rotationEffect(.degrees(14))
                    .offset(x: isAnimating ? travel / 2 : -travel / 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .onAppear {
                guard !isAnimating else { return }
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

struct MariSkeletonCircle: View {
    var size: CGFloat

    var body: some View {
        MariSkeletonBlock(width: size, height: size, cornerRadius: size / 2)
    }
}

struct GlassPanel<Content: View>: View {
    var tint: Color?
    var cornerRadius: CGFloat = 28
    var interactive = false
    @ViewBuilder var content: Content

    private var glass: Glass {
        let base = Glass.regular.tint(tint)
        return interactive ? base.interactive() : base
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    }
            }
            .glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: (tint ?? .white).opacity(0.16), radius: 24, x: 0, y: 12)
    }
}

struct MariSectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(MariPalette.ink)

            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)
        }
    }
}

struct MariMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        GlassPanel(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .fontDesign(.rounded)
                    .tracking(1.8)
                    .foregroundStyle(MariPalette.softInk.opacity(0.72))

                Text(value)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(MariPalette.ink)

                Text(detail)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MariPalette.softInk)
            }
        }
    }
}

struct MariAvatar: View {
    let title: String
    var tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.28))
            Text(String(title.prefix(2)).uppercased())
                .font(.headline.weight(.black))
                .fontDesign(.rounded)
                .foregroundStyle(MariPalette.ink)
        }
        .frame(width: 52, height: 52)
    }
}

struct MariBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .fontDesign(.rounded)
            .foregroundStyle(MariPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .overlay {
                        Capsule().stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            }
            .glassEffect(.regular.tint(tint), in: Capsule())
    }
}

extension AppointmentStatus {
    var accentColor: Color {
        switch self {
        case .pending: MariPalette.accent
        case .confirmed: MariPalette.sky
        case .arrived: MariPalette.mint
        case .noShow: Color(hex: 0xE5988B)
        case .cancelled: Color(hex: 0xD2C9C3)
        }
    }
}

extension NotificationKind {
    var accentColor: Color {
        switch self {
        case .booking: MariPalette.accent
        case .staff: MariPalette.sky
        case .client: MariPalette.rose
        case .system: MariPalette.plum
        }
    }

    var symbol: String {
        switch self {
        case .booking: "calendar.badge.plus"
        case .staff: "person.2.badge.gearshape"
        case .client: "message.badge.waveform"
        case .system: "gearshape.2.fill"
        }
    }
}

extension ClientTier {
    var accentColor: Color {
        switch self {
        case .vip: MariPalette.accent
        case .loyal: MariPalette.sky
        case .new: MariPalette.mint
        }
    }
}
