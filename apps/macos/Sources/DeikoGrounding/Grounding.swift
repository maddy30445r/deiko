import Foundation

/// Roles whose `description` labels a control rather than holding content.
/// Kept short: most controls carry meaningful labels.
private let presentationalRoles: Set<String> = [
    "AXImage",
    "AXDisclosureTriangle",
]

/// Whether this element's text identifies content the user could have meant.
///
/// `value`, `selectedText` and `title` are content. `description` is an
/// author-supplied label and counts only on a non-presentational role (an
/// icon's alt text names the widget, not the data). Takes plain strings so it
/// is testable without an `AXUIElement`. Erring towards "not content" is safe:
/// the caller keeps descending and reads the crop with OCR either way.
public func groundsContent(
    role: String?,
    value: String? = nil,
    title: String? = nil,
    description: String? = nil,
    selectedText: String? = nil
) -> Bool {
    // Whitespace is not text: a padded cell must not count as grounded.
    func present(_ s: String?) -> Bool {
        s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    if present(value) || present(selectedText) || present(title) { return true }

    // Only `description` is left; trust it unless the role marks it a widget label.
    guard present(description) else { return false }
    return !presentationalRoles.contains(role ?? "")
}
