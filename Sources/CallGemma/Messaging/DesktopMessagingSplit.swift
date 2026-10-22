#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns the divider and titlebar; SwiftUI owns the conversation presentation.
struct DesktopMessagingSplit: NSViewControllerRepresentable {
    var sidebar: AnyView
    var detail: AnyView
    var header: AnyView
    var composing: Bool
    var canCall: Bool
    var inCall: Bool
    var query: String
    var search: (String) -> Void
    var compose: () -> Void
    var call: () -> Void

    func makeNSViewController(context: Context) -> DesktopConversationController {
        DesktopConversationController(configuration: self)
    }
    func updateNSViewController(_ controller: DesktopConversationController, context: Context) {
        controller.update(self)
    }
}

@MainActor
final class DesktopConversationController: NSSplitViewController, NSToolbarDelegate, NSSearchFieldDelegate, NSGestureRecognizerDelegate {
    private let sidebarHost: NSHostingController<AnyView>
    private let detailHost: NSHostingController<AnyView>
    private let headerHost: NSHostingView<AnyView>
    private var configuration: DesktopMessagingSplit
    private var conversationToolbar: NSToolbar?
    private var callItem: NSToolbarItem?

    private var searchItem: NSToolbarItem?
    private var searchField: NSSearchField?
    private var searchMonitor: Any?
    private var isSearching = false
    private var updatingSearchVisibility = false
    private static let searchID = NSToolbarItem.Identifier("conversation.search")
    private static let dividerID = NSToolbarItem.Identifier("conversation.divider")
    private static let composeID = NSToolbarItem.Identifier("conversation.compose")
    private static let callID = NSToolbarItem.Identifier("conversation.call")

