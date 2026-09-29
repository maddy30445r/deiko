# Task memory

Deiko remembers your work as tasks: every brief is filed into the piece of
work it continues, and each task keeps a note of where it stands, what was
decided and what each agent reported. The next brief on that work carries the
note, so a new chat starts where the last one stopped.

## The board

The app's window shows every task and brief. From there you can:

- open a brief to see what you said, the screenshots and what the agent sent back;
- move a brief between tasks, or answer "Same work?" when Deiko filed it on its own;
- edit or forget any line in a task's note (your agent gets your version from the next brief);
- **Pick this up**, so your next brief joins that task from its first word;
- pin up to five project rules ("we use pnpm") that every brief in the project carries;
- search by keyword or by meaning, and hand a task off as Markdown.

## The memory server

Agents that speak the Model Context Protocol can read and write this memory
directly. In Settings → Memory, **Give your agent your Deiko memory** adds the
server to the agents found on your Mac: Claude Code, Codex, Cursor, Gemini
CLI, VS Code and Antigravity.

| Tool | What it does |
|---|---|
| `search_briefs` | Find earlier briefs by what was said, shown or reported |
| `list_tasks` | Every task, optionally for one project, with its status and where it stands |
| `get_task` | One task's note and its briefs |
| `get_brief` | One brief: its prompt, summary, the agent's report and kept screenshots |
| `save_outcome` | Record what the agent did for a brief: Did, Decided, Open, Files |

The server runs locally over stdio (`packages/core/src/memory-mcp.mjs`) and
only reads and writes files on your Mac. Everything it returns is marked as
data, never as instructions to follow.

## Reports from agents

Each brief asks the agent to call `save_outcome` when it finishes. In Claude
Code, connecting memory also adds a Stop hook
([`claude-stop-hook.mjs`](../packages/core/src/claude-stop-hook.mjs)): if the
agent is about to finish a Deiko brief without saving, it is asked once to do
so.

The report feeds the task's note: "Decided" lines carry into later briefs until an agent
retires them, and "Open" lines become the task's to-do. Browser chats can't
call tools, so their briefs carry the task's history brief by brief instead.
