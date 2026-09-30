import SwiftUI

/// Explicit browser destinations; opening history itself never contacts GitHub.
enum ProjectLinks {
    static let releases = URL(string: "https://github.com/cyruss648/menu-tidy/releases")!
    static let issues = URL(string: "https://github.com/cyruss648/menu-tidy/issues")!
    static let changelog = URL(string: "https://github.com/cyruss648/menu-tidy/blob/main/CHANGELOG.md")!
}

struct ReleaseHistoryView: View {
    let currentVersion: String
    @Environment(\.dismiss) private var dismiss
    private let entries: [HistoryEntry] = HistoryEntry.bundled()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("更新记录", systemImage: "clock.arrow.circlepath")
                        .font(.title2.weight(.semibold))
                    Text("当前版本 \(currentVersion) · 随应用附带，可离线阅读")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Label("此安装包未附带更新记录，请查看 GitHub 上的完整日志。",
                              systemImage: "doc.text")
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HistoryCard(entry: entry, initiallyExpanded: index == 0)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text("最新发布与完整历史记录可在 GitHub 查看。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("完整日志 ↗", destination: ProjectLinks.changelog)
                Link("GitHub 发布 ↗", destination: ProjectLinks.releases)
            }
            .font(.callout)
            .padding(20)
        }
        .frame(width: 720, height: 580)
    }
}

private struct HistoryEntry {
    let title: String
    let lines: [String]

    static func bundled() -> [Self] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n## [").dropFirst().compactMap { section in
            let lines = section.components(separatedBy: "\n")
            guard let heading = lines.first, !heading.hasPrefix("Unreleased]") else { return nil }
            return Self(title: heading.replacingOccurrences(of: "]", with: ""),
                        lines: Array(lines.dropFirst()).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }
}

private struct HistoryCard: View {
    let entry: HistoryEntry
    @State private var expanded: Bool

    init(entry: HistoryEntry, initiallyExpanded: Bool) {
        self.entry = entry
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("### ") {
                        Text(String(line.dropFirst(4)))
                            .font(.callout.weight(.semibold)).padding(.top, 6)
                    } else {
                        Text(markdown(line))
                            .font(.callout).lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Text(entry.title).font(.headline).padding(.vertical, 4)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.065)))
    }

    private func markdown(_ line: String) -> AttributedString {
        let source = line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line
        // Resolve repository-relative documentation links against the installed version's source.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let base = URL(string: "https://github.com/cyruss648/menu-tidy/blob/v\(version ?? "0.6.1")/")
        return (try? AttributedString(markdown: source,
                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
                                     baseURL: base)) ?? AttributedString(source)
    }
}
