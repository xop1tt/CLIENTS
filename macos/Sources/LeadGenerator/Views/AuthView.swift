import AppKit
import LeadCloud
import LeadGenCore
import SwiftUI

/// Вход и регистрация: облачная учётная запись (данные синхронизируются между устройствами)
/// или локальная (данные только на этом Mac). Если облако в сборке не настроено — только локальная.
struct AuthView: View {
    @Environment(\.session) private var session

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                            .resizable().frame(width: 84, height: 84)
                        Text("Lead Generator").font(.system(size: 26, weight: .bold))
                        Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    switch session.stage {
                    case .local: LocalAuthForm()
                    default: CloudAuthForm()
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var subtitle: String {
        switch session.stage {
        case .signIn: return "Войдите, чтобы продолжить"
        case .signUp: return "Создайте учётную запись"
        case .confirm: return "Подтвердите адрес почты"
        case .forgot, .reset: return "Восстановление пароля"
        case .newPassword: return "Новый пароль"
        case .local: return "Учётная запись на этом Mac"
        }
    }
}

// MARK: Облако

private struct CloudAuthForm: View {
    @Environment(\.session) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    enum Field { case email, password, confirm, code }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 14) {
            fields
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 300)

            if let i = session.info {
                Text(i).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 340)
            }
            if let e = session.error {
                Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(width: 340)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if session.busy { ProgressView().controlSize(.small) }
                    Text(primaryTitle).font(.system(size: 14, weight: .semibold))
                }
                .frame(width: 280)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(session.busy || !canSubmit)

            links
                .buttonStyle(.link)

            Text("Лиды, исключения и настройки поиска хранятся на этом Mac и синхронизируются через облако. Без сети приложение работает как обычно.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 360)
        }
        .onAppear { focus = .email }
        .onChange(of: session.stage) { _, stage in
            password = ""; confirm = ""; code = ""
            switch stage {
            case .confirm(let e), .reset(let e): email = e; focus = .code
            case .newPassword: focus = .password
            default: focus = .email
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch session.stage {
        case .signIn:
            emailField
            SecureField("Пароль", text: $password)
                .textContentType(.password).focused($focus, equals: .password).onSubmit(submit)
        case .signUp:
            emailField
            SecureField("Пароль", text: $password)
                .textContentType(.newPassword).focused($focus, equals: .password).onSubmit { focus = .confirm }
            SecureField("Повторите пароль", text: $confirm)
                .textContentType(.newPassword).focused($focus, equals: .confirm).onSubmit(submit)
            Text(Validation.passwordRules).font(.caption).foregroundStyle(.secondary)
        case .confirm(let e):
            Text(e).font(.headline)
            codeField
        case .forgot:
            emailField
        case .reset(let e):
            Text(e).font(.headline)
            codeField
            SecureField("Новый пароль", text: $password)
                .textContentType(.newPassword).focused($focus, equals: .password).onSubmit { focus = .confirm }
            SecureField("Повторите пароль", text: $confirm)
                .textContentType(.newPassword).focused($focus, equals: .confirm).onSubmit(submit)
            Text(Validation.passwordRules).font(.caption).foregroundStyle(.secondary)
        case .newPassword:
            SecureField("Новый пароль", text: $password)
                .textContentType(.newPassword).focused($focus, equals: .password).onSubmit { focus = .confirm }
            SecureField("Повторите пароль", text: $confirm)
                .textContentType(.newPassword).focused($focus, equals: .confirm).onSubmit(submit)
            Text(Validation.passwordRules).font(.caption).foregroundStyle(.secondary)
        case .local:
            EmptyView()
        }
    }

    private var emailField: some View {
        TextField("Электронная почта", text: $email)
            .textContentType(.username)
            .focused($focus, equals: .email)
            .onSubmit { if session.stage == .forgot { submit() } else { focus = .password } }
    }

    private var codeField: some View {
        TextField("Код из письма", text: $code)
            .textContentType(.oneTimeCode)
            .font(.system(.title3, design: .monospaced))
            .multilineTextAlignment(.center)
            .focused($focus, equals: .code)
            .onSubmit { if case .reset = session.stage { focus = .password } else { submit() } }
    }

    @ViewBuilder private var links: some View {
        switch session.stage {
        case .signIn:
            Button("Создать учётную запись") { go(.signUp) }
            Button("Забыли пароль?") { go(.forgot) }
            if session.hasUsers {
                Button("Войти в локальную учётную запись") { go(.local) }
            } else {
                Button("Работать без облака, только на этом Mac") { go(.local) }
            }
        case .signUp:
            Button("У меня уже есть учётная запись") { go(.signIn) }
        case .confirm(let e):
            Button("Отправить письмо ещё раз") { session.resendConfirmation(email: e) }.disabled(session.busy)
            Button("Назад ко входу") { go(.signIn) }
        case .forgot:
            Button("Назад ко входу") { go(.signIn) }
        case .reset(let e):
            Button("Отправить письмо ещё раз") { session.requestReset(email: e) }.disabled(session.busy)
            Button("Назад ко входу") { go(.signIn) }
        case .newPassword:
            Button("Отмена") { session.logout() }
        case .local:
            EmptyView()
        }
    }

    private var primaryTitle: String {
        switch session.stage {
        case .signIn: return "Войти"
        case .signUp: return "Зарегистрироваться"
        case .confirm: return "Подтвердить"
        case .forgot: return "Отправить код"
        case .reset, .newPassword: return "Сохранить пароль"
        case .local: return ""
        }
    }

    private var canSubmit: Bool {
        let hasEmail = !email.trimmingCharacters(in: .whitespaces).isEmpty
        switch session.stage {
        case .signIn: return hasEmail && !password.isEmpty
        case .signUp: return hasEmail && !password.isEmpty && !confirm.isEmpty
        case .confirm: return Validation.code(code) != nil
        case .forgot: return hasEmail
        case .reset: return Validation.code(code) != nil && !password.isEmpty && !confirm.isEmpty
        case .newPassword: return !password.isEmpty && !confirm.isEmpty
        case .local: return false
        }
    }

    private func go(_ stage: AuthStage) {
        session.error = nil
        session.info = nil
        session.stage = stage
    }

    private func submit() {
        guard canSubmit, !session.busy else { return }
        switch session.stage {
        case .signIn: session.cloudSignIn(email: email, password: password)
        case .signUp: session.cloudSignUp(email: email, password: password, confirm: confirm)
        case .confirm(let e): session.confirmSignUp(email: e, code: code)
        case .forgot: session.requestReset(email: email)
        case .reset(let e): session.finishReset(email: e, code: code, password: password, confirm: confirm)
        case .newPassword: session.setPasswordAfterRecovery(password, confirm: confirm)
        case .local: break
        }
    }
}

