# Claudes

Run multiple isolated Claude accounts on one Mac — work / personal / client —
each with its own dock icon, login, and Claude Code CLI config. A menu bar app
plus two small scripts. Roll-your-own Multi-Claude.

One **profile** = one cloned desktop app (`/Applications/Claude-<Name>.app`,
isolated via `--user-data-dir`) + one CLI config dir (`~/.claude-profiles/<Name>`
via `CLAUDE_CONFIG_DIR`).

<img src="docs/menu-v3.png" alt="Claudes menu: profiles with running indicators, per-profile desktop/terminal/copy-command actions, auto-repatch toggle" width="512">


## Install

```zsh
curl -fsSL https://raw.githubusercontent.com/sethwebster/claudes/main/install.sh | zsh
```

Builds locally (needs Xcode Command Line Tools — the installer prompts if
missing) and installs Claudes.app. Prefer to read before you pipe?

```zsh
git clone https://github.com/sethwebster/claudes && cd claudes
./install.sh
```

Then click 🤖 in the menu bar → **New Profile…** → e.g. `Work` → sign in once in
the new desktop app, and once in the CLI (`/login`). Add Claudes.app to
System Settings → Login Items to start at boot.

**Shell commands** (install.sh wires zsh, bash, and fish — whichever you
have): every profile gets a CLI command named after it — profile `Work` →
`claude-work`, profile `Expo` → `claude-expo`. Commands never shadow a real
binary of the same name; in zsh they even appear the moment a profile is
created (command-not-found hook), in bash/fish open a new shell after creating
one. `claude-as <Profile>` is the explicit, tab-completable form, and
`claudes run <Profile>` works from any shell or script with no integration
at all:

```sh
claude-expo               # Claude Code with the Expo profile
claude-as Expo --resume   # same, explicit form with args
claudes run Expo          # shell-neutral equivalent (claudes is on PATH)
```

For per-project auto-switching, use direnv: `export CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/Work`
in a repo's `.envrc`.

## The `claudes` CLI

Everything the tray does is also a command (the tray shells out to the same
script, so they can't drift):

```zsh
claudes list                        # profiles: ✓ active, 🟢 running
claudes use Work                    # switch the GLOBAL active profile
claudes run --next                  # new session on the next profile in rotation
claudes sessions [Profile]          # list Claude Code sessions
claudes transfer <id> --to Work     # move a session between profiles
claudes new <Name> | delete <Name> [--everything] | repatch [Name]
claudes desktop [Name]              # open a profile's desktop app
```

**Global switching:** `claudes use` turns `~/.claude` into a symlink pointing at
the active profile (the first switch migrates your original `~/.claude` to
`~/.claude-profiles/Default`). From then on, *anything* that reads the default
config dir — plain `claude` in any terminal, editors, IDE plugins — follows the
active profile. Running sessions keep the profile they started with, and
`claude-<profile>` / `CLAUDE_CONFIG_DIR` still pin a single invocation
regardless of the global setting.

## What the tray does

- Lists profiles with a running indicator (🟢/⚪️) and a ✓ on the active one
- Per profile: set as active (global), open the desktop app, open a Claude Code
  terminal session, reveal the data dir, transfer a session to another
  profile, delete the profile
- **New Profile…** — clones and patches Claude.app (progress shown in Terminal)
- **Auto-repatch** — the tray detects when Claude Desktop has updated (version
  drift between the original and each clone) and silently rebuilds idle clones
  in the background. Running instances are picked up on a later check after
  they quit. Menu bar shows 🤖⬆️ while an update is pending, ⏳ while
  rebuilding. Toggle it off in the menu if you prefer manual **Re-patch All**.
  Logins always survive (they live outside the bundle).
- **Self-update** — Claudes checks GitHub releases and offers a one-click
  "Update Claudes to vX.Y.Z" when a newer version ships.

`claude-<profile>` commands never switch anything global — they pin one
invocation via `CLAUDE_CONFIG_DIR`. The global default is whatever
`claudes use` (or the tray's **Set as Active**) last selected.

## How the clone works (and why it's shaped this way)

`make-claude-profile.sh`:

1. Copies `Claude.app` → `Claude-<Name>.app`, strips quarantine xattrs.
2. Patches `CFBundleIdentifier` + `CFBundleDisplayName` for a separate identity.
   `CFBundleName` must stay `Claude` — Electron derives the helper-app path from
   it and aborts otherwise.
3. Replaces the main executable with a wrapper that adds
   `--user-data-dir="~/Library/Application Support/Claude-<Name>"`, so isolation
   holds for Finder/Dock launches too.
4. Re-signs only what changed: the main binary ad-hoc with its original
   entitlements (minus team-provisioned ones, plus
   `disable-library-validation` so a team-less binary may load Anthropic's
   team-signed Electron Framework), then the outer bundle seal. Helpers and
   frameworks keep Anthropic's original signatures. Never `codesign --deep` —
   it strips Electron's JIT entitlements and the app crashes at launch.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Clone won't launch after a Claude update | 🤖 → **Re-patch All** |
| "Claudes can't control Terminal" | System Settings → Privacy & Security → Automation → Claudes → enable Terminal |
| Keychain prompt on a clone's first login | Normal (signing identity differs) — click Always Allow |
| `claude` not found in profile terminal | `npm install -g @anthropic-ai/claude-code` |
| Clone crashes at launch (SIGTRAP/dyld) | You may have re-signed it manually with `--deep` — re-patch |

## Releases & contributing

Releases are automated with semantic-release on pushes to `main` — use
[conventional commits](https://www.conventionalcommits.org) (`feat:`, `fix:`,
`BREAKING CHANGE:`) so versions and release notes generate themselves. CI
builds `Claudes.zip`, signs/notarizes when credentials are configured, and
attaches it to the GitHub release; the app's self-update picks it up from
there.

## Disclaimer

Unofficial. Not affiliated with Anthropic. Profile creation clones and re-signs
your locally installed Claude.app for personal use; the clones' built-in
auto-update is intentionally inert (use Re-patch All instead). Use at your own
risk.

## License

MIT
