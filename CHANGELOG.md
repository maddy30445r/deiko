# Changelog

Notable changes to Deiko. Earlier releases are on
[deiko.app/changelog](https://deiko.app/changelog).

## [Unreleased]

### Added
- A Claude Code Stop hook: an agent about to finish a Deiko brief without saving its report is asked to save it first. Added with the memory server from Settings.

## [0.5.7] — 2026-09-29

### Fixed
- A piece of work is named after what you asked, not after whichever file was open in your editor.

## [0.5.6] — 2026-09-29

### Added
- Pointing back: "remember the pricing fixes? In that task, make the page pink" joins that earlier work. When two could fit, the card asks which one.
- Short follow-ups ask "Same work?" when Deiko is fairly sure, instead of starting something new.
- A brief that starts new work tells your agent it can search your earlier work.

### Fixed
- Every brief gets its summary, and matching reads all of it rather than the first line.

## [0.5.5] — 2026-09-29

### Added
- Agents report back: Claude Code, Cursor and Codex save what they did, decided and left open, so the next chat on that work starts there.
- `list_tasks` in the memory server: an agent can see every piece of work in a project and where each stands.
- New briefs carry the decisions that still hold.
- Browser chats (ChatGPT, Claude.ai) get the work's history brief by brief.

## [0.5.4] — 2026-09-27

### Added
- Edit and forget any note Deiko remembers; your agent gets your version from the next brief.
- Search by meaning, including mixed-language queries.
- Pick this up, project rules, hand-off as Markdown, and a weekly summary on the Dashboard.

## [0.5.3] — 2026-09-26

### Added
- Offline filing queue: briefs still reach your agent, and file themselves once back online.
- "Same work?" on briefs Deiko filed on its own.
- Export memory to a single archive.

### Changed
- Task notes only state what comes from confirmed briefs, and cite the brief behind each line.
- Large boards re-read only the briefs that changed.

[0.5.7]: https://github.com/maddy30445r/deiko/releases/tag/v0.5.7
[0.5.6]: https://github.com/maddy30445r/deiko/releases/tag/v0.5.6
[0.5.5]: https://github.com/maddy30445r/deiko/releases/tag/v0.5.5
[0.5.4]: https://github.com/maddy30445r/deiko/releases/tag/v0.5.4
[0.5.3]: https://github.com/maddy30445r/deiko/releases/tag/v0.5.3
