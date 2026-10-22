import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import QuickLook

struct BlessengerView: View {
    @ObservedObject var controller: CallController
    @StateObject private var model = MessagingModel(directory: AppQualificationEnvironment.messaging)
    @State private var query = ""
    @State private var searching = false
    @State private var composing = false
    @State private var compositionID = UUID()
    @State private var recipients: [UUID] = []
    @State private var recipientQuery = ""
    @State private var recipientIndex = 0
    @FocusState private var recipientFocused: Bool
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var selectedAt = Date()
    @State private var showingDeleted = false
    @State private var memberThread: ChatThread?
    @Environment(\.undoManager) private var undoManager
    @State private var editing: Persona?
    @State private var newContact = false
    @State private var diagnostics = false
    @State private var editingMembers = false
    @State private var draft = ""
    @State private var draftSelection: TextSelection?
    @State private var mentions: [ChatMention] = []
    @State private var importing = false
    @State private var importingThread: UUID?
    @State private var recordingNote = false
    @State private var recordingThread: UUID?
    @State private var attachments: [MessageAttachment] = []
    private struct Draft {
        var text = ""
        var mentions: [ChatMention] = []
        var attachments: [MessageAttachment] = []
    }
    @State private var drafts: [UUID: Draft] = [:]
    private let attachmentLibrary = AttachmentLibrary()