// MARK: Локальная учётная запись

private struct LocalAuthForm: View {
    @Environment(\.session) private var session
    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    enum Field { case username, password, confirm }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                TextField("Имя пользователя", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { if registering { focus = .confirm } else { submit() } }
                if registering {
                    SecureField("Повторите пароль", text: $confirm)
                        .focused($focus, equals: .confirm)
                        .onSubmit(submit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .frame(width: 300)

            Toggle("Запомнить вход на этом Mac", isOn: $remember)
                .toggleStyle(.checkbox)

            if let e = session.error {
                Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(width: 320)
            }

            Button(action: submit) {
                Text(registering ? "Зарегистрироваться" : "Войти")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 280)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)

            Button(registering ? "У меня уже есть учётная запись" : "Создать учётную запись") {
                registering.toggle()
                session.error = nil
                confirm = ""
            }
            .buttonStyle(.link)

            if session.cloudAvailable {
                Button("Войти по электронной почте (с облаком)") {
                    session.error = nil
                    session.stage = .signIn
                }
                .buttonStyle(.link)
            }

            VStack(spacing: 4) {
                if registering && !session.hasUsers && session.legacyDatabase != nil {
                    Text("Лиды из прежней версии будут перенесены в эту учётную запись.")
                }
                Text("Локальные учётные записи и базы хранятся только на этом Mac. Пароль хранится в виде хэша PBKDF2.")
            }
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 340)
        }
        .onAppear {
            registering = !session.hasUsers
            focus = .username
        }
    }

    private func submit() {
        guard !username.isEmpty, !password.isEmpty else { return }
        if registering {
            session.register(username: username, password: password, confirm: confirm, remember: remember)
        } else {
            session.login(username: username, password: password, remember: remember)
        }
        if session.current != nil { password = ""; confirm = "" }
    }
}
