# claude-say — notes for Claude

A macOS menu bar player that speaks a chosen Claude Code response aloud.
Read `README.md` first: it holds the user-facing behaviour and a long
"Corner cases and debugging" section. This file holds the working rules.

## Layout

- `bin/say` — Python 3 launcher, standard library only. Reads the session
  transcript, cleans markdown, launches the player. Also forwards to
  `/usr/bin/say` when the invocation is not its own.
- `src/SayMenu.swift` — the menu bar app. Single file, AppKit, no packages.
- `bin/say-menu` — build output, git ignored.
- `install.sh` — build plus symlinks into `~/.local/bin`.
- `~/.claude/say-prefs.json` — speed, `voice` (Latin), `voice_cyrillic`.

## Build and check

```sh
swiftc -O -o bin/say-menu src/SayMenu.swift    # after any Swift edit
./install.sh                                   # build + relink
```

The user runs `!say` inside Claude Code. There is no test suite. Check changes
without needing to hear the audio:

```sh
say -l                                   # turns found in this session
say -t | head                            # cleaned text
printf 'One. Two. Три предложение.' > "$TMPDIR/t.txt"
bin/say-menu "$TMPDIR/t.txt" &           # launch the player
ps -o args= -p "$(pgrep -x say | head -1)"   # which voice and rate it chose
pgrep -x say-menu || echo "exited"       # it must quit after the last sentence
say --stop
```

`ps -o args=` on the child is the main check: it shows `-r <wpm>` and `-v <voice>`.

## Rules

1. **Keep `/usr/bin/say` as the engine.** AVSpeechSynthesizer only reaches the
   compact voices on this machine and sounds robotic. This was tried and
   reverted. Do not switch back.
2. **Keep the system-say forwarding path in `bin/say`.** `say` shadows
   `/usr/bin/say` on PATH; breaking the forward breaks the user's shell.
3. **No dependencies.** Python standard library, AppKit, `swiftc` from the
   Command Line Tools. No pip, no brew, no Swift packages.
4. **Nothing speaks unless the user asks.** No hooks, no automatic playback,
   no dictation, no network calls.
5. **The player must quit when the text ends**, so the menu bar item goes away.
6. **One process per sentence** is what makes a live speed or voice change
   possible. Do not batch sentences without saying so — the user chose the
   gaps over losing the live controls.
7. Update `README.md` when behaviour changes, including a new corner case.

## Where things live in the Swift file

- `readVoices()` parses `say -v '?'`; `SKIP` hides novelty voices; `Voice.rank`
  orders Premium > Enhanced > compact.
- `isCyrillic()` counts letters per sentence and picks the language.
- `speakCurrent()` / `finished()` / `killCurrent()` drive playback. `killed`
  guards against advancing when we stopped a process on purpose.
- `buildMenu()` lays the custom `NSView` out from the top down. Frames are
  absolute, so change the heights together, and keep every control inside the
  view bounds — a control placed below y=0 is clipped by the menu.
- `redraw()` updates the title, the play button symbol, the speed selection,
  the progress bar, the label, and the voice checkmarks.
