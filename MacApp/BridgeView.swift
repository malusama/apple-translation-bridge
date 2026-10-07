import SwiftUI
@preconcurrency import Translation

struct BridgeView: View {
    @Bindable var model: BridgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    BrandIconView()
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本地翻译桥").font(.largeTitle.weight(.semibold))
                        Text("英文译中文，在你的 Mac 上完成。").foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                GroupBox {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.languageReady ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.title2).foregroundStyle(model.languageReady ? .green : .blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.languageStatus).font(.headline)
                            Text("首次使用需要下载 Apple 语言包。下载后，翻译可离线使用。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.checking || model.downloading { ProgressView().controlSize(.small) }
                        if !model.languageReady {
                            Button(model.downloading ? "正在下载…" : "下载语言包") { model.requestDownload() }
                                .disabled(model.downloading).buttonStyle(.borderedProminent)
                        }
                        Button("重新检查") { Task { await model.refreshLanguages() } }
                            .disabled(model.checking || model.downloading)
                    }.padding(8)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("翻译文本").font(.title2.weight(.semibold))
                        Spacer()
                        if let elapsed = model.lastElapsed { Text("\(elapsed) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("英文").font(.headline)
                            TextEditor(text: $model.sourceText)
                                .font(.body).scrollContentBackground(.hidden)
                                .padding(8).frame(minHeight: 155)
                                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                                .accessibilityLabel("英文原文")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("简体中文").font(.headline)
                                Spacer()
                                Button { model.copy(model.translatedText) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless).disabled(model.translatedText.isEmpty).help("复制译文")
                            }
                            ScrollView {
                                Text(model.translatedText.isEmpty ? "译文会显示在这里" : model.translatedText)
                                    .foregroundStyle(model.translatedText.isEmpty ? .secondary : .primary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                            }.frame(minHeight: 171, maxHeight: 171)
                                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                                .accessibilityLabel("中文译文")
                        }
                    }
                    HStack {
                        Text("文本留在本机，不保存翻译历史。").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if model.translating { ProgressView().controlSize(.small) }
                        Button(model.translating ? "正在翻译…" : "翻译成中文") { Task { await model.translate() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.languageReady || model.translating || model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("本地翻译接口", systemImage: "network").font(.title2.weight(.semibold))
                        Spacer()
                        Circle().fill(model.serviceRunning ? .green : .secondary).frame(width: 8, height: 8)
                        Text(model.serviceRunning ? "运行中" : model.serviceStarting ? "正在启动…" : "已停止")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("端口")
                        TextField("3210", text: $model.portText).textFieldStyle(.roundedBorder).frame(width: 85)
                            .disabled(model.serviceRunning || model.serviceStarting).accessibilityLabel("接口端口")
                        Button(model.serviceRunning ? "停止接口" : "启动接口") {
                            if model.serviceRunning { model.stopService() } else { model.startService() }
                        }.disabled(!model.languageReady || model.serviceStarting)
                        Spacer()
                        if model.requestCount > 0 { Text("已处理 \(model.translatedRows) 段文本").foregroundStyle(.secondary).font(.callout) }
                    }
                    HStack {
                        Text(model.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("复制地址") { model.copy(model.endpoint) }.disabled(!model.serviceRunning)
                    }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    Text("沉浸式翻译 → 设置 → 翻译服务 → 自定义接口：粘贴上面的地址。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("接口仅接受这台 Mac 上的连接。关闭窗口后可从菜单栏打开；退出 App 会停止接口。")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("登录时打开本地翻译桥", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.checkbox)
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 18) {
                    Link("使用帮助", destination: URL(string: "https://malu.moe/apple-translation-bridge/")!)
                    Link("隐私政策", destination: URL(string: "https://malu.moe/apple-translation-bridge/privacy.html")!)
                    Spacer()
                    Text("1.0 · Apple Translation").foregroundStyle(.tertiary)
                }.font(.caption)
            }.padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 780, minHeight: 750)
        .task { await model.initialize() }
        .translationTask(model.downloadConfiguration) { session in
            await model.installLanguages(using: session)
        }
    }
}
