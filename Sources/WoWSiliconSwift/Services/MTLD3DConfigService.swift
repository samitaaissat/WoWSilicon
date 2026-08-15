import Foundation

enum MTLD3DConfigServiceError: LocalizedError {
    case gamePathMissing
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .gamePathMissing:
            return "Game path is not set. Configure it before adjusting the cursor size."
        case .writeFailed(let details):
            return "Failed to update mtld3d.conf: \(details)"
        }
    }
}

/// Reads/writes the `cursor.scale` key in the game folder's mtld3d.conf —
/// the mtld3d counterpart of DXVKConfigService's `d3d9.enlargeHardwareCursor`.
/// A multiplier of 1 removes the line so mtld3d's own default (`auto`) applies.
/// Only uncommented lines count: the shipped sample documents every key as a
/// `# key = value` comment, which must stay untouched documentation.
enum MTLD3DConfigService {
    static func cursorSizeMultiplier(gamePath: String) -> Int? {
        let trimmed = gamePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true).appendingPathComponent("mtld3d.conf", isDirectory: false)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in content.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("cursor.scale") else { continue }
            guard let valueComponent = line.split(separator: "=").last else { continue }
            // Non-numeric values (the upstream default `auto`) read as "unset".
            if let value = Int(valueComponent.trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    static func setCursorSizeMultiplier(gamePath: String, multiplier: Int) throws {
        let trimmed = gamePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MTLD3DConfigServiceError.gamePathMissing }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true).appendingPathComponent("mtld3d.conf", isDirectory: false)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        // Removal on a file we never created is a no-op — don't materialize an
        // empty mtld3d.conf just to hold nothing.
        if multiplier <= 1 && existing == nil { return }
        let content = updateCursorScaleLine(content: existing ?? "", multiplier: multiplier)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MTLD3DConfigServiceError.writeFailed(error.localizedDescription)
        }
    }

    private static func updateCursorScaleLine(content: String, multiplier: Int) -> String {
        if multiplier <= 1 {
            return removeCursorScaleLine(content: content)
        }

        let pattern = "(?m)^\\s*cursor\\.scale\\s*=\\s*\\S+\\s*$"
        let replacement = "cursor.scale = \(multiplier)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(content.startIndex..., in: content)
            if regex.firstMatch(in: content, options: [], range: range) != nil {
                return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: replacement)
            }
        }
        var newContent = content
        if !newContent.isEmpty && !newContent.hasSuffix("\n") {
            newContent += "\n"
        }
        newContent += replacement + "\n"
        return newContent
    }

    private static func removeCursorScaleLine(content: String) -> String {
        let pattern = "(?m)^\\s*cursor\\.scale\\s*=\\s*\\S+\\s*$\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        let updated = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
        return updated.replacingOccurrences(of: "\n\n", with: "\n")
    }
}
