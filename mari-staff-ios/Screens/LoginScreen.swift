import SwiftUI
import SafariServices

struct LoginScreen: View {
    @ObservedObject var sessionStore: AppSessionStore
    @FocusState private var focusedField: Field?
    @State private var isPINVisible = false
    @State private var isDeveloperToolsVisible = false
    @State private var resetPasswordSheet: ResetPasswordSheetItem?

    private enum Field {
        case phone
        case pin
        case baseURL
    }

    private var phoneBinding: Binding<String> {
        Binding(
            get: { Self.phoneLocalDigits(from: sessionStore.phone) },
            set: { value in
                sessionStore.phone = Self.buildPhoneValue(from: value)
            }
        )
    }

    private var isPhoneValid: Bool {
        Self.normalizedPhoneDigits(from: sessionStore.phone).count == 11
    }

    private var isPINValid: Bool {
        let pin = sessionStore.pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = pin.allSatisfy(\.isNumber)
        return digitsOnly && (4...8).contains(pin.count)
    }

    private var canSubmit: Bool {
        isPhoneValid && isPINValid && !sessionStore.isSubmitting
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 780

            ZStack {
                MariBackground()
                    .ignoresSafeArea()

                ScrollView {
                    Group {
                        if isWide {
                            desktopLayout
                        } else {
                            mobileLayout
                        }
                    }
                    .padding(.horizontal, isWide ? 28 : 0)
                    .padding(.vertical, isWide ? 28 : 0)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: sessionStore.phase) { _, phase in
            if case .authenticated = phase {
                focusedField = nil
            }
        }
        .onDisappear {
            focusedField = nil
        }
        .sheet(item: $resetPasswordSheet) { item in
            ResetPasswordSheet(url: item.url)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(0)
        }
    }

    private var mobileLayout: some View {
        VStack(spacing: 18) {
            iosHeader
                .padding(.top, 20)
                .padding(.horizontal, 20)

            authCard(compact: true)
                .padding(.horizontal, 16)

        }
        .padding(.top, 12)
    }

    private var iosHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.65), lineWidth: 1)
                        )
                        .frame(width: 64, height: 64)

                    Image(systemName: "person.crop.rectangle.stack.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(MariPalette.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mari Staff")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)

                    Text("Вход")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(MariPalette.ink)
                }

                Spacer(minLength: 0)
            }

            Text("Введите рабочий телефон и код-пароль, чтобы открыть кабинет.")
                .font(.subheadline)
                .foregroundStyle(MariPalette.softInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var desktopLayout: some View {
        HStack(alignment: .top, spacing: 22) {
            DesktopHero()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Mari Staff".uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(MariPalette.softInk.opacity(0.72))

                    Text("Вход")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(MariPalette.ink)

                    Text("Введите телефон сотрудника и код-пароль, чтобы открыть рабочий кабинет.")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MariPalette.softInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                authCard(compact: false)
            }
            .frame(maxWidth: 540, alignment: .topLeading)
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .shadow(color: Color.black.opacity(0.08), radius: 32, x: 0, y: 20)
            )
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 8)
    }

    private func authCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Вход в аккаунт")
                    .font(.system(size: compact ? 28 : 30, weight: .bold, design: .rounded))
                    .foregroundStyle(MariPalette.ink)

                Text("Телефон сотрудника и код-пароль")
                    .font(.subheadline)
                    .foregroundStyle(MariPalette.softInk)
            }

            VStack(spacing: 12) {
                MariInsetPhoneField(text: phoneBinding)
                    .focused($focusedField, equals: .phone)

                MariInsetPINField(
                    text: $sessionStore.pin,
                    isVisible: $isPINVisible
                )
                .focused($focusedField, equals: .pin)
            }

            if !sessionStore.errorMessage.isEmpty {
                Label {
                    Text(sessionStore.errorMessage)
                        .font(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .foregroundStyle(Color.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
            }

            Button {
                submitLogin()
            } label: {
                HStack(spacing: 10) {
                    if sessionStore.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }

                    Text("Войти")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 54 : 58)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(canSubmit ? MariPalette.accent : Color.gray.opacity(0.25))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            Button {
                if let url = URL(string: "https://staff.maribeauty.ru/staff/reset-pin") {
                    resetPasswordSheet = ResetPasswordSheetItem(url: url)
                }
            } label: {
                Text("Забыли пароль?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MariPalette.accent.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(compact ? 20 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 26 : 30, style: .continuous)
                .fill(Color.white.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 26 : 30, style: .continuous)
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 22, x: 0, y: 14)
    }

    private static func phoneLocalDigits(from value: String) -> String {
        let digits = value.filter(\.isNumber)
        if digits.hasPrefix("7") {
            return String(digits.dropFirst())
        }
        if digits.hasPrefix("8") {
            return String(digits.dropFirst())
        }
        return digits
    }

    private static func buildPhoneValue(from rawValue: String) -> String {
        let digits = rawValue.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        let limited = String(digits.prefix(10))
        return "+7\(limited)"
    }

    private static func normalizedPhoneDigits(from value: String) -> String {
        let digits = value.filter(\.isNumber)
        if digits.count == 10 {
            return "7\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("8") {
            return "7\(digits.dropFirst())"
        }
        return digits
    }

    private func submitLogin() {
        focusedField = nil

        Task {
            try? await Task.sleep(for: .milliseconds(120))
            await sessionStore.login()
        }
    }
}

private struct MobileHero: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: 0xF4C900)

            MariHeroPattern()
                .opacity(0.35)

            WaveShape()
                .fill(Color(hex: 0xF3F3F4))
                .frame(height: 150)
        }
        .frame(height: 280)
    }
}

