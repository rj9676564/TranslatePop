import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class PopupViewModel: ObservableObject {
    @Published var state: PopupContentState = .idle
    @Published var isHovering = false
    @Published var allowsScrolling = false
}

@MainActor
final class PopupPresenter: NSObject, PopupPresenting {
    private let logger = Logger(subsystem: "top.mrlb.TranslatePop", category: "Popup")
    private let panelWidth: CGFloat = 520
    private let minPanelHeight: CGFloat = 280
    private let maxPanelHeight: CGFloat = 620
    private let viewModel = PopupViewModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var activeAnchor: CGPoint?
    private var activeTopOrigin: CGPoint?

    func presentPending(at anchor: CGPoint) {
        logger.info("展示预加载弹窗")
        viewModel.state = .pending
        showPanel(anchor: anchor)
        scheduleDismiss(after: 8)
    }

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
        activeAnchor = nil
        activeTopOrigin = nil
        panel?.orderOut(nil)
    }

    private func showPanel(anchor: CGPoint) {
        let panel = self.panel ?? makePanel()
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = preferredPanelLayout()
        logger.info("size \(layout.height)");
        let preserveVisibleFrame = shouldPreserveVisibleFrame(for: panel, anchor: anchor)
        viewModel.allowsScrolling = preserveVisibleFrame ? true : layout.allowsScrolling
        let panelFrame: CGRect
        if preserveVisibleFrame {
            let currentFrame = panel.frame
            let topY = currentFrame.maxY
            panelFrame = CGRect(
                x: currentFrame.origin.x,
                y: topY - layout.height,
                width: panelWidth,
                height: layout.height
            )
        } else {
            panelFrame = preferredFrame(
                for: panel,
                anchor: anchor,
                visibleFrame: visibleFrame,
                height: layout.height
            )
        }
        panel.ignoresMouseEvents = shouldIgnoreMouseEvents
        if shouldIgnoreMouseEvents {
            viewModel.isHovering = false
        }
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        activeAnchor = anchor
        logger.info("弹窗已显示，x=\(panelFrame.origin.x, format: .fixed(precision: 0)) y=\(panelFrame.origin.y, format: .fixed(precision: 0))")
    }

    private func makePanel() -> NSPanel {
        let contentView = PopupCardView(viewModel: viewModel) { [weak self] hovering in
            self?.viewModel.isHovering = hovering
        } onClose: { [weak self] in
            self?.dismiss()
        }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: panelWidth, height: minPanelHeight)),
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
        panel.ignoresMouseEvents = true
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
                self.activeAnchor = nil
                self.activeTopOrigin = nil
                self.panel?.orderOut(nil)
            }
        }
    }

    private var shouldIgnoreMouseEvents: Bool {
        switch viewModel.state {
        case .error:
            return false
        case .idle, .pending, .loading, .result:
            return true
        }
    }

    private func preferredPanelLayout() -> (height: CGFloat, allowsScrolling: Bool) {
        let contentWidth = panelWidth - 32
        let textWidth = contentWidth - 4
        var totalHeight: CGFloat = 32
        totalHeight += 28

        if let originalText = currentOriginalText, !originalText.isEmpty {
            totalHeight += 22
            totalHeight += measuredHeight(
                for: formatted(originalText),
                width: textWidth,
                font: .systemFont(ofSize: 17, weight: .regular)
            )
            totalHeight += 12
        }

        switch viewModel.state {
        case .idle:
            break
        case .pending:
            totalHeight += 24
        case .loading:
            totalHeight += 24
        case .result(_, let result):
            totalHeight += 22
            totalHeight += measuredHeight(
                for: formatted(result.translatedText),
                width: textWidth,
                font: .systemFont(ofSize: 26, weight: .semibold)
            )
            totalHeight += 26
        case .error(let message, _, _):
            totalHeight += measuredHeight(
                for: formatted(message),
                width: textWidth,
                font: .systemFont(ofSize: 17, weight: .regular)
            )
        }

        totalHeight += 24
        let clampedHeight = min(max(totalHeight, minPanelHeight), maxPanelHeight)
        return (clampedHeight, totalHeight == maxPanelHeight)
    }

    private func shouldPreserveVisibleFrame(for panel: NSPanel, anchor: CGPoint) -> Bool {
        guard panel.isVisible,
              let activeAnchor
        else {
            return false
        }

        switch viewModel.state {
        case .loading, .result:
            break
        case .idle, .pending, .error:
            return false
        }

        return hypot(anchor.x - activeAnchor.x, anchor.y - activeAnchor.y) < 80
    }

    private func preferredFrame(
        for panel: NSPanel,
        anchor: CGPoint,
        visibleFrame: CGRect,
        height: CGFloat
    ) -> CGRect {
        let topOrigin = resolvedTopOrigin(
            for: panel,
            anchor: anchor,
            visibleFrame: visibleFrame
        )
        let clampedOriginY = max(
            visibleFrame.minY + 12,
            topOrigin.y - height
        )
        return CGRect(x: topOrigin.x, y: clampedOriginY, width: panelWidth, height: height)
    }

    private func resolvedTopOrigin(
        for panel: NSPanel,
        anchor: CGPoint,
        visibleFrame: CGRect
    ) -> CGPoint {
        if panel.isVisible,
           let activeAnchor,
           let activeTopOrigin,
           hypot(anchor.x - activeAnchor.x, anchor.y - activeAnchor.y) < 80 {
            return activeTopOrigin
        }

        let margin: CGFloat = 12
        let x = min(
            max(visibleFrame.midX - panelWidth / 2, visibleFrame.minX + margin),
            visibleFrame.maxX - panelWidth - margin
        )
        let preferredTopY = visibleFrame.midY + 80
        let topY = min(
            max(preferredTopY, visibleFrame.minY + minPanelHeight + margin),
            visibleFrame.maxY - margin
        )
        let point = CGPoint(x: x, y: topY)
        activeTopOrigin = point
        return point
    }

    private func measuredHeight(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = font.pointSize >= 24 ? 4 : 3

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }

    private var currentOriginalText: String? {
        switch viewModel.state {
        case .pending:
            return nil
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

    private func formatted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

            if viewModel.allowsScrolling {
                ScrollViewReader { proxy in
                    ScrollView {
                        scrollContent
                    }
                    .onChange(of: scrollResetKey) { _, _ in
                        proxy.scrollTo("top", anchor: .top)
                    }
                    .onAppear {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            } else {
                contentSections
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    @ViewBuilder
    private var scrollContent: some View {
        Color.clear
            .frame(height: 1)
            .id("top")
        contentSections
    }

    @ViewBuilder
    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let originalText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatted(originalText))
                        .font(.body)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch viewModel.state {
            case .idle:
                EmptyView()
            case .pending:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在取词...")
                        .foregroundStyle(.secondary)
                }
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
                    Text(formatted(result.translatedText))
                        .font(.title3.weight(.semibold))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("来源：\(sourceLabel) · 接口：\(result.providerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .error(let message, _, _):
                Text(formatted(message))
                    .foregroundStyle(.red)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scrollResetKey: String {
        switch viewModel.state {
        case .pending:
            return "pending"
        case .idle:
            return "idle"
        case .loading(let text, let method):
            return "loading-\(method.rawValue)-\(text)"
        case .result(let selection, let result):
            return "result-\(selection.text)-\(result.translatedText)"
        case .error(let message, let text, let method):
            return "error-\(method?.rawValue ?? "none")-\(text ?? "")-\(message)"
        }
    }

    private var title: String {
        switch viewModel.state {
        case .pending:
            return "正在取词"
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
        case .pending:
            return nil
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
        case .pending:
            return "处理中"
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
