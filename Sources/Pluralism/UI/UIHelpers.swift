import AppKit
import PluralismCore
import SwiftUI
import UniformTypeIdentifiers

/// Farbiger Punkt plus Text für den Laufzustand.
struct StatusBadge: View {
    let state: VMRunState

    var color: Color {
        switch state {
        case .running: return .green
        case .paused: return .yellow
        case .starting, .restoring, .saving, .stopping: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Symbol für das Gastsystem.
struct GuestIcon: View {
    let os: GuestOS
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: os == .windows ? "pc" : "terminal")
            .font(.system(size: size, weight: .regular))
            .frame(width: size * 1.6, height: size * 1.6)
            .foregroundStyle(os == .windows ? Color.blue : Color.orange)
    }
}

enum Format {
    static func memory(mib: Int) -> String {
        if mib % 1024 == 0 {
            return "\(mib / 1024) GB"
        }
        return String(format: "%.1f GB", Double(mib) / 1024)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Datei- und Ordnerauswahl über NSOpenPanel.
@MainActor
enum FilePicker {
    static func chooseFile(title: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExecutable(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Kleiner Hinweistext in Formularen.
struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
