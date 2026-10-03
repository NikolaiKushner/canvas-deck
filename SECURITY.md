# Security

Canvas Deck runs your shell and Claude Code, opens a local socket for Claude Code's hooks (`~/Library/Application Support/CanvasDeck/notify.sock`, mode 0600) and keeps a Linear OAuth grant in your Keychain.

If you find a security problem, please do not open a public issue. Report it privately through GitHub's **Security → Report a vulnerability** on this repository. You will get an answer within a week.
