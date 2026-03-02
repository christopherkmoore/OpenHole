import SwiftUI

struct SessionPickerView: View {
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var settings: AppSettings
    @StateObject private var loader = SessionListLoader()
    @State private var isCreating = false
    @State private var editingSessionId: String?
    @State private var editText = ""
    @FocusState private var editFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isCreating {
                    ProgressView("Starting new session...")
                } else if loader.isLoading {
                    ProgressView("Loading sessions...")
                } else if let error = loader.error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loader.load(ssh: connection) } }
                    }
                } else if loader.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new session to get going.")
                    }
                } else {
                    List {
                        ForEach(loader.sessions) { info in
                            if editingSessionId == info.id {
                                SessionRowEditing(
                                    info: info,
                                    isActive: info.id == session.sessionId,
                                    text: $editText,
                                    focused: $editFocused,
                                    onCommit: { commitEdit(for: info.id) }
                                )
                            } else {
                                Button {
                                    Task {
                                        await session.resumeExistingSession(id: info.id, settings: settings)
                                        dismiss()
                                    }
                                } label: {
                                    SessionRow(
                                        info: info,
                                        isActive: info.id == session.sessionId,
                                        customTitle: settings.sessionTitles[info.id]
                                    )
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            if info.id == session.sessionId {
                                                session.clearActiveSession(settings: settings)
                                            }
                                            settings.sessionTitles.removeValue(forKey: info.id)
                                            await loader.delete(id: info.id, ssh: connection)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        editText = settings.sessionTitles[info.id] ?? info.firstMessage
                                        editingSessionId = info.id
                                        editFocused = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                        Task {
                            session.clearActiveSession(settings: settings)
                            await session.createNewSession(settings: settings)
                            isCreating = false
                            dismiss()
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .disabled(isCreating)
                }
            }
            .task {
                await loader.load(ssh: connection)
            }
            .refreshable {
                await loader.load(ssh: connection)
            }
            .onChange(of: editFocused) { _, focused in
                if !focused, editingSessionId != nil {
                    commitEdit(for: editingSessionId!)
                }
            }
        }
    }

    private func commitEdit(for id: String) {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.sessionTitles.removeValue(forKey: id)
        } else {
            settings.sessionTitles[id] = trimmed
        }
        editingSessionId = nil
    }
}

// MARK: - Session Row (display mode)

struct SessionRow: View {
    let info: SessionInfo
    let isActive: Bool
    var customTitle: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    Text(customTitle ?? info.firstMessage)
                        .font(.body)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Text(info.timeAgo)
                    Text("\(info.messageCount) msgs")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Session Row (editing mode)

struct SessionRowEditing: View {
    let info: SessionInfo
    let isActive: Bool
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    TextField("Session title", text: $text)
                        .font(.body)
                        .focused(focused)
                        .onSubmit(onCommit)
                }

                HStack(spacing: 8) {
                    Text(info.timeAgo)
                    Text("\(info.messageCount) msgs")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCommit) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
