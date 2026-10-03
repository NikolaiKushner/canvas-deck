# Canvas Deck

**An infinite canvas for macOS where your Claude Code agents, their terminals, previews and tasks live side by side.**

When several Claude Code sessions run at once, each with its own `localhost`, a dozen terminal windows stop telling you anything: which agent finished, which one waits for a permission, which one is stuck. Canvas Deck puts them on one zoomable canvas and keeps you posted.

## Features

- **Terminal and Claude Code cards** on an infinite canvas: pan, pinch to zoom (16–256%), minimap, ⌘K to jump anywhere.
- **Agent state on every card**, from Claude Code's own hooks: working, permission for a tool, asking a question, done, error. A `claude` you type in any terminal card is tracked too.
- **Notices** in the corner of the canvas, and in macOS when the window is in the background. A permission prompt can be answered from the toast: **Allow** or **Deny**, without opening the card. ⌘J goes to the next agent waiting for you.
- **Sessions come back**: after a restart cards return to their places, terminals to their folders, and Claude Code cards resume their conversation (`claude --resume`). Past sessions are a menu away.
- **Claude Code limits** in the title bar: the 5-hour and weekly windows of the account you choose, per-model weekly limits included, refreshed from Claude Code's own `/usage` without a session open. Several accounts (`CLAUDE_CONFIG_DIR`) are told apart.
- **Browser cards** for any site, with a one-click **Open Preview** when a terminal prints a dev server's `localhost` address.
- **Linear**, through Linear's MCP server with an OAuth sign-in (no API key): your issues in ⌘K, Linear's own web app in a card, and on an issue's page **Start in Claude Code**, **Move to…** and the sprint, one click each. Linear notifications arrive as toasts.

## Requirements

- macOS 15 or later.
- [Claude Code](https://docs.claude.com/en/docs/claude-code/setup) 2.1.97 or later, installed any way (native installer, npm, Homebrew). Canvas Deck finds `claude` in the usual places or through your login shell, and says so when it cannot.
- zsh, bash or fish, for tracking a `claude` you type in a terminal card. Claude Code opened from the canvas is tracked with any shell.
- 5-hour and weekly limits exist for Claude subscriptions (Pro, Max, Team). With an API key, Bedrock or Vertex the app says there are none.

## Build from source

There is no signed release yet.

1. Xcode with **Settings → Components → Metal Toolchain** installed (terminals render with Metal).
2. [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
3. Generate the project, build and run:

   ```bash
   xcodegen generate
   xcodebuild -project CanvasDeck.xcodeproj -scheme CanvasDeck -configuration Release \
     -derivedDataPath build -skipPackagePluginValidation build
   open build/Build/Products/Release/CanvasDeck.app
   ```

   `-skipPackagePluginValidation` lets SwiftTerm's build-info plugin run without a prompt.

Without any setup the app is signed to run on your Mac only. To sign with your own Apple team, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (ignored by git) and fill in your team ID and certificate.

Tests of the shared package: `swift test --package-path Packages/CanvasKit`.

## Keys

| | |
|---|---|
| Open a card | double- or right-click the canvas |
| Go to a card, a session, an issue or a command | ⌘K |
| Next agent waiting for you | ⌘J |
| Back to the canvas from a card | ⌘⎋ |
| Fit all · 100% · zoom to card | ⇧1 · ⇧0 · ⇧2 |
| Pan | scroll, or hold Space and drag |

## Privacy and what it touches

- **No telemetry, no server of its own.** Everything stays on your Mac.
- **Claude Code's credentials are never read.** Signing in goes through `claude auth login`; Claude Code keeps its token in the macOS Keychain.
- **Your Claude Code configuration is not edited.** Hooks and the status line for canvas sessions are passed as `claude --settings` flags. The one exception is opt-in (Settings → Claude Code → Limits): the canvas status line in your `settings.json`, after a backup, with your previous status line restored when you turn it off.
- **Shell startup files are not edited.** A terminal card runs your own `.zshrc`, `.bashrc` or fish config, then puts the canvas `claude` wrapper first on its `PATH` (files in `~/Library/Application Support/CanvasDeck/shell`).
- **Linear**: Canvas Deck signs in to Linear's MCP server with its own OAuth grant; the tokens are in your Keychain. It changes an issue only when you pick an action from the issue's menu.
- **Limits** come from running `claude -p /usage` (no model call, no saved session, your hooks and MCP servers not loaded) every five minutes; this can be turned off.

## Development

```
CanvasDeck/          the app: canvas, cards, agents, integrations, settings
CanvasNotify/        canvas-notify: the hook and status line helper inside the app bundle
Packages/CanvasKit/  Swift package with the logic that is tested without the app
  CanvasCore         layout, camera, agent state, notices, search, prompts
  Usage              status line, limits, forecasts, transcript costs
  Trackers           OAuth for MCP servers, an MCP client, Linear
```

Launch flags for development: `--open=terminal,claude,usage,linear` opens cards at launch (and keeps your saved canvas untouched), `--type=<line>` types a line into the first of them, `--zoom=<percent>` zooms once they are placed, `--palette` opens ⌘K, `--appearance=dark` or `=light` overrides the system appearance, `--simulate-no-claude` behaves as if Claude Code were not installed.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).

Canvas Deck is an independent project, not affiliated with or endorsed by Anthropic or Linear. Claude and Claude Code are trademarks of Anthropic; Linear is a trademark of Linear Orbit, Inc.
