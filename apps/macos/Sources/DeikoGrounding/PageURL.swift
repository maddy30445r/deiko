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
        // `percentEncodedPath`, not `path`: the latter decodes as it goes, so
        // a `%3F` or a `%0A` inside the path would turn into a literal `?` or
        // newline in the label. Cut at the first `;` too — a path parameter
        // such as `;jsessionid=…` is session state, exactly the kind of thing
        // the query is already kept out for.
        let rawPath = String(parts.percentEncodedPath.prefix(while: { $0 != ";" }))
        let path = rawPath == "/" ? "" : rawPath
        return host.lowercased() + port + path
    }

    /// The same query/fragment/userinfo strip as `trim`, but for a value that
    /// is not necessarily http(s) or even a page — an arbitrary CFURL an
    /// accessibility attribute (`AXURL`, `AXDocument`, a link's `AXValue`)
    /// can hand back whole. Kept separate from `trim`, which also narrows to
    /// host+path and refuses non-http(s) schemes — a `file://` AXDocument
    /// needs to survive this one unchanged.
    public static func withoutQuery(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return raw }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? raw
    }

    /// `AXDocument` arrives as a file URL (`file:///Users/…/App.tsx`) or,
    /// from some apps, a bare path.
    public static func documentPath(_ raw: String) -> String? {
        if raw.hasPrefix("/") { return raw }
        guard let url = URL(string: raw), url.isFileURL else { return nil }
        return url.path
    }
}
