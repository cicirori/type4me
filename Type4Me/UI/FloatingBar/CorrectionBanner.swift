import SwiftUI
import AppKit

// MARK: - Banner View

struct CorrectionBannerView: View {
    let corrections: [CorrectionExtractor.Correction]
    let onAccept: (CorrectionExtractor.Correction) -> Void
    let onDismiss: (CorrectionExtractor.Correction) -> Void
    let onDismissAll: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(corrections.prefix(3).enumerated()), id: \.element) { _, correction in
                HStack(spacing: 8) {
                    // Correction display
                    HStack(spacing: 4) {
                        Text(correction.wrong)
                            .strikethrough()
                            .foregroundStyle(.white.opacity(0.5))
                        Text("→")
                            .foregroundStyle(.white.opacity(0.3))
                        Text(correction.correct)
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                    Spacer()

                    // Action buttons
                    Button {
                        onAccept(correction)
                    } label: {
                        Text(L("添加", "Add"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(red: 0.30, green: 0.62, blue: 0.35)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDismiss(correction)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if corrections.count > 3 {
                Text(L("+\(corrections.count - 3) 更多", "+\(corrections.count - 3) more"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: TF.barWidth)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Banner Controller

@MainActor
final class CorrectionBannerController {

    private var panel: FloatingBarPanel?
    private var autoDismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 10.0

    private var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func show(corrections: [CorrectionExtractor.Correction]) {
        guard !corrections.isEmpty else { return }
        hide()

        let inset: CGFloat = 8
        let estimatedHeight = CGFloat(min(corrections.count, 3)) * 34 + 24
        let frame = NSRect(x: 0, y: 0, width: TF.barWidth + inset * 2, height: estimatedHeight + inset * 2)

        let newPanel = FloatingBarPanel(contentRect: frame)
        let view = CorrectionBannerView(
            corrections: corrections,
            onAccept: { [weak self] correction in
                self?.state?.acceptCorrection(correction)
                self?.refreshOrHide()
            },
            onDismiss: { [weak self] correction in
                self?.state?.dismissCorrection(correction)
                self?.refreshOrHide()
            },
            onDismissAll: { [weak self] in
                self?.state?.dismissAllCorrections()
                self?.hide()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.layer?.backgroundColor = .clear
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]

        newPanel.contentView = hosting
        newPanel.setFrame(frame, display: false)
        positionAboveBar(newPanel)

        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        startAutoDismiss()
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let p = panel, p.isVisible else {
            panel = nil
            return
        }
        let panelRef = p
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panelRef.orderOut(nil)
            }
        })
    }

    private func positionAboveBar(_ panel: FloatingBarPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        // Position above the floating bar
        let barY = visible.origin.y + TF.barBottomOffset
        let y = barY + TF.barHeight + 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refreshOrHide() {
        guard let remaining = state?.pendingCorrections, !remaining.isEmpty else {
            hide()
            return
        }
        show(corrections: remaining)
    }

    private func startAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(autoDismissDelay))
            guard !Task.isCancelled else { return }
            hide()
            state?.dismissAllCorrections()
        }
    }
}
