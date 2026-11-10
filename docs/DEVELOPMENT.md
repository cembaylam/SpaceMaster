# SpaceMaster — development notes

macOS disk-space manager (macOS 27+, Apple Silicon only, Swift 6, SwiftPM, no .xcodeproj). Navigation mirrors
FileMaster (`~/Projects/oFileManager`): yazi-style 3 columns (parent | current | preview), vim keys, cursor memory.

## Layout
- `Sources/SMCore` (no AppKit): `DirEnumerator` (getattrlistbulk), `SizeScanner` + `Node` (parallel scanner, atomics
  propagate sizes to ancestors, LIFO stack so the opened folder scans first), `Safety` (Safe/Protected rules),
  `Volumes`, `Format`.
- `Sources/SMApp` (AppKit): `BrowserViewController` (navigation/keys/delete/undo), `FileListView` (custom-drawn rows with
  share bars + badges), `BrowserView` (columns, status bar, info pane), `SidebarViewController`, `MainWindowController`
  (toolbar), `MainMenu`.
- Only directories are nodes; files are summed into their folder and re-listed when a folder is displayed.

## Commands
`make run` (debug app), `make test`, `make bench DIR=~` (scan speed), `make dist` (DMG in dist/), `make icon`.
Debug: `SM_NAV=<path> SM_KEYS="jjl" SM_SNAPSHOT=/tmp/x.png SM_SNAPSHOT_DELAY=10 build/SpaceMaster.app/Contents/MacOS/SpaceMaster`
renders the window to PNG (screencapture lacks permission here) and quits.

## Notes
- Name `Scanner` clashes with Foundation: the class is `SizeScanner`.
- Without Full Disk Access ~700 TCC-protected folders each cost ~5 ms to be denied (scan of ~ takes 6 s instead of ~2).
- Sizes are allocated bytes (APFS clones/hardlinks counted per path, so totals can slightly exceed real usage).
- Trash does not free space until emptied; Delete Immediately (⌘⌥⌫) does.
