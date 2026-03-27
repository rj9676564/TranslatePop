import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class PopupViewModel: ObservableObject {
    @Published var state: PopupContentState = .idle
    @Published var isHovering = false
}

@MainActor
final class PopupPresenter: NSObject, PopupPresenting {
    private let logger = Logger(subsystem: "top.mrlb.TranslatePop", category: "Popup")
    private let panelSize = CGSize(width: 420, height: 320)
    private let viewModel = PopupViewModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func presentLoading(for selection: CapturedSelection) {
        logger.info("展示加载态弹窗，method=\(selection.method.rawValue, privacy: .public)")
        viewModel.state = .loading(originalText: selection.text, method: selection.method)
        showPanel(anchor: selection.anchorPoint)
        scheduleDismiss(after: 8)
    }

    func presentResult(selection: CapturedSelection, result: TranslationResult) {
        logger.info("展示成功态弹窗，provider=\(result.providerName, privacy: .public)")
        viewModel.state = .result(selection, result)
        showPanel(anchor: selection.anchorPoint)
        scheduleDismiss(after: 12)
    }

    func presentError(message: String, originalText: String?, method: CaptureMethod?, anchor: CGPoint) {
        logger.error("展示失败态弹窗，message=\(message, privacy: .public)")
        viewModel.state = .error(message: message, originalText: originalText, method: method)
        showPanel(anchor: anchor)
        dismissTask?.cancel()
        dismissTask = nil
    }

    func dismiss() {
        logger.info("手动关闭弹窗")
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func showPanel(anchor: CGPoint) {
        let panel = self.panel ?? makePanel()
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelFrame = PopupPositioner.frame(
            for: anchor,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        logger.info("弹窗已显示，x=\(panelFrame.origin.x, format: .fixed(precision: 0)) y=\(panelFrame.origin.y, format: .fixed(precision: 0))")
    }

    private func makePanel() -> NSPanel {
        let contentView = PopupCardView(viewModel: viewModel) { [weak self] hovering in
            self?.viewModel.isHovering = hovering
        } onClose: { [weak self] in
            self?.dismiss()
        }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: contentView)
        self.panel = panel
        return panel
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if !self.viewModel.isHovering {
                self.logger.info("自动关闭弹窗，after=\(seconds, format: .fixed(precision: 1))s")
                self.panel?.orderOut(nil)
            }
        }
    }
}

private struct PopupCardView: View {
    @ObservedObject var viewModel: PopupViewModel
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let originalText {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("原文")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(originalText)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    switch viewModel.state {
                    case .idle:
                        EmptyView()
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在翻译...")
                                .foregroundStyle(.secondary)
                        }
                    case .result(_, let result):
                        VStack(alignment: .leading, spacing: 6) {
                            Text("翻译")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(result.translatedText)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("来源：\(sourceLabel) · 接口：\(result.providerName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .error(let message, _, _):
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    private var title: String {
        switch viewModel.state {
        case .loading(_, let method):
            return "取词中 · \(method.rawValue)"
        case .result(let selection, _):
            return "翻译完成 · \(selection.method.rawValue)"
        case .error:
            return "翻译失败"
        case .idle:
            return "TranslatePop"
        }
    }

    private var originalText: String? {
        switch viewModel.state {
        case .loading(let text, _):
            return text
        case .result(let selection, _):
            return selection.text
        case .error(_, let text, _):
            return text
        case .idle:
            return nil
        }
    }

    private var sourceLabel: String {
        switch viewModel.state {
        case .loading(_, let method):
            return method.rawValue
        case .result(let selection, _):
            return selection.method.rawValue
        case .error(_, _, let method):
            return method?.rawValue ?? "未知"
        case .idle:
            return "未知"
        }
    }
}
