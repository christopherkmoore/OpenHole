import SwiftUI

struct FileContentView: View {
    let file: FileEntry
    @EnvironmentObject var connection: SSHConnectionManager
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading \(file.name)...")
                } else if let error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else {
                    ScrollView(.horizontal) {
                        ScrollView(.vertical) {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadContent()
            }
        }
    }

    private func loadContent() async {
        do {
            content = try await connection.executeCommand("cat \(file.fullPath) 2>/dev/null")
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}
