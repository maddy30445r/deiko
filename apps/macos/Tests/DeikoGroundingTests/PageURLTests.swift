import Testing
@testable import DeikoGrounding

@Test("a page address keeps host and path, never the query or fragment")
func pageURLKeepsHostAndPath() {
    #expect(PageURL.trim("https://build.example.com/users/8812?token=abc#top") == "build.example.com/users/8812")
    #expect(PageURL.trim("http://localhost:3000/signups") == "localhost:3000/signups")
    #expect(PageURL.trim("https://Example.com/") == "example.com")
    #expect(PageURL.trim("chrome://newtab/") == nil)
    #expect(PageURL.trim("file:///Users/dev/a.html") == nil)
    #expect(PageURL.trim("not a url") == nil)
}

@Test("a `;` path parameter is dropped, and the path is never percent-decoded")
func pageURLDropsPathParameters() {
    #expect(PageURL.trim("https://shop.example.com/cart;jsessionid=ABCDEF123456?x=1") == "shop.example.com/cart")
    #expect(PageURL.trim("https://example.com/a%3Fb%0Ac") == "example.com/a%3Fb%0Ac")
}

@Test("withoutQuery strips query, fragment and userinfo from any URL, not only http(s)")
func withoutQueryStripsSensitiveParts() {
    #expect(PageURL.withoutQuery("https://x.dev/reset?token=abc#frag") == "https://x.dev/reset")
    #expect(PageURL.withoutQuery("https://user:secret@example.com/a?x=1") == "https://example.com/a")
    #expect(PageURL.withoutQuery("file:///Users/dev/App.tsx") == "file:///Users/dev/App.tsx")
}

@Test("a document is a POSIX path, from a file URL or already one")
func documentPathFromFileURL() {
    #expect(PageURL.documentPath("file:///Users/dev/acme-portal/src/App.tsx") == "/Users/dev/acme-portal/src/App.tsx")
    #expect(PageURL.documentPath("/Users/dev/notes.md") == "/Users/dev/notes.md")
    #expect(PageURL.documentPath("https://x.dev/a") == nil)
}
