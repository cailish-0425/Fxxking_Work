import AppKit
import SwiftUI

/// 只观察承载菜单栏面板的窗口，不把设置窗口的出现当成一次金额揭示。
@MainActor
struct MenuBarPanelVisibility: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onOpen = onOpen
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
        // 更新金额或超时收起不会触发新的窗口打开事件。
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopObserving()
    }

    final class VisibilityView: NSView {
        var onOpen: () -> Void = {}
        var onClose: () -> Void = {}
        private var observers: [NSObjectProtocol] = []
        private var presented = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }

            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.openedIfVisible() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.closed() }
            })

            // 视图附着时窗口可能已经显示。预构造但不可见的窗口不会揭示。
            DispatchQueue.main.async { [weak self] in self?.openedIfVisible() }
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            closed()
        }

        private func openedIfVisible() {
            guard !presented, let window, window.isVisible, window.isKeyWindow else { return }
            presented = true
            onOpen()
        }

        private func closed() {
            guard presented else { return }
            presented = false
            onClose()
        }
    }
}