    private var thread: ChatThread? { model.state.threads.first { $0.id == model.selected } }
    private var messages: [ChatMessage] { model.state.messages.filter { $0.thread == model.selected } }
    private var mentionOptions: [ChatMention] {
        guard let range = draft.range(of: "@", options: .backwards) else { return [] }
        let query = String(draft[range.upperBound...])
        guard !query.contains("\n"), !mentions.contains(where: { query == $0.label + " " }) else { return [] }
        return (model.state.contacts.map { ChatMention(kind: .contact, id: $0.id, label: ConversationRouting.displayLabel($0, contacts: model.state.contacts)) }
            + model.state.threads.filter { $0.deleted != true }.map { ChatMention(kind: .conversation, id: $0.id, label: ConversationRouting.displayLabel($0, threads: model.state.threads)) })
            .filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        shell
        .task {
            await model.installBundledContacts(); await model.load()
            #if os(macOS)
            WebCompanion.shared.start(model: model, controller: controller)
            #endif
            await model.resumePending(controller: controller)
            await AppQualificationBridge.run(controller: controller, model: model)
        }
        .focusedSceneValue(\.showDiagnostics, { diagnostics = true })
        .focusedSceneValue(\.createContact, { newContact = true })
        .focusedSceneValue(\.createConversation, { beginComposition() })
        .onChange(of: controller.inCall) { _, active in
            if !active { Task { await model.resumePending(controller: controller) } }
        }
        .onChange(of: controller.playingVoiceNote) { _, playing in
            if playing == nil { Task { await model.resumePending(controller: controller) } }
        }
        .onChange(of: model.selected) { old, new in
            selectedAt = Date()
            let admittedDraft = composing && new == compositionID
            if new != nil { composing = false }
            if admittedDraft { return }
            Task { await controller.stopVoiceNotePlayback() }
            if let old, !composing { drafts[old] = Draft(text: draft, mentions: mentions, attachments: attachments) }
            let next = new.flatMap { drafts[$0] } ?? Draft()
            draftSelection = nil
            draft = next.text; mentions = next.mentions; attachments = next.attachments
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .audio, .pdf, .plainText], allowsMultipleSelection: true) { result in
            let destination = importingThread
            Task {
                guard let destination else { return }
                do {
                    for url in try result.get() {
                        let file = try await attachmentLibrary.importFile(url)
                        if model.selected == destination || (composing && compositionID == destination) { attachments.append(file) }
                        else { drafts[destination, default: Draft()].attachments.append(file) }
                    }
                } catch { model.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $newContact) {
            ContactEditor(contact: Persona(name: "", prompt: PromptChoice.everyday.text)) { contact in
                Task { await model.save(contact) }
            }
        }
        .sheet(item: $editing) { contact in ContactEditor(contact: contact) { contact in Task { await model.save(contact) } } }
        .sheet(isPresented: $editingMembers) {
            if let thread = memberThread { MembershipEditor(thread: thread, contacts: model.state.contacts) { updated in Task { await model.updateThread(updated) } } }
        }
        .sheet(isPresented: $diagnostics) {
            CallDiagnosticsView(controller: controller, audio: controller.callDiagnostics) {
                diagnostics = false
            }
        }
        .alert("Message failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    @ViewBuilder private var shell: some View {
        #if os(macOS)
        DesktopMessagingSplit(sidebar: AnyView(sidebar), detail: AnyView(detail),
            header: AnyView(compositionHeader), composing: composing, canCall: thread != nil && model.generating.isEmpty && !recordingNote,
            inCall: controller.inCall, query: query, search: { query = $0 }, compose: { beginComposition() }, call: call)
            .ignoresSafeArea(.container, edges: .top)
        #else
        NavigationSplitView { sidebar } detail: { detail }
        #endif
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 190
            VStack(spacing: 0) {
                #if os(iOS)
                HStack {
                    Spacer(minLength: 0)
                    Button { searching.toggle() } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel("Search conversations")
                }.padding(10)
                #endif
                #if os(iOS)
                if searching {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                }
                #endif
                List(selection: $model.selected) {
                    ForEach(model.state.threads.filter { ($0.deleted == true) == showingDeleted && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { chat in
                        #if os(macOS)
                        conversationRow(chat, compact: compact).tag(chat.id).contextMenu { conversationActions(chat) }
                        #else
                        NavigationLink(value: chat.id) { conversationRow(chat, compact: false) }.contextMenu { conversationActions(chat) }
                        #endif
                    }
                }.listStyle(.sidebar)
                .contextMenu {
                    Button(showingDeleted ? "Conversations" : "Recently Deleted", systemImage: showingDeleted ? "bubble.left.and.bubble.right" : "trash") {
                        showingDeleted.toggle(); model.selected = nil
                    }
                }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { beginComposition() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New message")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newContact = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Add contact")
            }
        }
        #endif
    }

    @ViewBuilder private func avatar(for chat: ChatThread, size: CGFloat) -> some View {
        if chat.participants.count > 1 {
            Image(systemName: "person.2.circle.fill").resizable().scaledToFit()
                .frame(width: size, height: size).foregroundStyle(.tint)
        } else {
            ContactAvatar(value: model.state.contacts.first { $0.id == chat.participants.first }?.avatar ?? "person.crop.circle.fill", size: size)
        }
    }

    @ViewBuilder private func conversationRow(_ chat: ChatThread, compact: Bool) -> some View {
        if compact {
            VStack(spacing: 6) {
                avatar(for: chat, size: 48)
                conversationTitle(chat).font(.caption)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
                .accessibilityLabel(chat.title)
        } else {
            HStack(spacing: 12) {
                avatar(for: chat, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    conversationTitle(chat)
                    if let last = model.state.messages.last(where: { $0.thread == chat.id }) {
                        Text(last.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.padding(.vertical, 5)
        }
    }

    private var detail: some View {
            VStack(spacing: 0) {
                if composing {
                    #if os(iOS)
                    recipientEntry
                    #endif
                    recipientSuggestions
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                MessageBubble(message: message, name: model.state.contacts.first { $0.id == message.sender }?.name,
                                    controller: controller, contact: model.state.contacts.first { $0.id == message.sender },
                                    reply: { draft = "> " + (message.text.isEmpty ? "♫" : message.text) + "\n\n" },
                                    delete: {
                                        Task { await model.deleteMessage(message.id) }
                                        undoManager?.registerUndo(withTarget: model) { target in Task { await target.deleteMessage(message.id, deleted: false) } }
                                        undoManager?.setActionName("Delete Message")
                                    }) { emoji in
                                    Task { await model.react(message, emoji: emoji) }
                                }.id(message.id)
                            }
                        }.padding(20)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                if !mentionOptions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(mentionOptions, id: \.self) { mention in
                                Button { insertMention(mention) } label: {
                                    Label(mention.label, systemImage: mention.kind == .contact ? "person.crop.circle" : "bubble.left.and.bubble.right")
                                }
                            }
                        }.padding(.horizontal)
                    }.frame(height: 36)
                }
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(attachments) { attachment in
                                Button { attachments.removeAll { $0.id == attachment.id } } label: {
                                    Label(attachment.name, systemImage: "xmark.circle")
                                }.help("Remove attachment")
                            }
                        }.padding(.horizontal)
                    }.frame(height: 36)
                }
                if recordingNote {
                    VoiceNoteComposer(controller: controller, commit: { url in
                        guard let destination = recordingThread else { throw GemmaError(message: "No conversation is selected.") }
                        let file = try await attachmentLibrary.importFile(url)
                        let admitted = await model.send("", threadID: destination, mentions: [], attachments: [file], controller: controller, onAdmitted: { recordingNote = false })
                        guard admitted else { throw GemmaError(message: model.error ?? "The voice note could not be sent.") }
                    }, dismiss: { recordingNote = false })
                    .padding(12)
                } else {
                HStack(alignment: .bottom, spacing: 10) {
                    Button { importingThread = composing ? compositionID : model.selected; importing = true } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).disabled(thread == nil && !composing)
                    .help("Attachments").accessibilityLabel("Attachments")
                    TextField("", text: $draft, selection: $draftSelection, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.plain).padding(10)
                        .glassEffect(.regular, in: Capsule())
                        .accessibilityLabel("Message").submitLabel(.send).onSubmit(send)
                        .onKeyPress(.return, phases: .down) { key in
                            if key.modifiers.contains(.shift) {
                                let range: Range<String.Index>
                                if let selection = draftSelection, case .selection(let selected) = selection.indices {
                                    range = selected
                                } else { range = draft.endIndex..<draft.endIndex }
                                let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
                                draft.replaceSubrange(range, with: "\n")
                                draftSelection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
                                return .handled
                            }
                            send()
                            return .handled
                        }
                    Button {
                        Task {
                            guard let destination = await materializeComposition() else { return }
                            recordingThread = destination
                            recordingNote = true
                        }
                    } label: { Image(systemName: "mic").frame(width: 28, height: 28) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .disabled((thread == nil && recipients.isEmpty) || controller.inCall)
                        .help("Record voice note").accessibilityLabel("Record voice note")
                }.padding(12)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { beginComposition() } label: { Image(systemName: "square.and.pencil") }
                        .help("New message").accessibilityLabel("New message")
                }
                ToolbarItem(placement: .primaryAction) { callButton }
                ToolbarItem(placement: .principal) { contactHeader }
            }
            #endif
    }

    private func call() {
        if controller.inCall { controller.toggleCall() }
        else if let thread, let contact = ConversationRouting.initialResponder(in: thread, state: model.state) {
            let participants = thread.participants.compactMap { id in model.state.contacts.first { $0.id == id } }
            controller.dial(participants: participants, initialSpeaker: contact.id, memoryStore: model.store)
        }
    }

    private var callButton: some View {
                    Button(action: call) {
                        Image(systemName: controller.inCall ? "phone.down.fill" : "phone.fill")
                            .foregroundStyle(controller.inCall ? .red : thread == nil ? .gray : .green)
                    }
                    .disabled(thread == nil || !model.generating.isEmpty)
                    .help(controller.inCall ? "End call" : "Call")
                    .accessibilityLabel(controller.inCall ? "End call" : "Call")
    }

    @ViewBuilder private var compositionHeader: some View {
        if composing { recipientEntry } else { contactHeader }
    }

    @ViewBuilder private var contactHeader: some View {
        if controller.inCall, controller.callParticipants.count > 1,
           let active = controller.callParticipants.first(where: { $0.id == controller.activeCallParticipant }) {
            Menu {
                ForEach(controller.callParticipants) { contact in
                    Button { controller.requestCallParticipant(contact.id) } label: {
                        if contact.id == controller.activeCallParticipant {
                            Label(ConversationRouting.displayLabel(contact, contacts: controller.callParticipants), systemImage: "checkmark")
                        } else {
                            Text(ConversationRouting.displayLabel(contact, contacts: controller.callParticipants))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 22)).foregroundStyle(.tint)
                    VStack(spacing: 2) {
                        Text(thread?.title ?? controller.callParticipants.map(\.name).joined(separator: ", "))
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            ContactAvatar(value: active.avatar, size: 16)
                            Text(active.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the recipient of your next spoken turn")
            .accessibilityLabel("Call participant: " + active.name)
        } else if let thread {
                        VStack(spacing: 2) {
                            avatar(for: thread, size: 28)
                            Text(thread.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { editHeader(thread) }
                        .focusable()
                        .onKeyPress(.return) { editHeader(thread); return .handled }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { editHeader(thread) }
                        .help("Edit conversation").accessibilityLabel("Edit " + thread.title)
                        .contextMenu {
                            Button { newContact = true } label: { Label("Contact", systemImage: "person.badge.plus") }
                            Button { Task { await model.retry(thread: thread.id, controller: controller) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            Button { diagnostics = true } label: { Label("Diagnostics", systemImage: "info.circle") }
                        }
                    }
    }

    private func editHeader(_ thread: ChatThread) {
        if thread.participants.count == 1 {
            editing = model.state.contacts.first { $0.id == thread.participants.first }
        } else { memberThread = thread; editingMembers = true }
    }

    private func send() {
        guard (model.selected != nil || (composing && !recipients.isEmpty)), (!draft.isEmpty || !attachments.isEmpty) else { return }
        let text = draft; let refs = mentions.filter { ConversationRouting.contains($0, in: draft) }; let files = attachments
        draftSelection = nil
        draft = ""; mentions = []; attachments = []
        Task {
            guard let threadID = await materializeComposition() else {
                draft = text; mentions = refs; attachments = files
                return
            }
            let admitted = await model.send(text, threadID: threadID, mentions: refs, attachments: files, controller: controller)
            if !admitted {
                if model.selected == threadID {
                    draft = text + (draft.isEmpty ? "" : "\n" + draft)
                    mentions = refs + mentions
                    attachments = files + attachments
                } else {
                    var restored = drafts[threadID] ?? Draft()
                    restored.text = text + (restored.text.isEmpty ? "" : "\n" + restored.text)
                    restored.mentions = refs + restored.mentions
                    restored.attachments = files + restored.attachments
                    drafts[threadID] = restored
                }
            }
        }
    }
    private func beginComposition() {
        guard !recordingNote else { return }
        if let old = model.selected { drafts[old] = Draft(text: draft, mentions: mentions, attachments: attachments) }
        model.selected = nil
        compositionID = UUID(); recipients = []; recipientQuery = ""; recipientIndex = 0
        composing = true; draft = ""; mentions = []; attachments = []
        recipientFocused = true
    }
    private func materializeComposition() async -> UUID? {
        if !composing { return model.selected }
        guard !recipients.isEmpty else { recipientFocused = true; return nil }
        return await model.createChat(contacts: recipients, id: compositionID)
    }
    private var recipientOptions: [Persona] {
        ConversationRouting.recipientContacts(in: model.state).filter {
            !recipients.contains($0.id) && (recipientQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(recipientQuery))
        }
    }
    private func addRecipient(_ person: Persona) {
        recipients.append(person.id); recipientQuery = ""; recipientIndex = 0; recipientFocused = true
    }
    private var recipientEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text("To:").foregroundStyle(.secondary)
                    ForEach(recipients, id: \.self) { id in
                        if let person = model.state.contacts.first(where: { $0.id == id }) {
                            HStack(spacing: 5) {
                                ContactAvatar(value: person.avatar, size: 22)
                                Text(person.name)
                                Button { recipients.removeAll { $0 == id } } label: { Image(systemName: "xmark").font(.caption2) }
                                    .accessibilityLabel("Remove " + person.name)
                            }.padding(6).background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    TextField("", text: $recipientQuery)
                        .textFieldStyle(.plain).frame(minWidth: 140).focused($recipientFocused)
                        .accessibilityLabel("Recipients")
                        .onChange(of: recipientQuery) { _, _ in recipientIndex = 0 }
                        .onKeyPress(.downArrow) { recipientIndex = min(recipientIndex + 1, max(0, recipientOptions.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { recipientIndex = max(0, recipientIndex - 1); return .handled }
                        .onKeyPress(.return) { acceptRecipient() }
                        .onKeyPress(.tab) { acceptRecipient() }
                        .onKeyPress(.escape) { recipientFocused = false; return .handled }
                }.padding(.vertical, 4)
            }
        }.padding(.horizontal, 8).buttonStyle(.plain)
    }
    private func acceptRecipient() -> KeyPress.Result {
        guard recipientOptions.indices.contains(recipientIndex) else { return .ignored }
        addRecipient(recipientOptions[recipientIndex])
        return .handled
    }
    @ViewBuilder private var recipientSuggestions: some View {
            if recipientFocused && !recipientOptions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(recipientOptions.enumerated()), id: \.element.id) { index, person in
                            Button { addRecipient(person) } label: {
                                HStack(spacing: 10) {
                                    ContactAvatar(value: person.avatar, size: 30)
                                    Text(ConversationRouting.displayLabel(person, contacts: model.state.contacts))
                                    Spacer()
                                }.padding(8).contentShape(Rectangle())
                                    .background(index == recipientIndex ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 200).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
    }
    @ViewBuilder private func conversationTitle(_ chat: ChatThread) -> some View {
        if renaming == chat.id {
            TextField("", text: $renameText).textFieldStyle(.plain).focused($renameFocused)
                .accessibilityLabel("Conversation name")
                .onSubmit { commitRename(chat) }
                .onKeyPress(.escape) { renaming = nil; return .handled }
                .onChange(of: renameFocused) { _, focused in if !focused { commitRename(chat) } }
        } else {
            Text(chat.title).lineLimit(1).onTapGesture {
                if model.selected == chat.id && Date().timeIntervalSince(selectedAt) > 0.4 { beginRename(chat) }
                else { model.selected = chat.id }
            }
        }
    }
    private func beginRename(_ chat: ChatThread) {
        renameText = chat.title; renaming = chat.id; renameFocused = true
    }
    private func commitRename(_ chat: ChatThread) {
        guard renaming == chat.id else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else { return }
        var updated = chat; updated.title = title
        Task { await model.updateThread(updated) }
    }
    @ViewBuilder private func conversationActions(_ chat: ChatThread) -> some View {
        if chat.deleted == true {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                var restored = chat; restored.deleted = nil
                Task { await model.updateThread(restored) }
            }
        } else {
        Button("Rename", systemImage: "pencil") { beginRename(chat) }
        Button(chat.participants.count == 1 ? "Edit Contact" : "Edit Group", systemImage: "person.crop.circle") { editHeader(chat) }
        Button("Restore Deleted Messages", systemImage: "arrow.uturn.backward") { Task { await model.restoreMessages(in: chat.id) } }
        Button("Delete", systemImage: "trash", role: .destructive) {
            var deleted = chat; deleted.deleted = true
            if model.selected == chat.id { model.selected = nil }
            Task { await model.updateThread(deleted) }
            undoManager?.registerUndo(withTarget: model) { target in Task { await target.updateThread(chat) } }
            undoManager?.setActionName("Delete Conversation")
        }
        }
        Divider()
        Button(showingDeleted ? "Conversations" : "Recently Deleted", systemImage: "trash") {
            showingDeleted.toggle(); model.selected = nil
        }
    }
    private func insertMention(_ mention: ChatMention) {
        if let range = draft.range(of: "@", options: .backwards) { draft.replaceSubrange(range.lowerBound..., with: "@\(mention.label) ") }
        mentions.append(mention)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let name: String?
    @ObservedObject var controller: CallController
    let contact: Persona?
    let reply: () -> Void
    let delete: () -> Void
    let react: (String) -> Void
    @State private var preview: URL?
    @State private var choosingReaction = false
    @State private var expandedReactions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reactionFrequency") private var reactionFrequency = Data()
        var body: some View {
        HStack {
            if message.sender == nil { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 5) {
                if let name { Text(name).font(.caption).foregroundStyle(.secondary) }
                if message.voiceNote == true, message.sender != nil {
                    voicePlayer
                }
                if message.voiceNote != true {
                Text(message.text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(message.sender == nil ? Color.white : .primary)
                    .background(message.sender == nil ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

                }
                ForEach(message.attachments) { attachment in
                    if attachment.kind == .audio { voicePlayer }
                    else {
                        Button { preview = attachment.url } label: { Label(attachment.name, systemImage: "doc") }
                            .buttonStyle(.plain).accessibilityLabel(attachment.name)
                    }
                }
                if !message.reactions.isEmpty { Text(message.reactions.sorted().joined()).font(.caption) }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .overlay { MessageSecondaryClick { expandedReactions = false; choosingReaction = true } }
            #else
            .onLongPressGesture { expandedReactions = false; choosingReaction = true }
            #endif
            .accessibilityAction(named: Text("Message actions")) { expandedReactions = false; choosingReaction = true }
            .popover(isPresented: $choosingReaction, attachmentAnchor: .rect(.bounds), arrowEdge: message.sender == nil ? .leading : .trailing) {
                VStack(spacing: 0) {
                    if expandedReactions {
                        ReactionPalette { emoji in chooseReaction(emoji); choosingReaction = false }
                            .transition(.opacity)
                    } else { messageMenu.transition(.opacity) }
                }.frame(width: 350)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: expandedReactions)
                    .presentationCompactAdaptation(.popover)
            }
            if message.sender != nil { Spacer(minLength: 48) }
        }.quickLookPreview($preview)
    }
    private var messageMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
                ForEach(frequentReactions, id: \.self) { emoji in
                    Button { chooseReaction(emoji); choosingReaction = false } label: {
                        Text(emoji).font(.system(size: 27)).frame(maxWidth: .infinity).frame(height: 40)
                    }.accessibilityLabel(emoji)
                }
                Button { expandedReactions = true } label: {
                    Image(systemName: "face.smiling").font(.system(size: 23)).frame(maxWidth: .infinity).frame(height: 40)
                }.help("More emoji").accessibilityLabel("More emoji")
            }.padding(.bottom, 6)
            menuAction("Reply", icon: "arrowshape.turn.up.left") { reply() }
            Divider().padding(.vertical, 3)
            menuAction("Copy", icon: "doc.on.doc") { copyMessage() }
            if let file = message.attachments.first {
                ShareLink(item: file.url) { menuLabel("Share", icon: "square.and.arrow.up") }
            } else { ShareLink(item: message.text) { menuLabel("Share", icon: "square.and.arrow.up") } }
            menuAction("Print", icon: "printer") { printMessage() }
            Divider().padding(.vertical, 3)
            menuAction("Delete", icon: "trash") { delete() }
        }.padding(12).buttonStyle(ReactionMenuButtonStyle())
    }
    private func menuLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
    }
    private func menuAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            choosingReaction = false
            DispatchQueue.main.async { action() }
        } label: { menuLabel(title, icon: icon) }
    }
    private var frequentReactions: [String] {
        let defaults = ["❤️", "👍", "👎", "😂", "‼️", "❓", "🙏", "💯", "🙌", "✔️", "🐸"]
        let counts = (try? JSONDecoder().decode([String: Int].self, from: reactionFrequency)) ?? [:]
        let ranked = counts.keys.sorted { a, b in
            if counts[a] != counts[b] { return counts[a, default: 0] > counts[b, default: 0] }
            return a < b
        }
        return Array((ranked + defaults.filter { !ranked.contains($0) }).prefix(11))
    }
    private func chooseReaction(_ emoji: String) {
        var counts = (try? JSONDecoder().decode([String: Int].self, from: reactionFrequency)) ?? [:]
        counts[emoji, default: 0] += 1
        if let data = try? JSONEncoder().encode(counts) { reactionFrequency = data }
        react(emoji)
    }
    private func copyMessage() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        if let file = message.attachments.first { NSPasteboard.general.writeObjects([file.url as NSURL]) }
        else { NSPasteboard.general.setString(message.text, forType: .string) }
        #else
        if let file = message.attachments.first { UIPasteboard.general.url = file.url }
        else { UIPasteboard.general.string = message.text }
        #endif
    }
    private func printMessage() {
        let text = [name, message.text.isEmpty ? nil : message.text,
                    message.attachments.isEmpty ? nil : message.attachments.map(\.name).joined(separator: "\n")]
            .compactMap { $0 }.joined(separator: "\n\n")
        #if os(macOS)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let view = MessagePrintLayout.makeView(text: text, printInfo: info)
        NSPrintOperation(view: view, printInfo: info).run()
        #else
        let operation = UIPrintInteractionController.shared
        operation.printFormatter = UISimpleTextPrintFormatter(text: text)
        operation.present(animated: true)
        #endif
    }
    private var voicePlayer: some View {
        let active = controller.playingVoiceNote == message.id
        let fraction = active && controller.voiceNoteDuration > 0 ? controller.voiceNotePosition / controller.voiceNoteDuration : 0
        return HStack(spacing: 10) {
            Button { controller.toggleVoiceNote(message, contact: contact) } label: {
                Image(systemName: active && !controller.voiceNotePaused ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 30)
            }.buttonStyle(.plain).accessibilityLabel(active && !controller.voiceNotePaused ? "Pause voice note" : "Play voice note")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    VoiceNoteWaveform(seed: message.id.uuidString).foregroundStyle(.secondary.opacity(0.45))
                    VoiceNoteWaveform(seed: message.id.uuidString).foregroundStyle(.tint)
                        .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * fraction) }
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if active { controller.seekVoiceNote(to: value.location.x / max(1, geometry.size.width)) }
                    })
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        if active { controller.seekVoiceNote(to: fraction + (direction == .increment ? 0.05 : -0.05)) }
                    }
            }.frame(width: 150, height: 28)
            if active {
                Text(Duration.seconds(controller.voiceNotePosition).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).monospacedDigit()
            }
        }.padding(12).background(.quaternary, in: Capsule())
    }

}

private struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var contact: Persona
    let save: (Persona) -> Void
    @State private var preview: AVAudioPlayer?
    @State private var recording = false
    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    ContactAvatar(value: contact.avatar, size: 48)
                    TextField("Name", text: $contact.name)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(0..<14) { index in
                            Button { contact.avatar = "portrait:\(index)" } label: {
                                ContactAvatar(value: "portrait:\(index)", size: 36)
                                    .overlay(Circle().stroke(contact.avatar == "portrait:\(index)" ? Color.accentColor : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityLabel("Portrait \(index + 1)")
                        }
                    }
                }
                TextEditor(text: $contact.prompt).frame(minHeight: 130).accessibilityLabel("System prompt")
                Picker("Voice", selection: $contact.voice) {
                    Text("Default").tag(nil as String?)
                    if let custom = contact.voice, custom.hasPrefix("/") { Text("Custom").tag(Optional(custom)) }
                    ForEach(BlessengerResources.voiceNames, id: \.self) { name in Text(BlessengerResources.label(name)).tag(Optional(name)) }
                }
                HStack {
                    Button {
                        if let name = contact.voice, let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : BlessengerResources.voiceURL(name) {
                            preview = try? AVAudioPlayer(contentsOf: url); preview?.play()
                        }
                    } label: { Image(systemName: "play.fill") }.accessibilityLabel("Preview voice").disabled(contact.voice == nil)
                    Button { recording = true } label: { Image(systemName: "waveform.badge.plus") }.accessibilityLabel("Import or record voice")
                }
                TextField("Wake name", text: $contact.wakeName)
            }
            .formStyle(.grouped)
            .navigationTitle(contact.name.isEmpty ? "Add Contact" : contact.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(contact); dismiss() }
                        .disabled(contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || contact.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.frame(minWidth: 360, minHeight: 380)
        .onDisappear { preview?.stop() }
        .sheet(isPresented: $recording) {
            VoiceSampleEditor(initialURL: nil) { url, _ in
                // VoiceSampleEditor returns an app-owned trimmed recording.
                contact.voice = url.path
            }
        }
    }
}

