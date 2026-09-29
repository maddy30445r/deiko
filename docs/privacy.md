# Privacy

Deiko sees your screen and hears your voice, so this page says exactly what is
stored, what is sent, and to whom.

## Stored on your Mac

Everything Deiko keeps lives in `~/Library/Application Support/Deiko`: your
briefs, the screenshots you kept, transcripts, task notes and the board. It is
never uploaded or synced. Recordings are deleted as soon as a brief is made.

Nothing is captured unless a session is running, and a red bar sits at the top
of the screen for as long as one is. Clicking it stops the session.

## Sent for processing

| What | Where | When |
|---|---|---|
| Your voice recording | Groq (Whisper), directly with your key or through the relay | Transcription; offline or past the free minutes, Apple's on-device recogniser is used instead and nothing is sent |
| Your transcript | Groq, directly with your key or through the relay | Writing the brief's summary |
| What you said, its summary, window and page titles, web addresses (host and path only), open document names, and notes on your earlier work | Jev (via OpenRouter), through the relay | Filing the brief into a task |

The relay keeps none of it: no audio or text is written to disk, and its logs
hold only a timestamp, the route, the status and a short fingerprint of the
install's token. Screenshots, OCR text and accessibility text are never sent
to the relay or to any model provider.

Turn off "Sort briefs into tasks" in Settings and nothing is sent for filing;
a new brief then joins earlier work only when you move it there, or when it is
a short follow-up in the same window.

## Sent to your agent

The brief, including any screenshots it kept, goes to the agent you hand it
to (Claude Code, Cursor, Codex or a browser chat), under that agent's own
terms. If a screenshot shows a credential, Deiko withholds it and says so in
the brief.

## The install token

The relay identifies an install by a salted hash of the Mac's hardware id.
The id itself is never stored or sent. It meters the free allowance and
survives a reinstall, which is why a reinstall doesn't restore it.
