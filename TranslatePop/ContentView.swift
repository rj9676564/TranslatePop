import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TranslatePop")
                .font(.title3.weight(.semibold))
            Label(coordinator.permissionState.summaryText, systemImage: coordinator.menuBarIconName)
                .foregroundStyle(.secondary)
            Text(coordinator.latestStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("启用全局监听", isOn: Binding(
                get: { coordinator.isMonitoring },
                set: { _ in coordinator.toggleMonitoring() }
            ))

            SettingsLink {
                Text("打开设置")
            }

            Button("刷新权限状态") {
                coordinator.refreshPermissions()
            }

            Divider()

            Text("提示：双击单词或按住拖选句子后，会在鼠标附近弹出翻译卡片。首次使用请先在设置中完成权限授权。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("接口配置") {
                Picker("供应商类型", selection: Binding(
                    get: { coordinator.settingsStore.providerConfiguration.providerKind },
                    set: { coordinator.settingsStore.providerConfiguration.applySuggestedTemplate(for: $0) }
                )) {
                    ForEach(TranslationProviderKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                TextField("Provider 名称", text: providerBinding(\.providerName))
                TextField("Base URL", text: providerBinding(\.baseURL))
                SecureField("API Key", text: providerBinding(\.apiKey))
                TextField("Model（可选）", text: providerBinding(\.model))
                HStack {
                    Text("超时")
                    Slider(value: timeoutBinding, in: 5...60, step: 1)
                    Text("\(Int(coordinator.settingsStore.providerConfiguration.timeoutSeconds))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                }
                TextEditor(text: providerBinding(\.customHeaders))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                Text("自定义请求头一行一个，格式为 `Header-Name: Value`")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("留空 Model 时会按供应商自动补默认值：Zhipu 使用 glm-5。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("权限与回退") {
                Text("TranslatePop 只在你双击取词或拖选文本时工作，不会持续读取你的屏幕内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                permissionRow(
                    title: "辅助功能",
                    description: "用于读取其他软件当前真正选中的文本，并支持双击取词与拖选翻译。这是自动取词的必需权限。",
                    granted: coordinator.permissionState.accessibilityGranted,
                    requestAction: coordinator.requestAccessibilityPermission,
                    settingsAction: coordinator.openAccessibilitySettings
                )
                permissionRow(
                    title: "屏幕录制 / OCR",
                    description: "用于后续 OCR 能力扩展，当前版本不会在自动取词中使用这项权限。",
                    granted: coordinator.permissionState.screenCaptureLikelyGranted,
                    requestAction: coordinator.requestScreenCapturePermission,
                    settingsAction: coordinator.openScreenCaptureSettings
                )
                Text("建议先完成辅助功能授权，保证自动取词体验；屏幕录制权限可以暂时不启用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("调试") {
                Button(isTesting ? "测试中..." : "测试翻译接口连通性") {
                    isTesting = true
                    Task {
                        await coordinator.testTranslationConnection()
                        isTesting = false
                    }
                }
                .disabled(isTesting)

                Button("保存配置") {
                    coordinator.saveSettings()
                }

                Text(coordinator.latestStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear {
            coordinator.refreshPermissions()
        }
    }

    private func providerBinding(_ keyPath: WritableKeyPath<ProviderConfiguration, String>) -> Binding<String> {
        Binding(
            get: { coordinator.settingsStore.providerConfiguration[keyPath: keyPath] },
            set: { coordinator.settingsStore.providerConfiguration[keyPath: keyPath] = $0 }
        )
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { coordinator.settingsStore.providerConfiguration.timeoutSeconds },
            set: { coordinator.settingsStore.providerConfiguration.timeoutSeconds = $0 }
        )
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Spacer()
                Button("请求授权", action: requestAction)
                Button("打开设置", action: settingsAction)
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
