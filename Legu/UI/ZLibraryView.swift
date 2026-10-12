import SwiftUI

/// Z-Library 账号与域名设置(凭据仅存本机,不入代码/仓库)
struct ZLibraryView: View {
    @ObservedObject private var session = ZLibSession.shared
    @State private var email = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        List {
            Section {
                if session.isLoggedIn {
                    LabeledContent("账号", value: session.savedEmail)
                    if !session.userName.isEmpty {
                        LabeledContent("昵称", value: session.userName)
                    }
                    LabeledContent("今日下载", value: "\(session.downloadsToday)/\(session.downloadsLimit)")
                    LabeledContent("当前域名", value: session.domain)
                    Button(role: .destructive) {
                        session.logout()
                        message = "已退出登录"
                        messageIsError = false
                    } label: {
                        Text("退出登录")
                    }
                } else {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    TextField("域名(默认 z-lib.sk)", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await doLogin() }
                    } label: {
                        HStack {
                            Text("登录")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(messageIsError ? .red : .secondary)
                }
            } header: {
                Text("账号")
            } footer: {
                Text("凭据只保存在这台手机上(App 本地文件),不会上传到除 Z-Library 登录之外的任何地方。\nz-lib.sk 连不上时会自动尝试其他官方域名(z-lib.gd / z-lib.gl / article.sk 等)。")
            }

            Section {
                LabeledContent("下载额度", value: "免费账号每天约 \(session.downloadsLimit) 本")
                Text("搜索到的书需要点「下载并阅读」:整本下载(通常几 MB)后自动解析进书架,之后完全离线 —— 阅读、排版、听书与现有书一致,可在「下载管理」里查看占用和删除。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("Z-Library")
        .onAppear {
            if email.isEmpty { email = session.savedEmail }
            if password.isEmpty { password = session.savedPassword }
            if domain.isEmpty { domain = session.preferredDomain }
            Task { await session.refreshProfile() }
        }
    }

    private func doLogin() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await session.login(email: email, password: password, preferredDomain: domain)
            message = "登录成功(域名 \(session.domain))"
            messageIsError = false
        } catch {
            message = "登录失败:\(error.localizedDescription)"
            messageIsError = true
        }
    }
}
