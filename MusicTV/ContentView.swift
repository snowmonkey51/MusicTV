//
//  ContentView.swift
//  MusicTV
//
//  Created by aaron bevill on 2/15/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            NowPlayingView()
        }
        .navigationTitle("MusicTV")
        .onAppear {
            engine.attach(to: appState)
        }
        .background(
            SplitViewSidebarToggle(isFullScreen: appState.isFullScreen)
        )
        .background(
            KeyEventHandler(
                onSpace: { engine.togglePlayPause() },
                onEscape: {
                    if appState.isFullScreen {
                        appState.toggleFullScreen()
                    }
                },
                onRightArrow: { engine.skip() },
                onLeftArrow: { engine.skipBack() },
                onF: { appState.toggleFullScreen() }
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            appState.isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            appState.isFullScreen = false
        }
        .task {
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                let frame = window.frame
                if frame.height > frame.width * 0.6 {
                    let newHeight = frame.width * (9.0 / 16.0)
                    let newOrigin = NSPoint(x: frame.origin.x, y: frame.origin.y + (frame.height - newHeight))
                    let newFrame = NSRect(origin: newOrigin, size: NSSize(width: frame.width, height: newHeight))
                    window.setFrame(newFrame, display: true, animate: false)
                }
            }
        }
    }
}

// MARK: - AppKit-level Sidebar Toggle

/// Finds the NSSplitViewController backing NavigationSplitView and uses
/// toggleSidebar to collapse/expand, bypassing SwiftUI's columnVisibility timing issues.
struct SplitViewSidebarToggle: NSViewRepresentable {
    var isFullScreen: Bool

    func makeNSView(context: Context) -> SidebarToggleView {
        SidebarToggleView()
    }

    func updateNSView(_ nsView: SidebarToggleView, context: Context) {
        nsView.targetFullScreen = isFullScreen
        DispatchQueue.main.async {
            nsView.syncSidebar()
        }
    }
}

class SidebarToggleView: NSView {
    var targetFullScreen = false
    private var sidebarIsCollapsed = false
    private var savedStyleMask: NSWindow.StyleMask?

    func syncSidebar() {
        guard let window else { return }

        if targetFullScreen && !sidebarIsCollapsed {
            // Collapse sidebar
            if let splitVC = findSplitViewController() {
                if splitVC.splitViewItems.count > 1 {
                    splitVC.splitViewItems[0].animator().isCollapsed = true
                    sidebarIsCollapsed = true
                }
            } else {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                sidebarIsCollapsed = true
            }
            // Hide titlebar
            savedStyleMask = window.styleMask
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar?.isVisible = false
        } else if !targetFullScreen && sidebarIsCollapsed {
            // Expand sidebar
            if let splitVC = findSplitViewController() {
                if splitVC.splitViewItems.count > 1 {
                    splitVC.splitViewItems[0].animator().isCollapsed = false
                    sidebarIsCollapsed = false
                }
            } else {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                sidebarIsCollapsed = false
            }
            // Restore titlebar
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.toolbar?.isVisible = true
        }
    }

    private func findSplitViewController() -> NSSplitViewController? {
        // Walk up the responder chain to find NSSplitViewController
        var responder: NSResponder? = self
        while let r = responder {
            if let splitVC = r as? NSSplitViewController {
                return splitVC
            }
            responder = r.nextResponder
        }
        // Also try finding via window's contentViewController
        if let rootVC = window?.contentViewController {
            return findSplitVCInChildren(rootVC)
        }
        return nil
    }

    private func findSplitVCInChildren(_ vc: NSViewController) -> NSSplitViewController? {
        if let splitVC = vc as? NSSplitViewController {
            return splitVC
        }
        for child in vc.children {
            if let found = findSplitVCInChildren(child) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Window-level Key Event Handler

struct KeyEventHandler: NSViewRepresentable {
    var onSpace: () -> Void
    var onEscape: () -> Void
    var onRightArrow: () -> Void
    var onLeftArrow: () -> Void
    var onF: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onSpace = onSpace
        view.onEscape = onEscape
        view.onRightArrow = onRightArrow
        view.onLeftArrow = onLeftArrow
        view.onF = onF
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onEscape = onEscape
        nsView.onRightArrow = onRightArrow
        nsView.onLeftArrow = onLeftArrow
        nsView.onF = onF
    }
}

class KeyCaptureView: NSView {
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onLeftArrow: (() -> Void)?
    var onF: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKey(event) ? nil : event
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let firstResponder = window?.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }

        switch event.keyCode {
        case 49: // Space
            onSpace?()
            return true
        case 53: // Escape
            onEscape?()
            return true
        case 124: // Right arrow
            onRightArrow?()
            return true
        case 123: // Left arrow
            onLeftArrow?()
            return true
        case 3: // F key
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                onF?()
                return true
            }
            return false
        default:
            return false
        }
    }
}
