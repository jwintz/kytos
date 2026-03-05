# PROMPT

Checkout ~/Syntropment/hyalo to see how it handles itermcolors files. We have added Kythos-light and Kytos-dark.itermcolors to be used by Kytos dynamically changing with system or chosen appearance.

- Settings: on ipados, since there is no settings window, the settings need to be found in the inspector
- Settings: add a page with font choice (a picker with preview for fasily and size is wanted), cursor type (block, underline, vertical bar), cursor blink
- Settings: add a page on the shell: offer to use either the system one on macos, or the embedded mksh (default and only choice on ipados).

- Persistent sessions: the point in using Pane is to have persistent sessions. So we need to save the layout of the panes and restore it when the app is launched.
- Persistence should also handle windows. So when the app is launched, it should restore the windows and their tabs and sessions.

- New session shortcut: CMD+SHIFT+N should open a new session within the current tab.
- New tab shortcut: CMD+T should open a new tab with a new session.
- New window shortcut: CMD+N should open a new window with a new tab.

- Sessions context menu in the sidebar: rename, close, duplicate, close all but this one, close all
- Sessions shortcuts: CMD+SHFT+W to close, CMD+SHFT+D to duplicate, CMD+OPT+SHIFT+Arrow to navigate

- Navigator sessions list: no tab groups, use the tab as the group. So the list should only contain the sessions in the current tab.

- the bundle identifier prefix must be me.jwintz so me.jwintz.kytos

- Xcodegen is used as such: `swift run --package-path .build/checkouts/XcodeGen xcodegen generate --spec project.yml`