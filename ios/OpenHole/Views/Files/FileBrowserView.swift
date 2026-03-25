import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var settings: AppSettings
    @State private var currentPath: String = "~"
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedFile: FileEntry?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loadDirectory() } }
                    }
                } else {
                    List {
                        if currentPath != "~" && currentPath != "/" {
                            Button {
                                let parent = (currentPath as NSString).deletingLastPathComponent
                                currentPath = parent.isEmpty ? "/" : parent
                                Task { await loadDirectory() }
                            } label: {
                                Label("..", systemImage: "folder")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(entries) { entry in
                            FileRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if entry.isDirectory {
                                        currentPath = entry.fullPath
                                        Task { await loadDirectory() }
                                    } else {
                                        selectedFile = entry
                                    }
                                }
                        }
                    }
                    .refreshable { await loadDirectory() }
                }
            }
            .navigationTitle(currentPath.split(separator: "/").last.map(String.init) ?? "Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if currentPath != "~" && currentPath != "/" {
                        Button {
                            let parent = (currentPath as NSString).deletingLastPathComponent
                            currentPath = parent.isEmpty ? "/" : parent
                            Task { await loadDirectory() }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(currentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .sheet(item: $selectedFile) { file in
                FileContentView(file: file)
            }
            .task {
                currentPath = settings.workingDirectory
                await loadDirectory()
            }
        }
    }

    private func loadDirectory() async {
        guard connection.isConnected else {
            error = "Not connected"
            return
        }

        isLoading = true
        error = nil

        do {
            let output = try await connection.executeCommand("ls -la \(currentPath) 2>/dev/null")
            entries = parseLsOutput(output, basePath: currentPath)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func parseLsOutput(_ output: String, basePath: String) -> [FileEntry] {
        output.split(separator: "\n")
            .dropFirst() // "total N" line
            .compactMap { line -> FileEntry? in
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard parts.count >= 9 else { return nil }
                let name = String(parts[8])
                guard name != "." && name != ".." else { return nil }

                let perms = String(parts[0])
                let isDir = perms.hasPrefix("d")
                let size = Int(parts[4]) ?? 0
                let fullPath = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"

                return FileEntry(
                    name: name,
                    fullPath: fullPath,
                    isDirectory: isDir,
                    size: size,
                    permissions: perms
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

struct FileEntry: Identifiable {
    let id = UUID()
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let size: Int
    let permissions: String
}

struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon)
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                if !entry.isDirectory {
                    Text(formatSize(entry.size))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var fileIcon: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "js", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "md", "txt", "rtf":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        default:
            return "doc"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
