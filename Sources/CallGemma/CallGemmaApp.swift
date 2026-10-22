#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

@main
struct CallGemmaApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var controller = CallController(
        audio: CallAudio(captureOverride: AppQualificationEnvironment.usesSyntheticInput ? [] : nil),
        directory: AppQualificationEnvironment.runtime)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        #if os(macOS)
        Window("Blessenger", id: "blessenger") {
            if ProcessInfo.processInfo.environment["CALL_GEMMA_TEST_HOST"] == "1" { EmptyView() }
            else { content.frame(minWidth: 480, minHeight: 480).background(AutomationWindowVisibility()) }
        }
        // Hosted tests need the app process, but should not open a blank window.
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["CALL_GEMMA_TEST_HOST"] == "1"
            ? .suppressed : .automatic)
        .defaultSize(width: 960, height: 700)
        .commands { BlessengerCommands() }
        #else
        WindowGroup { content }
        #endif
    }

    private var content: some View {
        BlessengerView(controller: controller)
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                if phase == .background { controller.suspendForBackground() }
                if phase == .active { controller.resumeFromBackground() }
                #endif
            }
            .task {
                #if os(macOS)
                appDelegate.controller = controller
                #endif
                if ProcessInfo.processInfo.environment["CALL_GEMMA_TEST_HOST"] != "1" {
                    controller.prepare(allowAvailableModel: true)
                }
            }
    }
}

private struct CreateContactKey: FocusedValueKey { typealias Value = () -> Void }
private struct DiagnosticsKey: FocusedValueKey { typealias Value = () -> Void }
private struct CreateConversationKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var showDiagnostics: (() -> Void)? {
        get { self[DiagnosticsKey.self] }
        set { self[DiagnosticsKey.self] = newValue }
    }
    var createContact: (() -> Void)? {
        get { self[CreateContactKey.self] }
        set { self[CreateContactKey.self] = newValue }
    }
    var createConversation: (() -> Void)? {
        get { self[CreateConversationKey.self] }
        set { self[CreateConversationKey.self] = newValue }
    }
}

#if os(macOS)
private struct BlessengerCommands: Commands {
    @FocusedValue(\.showDiagnostics) private var showDiagnostics
    @FocusedValue(\.createContact) private var createContact
    @FocusedValue(\.createConversation) private var createConversation
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Conversations") {
                NSApp.sendAction(#selector(DesktopConversationController.showConversationSearch(_:)), to: nil, from: nil)
            }.keyboardShortcut("f")
        }
        CommandGroup(after: .toolbar) {
            Button("Connect iPhone") { WebCompanion.shared.showPairing() }
            Button("Diagnostics") { showDiagnostics?() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(showDiagnostics == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message") { createConversation?() }
                .keyboardShortcut("n").disabled(createConversation == nil)
            Button("Add Contact") { createContact?() }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(createContact == nil)
        }
    }
}
#endif

#if os(macOS)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: CallController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppQualificationEnvironment.hidesAutomationWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let controller else { return .terminateNow }
        terminating = true
        Task {
            let saved = await controller.shutdown()
            terminating = saved
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppQualificationEnvironment.hidesAutomationWindow
    }
}

/// Keep the real SwiftUI hierarchy and app bridge alive without presenting a
/// synthetic-input window as the user's usable app. Visible UI tests opt in.
private struct AutomationWindowVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard AppQualificationEnvironment.usesSyntheticInput, let window else { return }
            window.title = "Blessenger — Automation"
            if AppQualificationEnvironment.hidesAutomationWindow {
                window.isExcludedFromWindowsMenu = true
                DispatchQueue.main.async { [weak window] in window?.orderOut(nil) }
            }
        }
    }
}

#endif

