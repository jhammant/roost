# Roost

One menu-bar home for the small tools you live with. Instead of a row of icons, one bird, one menu, and a
badge that only lights up when something needs you.

```text
🐦 2                       ← the most urgent badge across every module
───────────────────────────────────────────────
Agents — 1 blocked · 2 waiting · 6 working
  Needs you
  Approve in atc web… — Review action                  → opens the web UI for passkey approval
  !  session-a — permission prompt: Bash  touch x      → jumps to its terminal tab
  a-mail request — Answer in the a-mail app.
  Waiting on you
  ◆  docs-site — “Of your 5 open PRs, one needs action…”
  Later ▸                                             → next 24 h, e.g. “Wake session-a — in 12m”
  Jobs ▸                                              → hosts, with failing jobs first
  Working
  ●  web-app — Bash  Run the playtest
  Servers
  buildbox: 10 agents, 1 stale ▸
  Quota: Claude 5h 25% · week 80%   Codex weekly 19%   Kimi 5h 1%   DeepSeek $11.42
  Swarm cap: ≤4 comfortable (auto) ▸
  Open atc…
  Open atc web
───────────────────────────────────────────────
Clipboard
  Recent clips ▸
  Search clips…  ⌥⌘V
  Pause capture
───────────────────────────────────────────────
This Mac ▸                 ← a script module: any executable that prints JSON
───────────────────────────────────────────────
Open at login ✓
```

## Modules