private struct DesktopHero: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(hex: 0xF4C900))

            MariHeroPattern()
                .opacity(0.35)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Авторизация".uppercased())
                        .font(.caption.weight(.black))
                        .tracking(3)
                        .foregroundStyle(Color(hex: 0x4A4F56))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.55)))

                    Text("Админ панель")
                        .font(.system(size: 58, weight: .black, design: .rounded))
                        .tracking(-1.5)
                        .foregroundStyle(Color(hex: 0x30343A))

                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(Color(hex: 0xF6878D))
                        .frame(width: 96, height: 4)

                    Text("Экран входа в Mari Beauty Staff.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x535860))
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .padding(44)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 12) {
                    Text("MARI STAFF")
                        .font(.caption.weight(.black))
                        .tracking(3)
                        .foregroundStyle(Color(hex: 0x626770))

                    Text("Используйте рабочий телефон и ваш пин-код, чтобы открыть журнал, записи и уведомления.")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x464B54))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 360, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(0.52))
                )
                .padding(.leading, 44)
                .padding(.bottom, 88)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WaveShape()
                .fill(Color.white.opacity(0.94))
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 680)
    }
}

private struct MariHeroPattern: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 6)
                .frame(width: 220, height: 140)
                .offset(x: -120, y: -120)

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 6)
                .frame(width: 260, height: 160)
                .offset(x: 40, y: -136)

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 6)
                .frame(width: 240, height: 150)
                .offset(x: 140, y: -16)

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 6)
                .frame(width: 240, height: 150)
                .offset(x: -60, y: 92)

            Circle()
                .stroke(.white.opacity(0.34), lineWidth: 6)
                .frame(width: 240, height: 150)
                .offset(x: 120, y: 110)
        }
        .compositingGroup()
    }
}

private struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.44))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.72),
            control1: CGPoint(x: rect.width * 0.16, y: rect.height * 0.18),
            control2: CGPoint(x: rect.width * 0.28, y: rect.height * 0.56)
        )
        path.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.52),
            control1: CGPoint(x: rect.width * 0.58, y: rect.height * 0.9),
            control2: CGPoint(x: rect.width * 0.8, y: rect.height * 0.72)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct MariInsetPhoneField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Телефон")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)

            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MariPalette.softInk)

                Text("+7")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MariPalette.ink)

                TextField("9780000000", text: $text)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MariPalette.ink)
                    .tint(MariPalette.accent)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

private struct MariInsetPINField: View {
    @Binding var text: String
    @Binding var isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Код-пароль")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MariPalette.softInk)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MariPalette.softInk)

                Group {
                    if isVisible {
                        TextField("Введите код-пароль", text: $text)
                    } else {
                        SecureField("Введите код-пароль", text: $text)
                    }
                }
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.weight(.semibold))
                .foregroundStyle(MariPalette.ink)
                .tint(MariPalette.accent)

                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MariPalette.softInk)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }
}


private struct ResetPasswordSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ResetPasswordSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

#Preview {
    LoginScreen(sessionStore: AppSessionStore(configuration: AppConfigurationStore()))
}