    init(configuration: DesktopMessagingSplit) {
        self.configuration = configuration
        sidebarHost = NSHostingController(rootView: configuration.sidebar)
        detailHost = NSHostingController(rootView: configuration.detail)
        headerHost = NSHostingView(rootView: configuration.header)
        headerHost.safeAreaRegions = []
        headerHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(collapseToRail(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delegate = self
        doubleClick.delaysPrimaryMouseButtonEvents = false
        splitView.addGestureRecognizer(doubleClick)
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.canCollapse = false
        sidebar.minimumThickness = 100
        sidebar.maximumThickness = 380
        sidebar.holdingPriority = .defaultLow
        let detail = NSSplitViewItem(viewController: detailHost)
        detail.minimumThickness = 320
        addSplitViewItem(sidebar)
        addSplitViewItem(detail)
        splitView.setPosition(260, ofDividerAt: 0)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = splitView.convert(event.locationInWindow, from: nil)
        guard let sidebar = splitView.arrangedSubviews.first else { return false }
        return abs(point.x - sidebar.frame.maxX) <= max(4, splitView.dividerThickness)
    }

    @objc private func collapseToRail(_ gesture: NSClickGestureRecognizer) {
        splitView.setPosition(100, ofDividerAt: 0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        if conversationToolbar != nil {
            window.contentView?.superview?.addSubview(headerHost, positioned: .above, relativeTo: nil)
            resizeHeader()
            return
        }
        let toolbar = NSToolbar(identifier: "Blessenger.Conversation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        conversationToolbar = toolbar
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.toolbar = toolbar
        // A title is not a toolbar control. Keep it outside the toolbar's
        // 36-point glass control clipping and align it with the detail pane.
        window.contentView?.superview?.addSubview(headerHost, positioned: .above, relativeTo: nil)
        resizeHeader()
        updateSearchVisibility()
    }

    func update(_ configuration: DesktopMessagingSplit) {
        self.configuration = configuration
        sidebarHost.rootView = configuration.sidebar
        detailHost.rootView = configuration.detail
        headerHost.rootView = configuration.header
        resizeHeader()

        configureCall()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchID, Self.dividerID, Self.composeID,
         .flexibleSpace, Self.callID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.dividerID {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0)
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id {
        case Self.searchID:
            item.autovalidates = false
            item.isEnabled = true
            item.label = "Search conversations"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: item.label)
            item.action = #selector(openSearch)
            searchItem = item
        case Self.composeID:
            item.isNavigational = true
            item.label = "New message"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
            item.action = #selector(compose)
        case Self.callID:
            callItem = item
            item.action = #selector(call)
            item.autovalidates = false
            configureCall()
        default: return nil
        }
        item.toolTip = item.label
        return item
    }
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        updateSearchVisibility()
        resizeHeader()
    }
    private func resizeHeader() {
        guard let window = view.window, let parent = headerHost.superview else { return }
        let sidebarEdge = splitView.arrangedSubviews.first?.frame.maxX ?? 0
        let detailBounds = splitView.convert(NSRect(x: sidebarEdge, y: 0,
            width: splitView.bounds.width - sidebarEdge, height: splitView.bounds.height), to: parent)
        let available = max(80, detailBounds.width - 120)
        let width = configuration.composing ? available : min(220, available)
        let height: CGFloat = 52
        headerHost.frame = NSRect(x: detailBounds.midX - width / 2,
            y: parent.bounds.maxY - height, width: width, height: height)
        headerHost.isHidden = window.toolbar == nil
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        resizeHeader()
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeSearch()
        headerHost.removeFromSuperview()
    }
    private func configureCall() {
        callItem?.label = configuration.inCall ? "End call" : "Call"
        callItem?.toolTip = callItem?.label
        callItem?.image = NSImage(systemSymbolName: configuration.inCall ? "phone.down" : "phone",
                                 accessibilityDescription: callItem?.label)
        callItem?.isEnabled = configuration.canCall
    }
    private func updateSearchVisibility() {
        guard !updatingSearchVisibility, let toolbar = conversationToolbar else { return }
        updatingSearchVisibility = true
        defer { updatingSearchVisibility = false }
        let compact = (splitView.arrangedSubviews.first?.frame.width ?? 260) < 190
        if compact {
            if isSearching { closeSearch() }
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.searchID }) {
                toolbar.removeItem(at: index)
                searchItem = nil
            }
        } else if !toolbar.items.contains(where: { $0.itemIdentifier == Self.searchID }),
                  let divider = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.dividerID }) {
            toolbar.insertItem(withItemIdentifier: Self.searchID, at: divider)
        }
    }

    @objc func showConversationSearch(_ sender: Any?) { openSearch() }

    @objc private func openSearch() {
        if let window = view.window, splitView.bounds.width < 581 {
            var frame = window.frame
            frame.size.width += 581 - splitView.bounds.width
            window.setFrame(frame, display: true)
        }
        if (splitView.arrangedSubviews.first?.frame.width ?? 0) < 260 {
            splitView.setPosition(260, ofDividerAt: 0)
        }
        updateSearchVisibility()
        if isSearching { view.window?.makeFirstResponder(searchField); return }
        guard let item = searchItem else { return }
        isSearching = true
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 150, height: 32))
        field.placeholderString = "Search"
        field.setAccessibilityLabel("Search conversations")
        field.textColor = .labelColor
        field.delegate = self
        field.stringValue = configuration.query
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged)
        searchField = field
        item.action = nil
        item.target = nil
        item.view = field
        item.isEnabled = true
        field.isEnabled = true
        field.target = self
        field.action = #selector(searchChanged)
        item.minSize = NSSize(width: 150, height: 32)
        item.maxSize = NSSize(width: 150, height: 32)
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.isSearching else { return }
            self.view.window?.makeFirstResponder(field)
            self.searchMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let field = self.searchField, event.window === self.view.window,
                       !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                        self.closeSearch()
                    }
                }
                return event
            }
        }
    }

    @objc private func closeSearch() {
        guard isSearching else { return }
        isSearching = false
        if let searchMonitor { NSEvent.removeMonitor(searchMonitor); self.searchMonitor = nil }
        view.window?.makeFirstResponder(nil)
        searchField?.delegate = nil
        searchField = nil
        // Recreate the standard item so no expanded-field width constraints
        // survive into the compact magnifying-glass button.
        if let toolbar = conversationToolbar,
           let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.searchID }) {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: Self.searchID, at: index)
        }
        configuration.search("")
    }
    @objc private func searchChanged() {
        guard let searchField else { return }
        if searchField.stringValue.isEmpty && !configuration.query.isEmpty { closeSearch(); return }
        configuration.search(searchField.stringValue)
    }
    func controlTextDidChange(_ notification: Notification) { searchChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if NSStringFromSelector(commandSelector) == "cancelOperation:" {
            closeSearch()
            return true
        }
        return false
    }
    @objc private func compose() { configuration.compose() }
    @objc private func call() { configuration.call() }
}
#endif
