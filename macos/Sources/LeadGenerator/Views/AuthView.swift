import AppKit
import LeadGenCore
import SwiftUI

/// Вход и регистрация. Учётные записи хранятся на этом Mac.
struct AuthView: View {
    @Environment(SessionModel.self) private var session
    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    enum Field { case username, password, confirm }

    var body: some View {
        @Bindable var session = session
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 84, height: 84)
                    Text("Lead Generator").font(.system(size: 26, weight: .bold))
                    Text(registering ? "Создайте учётную запись" : "Войдите, чтобы продолжить")
                        .foregroundStyle(.secondary)
                }
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

                VStack(spacing: 4) {
                    if registering && !session.hasUsers && session.legacyDatabase != nil {
                        Text("Лиды из прежней версии будут перенесены в эту учётную запись.")
                    }
                    Text("Учётные записи и базы хранятся только на этом Mac. Пароль хранится в виде хэша PBKDF2.")
                }
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 340)
            }
            .padding(40)
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
