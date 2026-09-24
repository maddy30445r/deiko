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

@Test("a document is a POSIX path, from a file URL or already one")
func documentPathFromFileURL() {
    #expect(PageURL.documentPath("file:///Users/dev/acme-portal/src/App.tsx") == "/Users/dev/acme-portal/src/App.tsx")
    #expect(PageURL.documentPath("/Users/dev/notes.md") == "/Users/dev/notes.md")
    #expect(PageURL.documentPath("https://x.dev/a") == nil)
}
