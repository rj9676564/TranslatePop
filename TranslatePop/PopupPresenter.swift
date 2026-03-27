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
    private var panelWidth: CGFloat {
        guard let text = currentOriginalText, !text.isEmpty else { return 420 }
        if text.count < 30 { return 340 }
        if text.count < 100 { return 440 }
        return 520
    }
    private var panelHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight - 80
    }
    private let viewModel = PopupViewModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var activeAnchor: CGPoint?
    private var activeTopOrigin: CGPoint?

    func presentPending(at anchor: CGPoint) {
        logger.info("展示预加载弹窗")
        activeTopOrigin = nil
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

    func presentStreaming(selection: CapturedSelection, partialText: String, providerName: String) {
        logger.info("展示流式翻译，provider=\(providerName, privacy: .public)")
        viewModel.state = .streaming(selection: selection, partialText: partialText, providerName: providerName)
        showPanel(anchor: selection.anchorPoint)
        dismissTask?.cancel()
        dismissTask = nil
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

    func dismissForUserInteraction(at point: CGPoint) {
        guard let panel, panel.isVisible else { return }
        switch viewModel.state {
        case .pending, .loading, .streaming:
            logger.info("用户交互到来，但当前弹窗仍在处理中，保持显示")
            return
        case .idle, .result, .error:
            break
        }
        if !panel.ignoresMouseEvents, panel.frame.contains(point) {
            logger.info("点击发生在弹窗内部，保持显示")
            return
        }
        dismiss()
    }

    private func showPanel(anchor: CGPoint) {
        let panel = self.panel ?? makePanel()
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let topOrigin = resolvedTopOrigin(
            for: panel,
            anchor: anchor,
            visibleFrame: visibleFrame
        )
        let layout = preferredPanelLayout(topOriginY: topOrigin.y, visibleFrame: visibleFrame)
        logger.info("size \(layout.height)")
        let preserveVisibleFrame = shouldPreserveVisibleFrame(for: panel, anchor: anchor)
        viewModel.allowsScrolling = layout.allowsScrolling
        let panelFrame: CGRect
        if preserveVisibleFrame {
            panelFrame = CGRect(
                x: topOrigin.x,
                y: topOrigin.y - layout.height,
                width: panelWidth,
                height: layout.height
            )
        } else {
            panelFrame = preferredFrame(
                topOrigin: topOrigin,
                visibleFrame: visibleFrame,
                height: layout.height
            )
        }
        panel.ignoresMouseEvents = shouldIgnoreMouseEvents
        if shouldIgnoreMouseEvents {
            viewModel.isHovering = false
        }
        let clampedPanelFrame = clampedFrame(panelFrame, visibleFrame: visibleFrame)
        panel.setFrame(clampedPanelFrame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        activeAnchor = anchor
        logger.info("弹窗已显示，x=\(clampedPanelFrame.origin.x, format: .fixed(precision: 0)) y=\(clampedPanelFrame.origin.y, format: .fixed(precision: 0))")
    }

    private func makePanel() -> NSPanel {
        let contentView = PopupCardView(viewModel: viewModel) { [weak self] hovering in
            self?.viewModel.isHovering = hovering
        } onClose: { [weak self] in
            self?.dismiss()
        }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: panelWidth, height: panelHeight)),
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
        case .streaming:
            return !viewModel.allowsScrolling
        case .result:
            return !viewModel.allowsScrolling
        case .idle, .pending, .loading:
            return true
        }
    }

    private func preferredPanelLayout(topOriginY: CGFloat, visibleFrame: CGRect) -> (height: CGFloat, allowsScrolling: Bool) {
        let contentWidth = panelWidth - 32
        let textWidth = contentWidth - 4
        var totalHeight: CGFloat = 32
        totalHeight += 28

        if let originalText = currentOriginalText, !originalText.isEmpty {
            totalHeight += 22
            totalHeight += measuredHeight(
                for: formatted(originalText),
                width: textWidth,
                font: .systemFont(ofSize: 13, weight: .regular),
                lineSpacing: 3
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
        case .streaming(_, let partialText, _):
            totalHeight += 22
            totalHeight += measuredHeight(
                for: formatted(partialText),
                width: textWidth,
                font: .systemFont(ofSize: 15, weight: .semibold),
                lineSpacing: 4
            )
            totalHeight += 26
        case .result(_, let result):
            totalHeight += 22
            totalHeight += measuredHeight(
                for: formatted(result.translatedText),
                width: textWidth,
                font: .systemFont(ofSize: 15, weight: .semibold),
                lineSpacing: 4
            )
            totalHeight += 26
        case .error(let message, _, _):
            totalHeight += measuredHeight(
                for: formatted(message),
                width: textWidth,
                font: .systemFont(ofSize: 13, weight: .regular),
                lineSpacing: 3
            )
        }

        totalHeight += 24
        let finalHeight = min(totalHeight, panelHeight)
        return (finalHeight, totalHeight > panelHeight)
    }

    private func shouldPreserveVisibleFrame(for panel: NSPanel, anchor: CGPoint) -> Bool {
        guard panel.isVisible,
              let activeAnchor
        else {
            return false
        }

        switch viewModel.state {
        case .loading, .streaming, .result:
            break
        case .idle, .pending, .error:
            return false
        }

        return hypot(anchor.x - activeAnchor.x, anchor.y - activeAnchor.y) < 80
    }

    private func preferredFrame(
        topOrigin: CGPoint,
        visibleFrame: CGRect,
        height: CGFloat
    ) -> CGRect {
        let clampedOriginY = max(
            visibleFrame.minY + 12,
            topOrigin.y - height
        )
        return CGRect(x: topOrigin.x, y: clampedOriginY, width: panelWidth, height: height)
    }

    private func clampedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let horizontalMargin: CGFloat = 12
        let verticalMargin: CGFloat = 12
        let width = min(frame.width, visibleFrame.width - horizontalMargin * 2)
        let height = min(frame.height, visibleFrame.height - verticalMargin * 2)
        let x = min(
            max(frame.origin.x, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - width - horizontalMargin
        )
        let y = min(
            max(frame.origin.y, visibleFrame.minY + verticalMargin),
            visibleFrame.maxY - height - verticalMargin
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func resolvedTopOrigin(
        for panel: NSPanel,
        anchor: CGPoint,
        visibleFrame: CGRect
    ) -> CGPoint {
        if let activeTopOrigin {
            return activeTopOrigin
        }
        
        let margin: CGFloat = 12
        // X轴：窗口最左侧在鼠标之后 50 像素（如果右侧空间不够，系统则会自动靠齐屏幕右侧边缘防飞出）
        let x = min(
            max(anchor.x + 150, visibleFrame.minX + margin),
            visibleFrame.maxX - panelWidth - margin
        )
        
        // Y轴：优先放在鼠标下方稍稍偏移（距离大概20个像素），不遮挡划词的内容
        let preferredTopY = anchor.y - 20
        
        // 只限制最高点不要飞出屏幕正上方（最低点不用在这里操心，后续 clampedFrame 遇到屏幕底部会自动把它“向上挤起”）
        let topY = min(preferredTopY, visibleFrame.maxY - margin)
        
        let point = CGPoint(x: x, y: topY)
        activeTopOrigin = point
        return point
    }

    private func measuredHeight(for text: String, width: CGFloat, font: NSFont, lineSpacing: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        paragraphStyle.lineSpacing = lineSpacing

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
        case .streaming(let selection, _, _):
            return selection.text
        case .result(let selection, _):
            return selection.text
        case .error(_, let text, _):
            return text
        case .idle:
            return nil
        }
    }
}

private struct PopupCardView: View {
    @ObservedObject var viewModel: PopupViewModel
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            contentCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    private var contentCard: some View {
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
                    Text(attributedText(for: formatted(originalText), font: .systemFont(ofSize: 13, weight: .regular), lineSpacing: 3))
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
            case .streaming(_, let partialText, let providerName):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在翻译...")
                            .foregroundStyle(.secondary)
                    }
                    Text("翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(attributedText(for: formatted(partialText), font: .systemFont(ofSize: 15, weight: .semibold), lineSpacing: 4))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("来源：\(sourceLabel) · 接口：\(providerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .result(_, let result):
                VStack(alignment: .leading, spacing: 6) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(attributedText(for: formatted(result.translatedText), font: .systemFont(ofSize: 15, weight: .semibold), lineSpacing: 4))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("来源：\(sourceLabel) · 接口：\(result.providerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .error(let message, _, _):
                Text(attributedText(for: formatted(message), font: .systemFont(ofSize: 13, weight: .regular), lineSpacing: 3))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrollResetKey: String {
        switch viewModel.state {
        case .pending:
            return "pending"
        case .idle:
            return "idle"
        case .loading(let text, let method):
            return "loading-\(method.rawValue)-\(text)"
        case .streaming(let selection, let partialText, let providerName):
            return "streaming-\(selection.method.rawValue)-\(providerName)-\(partialText)"
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
        case .streaming(let selection, _, _):
            return "翻译中 · \(selection.method.rawValue)"
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
        case .streaming(let selection, _, _):
            return selection.text
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
        case .streaming(let selection, _, _):
            return selection.method.rawValue
        case .result(let selection, _):
            return selection.method.rawValue
        case .error(_, _, let method):
            return method?.rawValue ?? "未知"
        case .idle:
            return "未知"
        }
    }
}

fileprivate func formatted(_ text: String) -> String {
    // 先统一平台换行符
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    
    // 使用正则：如果单个换行符前后都不是换行符，就把它替换成空格
    guard let regex = try? NSRegularExpression(pattern: "(?<!\n)\n(?!\n)", options: []) else { return normalized }
    
    let range = NSRange(normalized.startIndex..., in: normalized)
    let singleLineBreakReplaced = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: " ")
    
    return singleLineBreakReplaced
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

fileprivate func attributedText(for string: String, font: NSFont, lineSpacing: CGFloat) -> AttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byCharWrapping
    style.lineSpacing = lineSpacing
    let nsAttrString = NSAttributedString(
        string: string,
        attributes: [
            .paragraphStyle: style,
            .font: font
        ]
    )
    return AttributedString(nsAttrString)
}
