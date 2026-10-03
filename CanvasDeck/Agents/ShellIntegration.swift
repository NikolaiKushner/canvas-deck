import Foundation

/// Makes a hand-typed `claude` in any terminal card a canvas agent: a `claude`
/// shim goes first on the card's PATH and adds our `--settings` (hooks and the
/// status line) before running the real CLI.
///
/// PATH set in the environment does not survive rc files that prepend their
/// own folders (`export PATH="$HOME/.local/bin:$PATH"`), so zsh gets its own
/// ZDOTDIR and bash its own `--rcfile`: they run the user's startup files
/// unchanged and put the shim folder first afterwards. fish runs its own
/// config as usual and then `--init-command`. Other shells only get the
/// environment PATH, which their rc files may override.
///
/// The files are written to Application Support at launch, not bundled: the
/// zsh ones are dotfiles, and their paths must not move with the app.
enum ShellIntegration {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/shell", directoryHint: .isDirectory)
    }
    static var binDirectory: URL { directory.appending(path: "bin", directoryHint: .isDirectory) }
    static var zshDirectory: URL { directory.appending(path: "zsh", directoryHint: .isDirectory) }
    static var bashRC: URL { directory.appending(path: "bash/rc") }

    enum Kind { case zsh, bash, fish, other }

    static func kind(of shell: String) -> Kind {
        switch (shell as NSString).lastPathComponent {
        case "zsh": .zsh
        case "bash": .bash
        case "fish": .fish
        default: .other
        }
    }

    static func supports(shell: String) -> Bool { kind(of: shell) != .other }

    /// fish reads its config first, then this: the shim folder goes first on PATH.
    static let fishInit = "set -gx PATH $CANVAS_BIN (string match -v -- $CANVAS_BIN $PATH)"

    /// Writes the shim and the startup files when they differ from this build's.
    static func install() {
        let files: [(URL, String, Bool)] = [
            (binDirectory.appending(path: "claude"), claudeShim, true),
            (zshDirectory.appending(path: ".zshenv"), zshenv, false),
            (zshDirectory.appending(path: ".zprofile"), zprofile, false),
            (zshDirectory.appending(path: ".zshrc"), zshrc, false),
            (zshDirectory.appending(path: ".zlogin"), zlogin, false),
            (bashRC, bashrc, false),
        ]
        let manager = FileManager.default
        for (url, text, executable) in files {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            if executable { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    /// Arguments and argv[0] for an interactive shell in a card, optionally
    /// running `script` first (`-c`).
    static func launch(shell: String, script: String?) -> (args: [String], execName: String) {
        let name = (shell as NSString).lastPathComponent
        let enabled = Settings.terminalAgentShim
        switch (kind(of: shell), enabled) {
        case (.bash, true):
            // A login bash ignores --rcfile; ours reads the login files itself.
            return (["--rcfile", bashRC.path, "-i"] + (script.map { ["-c", $0] } ?? []), name)
        case (.fish, true):
            return (["-l", "-C", fishInit] + (script.map { ["-i", "-c", $0] } ?? []), "-" + name)
        default:
            return ((script.map { ["-l", "-i", "-c", $0] } ?? ["-l"]), "-" + name)
        }
    }

    /// The shell a launch script ends with once Claude Code exits.
    static func relaunchCommand(shell: String) -> String {
        let quoted = ClaudeLaunch.shellQuote(shell)
        guard Settings.terminalAgentShim else { return "exec \(quoted) -l" }
        switch kind(of: shell) {
        // Our startup files hand ZDOTDIR back to the user's; take it again.
        case .zsh: return "ZDOTDIR=\"$CANVAS_ZDOTDIR\" exec \(quoted) -l"
        case .bash: return "exec \(quoted) --rcfile \(ClaudeLaunch.shellQuote(bashRC.path)) -i"
        // Runs inside fish: its quoting, which has no '\'' escape. fishInit has no quotes.
        case .fish: return "exec \(quoted) -l -C '\(fishInit)'"
        case .other: return "exec \(quoted) -l"
        }
    }

    /// Variables for a card's shell, on top of the app's environment.
    static func environment(shell: String, base: [String: String]) -> [String: String] {
        var env = base
        // The app may itself run from a card: nothing of a parent session leaks in.
        env["CANVAS_CLAUDE_WRAPPED"] = nil
        guard Settings.terminalAgentShim else { return env }
        let bin = binDirectory.path
        env["CANVAS_BIN"] = bin
        env["CANVAS_CLAUDE_SETTINGS"] = ClaudeLaunch.settingsJSON(notifyPath: TerminalNode.notifyPath)
        env["PATH"] = bin + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if kind(of: shell) == .zsh {
            env["CANVAS_USER_ZDOTDIR"] = base["ZDOTDIR"] ?? NSHomeDirectory()
            env["CANVAS_ZDOTDIR"] = zshDirectory.path
            env["ZDOTDIR"] = zshDirectory.path
        }
        return env
    }

    // MARK: - Files

    /// Subcommands of `claude` 2.1.284 that are not a session: passed through as is.
    static let subcommands = [
        "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs",
        "mcp", "plugin", "plugins", "project", "respawn", "rm", "setup-token", "stop", "kill",
        "ultrareview", "update", "upgrade",
    ]

    static var claudeShim: String {
        """
        #!/bin/sh
        # Canvas Deck: `claude` in a canvas card. Adds the canvas hooks and
        # status line (CANVAS_CLAUDE_SETTINGS) to a Claude Code session, then runs
        # the real CLI. Anything that is not a session, and any session outside a
        # card, goes to the real CLI unchanged. Written by the app; edits are lost.

        shim_dir=$(cd "$(dirname "$0")" && pwd -P)

        real=""
        old_ifs=$IFS
        IFS=:
        for dir in $PATH; do
            [ -n "$dir" ] || continue
            [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$shim_dir" ] && continue
            if [ -x "$dir/claude" ] && [ ! -d "$dir/claude" ]; then real="$dir/claude"; break; fi
        done
        IFS=$old_ifs
        if [ -z "$real" ]; then
            for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
                if [ -x "$candidate" ]; then real=$candidate; break; fi
            done
        fi
        if [ -z "$real" ]; then
            echo "claude: Claude Code is not installed (https://claude.com/claude-code)" >&2
            exit 127
        fi

        # Not in a card, or already inside a canvas session (Claude's own tools).
        if [ -z "$CANVAS_NODE_ID" ] || [ -z "$CANVAS_CLAUDE_SETTINGS" ] || [ -n "$CANVAS_CLAUDE_WRAPPED" ]; then
            exec "$real" "$@"
        fi

        case "$1" in
            \(subcommands.joined(separator: "|"))) exec "$real" "$@" ;;
        esac
        for arg in "$@"; do
            case "$arg" in
                # Version and help print and exit; own --settings wins over ours.
                -v|--version|-h|--help|--settings|--settings=*) exec "$real" "$@" ;;
            esac
        done

        CANVAS_CLAUDE_WRAPPED=1
        export CANVAS_CLAUDE_WRAPPED
        exec "$real" --settings "$CANVAS_CLAUDE_SETTINGS" "$@"

        """
    }

    // zsh reads $ZDOTDIR/.zshenv, .zprofile, .zshrc, .zlogin in that order.
    // Each of ours runs the user's file with the user's ZDOTDIR, then points
    // ZDOTDIR back here for the next one. The last one to run puts the shim
    // first on PATH and leaves ZDOTDIR as the user had it.

    private static let zshHeader = "# Canvas Deck shell integration: runs your own zsh startup files, then\n# puts the canvas `claude` first on PATH. Written by the app; edits are lost.\n"

    static var zshenv: String {
        zshHeader + """
        ZDOTDIR=$CANVAS_USER_ZDOTDIR
        [[ -r $ZDOTDIR/.zshenv ]] && builtin source $ZDOTDIR/.zshenv
        # Your .zshenv may move ZDOTDIR; the other files are read from there.
        CANVAS_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$CANVAS_ZDOTDIR

        canvas_finish() {
            path=(${CANVAS_BIN} ${path:#${CANVAS_BIN}})
            if [[ $CANVAS_USER_ZDOTDIR == $HOME ]]; then unset ZDOTDIR; else ZDOTDIR=$CANVAS_USER_ZDOTDIR; fi
            unfunction canvas_finish
        }

        """
    }

    static var zprofile: String {
        zshHeader + """
        ZDOTDIR=$CANVAS_USER_ZDOTDIR
        [[ -r $ZDOTDIR/.zprofile ]] && builtin source $ZDOTDIR/.zprofile
        ZDOTDIR=$CANVAS_ZDOTDIR

        """
    }

    static var zshrc: String {
        zshHeader + """
        # /etc/zshrc ran with our ZDOTDIR and put history here; it is yours.
        [[ $HISTFILE == $CANVAS_ZDOTDIR/.zsh_history ]] && HISTFILE=$CANVAS_USER_ZDOTDIR/.zsh_history
        ZDOTDIR=$CANVAS_USER_ZDOTDIR
        [[ -r $ZDOTDIR/.zshrc ]] && builtin source $ZDOTDIR/.zshrc
        if [[ -o login ]]; then ZDOTDIR=$CANVAS_ZDOTDIR; else canvas_finish; fi

        """
    }

    static var zlogin: String {
        zshHeader + """
        ZDOTDIR=$CANVAS_USER_ZDOTDIR
        [[ -r $ZDOTDIR/.zlogin ]] && builtin source $ZDOTDIR/.zlogin
        (( $+functions[canvas_finish] )) && canvas_finish

        """
    }

    static var bashrc: String {
        """
        # Canvas Deck shell integration: what a login bash reads, then the
        # canvas `claude` first on PATH. Written by the app; edits are lost.
        [ -r /etc/profile ] && . /etc/profile
        for canvas_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -r "$canvas_file" ]; then . "$canvas_file"; break; fi
        done
        unset canvas_file
        case ":$PATH:" in
            *":$CANVAS_BIN:"*) PATH=":$PATH:"; PATH=${PATH//":$CANVAS_BIN:"/:}; PATH=${PATH#:}; PATH=${PATH%:} ;;
        esac
        export PATH="$CANVAS_BIN:$PATH"

        """
    }
}
