import SwiftUI
@preconcurrency import Translation

struct BridgeView: View {
    @Bindable var model: BridgeModel
    @State private var copiedEndpoint: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    BrandIconView()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地翻译桥").font(.largeTitle.weight(.semibold))
                        Text("为沉浸式翻译提供 Mac 本地翻译服务。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                serviceSection
                setupSection

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("关闭窗口后服务继续运行。通过「窗口 → 打开翻译窗口」或 ⌘0 恢复窗口；退出 App 会停止服务。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Toggle("登录时打开本地翻译桥", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.checkbox)
                        Spacer()
                        Link("使用帮助", destination: URL(string: "https://malu.moe/apple-translation-bridge/")!)
                        Link("隐私政策", destination: URL(string: "https://malu.moe/apple-translation-bridge/privacy.html")!)
                    }
                    .font(.caption)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 740, minHeight: 620)
        .onChange(of: model.endpoint) { copiedEndpoint = nil }
        .task { await model.initialize() }
        .translationTask(model.downloadConfiguration) { session in
            await model.installLanguages(using: session)
        }
    }

    private var serviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("启动接口服务", systemImage: "network")
                            .font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.serviceRunning ? .green : .secondary)
                                .frame(width: 7, height: 7)
                            Text(model.serviceRunning ? "运行中 · 可以连接沉浸式翻译" : model.serviceStarting ? "正在启动…" : "尚未启动")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Spacer()
                    if model.serviceRunning {
                        Button("停止服务") { model.stopService() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    } else {
                        Button(model.serviceStarting ? "正在启动…" : "启动接口服务") { model.startService() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.languageReady || model.serviceStarting)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: model.languageReady ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(model.languageReady ? .green : .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.languageStatus).font(.callout.weight(.medium))
                        Text(model.languageReady ? "Apple 在本机完成翻译，语言包可离线使用。" : "首次使用先下载英文和简体中文语言包。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.checking || model.downloading { ProgressView().controlSize(.small) }
                    if !model.languageReady {
                        Button(model.downloading ? "正在下载…" : "下载语言包") { model.requestDownload() }
                            .disabled(model.downloading)
                    }
                    Button { Task { await model.refreshLanguages() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.checking || model.downloading)
                    .help("重新检查语言包")
                    .accessibilityLabel("重新检查语言包")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("沉浸式翻译接口地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Text(model.endpoint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        Button(copiedEndpoint == model.endpoint ? "已复制" : "复制接口地址") {
                            model.copy(model.endpoint)
                            copiedEndpoint = model.endpoint
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.serviceRunning)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    Text("端口").foregroundStyle(.secondary)
                    TextField("3210", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(model.serviceRunning || model.serviceStarting)
                        .accessibilityLabel("接口端口")
                    Text("仅供本机使用 · 无需 API Key")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.requestCount > 0 {
                        Text("已处理 \(model.translatedRows) 段文本")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .padding(12)
        }
    }

    private var setupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("配置沉浸式翻译", systemImage: "puzzlepiece.extension")
                    .font(.title2.weight(.semibold))
                setupStep(1, title: "开启自定义接口", detail: "打开浏览器扩展的「设置 → 开发者设置」，启用 Beta 特性。")
                setupStep(2, title: "粘贴接口地址", detail: "进入「翻译服务」，选择「自定义接口」，填入上面的接口地址。")
                setupStep(3, title: "测试并开始翻译", detail: "在扩展中测试服务，将翻译服务设为「自定义接口」、目标语言设为简体中文，再翻译英文网页。")
                Link("查看沉浸式翻译官方配置说明", destination: URL(string: "https://immersivetranslate.com/zh-Hans/docs/services/custom/")!)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func setupStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