struct ContactAvatar: View {
    let value: String
    let size: CGFloat

    private func portrait(_ index: Int) -> Image {
        #if os(macOS)
        // Native Menu bridges the image independently of SwiftUI layout modifiers.
        // Supply one portrait with the correct intrinsic size, never the atlas.
        if let source = BlessengerResources.bundle.image(forResource: "contact-portrait-\(index)"),
           let image = source.copy() as? NSImage {
            image.size = NSSize(width: size, height: size)
            return Image(nsImage: image)
        }
        return Image(systemName: "person.crop.circle.fill")
        #else
        return Image("contact-portrait-\(index)", bundle: BlessengerResources.bundle)
        #endif
    }

    var body: some View {
        if value.hasPrefix("portrait:"), let index = Int(value.dropFirst(9)), (0..<14).contains(index) {
            portrait(index)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle()).accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle.fill").resizable()
                .frame(width: size, height: size).foregroundStyle(.tint).accessibilityHidden(true)
        }
    }
}

private struct MembershipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var thread: ChatThread
    let contacts: [Persona]
    let save: (ChatThread) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $thread.title)
                ForEach(contacts) { contact in
                    Toggle(ConversationRouting.displayLabel(contact, contacts: contacts), isOn: Binding(
                        get: { thread.participants.contains(contact.id) },
                        set: { selected in
                            if selected { thread.participants.append(contact.id) }
                            else { thread.participants.removeAll { $0 == contact.id } }
                        }))
                }
            }.formStyle(.grouped)
            .navigationTitle("Members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(thread); dismiss() }.disabled(thread.participants.isEmpty || thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.frame(minWidth: 340, minHeight: 360)
    }
}

