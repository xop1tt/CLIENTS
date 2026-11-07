import AppKit
import LeadGenCore
import SwiftUI

struct LeadInspector: View {
    @Environment(\.appModel) private var model
    @Environment(\.look) private var look
    @Environment(\.openSettings) private var openSettings
    let lead: LeadItem

    @State private var tab = 0
    @State private var note = ""
    @State private var recipient = ""
    @State private var subject = ""
    @State private var draft = ""
    @State private var mail: MailController?
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 14)
            Picker("", selection: $tab) {
                Text("Обзор").tag(0)
                Text("Написать").tag(1)
                Text("История").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18 * look.scale) {
                    switch tab {
                    case 0: overview
                    case 1: outreach
                    default: history
                    }
                }
                .scaledPadding(.all, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: load)
        .onChange(of: lead.id) { _, _ in load() }
    }

    private func load() {
        note = lead.note
        resetDraft()
        recipient = lead.data.emails.first ?? ""
        sendError = nil
        if mail?.user != model.username.lowercased() { mail = MailController(user: model.username, inert: model.isInert) }
    }

    private func resetDraft() {
        let d = DraftWriter.email(for: lead.data, signature: model.signature)
        subject = d.subject
        draft = d.body
    }

    // MARK: Заголовок

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(lead.data.title.first(where: { $0.isLetter }) ?? "•").uppercased())
                .appFont(15, .semibold)
                .frame(width: 38 * look.scale, height: 38 * look.scale)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(lead.data.title).appFont(15, .semibold).lineLimit(3).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(lead.data.kind.title)
                    Text("·")
                    Text(SourceCatalog.title(lead.data.source))
                    if let r = lead.data.region, !r.isEmpty { Text("·"); Text(r) }
                }
                .appFont(12).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.toggleFavorite([lead.id]) } label: {
                Image(systemName: lead.favorite ? "star.fill" : "star").foregroundStyle(lead.favorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(lead.favorite ? "Убрать из избранного" : "В избранное")
            Menu {
                if let url = URL(string: lead.data.url), !lead.data.url.isEmpty { Button("Открыть оригинал") { NSWorkspace.shared.open(url) } }
                Button(lead.archived ? "Вернуть из архива" : "В архив") { model.setArchived([lead.id], !lead.archived) }
                Divider()
                if let d = lead.data.domain { Button("Исключить домен \(d)") { model.exclude(.domain, d) } }
                ForEach(lead.data.phones, id: \.self) { p in Button("Исключить телефон \(p)") { model.exclude(.phone, p) } }
                Button("Исключить по названию") { model.exclude(.name, lead.data.title) }
                Divider()
                Button("Удалить", role: .destructive) { model.delete([lead.id]) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Обзор

    @ViewBuilder private var overview: some View {
        scoreBox
        if !lead.data.scoreReasons.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                PanelHeader(title: "Почему такая оценка")
                ForEach(lead.data.scoreReasons, id: \.self) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: r.contains("(-") || r.contains("ниже") || r.contains("похоже") ? "minus.circle" : "plus.circle")
                            .foregroundStyle(r.contains("(-") || r.contains("ниже") || r.contains("похоже") ? Color.red : Color.green)
                        Text(r).appFont(12.5).textSelection(.enabled)
                    }
                }
            }
        }
        if !lead.data.facts.isEmpty || !lead.data.assumptions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                PanelHeader(title: "Факты и предположения")
                ForEach(lead.data.facts, id: \.self) { f in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(f).appFont(12.5).textSelection(.enabled)
                    }
                }
                ForEach(lead.data.assumptions, id: \.self) { a in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                        Text(a).appFont(12.5).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text("Зелёное — проверено, жёлтое — предположение системы.").appFont(11).foregroundStyle(.tertiary)
            }
        }
        contacts
        if !lead.data.description.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                PanelHeader(title: "Описание")
                Text(lead.data.description).appFont(12.5).textSelection(.enabled).lineLimit(14)
            }
        }
        if !lead.data.externalResults.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                PanelHeader(title: "Анализаторы", trailing: "хранятся отдельно")
                analyzerRow("Правила", score: lead.data.score, label: nil, ok: true)
                ForEach(lead.data.externalResults, id: \.self) { r in
                    analyzerRow(r.service, score: r.score, label: r.label ?? r.error, ok: r.ok)
                }
            }
        }
        VStack(alignment: .leading, spacing: 7) {
            PanelHeader(title: "Заметка")
            TextEditor(text: $note)
                .appFont(12.5)
                .frame(minHeight: 70 * look.scale)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                .onChange(of: note) { _, new in
                    if new != lead.note { model.setNote(lead.id, new) }
                }
        }
    }

    private var scoreBox: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                Circle().trim(from: 0, to: min(lead.data.score, 100) / 100)
                    .stroke(Palette.scoreColor(lead.data.score), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(lead.data.score.rounded()))").appFont(18, .semibold).monospacedDigit()
            }
            .frame(width: 56 * look.scale, height: 56 * look.scale)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(lead.data.relevance.title) перспективность").appFont(13, .semibold)
                Text("Оценка системы по правилам, а не факт.").appFont(11.5).foregroundStyle(.secondary)
                Text("Найден \(lead.discoveredAt.fullRu)").appFont(11.5).foregroundStyle(.secondary)
            }
        }
        .scaledPadding(.all, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder private var contacts: some View {
        let d = lead.data
        let rows: [(String, String, String)] = {
            var r: [(String, String, String)] = []
            for p in d.phones { r.append(("phone", "Телефон", p)) }
            for e in d.emails { r.append(("envelope", "Email", e)) }
            if let w = d.website, !w.isEmpty { r.append(("globe", "Сайт", w)) }
            if let a = d.address, !a.isEmpty { r.append(("mappin.and.ellipse", "Адрес", a)) }
            for (k, v) in d.contacts.sorted(by: { $0.key < $1.key }) where !d.emails.contains(v) && !d.phones.contains(v) {
                r.append(("person.crop.circle", k, v))
            }
            if let b = d.budget { r.append(("rublesign.circle", "Бюджет", "\(Int(b).formatted()) \(d.currency ?? "")")) }
            if let c = d.category ?? d.projectType { r.append(("tag", "Категория", c)) }
            return r
        }()
        VStack(alignment: .leading, spacing: 7) {
            PanelHeader(title: "Контакты и данные")
            if rows.isEmpty {
                Text("Контакты не найдены").appFont(12.5).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.0).foregroundStyle(.secondary).frame(width: 16)
                    Text(row.1).appFont(12.5).foregroundStyle(.secondary).frame(width: 80 * look.scale, alignment: .leading)
                    if row.0 == "globe", let url = URL(string: row.2.hasPrefix("http") ? row.2 : "https://" + row.2) {
                        Link(row.2, destination: url).appFont(12.5)
                    } else {
                        Text(row.2).appFont(12.5).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if row.0 == "phone", ContactLinks.telURL(row.2) != nil {
                        Button { call(row.2) } label: { Image(systemName: "phone.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.green).help("Позвонить через FaceTime или iPhone")
                            .accessibilityLabel("Позвонить \(row.2)")
                    }
                    if row.0 == "envelope", ContactLinks.isEmail(row.2) {
                        Button { write(to: row.2) } label: { Image(systemName: "envelope.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tint).help("Написать письмо")
                            .accessibilityLabel("Написать на \(row.2)")
                    }
                    Button { copy(row.2) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Скопировать")
                }
            }
            if let url = URL(string: d.url), !d.url.isEmpty {
                Link(destination: url) { Label("Открыть оригинал", systemImage: "arrow.up.right.square") }.appFont(12.5)
            }
        }
    }

    private func analyzerRow(_ name: String, score: Double?, label: String?, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "cpu" : "exclamationmark.triangle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).appFont(12.5)
                if let label { Text(label).appFont(11).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if let score { Text("\(Int(score.rounded()))").appFont(12.5, .semibold).foregroundStyle(Palette.scoreColor(score)) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    // MARK: Написать

    private var outgoing: OutgoingMail {
        OutgoingMail(to: recipient.trimmingCharacters(in: .whitespaces), subject: subject, body: draft)
    }

    @ViewBuilder private var outreach: some View {
        let smtp = mail?.smtpReady == true
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Email")
            HStack(spacing: 6) {
                Text("Кому").appFont(12.5).foregroundStyle(.secondary).frame(width: 46 * look.scale, alignment: .leading)
                TextField("", text: $recipient, prompt: Text("адрес получателя"))
                    .labelsHidden().accessibilityLabel("Кому").inputField()
                if lead.data.emails.count > 1 {
                    Menu {
                        ForEach(lead.data.emails, id: \.self) { e in Button(e) { recipient = e } }
                    } label: { Image(systemName: "chevron.down.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Другие адреса лида")
                }
            }
            HStack(spacing: 6) {
                Text("Тема").appFont(12.5).foregroundStyle(.secondary).frame(width: 46 * look.scale, alignment: .leading)
                TextField("", text: $subject, prompt: Text("тема письма"))
                    .labelsHidden().accessibilityLabel("Тема").inputField()
            }
            if lead.data.emails.isEmpty {
                Label("У лида нет email: впишите адрес вручную", systemImage: "info.circle").appFont(11.5).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft)
                .appFont(13)
                .frame(minHeight: 220 * look.scale)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                if smtp {
                    Button { sendNow() } label: { Label("Отправить", systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ContactLinks.isEmail(recipient) || mail?.sending == true)
                    if mail?.sending == true { ProgressView().controlSize(.small) }
                    Button { openInMail() } label: { Label("В Почте", systemImage: "envelope") }
                        .disabled(!ContactLinks.isEmail(recipient))
                        .help("Открыть письмо в программе «Почта»")
                } else {
                    Button { openInMail() } label: { Label("Открыть в Почте", systemImage: "envelope") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ContactLinks.isEmail(recipient))
                }
                Spacer()
                Button { copy((subject.isEmpty ? "" : "Тема: \(subject)\n\n") + draft); model.lastMessage = "Письмо скопировано" } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Копировать")
                Button { resetDraft() } label: { Image(systemName: "arrow.counterclockwise") }.help("Вернуть черновик")
            }
            if let sendError { Label(sendError, systemImage: "exclamationmark.triangle.fill").appFont(11.5).foregroundStyle(.red) }
            if smtp, let a = mail?.account {
                Text("Отправка с \(a.fromAddress) прямо из приложения\(a.copyToSelf ? ", копия — вам в ящик" : ""). Письмо попадёт в «Историю» лида.")
                    .appFont(11).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Письмо откроется в «Почте». Чтобы отправлять прямо отсюда, подключите почту.").appFont(11).foregroundStyle(.secondary)
                    Button("Настроить") {
                        UserDefaults.standard.set(SettingsSection.outreach.rawValue, forKey: "settings.section")
                        openSettings()
                    }
                    .buttonStyle(.link).appFont(11)
                }
            }
            Text("Черновик собран по шаблону из фактов о лиде. Письма уходят по одному, по вашей кнопке: массовой рассылки нет. Подпись задаётся в настройках.")
                .appFont(11).foregroundStyle(.secondary)
        }
    }

    private func write(to address: String) {
        recipient = address
        tab = 1
    }

    private func call(_ phone: String) {
        guard let url = ContactLinks.telURL(phone) else { return }
        if NSWorkspace.shared.open(url) { model.logEvent(lead.id, "Звонок: \(phone)") }
    }

    private func sendNow() {
        guard let mail else { return }
        let m = outgoing
        sendError = nil
        Task {
            if await mail.send(m) {
                model.logEvent(lead.id, "Письмо отправлено на \(m.to)" + (m.subject.isEmpty ? "" : ": «\(m.subject)»"))
                model.lastMessage = "Письмо отправлено на \(m.to)"
            } else {
                sendError = mail.lastError
            }
        }
    }

    private func openInMail() {
        let m = outgoing
        if MailController.openInMailApp(m) {
            model.logEvent(lead.id, "Письмо подготовлено в «Почте» для \(m.to)")
        } else {
            sendError = "Не удалось открыть почтовую программу"
        }
    }

    // MARK: История

    @ViewBuilder private var history: some View {
        let events = model.events(lead.id)
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "История изменений")
            if events.isEmpty { Text("Событий пока нет").appFont(12.5).foregroundStyle(.secondary) }
            ForEach(events) { e in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(.tint).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.action).appFont(12.5)
                        if let at = e.at { Text(at.fullRu).appFont(11).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
