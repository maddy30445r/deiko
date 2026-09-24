import Foundation

/// What of a page's address Deiko keeps: host (with port) and path. Never the
/// query or the fragment — they carry session tokens, reset links and search
/// terms, and nothing about WHICH page this is. Pure, so it is tested without
/// a browser.
public enum PageURL {
    public static func trim(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw),
              parts.scheme == "http" || parts.scheme == "https",
              let host = parts.host, !host.isEmpty
        else { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        let path = parts.path == "/" ? "" : parts.path
        return host.lowercased() + port + path
    }

    /// `AXDocument` arrives as a file URL (`file:///Users/…/App.tsx`) or,
    /// from some apps, a bare path.
    public static func documentPath(_ raw: String) -> String? {
        if raw.hasPrefix("/") { return raw }
        guard let url = URL(string: raw), url.isFileURL else { return nil }
        return url.path
    }
}
