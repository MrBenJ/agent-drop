# AgentDrop.app manual test checklist

Spec §8: the app's models are unit-tested; its UI is checked by hand against this list.
Run it on a Mac where you don't mind the app's real setup, or on a fresh user account.
Build first: `Scripts/build-app.sh && cp -R .build/AgentDrop.app /Applications/`.

Reset to a first run: quit the app, then
`rm ~/Library/Application\ Support/AgentDrop/config.json` (this keeps your drops; it
only forgets setup and settings).

## First run (spec §2)
- [ ] `open /Applications/AgentDrop.app`: the setup window appears, shows `~/AgentDrop`,
      and "Start Agent Drop at login?" has **Yes** selected.
- [ ] Before finishing: `~/AgentDrop` was not created by the app, and
      `drop watch --inbox` exits 1 with "hasn't been set up yet".
- [ ] **Change…** to `~/Desktop/AgentDrop`: the protected-folder explanation appears.
      **Finish Setup**: macOS asks for Desktop access *after* the explanation.
- [ ] After setup: System Settings → General → Login Items lists Agent Drop.
- [ ] `drop open <id>` before setup (`drop add` works without the app): finishing setup
      then shows that drop.

## Menu bar (spec §6)
- [ ] The icon shows the unread count; `drop add x.md --from me` raises it within a second.
- [ ] The dropdown lists the 10 most recent drops (unread dot, title, project, from, time),
      then the Inbox, then Open Agent Drop / Settings… / Quit.
- [ ] Clicking a drop opens the window on it and clears its unread dot.
- [ ] Quit, then `ls ~/Library/Application\ Support/AgentDrop/`: no `server.json`.

## Window
- [ ] Closing the window leaves the menu bar icon; the Dock icon reopens the window.
- [ ] Sidebar: All Drops, Inbox (count), Handoffs (grouped open/claimed/done),
      Unregistered (count), Archived, Projects/Tags/From. A `--from a/b/c` value shows as a tree.
- [ ] The search field shows in the window's toolbar and filters by title, description and filename.
- [ ] A Markdown drop renders with tables, task lists and code blocks; dark mode follows
      the system; a relative image next to it shows; an `https://` link opens the browser;
      a `<script>` in the file does nothing.
- [ ] A `.swift` or `.txt` drop shows monospace text; an image or PDF shows Quick Look.
- [ ] A folder drop shows its tree above the rendered README; a symlink inside it shows
      as `name → target` and is never previewed.
- [ ] Open in VS Code opens the file (a folder drop opens as a workspace). With `code`
      not installed, the button is disabled with a tooltip.
- [ ] Reveal in Finder, Copy Path, Copy `drop cat <id>` (`drop path` for folders) work.
- [ ] Handoff buttons: Release on a claimed drop, Mark Done… with a note, Reopen.
      `drop show <id> --json` agrees after each.
- [ ] Edit Metadata: the Kind picker is disabled while claimed or done.
- [ ] Archive / Unarchive moves the drop between All Drops and Archived.
- [ ] Delete a drop's file in Finder: it greys out; **Remove Record…** removes it.
- [ ] Put a file in `~/AgentDrop` by hand: it appears under Unregistered; **Register…**
      requires From and registers it in place.

## Folder changes (spec §3)
- [ ] `drop config set-folder ~/Other`: the window switches to the new folder at once.
- [ ] `drop config set-folder ~/Documents/Drops`: the menu shows "Drop folder changed —
      confirm"; `drop watch --inbox` exits 1 ("Confirm the new drop folder…"); confirming
      in the window starts serving it.

## Watching (spec §4 Watching, §5)
- [ ] Quit the app. `drop watch --inbox`: the app starts with no window, menu bar icon only.
- [ ] `drop open <id>` with the app quit: it launches and shows that drop.
- [ ] Settings → General shows the server's port. Quit the app, occupy 47390–47399
      (`for p in $(seq 47390 47399); do nc -l 127.0.0.1 $p & done`), launch it: the window
      shows the no-port banner. `kill %1` (frees 47390), **Retry** recovers.

## Settings
- [ ] Hide Dock icon hides it immediately; the menu bar still opens the window.
- [ ] Notify on new drops: `drop add` from a terminal shows a notification; clicking it
      opens the drop. Off: no notification.
- [ ] Event history: presets and Custom… write `eventRetentionDays` (`drop config show`).
      `drop config set-retention 14` shows as Custom 14. The note about deletion is shown.