| Module | What it is |
|---|---|
| **Agents** | [atc](https://github.com/jhammant/atc), air traffic control for coding agents. Badge: urgent needs (red), else failing jobs (orange), else waiting sessions (orange). See Needs you, Later and Jobs; jump to a session or open atc web for approvals; raise or lower the swarm cap; see servers and provider quotas. |
| **Clipboard** | [SmartClip](https://github.com/jhammant/SmartClip)'s engine: records everything you copy (text, images with their text read on-device, file paths), ⌥⌘V to search and paste it back. Same history store as SmartClip's `/cpy`, `/pst` and `/clh`. |
| **Plugins** | Folders in `~/.config/roost/plugins/`, each with a `plugin.json`: their own schedule, timeout and environment, confirmations for anything with side effects, and a tool can ship its plugin in its own repo. See [Plugins](#plugins). |
| **Scripts** | Every executable in `~/.config/roost/modules/` becomes a submenu. No Swift needed. |

Every module, built in or plugin, can be switched off under **Plugins ▸** in the menu. Roost remembers it in
`~/.config/roost/settings.json`.

### Agents: needs, approvals and jobs

**Needs you** puts urgent queue items first: blocked sessions, atc approvals, and a-mail approvals,
requests and device approvals. The red badge uses `counts.needs_urgent`, which counts queue items, not the
quantities inside an a-mail summary. Other a-mail items display their answer location from atc's hint;
**Waiting on you** keeps session jump actions and waiting times. The needs queue replaces duplicate blocked
and waiting entries from the old session groups. Remote needs remain visible between the slower host polls.

**Approve in atc web…** and **Open atc web** open the configured URL. Approval happens in the web UI using
your passkey. Put the web UI's URL on the first line of `~/.config/atc/web-url` (an app started at login has
no shell environment), or set `ATC_WEB_URL` in Roost's environment, for example:

```bash
ATC_WEB_URL=https://example.com/atc .build/debug/Roost
```

For an app opened from Finder or at login, set the GUI launch environment and restart Roost:

```bash
launchctl setenv ATC_WEB_URL https://example.com/atc
```

`launchctl setenv` applies to the current login session; arrange to set it at login if you need it after
logging out. A shell-profile export alone does not configure a Finder-launched app. Without a valid URL,
approval rows remain visible but disabled, with an `ATC_WEB_URL` setup hint, and **Open atc web** is omitted.

**Later** lists scheduled wake-ups and reminders due from now through the next 24 hours, sorted by time,
with labels such as `in 12m`. Items with unknown, invalid or past times are omitted. These rows are informational.

**Jobs** groups loom jobs by host, failing first, and shows state, last exit code and purpose (as a tooltip).
Click a job to open `loom jobs status <name>` in Terminal; remote hosts use
`loom --host <host> jobs status <name>`. Unreachable hosts show their error and any last-seen jobs.
The orange badge uses `counts.jobs_failing` before falling back to the waiting-session count.

Older atc output without these keys retains the original blocked/waiting menu and badge. Missing counts
are derived from available queue/job rows; absent or empty Later and Jobs data adds no submenu.

### Writing a script module

Roost runs each executable every 30 seconds and reads JSON from its output:

```json
{
  "title": "Servers",
  "badge": {"text": "1", "level": "alert"},
  "items": [
    {"title": "buildbox: ok", "open": "https://buildbox.local"},
    {"title": "Restart the relay", "run": "ssh buildbox sudo systemctl restart relay"},
    {"title": "Logs", "items": [{"title": "Last deploy", "run": ["open", "-a", "Console"]}]},
    {"title": "Just a line of information"}
  ]
}
```

- `badge`: a string (shown as info), or `{"text", "level": "info" | "warn" | "alert"}`. The most urgent badge
  across all modules is shown next to the bird.
- An item can `run` a shell command (string) or an argv array, `open` a URL or path, or hold `items` (a
  submenu). Add `disabled`, `checked` or `tooltip` as you like. An item with none of these is a greyed line.
  `{"separator": true}` draws a line.
- `"hotkey": "ctrl+opt+cmd+g"` on an item with an action makes a system-wide shortcut that does what clicking it
  does, and shows it beside the item. Modifiers: `cmd`, `shift`, `opt`, `ctrl` (at least one); keys: letters,
  digits, punctuation, `f1`–`f12`, arrows, `return`, `tab`, `space`, `escape`. If two items ask for the same
  combination the first keeps it, and one another app already owns is reported once.
- A script that fails, times out (10s) or prints something other than JSON shows up as `name ⚠︎` with the
  error inside, so a broken module never takes the menu down.

[`examples/modules/this-mac.sh`](examples/modules/this-mac.sh) is a working example:

```bash
mkdir -p ~/.config/roost/modules
cp examples/modules/this-mac.sh ~/.config/roost/modules/
```

## Plugins

A script module is one executable. A plugin is a folder, so it can carry its own code, ship inside the repo of
the tool it belongs to, and say how it wants to run:

```json
{
  "id": "crm-mail-sync",
  "name": "CRM mail sync",
  "description": "Emails waiting to be logged to HubSpot",
  "version": "0.1.0",
  "command": ["./roost_plugin.py"],
  "interval": 300,
  "timeout": 20,
  "env": {"CRM_MAIL_SYNC_CONFIG": "~/.config/crm-mail-sync/config.yaml"},
  "requires": ["python3", "crm-mail-sync"]
}
```

| Key | Meaning |
|---|---|
| `command` | Required. An argv array or a shell string. A relative path (`./roost_plugin.py`) is found in the plugin's folder. |
| `id` | Lowercase, unique. Defaults to the folder name. |
| `name`, `description`, `version` | Shown under **Plugins ▸**. |
| `interval` | Seconds between refreshes, 5 to 86400. Default 30. |
| `timeout` | Seconds before a refresh is stopped, 1 to 300. Default 10. |
| `env` | Extra environment variables; a leading `~` is expanded. Roost adds `ROOST_PLUGIN_ID` and `ROOST_PLUGIN_DIR`. |
| `requires` | Commands that must be on the PATH. Until they are, the plugin shows "needs … on the PATH" instead of failing. |

The command prints the same JSON as a script module, with two additions:

- Its `run` items run in the plugin's folder with its environment, so a plugin can call itself back:
  `{"title": "Skip", "run": ["./roost_plugin.py", "skip", "42"]}`. The plugin refreshes straight afterwards.
- `"confirm": "Log this email to HubSpot?"` on an item asks first and only runs it on OK. Use it for anything
  with side effects.

A plugin that fails, times out or prints something other than JSON shows as `name ⚠︎` with the reason, and a
folder with a bad `plugin.json` is listed under **Plugins ▸** with what to fix. Neither takes the menu down.
Plugins added, edited or removed while Roost runs are picked up within 30 seconds, or at once with
**Plugins ▸ Reload plugins**.

```bash
Roost --check-plugin path/to/plugin      # run it once and print its menu, as Roost would show it
Roost --install-plugin path/to/plugin    # check plugin.json, then symlink it into ~/.config/roost/plugins
Roost --plugins                          # what is installed, on or off, and anything broken
Roost --uninstall-plugin crm-mail-sync   # remove the link; the plugin's folder is untouched
```

`ROOST_PLUGINS_DIR` and `ROOST_CONFIG_DIR` point Roost at other folders, for testing.

Plugins in the wild:

- [crm-mail-sync](https://github.com/jhammant/crm-mail-sync/tree/main/integrations/roost): the HubSpot
  email-logging review queue, with *Log to HubSpot…* and *Skip* per email, and any person flagged to sync.
- [claude-sessions](https://github.com/jhammant/claude-sessions/tree/main/roost-plugin): tile your Claude Code
  windows (grid, focus, side by side, per display), auto-tile, reopen a closed window.

## Build and install

macOS 13+, Swift 5.9+. Roost depends on SmartClip's `SmartClipKit` through a path dependency, so clone the
two side by side:

```bash
git clone -b feat/smartclipkit https://github.com/jhammant/SmartClip ../SmartClip   # SmartClipKit, until it lands on main
./scripts/build-app.sh --install --run
```

The build is signed with your Apple Development identity when you have one, so the Accessibility grant
(needed only for pressing ⌘V after you pick a clip) survives rebuilds.

On first launch Roost adds itself to your login items; turn that off in its menu. If SmartClip.app is also
running, Roost leaves it recording and offers to take over, so a copy is never recorded twice.

## Checking it without the menu bar

```bash
/Applications/Roost.app/Contents/MacOS/Roost --dump-menu   # every module and plugin, built once, printed as text
ROOST_MODULES_DIR=examples/modules .build/debug/Roost --dump-menu
swift test
```

## License

MIT
