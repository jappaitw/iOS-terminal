# PocketCode

A VS Code–style code editor for iPhone and iPad: **Explorer**, **Editor**, and **Terminal**.

| Panel | What it does |
|---|---|
| Explorer | Folder tree with indent guides, file-type icons, new file/folder, rename, delete, copy path. Works on local folders (app Documents or any folder from Files) and remote hosts over SFTP. |
| Editor | Tree-sitter syntax highlighting (Dark+ colors) for ~20 languages, line numbers, current-line highlight, tabs with unsaved dots, breadcrumbs, find & replace, bracket pairing, symbol key row, undo/redo, save (⌘S). Images preview; binary files are detected. |
| Terminal | Real `xterm-256color` shell over SSH (SwiftTerm), multiple terminals, resize, ANSI colors, Esc/Ctrl/Tab/arrow keys row. "Open in Integrated Terminal" from the explorer. |

iOS does not let apps run a local shell, so the terminal needs an SSH host (like VS Code Remote-SSH).
SSH host keys are pinned on first connect; passwords and keys are stored in the Keychain.

## Build

```bash
brew install xcodegen
xcodegen generate
open PocketCode.xcodeproj
```

Dependencies (Swift Package Manager): Citadel 0.12.0 (SSH/SFTP), SwiftTerm, Runestone + TreeSitterLanguages.
Citadel is pinned to exactly 0.12.0 because 0.12.1 switched to a third-party swift-nio-ssh fork.

Layout: iPhone shows one panel at a time with an activity bar at the bottom; iPad / landscape shows
activity bar + explorer sidebar + editor with a resizable terminal panel (⌃` toggles it, ⌘B the sidebar).
