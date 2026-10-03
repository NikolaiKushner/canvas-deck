# Contributing to Canvas Deck

Thanks for taking a look. Issues and pull requests are welcome.

## Before a pull request

- **Open an issue first** for anything larger than a fix, so we can agree on the approach before you spend time on it.
- **Build and test**: `swift test --package-path Packages/CanvasKit`, then build the app as in the [README](README.md#build-from-source) and try the change in it.
- **Logic goes in `Packages/CanvasKit`** when it can be tested without AppKit (layout, parsing, state machines), with tests next to it. The app target stays thin.
- **Keep it working for everyone.** Nothing may assume one person's setup: find `claude`, the shell, Claude Code's configuration folder and the plan at run time, and say clearly when something is missing.
- **Do not touch what is not ours**: no edits to the user's shell files or Claude Code settings outside an explicit opt-in, no reading of Claude Code's credentials.
- **Interface text is English**, short and plain. Labels must not be cut off.

## Style

Follow the code around you: names that say what a thing is, comments that say why, small focused types. Swift 6 language mode in the package.

## Reporting bugs

Say what you did, what you expected and what happened, with your macOS and Claude Code versions (`claude --version`). Logs: `log show --last 10m --predicate 'subsystem == "app.canvasdeck"'`.
