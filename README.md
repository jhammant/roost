# Roost

One menu-bar home for the small tools you live with. Instead of a row of icons, one bird, one menu, and a
badge that only lights up when something needs you.

```text
🐦 2                       ← the most urgent badge across every module
───────────────────────────────────────────────
Agents — 1 blocked · 2 waiting · 6 working
  Blocked on you
  !  steer-06 — permission prompt: Bash  touch x        → jumps to its terminal tab
  Waiting on you
  ◆  recos-66 — “Of your 5 open PRs, one needs action…”
  Working
  ●  gunflower-96 — Bash  Run the playtest
  Servers
  endor: 10 agents, 1 stale ▸
  Quota: Claude 5h 25% · week 80%   Codex weekly 19%   Kimi 5h 1%   DeepSeek $11.42
  Swarm cap: ≤4 comfortable (auto) ▸
  Open atc…
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
| **Agents** | [atc](https://github.com/jhammant/atc), air traffic control for coding agents. Badge: sessions blocked on a prompt (red), else waiting for you (orange). Click a session to jump to its terminal tab; raise or lower the swarm cap; see your servers and every provider's quota. |
| **Clipboard** | [SmartClip](https://github.com/jhammant/SmartClip)'s engine: records everything you copy (text, images with their text read on-device, file paths), ⌥⌘V to search and paste it back. Same history store as SmartClip's `/cpy`, `/pst` and `/clh`. |
| **Scripts** | Every executable in `~/.config/roost/modules/` becomes a submenu. No Swift needed. |

### Writing a script module

Roost runs each executable every 30 seconds and reads JSON from its output:

```json
{
  "title": "Servers",
  "badge": {"text": "1", "level": "alert"},
  "items": [
    {"title": "endor: ok", "open": "https://endor.local"},
    {"title": "Restart the relay", "run": "ssh endor sudo systemctl restart relay"},
    {"title": "Logs", "items": [{"title": "Last deploy", "run": ["open", "-a", "Console"]}]},
    {"title": "Just a line of information"}
  ]
}
```

- `badge`: a string (shown as info), or `{"text", "level": "info" | "warn" | "alert"}`. The most urgent badge
  across all modules is shown next to the bird.
- An item can `run` a shell command (string) or an argv array, `open` a URL or path, or hold `items` (a
  submenu). Add `disabled`, `checked` or `tooltip` as you like. An item with none of these is a greyed line.
- A script that fails, times out (10s) or prints something other than JSON shows up as `name ⚠︎` with the
  error inside, so a broken module never takes the menu down.

[`examples/modules/this-mac.sh`](examples/modules/this-mac.sh) is a working example:

```bash
mkdir -p ~/.config/roost/modules
cp examples/modules/this-mac.sh ~/.config/roost/modules/
```

## Build and install

macOS 13+, Swift 5.9+. Roost depends on SmartClip's `SmartClipKit` through a path dependency, so clone the
two side by side:

```bash
git clone https://github.com/jhammant/SmartClip ../SmartClip
./scripts/build-app.sh --install --run
```

The build is signed with your Apple Development identity when you have one, so the Accessibility grant
(needed only for pressing ⌘V after you pick a clip) survives rebuilds.

On first launch Roost adds itself to your login items; turn that off in its menu. If SmartClip.app is also
running, Roost leaves it recording and offers to take over, so a copy is never recorded twice.

## Checking it without the menu bar

```bash
/Applications/Roost.app/Contents/MacOS/Roost --dump-menu   # every module, built once, printed as text
ROOST_MODULES_DIR=examples/modules .build/debug/Roost --dump-menu
swift test
```

## License

MIT
