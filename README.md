<div align="center">

<img src="docs/logo.png" alt="Claudes logo: a stack of orange Claude app tiles" width="128">

# Claudes

**Run multiple isolated Claude accounts on one Mac.**

Work · personal · client — each with its own dock icon, login, and
Claude Code CLI config. A menu bar app plus a small CLI.
Roll-your-own Multi-Claude.

[![Latest release](https://img.shields.io/github/v/release/sethwebster/claudes?label=release)](https://github.com/sethwebster/claudes/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS-black)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](#license)

<img src="docs/menu-v3.png" alt="Claudes menu: profiles with running indicators, per-profile desktop/terminal/copy-command actions, auto-repatch toggle" width="512">

</div>

One **profile** = one cloned desktop app + one isolated CLI config:

|         | Lives at                            | Isolated via        |
| ------- | ----------------------------------- | ------------------- |
| Desktop | `/Applications/Claude-<Name>.app`   | `--user-data-dir`   |
| CLI     | `~/.claude-profiles/<Name>`         | `CLAUDE_CONFIG_DIR` |

## Install

```zsh
curl -fsSL https://raw.githubusercontent.com/sethwebster/claudes/main/install.sh | zsh
```

Prefers the signed release; falls back to building from source (the installer
prompts for Xcode Command Line Tools if missing). Prefer to read before you pipe?

```zsh
git clone https://github.com/sethwebster/claudes && cd claudes
./install.sh
```

Then:

1. Click the **Claudes icon** in the menu bar → **New Profile…** → e.g. `Work`
2. Sign in once in the new desktop app, and once in the CLI (`/login`)
3. Optional: add Claudes.app to **System Settings → Login Items**

The installer puts `claudes` on your PATH and wires shell helpers for **zsh**,
**bash**, and **fish** — whichever you have. `./uninstall.sh` reverses all of
it (add `--purge` to also remove profiles).

## Everyday use

Every profile gets a command named after it:

```sh
claude-expo               # Claude Code with the Expo profile
claude-as Expo --resume   # same, explicit + tab-completable
claudes run Expo          # shell-neutral (works in scripts, any shell)
```

Profile commands never shadow a real binary of the same name. In zsh they
appear the moment a profile is created; in bash/fish, open a new shell after
creating one.

> [!TIP]
> Per-project auto-switching: put
> `export CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/Work` in a repo's `.envrc`
> (direnv).

## Sessions & rotation

Claude Code sessions belong to a profile, but they don't have to stay there.
Claudes can list them, move them between profiles, and rotate new work across
your accounts — handy when one account hits its usage limit mid-task.

```sh
claudes sessions                    # id · date · project · first prompt
claudes transfer <id> --to Work     # move a session (transcript + todos + env)
claudes transfer <id> --next        # …or to the next profile in rotation
claudes run --next                  # new session on the next profile
claudes desktop --next              # next profile's desktop app
```

And the one-liner for "keep going on another account":

```sh
claudes run --next --start-from-session=<id>
```

That finds the session wherever it lives, moves it to the next profile in
rotation (skipping the one it's already on), jumps to the session's project
directory, and resumes it there — same conversation, different account.

Rotation is round-robin over all profiles (Default included). One shared
pointer — `run`, `desktop`, and `transfer` advance it together. Transfers are
also in the tray: each profile's menu has **Transfer Session…** with a session
picker and a one-click "Open Now" after the move.

## The `claudes` CLI

Everything the tray does is also a command — the tray shells out to the same
script, so the two can't drift:

| Command                          | What it does                                  |
| -------------------------------- | --------------------------------------------- |
| `claudes list`                   | Profiles: ✓ active, 🟢 running                |
| `claudes use <Profile>`          | Switch the **global** active profile          |
| `claudes run <Profile\|--next>`  | New session, pinned or rotating; `--start-from-session=<id>` moves + resumes |
| `claudes sessions [Profile]`     | List sessions (id · date · project · prompt)  |
| `claudes transfer <id> --to <P>` | Move a session between profiles (`--next` rotates) |
| `claudes new <Name>`             | Create a profile                              |
| `claudes delete <Name>`          | Delete (`--everything` removes data + config) |
| `claudes repatch [Name]`         | Rebuild clone(s) after a Claude update        |
| `claudes desktop [Name\|--next]` | Open a profile's desktop app                  |

> [!NOTE]
> **Global switching.** `claudes use` turns `~/.claude` into a symlink to the
> active profile (the first switch migrates your original `~/.claude` to
> `~/.claude-profiles/Default`). From then on, *anything* that reads the
> default config dir — plain `claude` in any terminal, editors, IDE plugins —
> follows the active profile. Running sessions keep the profile they started
> with, and `claude-<profile>` / `CLAUDE_CONFIG_DIR` still pin a single
> invocation regardless of the global setting.

## The menu bar app

- Profiles at a glance — 🟢 running, ✓ active
- Per profile: **Set as Active**, open desktop app, open a Claude Code
  terminal session (in your preferred terminal — Terminal, iTerm2, Warp,
  Ghostty, kitty, Alacritty, WezTerm), **Transfer Session…**, reveal data
  dir, delete
- **New Profile…** — clones and patches Claude.app (progress in Terminal)
- **Auto-repatch** — detects Claude Desktop updates (version drift between the
  original and each clone) and silently rebuilds idle clones in the background;
  running ones are picked up after they quit. Menu bar shows ⬆️ while an
  update is pending, ⏳ while rebuilding. Prefer manual? Toggle it off and use
  **Re-patch All**. Logins always survive — they live outside the bundle.
- **Self-update** — one click when a new Claudes release ships

## Under the hood

`make-claude-profile.sh` builds each clone:

1. Copies `Claude.app` → `Claude-<Name>.app`, strips quarantine xattrs.
2. Patches `CFBundleIdentifier` + `CFBundleDisplayName` for a separate
   identity. `CFBundleName` must stay `Claude` — Electron derives the
   helper-app path from it and aborts otherwise.
3. Replaces the main executable with a wrapper that adds
   `--user-data-dir="~/Library/Application Support/Claude-<Name>"`, so
   isolation holds for Finder/Dock launches too.
4. Re-signs only what changed: the main binary ad-hoc with its original
   entitlements (minus team-provisioned ones, plus
   `disable-library-validation` so a team-less binary may load Anthropic's
   team-signed Electron Framework), then the outer bundle seal. Helpers and
   frameworks keep Anthropic's original signatures. Never `codesign --deep` —
   it strips Electron's JIT entitlements and the app crashes at launch.

Session transfers move the transcript
(`projects/<slug>/<id>.jsonl`) plus its per-session side data (`session-env`,
`file-history`, `todos`) between config dirs — nothing is copied or left
behind, and the destination refuses an id it already has.

## Troubleshooting

| Symptom                                   | Fix                                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------------ |
| Clone won't launch after a Claude update  | Claudes menu → **Re-patch All**                                                |
| "Claudes can't control Terminal"          | System Settings → Privacy & Security → Automation → Claudes → enable Terminal  |
| Keychain prompt on a clone's first login  | Normal (signing identity differs) — click **Always Allow**                     |
| `claude` not found in profile terminal    | `npm install -g @anthropic-ai/claude-code`                                     |
| `claudes` not found after an update       | Re-run install.sh (relinks the PATH symlink)                                   |
| Clone crashes at launch (SIGTRAP/dyld)    | You may have re-signed it manually with `--deep` — re-patch                    |

## Releases & contributing

Releases are automated with semantic-release on pushes to `main` — use
[conventional commits](https://www.conventionalcommits.org) (`feat:`, `fix:`,
`BREAKING CHANGE:`) so versions and release notes generate themselves. CI
builds `Claudes.zip`, signs/notarizes when credentials are configured, and
attaches it to the GitHub release; the app's self-update picks it up from
there.

> [!IMPORTANT]
> **Unofficial.** Not affiliated with Anthropic. Profile creation clones and
> re-signs your locally installed Claude.app for personal use; the clones'
> built-in auto-update is intentionally inert (use Re-patch All instead). Use
> at your own risk.

## License

MIT
