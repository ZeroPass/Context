# Context

**Your coding sessions. Back in context.**

Working with coding agents means keeping track of more than code: which
conversation belongs to which project, which Terminal tabs you had open, how
much account usage is left, and where the agent put its results.

Context brings those pieces together. Find the right session, pick up where
you left off, and keep reports and files beside the work instead of scattered
across terminal scrollback and external apps.

A Windows desktop companion for **Codex, Claude Code, Kimi Code, OpenCode,
Qwen Code, Muse, and ZCode**, built around WSL workflows.

[Get Started](#get-started) | [Whiteboard](#keep-the-results-next-to-the-work) | [Build](#build-context) | [Full Guide](docs/GUIDE.md)

![Context with grouped coding sessions, Codex account pacing, and a Whiteboard report preview](./Context%20app%20screenshoot.png)

## What Context Solves

| Instead of... | You get... |
| --- | --- |
| Hunting through history for the right conversation | A named, searchable session library across coding agents. |
| Rebuilding your Terminal workspace each time | Remembered tab groups that reopen only the sessions that are missing. |
| Finding out too late that an account is nearly exhausted | Codex usage, reset times, and pacing in one view. |
| Losing useful outputs in terminal scrollback | A shared Whiteboard for finished answers, reports, images, videos, and files. |

## Find the Conversation. Continue the Work.

Give sessions names that mean something to you. Keep related work in color
groups, drag it into the order you want, and filter the whole library as you
type. Your list is saved as an ordinary Markdown file, with autosave on by default.

Click to copy a resume command, or choose to open sessions directly in Ubuntu
tabs in Windows Terminal. Recent sessions help you recover work you have not
saved yet; add one without retyping its name or session ID. Fork where the
agent supports it, without inventing commands for those that do not.

Context sits beside the agents you already use. You keep their native TUIs,
tools, and workflows; you get a better way to find and return to them.

## Bring Your Workspace Back

The **Terminal tabs** card shows running coding agents grouped by Terminal
window. Recognize sessions by your saved names rather than a row of anonymous tabs.

Closing an individual tab updates the active group. Closing the whole window
keeps its last observed set of sessions, ready to restore later. Reopening a
group skips anything already open, so restoring work does not mean duplicating it.

## Know What Is Left Before You Run Out

Codex account cards bring sign-in switching, usage, reset times, and pacing
together. See not just the allowance left, but whether you are spending it faster
or slower than the time remaining before reset.

Save accounts under names you recognize and switch between them without
manually juggling credential files. Each account keeps its own reported reset;
temporary manual overrides can be edited, removed, or left to expire.

You can also arm a one-time model downgrade for a reset or a delay in hours,
rather than remembering to change the model later. Account switching and
pacing are Codex-specific; integration capabilities differ between providers.

## Keep the Results Next to the Work

**Whiteboard is a shared space between you and your agents.**

Ask an agent to publish its finished answer, report, or files. The newest six
publications stay in a slim tab strip, with formatted output and local previews
together in one pane. It is a deliberate handoff, not another full chat history
to search through.

Open images, videos, and Markdown without leaving Context. Browse a report's
attachments, zoom in, expand a preview across the app, and copy or save what
you need. File-location controls help you get back to the source.

It works the other way too: drag in a file, folder, image, or text, or paste with
**Ctrl+V**. Preview what you dropped, then copy a short handoff prompt for an
agent to work on it. No need to explain the same file location from scratch.

Use **Copy first prompt** beside the Whiteboard tabs to introduce an agent to
your board. The prompt includes the active file's location; publishing rules
live in its header. In a configured workspace, **`wb.md`** refers to that board.

Whiteboard lives beside your session library, separated by a draggable divider.
Show or hide it when needed; Context remembers your layout. Choose light, dark,
sepia, or dusk, with your own accent and group colors.

## Get Started

1. [Build Context](#build-context), then install `Context.appx`.
2. In **Settings**, choose your sessions Markdown file or create an example.
3. Add sessions yourself or save them from the provider's recent-session list.
4. Turn on **Whiteboard** and use **Copy first prompt** to introduce it to an agent.

Install and sign in to your coding agents separately in WSL. To open sessions
directly, enable **Open sessions in Terminal** in Settings; right-click still
offers copying. ZCode remains copy-only.

Context can ask for Windows administrator approval at startup to reuse an
elevated Terminal without asking for every new tab. This is configurable.

## Your Files Stay Yours

The session library and Whiteboard are local Markdown files. Pasted attachments
and handoff notes stay local too; Whiteboard does not upload them.
Existing files dropped onto it are referenced in place, not copied or deleted.

Session files, publications, attachments, and saved credentials are private
local data and must not be committed or shared. Account features contact their
provider APIs. See the [guide](docs/GUIDE.md) for storage, cleanup, and platform limits.

## Build Context

From PowerShell in this project folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1
```

Or double-click **`Build_APPX.bat`**. The result is `Context.appx` in the project root.
The included packaging scripts can provision prerequisites and create a local
signing certificate, with Windows approval where required. Another machine
must trust that certificate before installing a self-signed package.

[Windows build guide](BUILD_WINDOWS_APPX_POWERSHELL.md) covers setup, portable
output, WSL/UNC builds, and certificate troubleshooting.

Built with **Flutter, Rust, and [Rinf](https://pub.dev/packages/rinf)**.
Developer commands, regression checks, and detailed behavior are in the [full guide](docs/GUIDE.md).

## License

Dual-licensed under [LGPL v3](LICENSE.LGPL) and a
[commercial license](LICENSE.COMMERCIAL). Bundled third-party components retain
their own licenses.
