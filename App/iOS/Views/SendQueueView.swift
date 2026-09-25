import SwiftUI
import UIKit
import SwiftData
import MessageUI
import ReminderCore

/// Messages due right now for tap-to-send reminders. Each one opens the system
/// compose sheet pre-filled; "Send all" walks through them one after another.
struct SendQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var appState = AppState.shared

    @State private var messages: [PlannedMessage] = []
    @State private var composing: PlannedMessage?
    @State private var isSendingAll = false

    private var repository: Repository { Repository(context: modelContext) }

    var body: some View {
        NavigationStack {
            List {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "All caught up",
                        systemImage: "checkmark.circle",
                        description: Text("Tap-to-send reminders that are due will show up here.")
                    )
                } else {
                    Section {
                        ForEach(messages) { message in
                            QueueRow(
                                message: message,
                                onSend: { composing = message },
                                onMarkSent: { finish(message, status: .sent, note: "Marked as sent") },
                                onSkip: { finish(message, status: .skipped) }
                            )
                        }
                    } footer: {
                        Text("Messages go out from your own number or Apple Account through the Messages app, so they cost nothing extra.")
                    }
                }
            }
            .navigationTitle("Ready to send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if messages.count > 1 {
                        Button("Send all") {
                            isSendingAll = true
                            composing = messages.first
                        }
                    }
                }
            }
            .messageComposer($composing) { message, result in
                handle(result, for: message)
            }
            .onAppear(perform: reload)
            .onChange(of: appState.refreshToken) { _, _ in reload() }
        }
    }

    private func reload() {
        messages = SendQueue.dueMessages(repository: repository)
    }

    private func handle(_ result: MessageComposeResult, for message: PlannedMessage) {
        switch result {
        case .sent:
            finish(message, status: .sent)
        case .failed:
            isSendingAll = false
        case .cancelled:
            isSendingAll = false
        @unknown default:
            isSendingAll = false
        }
    }

    private func finish(_ message: PlannedMessage, status: DeliveryStatus, note: String = "") {
        SendQueue.record(message, status: status, note: note, repository: repository)
        reload()
        guard isSendingAll else { return }
        if let next = messages.first(where: { $0.key != message.key }) {
            // Let the previous sheet finish dismissing before presenting the next.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                composing = next
            }
        } else {
            isSendingAll = false
        }
    }
}

private struct QueueRow: View {
    let message: PlannedMessage
    let onSend: () -> Void
    let onMarkSent: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.recipientName.isEmpty ? HandleNormalizer.displayFormat(message.handle) : message.recipientName)
                        .font(.headline)
                    Text(message.reminderTitle.isEmpty ? "Reminder" : message.reminderTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.occurrence, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack {
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Menu {
                    Button("Mark as sent", systemImage: "checkmark", action: onMarkSent)
                    Button("Skip this one", systemImage: "forward", role: .destructive, action: onSkip)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Presenting the compose sheet

extension View {
    /// Presents the Messages compose sheet for `message`, or a fallback alert on
    /// devices that cannot send texts (Simulator, some iPads).
    func messageComposer(
        _ message: Binding<PlannedMessage?>,
        onResult: @escaping (PlannedMessage, MessageComposeResult) -> Void
    ) -> some View {
        modifier(MessageComposerModifier(message: message, onResult: onResult))
    }
}

private struct MessageComposerModifier: ViewModifier {
    @Binding var message: PlannedMessage?
    let onResult: (PlannedMessage, MessageComposeResult) -> Void

    private var canSend: Bool { MessageComposeView.canSendText }

    func body(content: Content) -> some View {
        content
            .sheet(item: canSend ? $message : .constant(nil)) { item in
                MessageComposeView(recipients: [item.handle], body: item.text) { result in
                    message = nil
                    onResult(item, result)
                }
                .ignoresSafeArea()
            }
            .alert(
                "This device can't send messages",
                isPresented: Binding(
                    get: { !canSend && message != nil },
                    set: { if !$0 { message = nil } }
                ),
                presenting: message
            ) { item in
                Button("Copy message") {
                    UIPasteboard.general.string = item.text
                    message = nil
                }
                Button("Mark as sent") {
                    message = nil
                    onResult(item, .sent)
                }
                Button("Cancel", role: .cancel) {
                    message = nil
                }
            } message: { item in
                Text("Messages isn't available here (for example in the Simulator). Copy the text to send it to \(item.handle) another way.")
            }
    }
}
