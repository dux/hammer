# HammerGUI

Native macOS (SwiftUI) runner for a Hammerfile. Launched by `hammer --gui`:
it reads `hammer h:json`, renders a sidebar of groups/tasks and a form per
task, and runs the selected task as a `hammer <path> ...` subprocess,
streaming output into a panel.

## Build

```sh
./build_app.sh          # -> ../Hammer.app (the vendored bundle)
```

`hammer --gui` spawns `../Hammer.app/Contents/MacOS/HammerGUI` directly
(inheriting the caller's environment, so `ruby`/`hammer` resolve the same
as in your shell) with `--project <hammerfile dir> --hammer <bin>`.

## Dev

```sh
swift build && swift run HammerGUI --project /path/to/project --hammer "$(command -v hammer)"
```

## Notes

* arm64-only, macOS 11+ (the Apple-Silicon floor). Sticks to 10.15/11
  SwiftUI APIs (`HSplitView`/`VSplitView`, `ObservableObject`).
* Output is plain text (`NO_COLOR=1`). Interactive helpers
  (`ask`/`yes?`/`choose`) and the `HAMMER_GUI=1` event protocol are a
  planned follow-up - see `doc/gui-feature.md`.
