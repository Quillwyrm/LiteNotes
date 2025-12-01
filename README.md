![LiteMark](logo.png)

LiteMark is a lightweight Markdown reader and project-notes plugin for [Lite XL](https://github.com/lite-xl/lite-xl).

It adds a dedicated “read mode” view for `.md` files and an optional per-project scratch-notes file.

## Features:

- **Markdown read view**
  - Render any `.md` file in a clean, non-editable view.
  - Uses Lite XL’s theme colors (`style.text`, `style.syntax[...]`) so it matches your current theme.

- **Per-project notes**
  - One notes file per project, stored under `USERDIR/project_notes/`.
  - Opened via a dedicated command, independent of whatever file you’re currently editing.

- **Read / Edit modes**
  - Double-click inside the read view to switch to a normal editor view for that document.
  - Leaving the edit view automatically saves and returns to read mode.

- **Code fences with syntax highlighting**
  - If LiteXL has a syntax for the given `lang`, the code is tokenized and colored.
  - Code blocks are rendered with a shaded background.

- **Custom status bar**
  - Shows `READ` or `EDIT` on the right when the active view is a LiteMark view.
  - Shows the current document path on the left.

- **Context menu integration**
  - Right-click in a `.md` `DocView` → “View Markdown” to open the same buffer in LiteMark.
    

## Example:

![LiteMark](Example.png)
- **Markdown rendering in your editor!**

## Usage Guide:

### Commands

LiteMark registers these commands in the command palette:

- **`LiteMark: View Current Markdown`**
  - If the active view is a `DocView` with a `.md` filename, opens a LiteMark read view for the same document.
  - If the current file is not Markdown, shows an error and does nothing.

- **`LiteMark: View Project Notes`**
  - Opens the per-project notes file in a LiteMark read view.
  - Creates the notes file if it does not exist yet.

There is also an alias `litemark:note` which currently just delegates to “View Current Markdown”.

### Read / Edit workflow

- Open a `.md` file in Lite XL as usual.
- Use:
  - the command palette (`LiteMark: View Current Markdown`), or
  - the right-click context menu → **View Markdown**
- You’ll see the LiteMark read view for that document.
- **Double-click inside the read view** to drop into a normal editor for the same buffer.
- When you move focus away from the edit view, it auto-saves and swaps back to the read view.

### Project notes

- `LiteMark: View Project Notes` chooses a notes file based on the current project root and opens it in read mode.
- Notes are stored under `USERDIR/project_notes/` using a sanitized project name, so they don’t clutter your project tree.

## Markdown coverage:

LiteMark aims to cover the common, everyday Markdown you see in READMEs and notes, not the entire CommonMark + extensions ecosystem.

**Block-level features:**

- ATX headings: `#` through `######`
- Paragraphs: separated by one or more blank lines
- Unordered lists: `-`, `*`, or `+`
- Ordered lists: `1.`, `2.`, …
- Task lists: `- [ ]` and `- [x]`
- Horizontal rules: `---`
- Fenced code blocks: ```` ```lang ... ``` ```` with optional language label

**Inline features:**

- Bold: `**text**` or `__text__`
- Italic: `*text*` or `_text_`
- Inline code: `` `code` ``
- Strikethrough: `~~text~~`

Everything else is treated as plain text (still laid out nicely, just without special semantics).

## Not *(yet)* supported:

These are intentionally **not** handled specially right now:

- Setext headings (`Title` followed by `====` or `----`)
- Links and autolinks: `[label](url)`, `<https://example.com>`
- Images: `![alt](path.png)`
- Tables
- Blockquotes: `> quoted text`
- Inline HTML blocks
- Footnotes, math, admonitions, or other extension syntax

If you use these, they will still render as readable text, just without special styling or layout.

---

