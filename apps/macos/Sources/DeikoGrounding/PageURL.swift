import Foundation

/// What of a page's address Deiko keeps: host (with port) and path. Never the
/// query or fragment, which carry session tokens and search terms.
public enum PageURL {
    public static func trim(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw),
              parts.scheme == "http" || parts.scheme == "https",
              let host = parts.host, !host.isEmpty
        else { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        // `percentEncodedPath`, not `path`: the latter decodes, so a `%3F` or
        // `%0A` would become a literal `?` or newline in the label. Cut at the
        // first `;` too: a path parameter such as `;jsessionid=` is session state.
        let rawPath = String(parts.percentEncodedPath.prefix(while: { $0 != ";" }))
        let path = rawPath == "/" ? "" : rawPath
        return host.lowercased() + port + path
    }

    /// The same query/fragment/userinfo strip as `trim`, for a value that need
    /// not be http(s) or a page (an `AXURL`, `AXDocument` or link `AXValue`).
    /// Unlike `trim` it keeps the scheme, so a `file://` document survives.
    public static func withoutQuery(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return raw }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? raw
    }

    /// `AXDocument` arrives as a file URL or, from some apps, a bare path.
    public static func documentPath(_ raw: String) -> String? {
        if raw.hasPrefix("/") { return raw }
        guard let url = URL(string: raw), url.isFileURL else { return nil }
        return url.path
    }
}