private struct ReactionEmoji: Decodable, Identifiable {
    let emoji: String
    let name: String
    let category: String
    var id: String { emoji }
}

/// Keep native button semantics and focus rings, adding menu-style pointer feedback
/// inside the popover (plain SwiftUI buttons do not supply hover highlighting).
private struct ReactionMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }
    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(hovering && enabled ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(enabled ? (configuration.isPressed ? 0.8 : hovering ? 1 : 0) : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

private struct ReactionPalette: View {
    let select: (String) -> Void
    @State private var entries: [ReactionEmoji] = []
    @State private var query = ""
    @State private var category = ""
    @FocusState private var searching: Bool
    private let categories = [
        ("Smileys & Emotion", "face.smiling"), ("People & Body", "hand.wave"),
        ("Animals & Nature", "leaf"), ("Food & Drink", "fork.knife"),
        ("Travel & Places", "car"), ("Activities", "sportscourt"),
        ("Objects", "lightbulb"), ("Symbols", "heart"), ("Flags", "flag")
    ]
    private var results: [ReactionEmoji] {
        entries.filter { entry in
            if !query.isEmpty { return entry.name.localizedCaseInsensitiveContains(query) || entry.emoji == query }
            return category.isEmpty || entry.category == category
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain).focused($searching)
                    .accessibilityLabel("Search emoji")
                    .onChange(of: query) { _, value in
                        if entries.contains(where: { $0.emoji == value }) { select(value) }
                    }
                    .onSubmit { if let result = results.first { select(result.emoji) } }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                #if os(macOS)
                Button { searching = true; NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "character.bubble") }
                    .help("Emoji & Symbols").accessibilityLabel("Emoji and Symbols")
                #endif
            }.padding(9).background(.quaternary, in: Capsule())
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 5) {
                    ForEach(results) { entry in
                        Button { select(entry.emoji) } label: {
                            Text(entry.emoji).font(.system(size: 32)).frame(maxWidth: .infinity).frame(height: 46)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }.help(entry.name).accessibilityLabel(entry.name)
                    }
                }
            }.frame(height: 360)
            HStack(spacing: 0) {
                ForEach(categories, id: \.0) { name, icon in
                    Button { category = category == name ? "" : name; query = "" } label: {
                        Image(systemName: icon).frame(maxWidth: .infinity).frame(height: 28)
                            .foregroundStyle(category == name ? Color.accentColor : Color.secondary)
                    }.help(name).accessibilityLabel(name)
                }
            }

        }.padding(12).frame(width: 350).buttonStyle(ReactionMenuButtonStyle())
        .task {
            entries = await Task.detached {
                guard let url = BlessengerResources.bundle.url(forResource: "emoji", withExtension: "json"),
                      let data = try? Data(contentsOf: url) else { return [ReactionEmoji]() }
                return (try? JSONDecoder().decode([ReactionEmoji].self, from: data)) ?? []
            }.value
            searching = true
        }
    }
}

#if os(macOS)
/// Intercept only secondary clicks; selection, dragging and playback controls
/// continue receiving ordinary pointer events in the SwiftUI bubble underneath.
private struct MessageSecondaryClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> SecondaryClickView { SecondaryClickView(action: action) }
    func updateNSView(_ view: SecondaryClickView, context: Context) { view.action = action }
    final class SecondaryClickView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }
    }
}
#endif


/// Only the deliberately opened diagnostic sheet observes microphone telemetry.
private struct CallDiagnosticsView: View {
    @ObservedObject var controller: CallController
    @ObservedObject var audio: CallAudioDiagnostics
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.status)
            Text(audio.text)
            if let notice = controller.notice { Text(notice) }
            Button("Done", action: dismiss)
        }.padding().frame(minWidth: 320).textSelection(.enabled)
    }
}
