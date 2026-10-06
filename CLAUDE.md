# claude-say — notes for Claude

A macOS menu bar player that speaks a chosen Claude Code response aloud.
Read `README.md` first: it holds the user-facing behaviour and a long
"Corner cases and debugging" section. This file holds the working rules.

## Layout

- `bin/say` — Python 3 launcher, standard library only. Reads the session
  transcript, cleans markdown (tables become "Header: value" phrases), launches
  the player. Also forwards to `/usr/bin/say` when the invocation is not its own.
- `bin/speak` — uv script (edge-tts, num2words). Renders text with a Microsoft
  neural voice, `-o file` for the player; plays chunks itself when run by hand.
  `pronounce()` runs on every text, `--raw` included: the user's rules from
  `~/.config/claude-say/pronounce.txt`, then "4-й"-style numbers to words.
  Voice `auto` picks Dmitry for text with any Russian word, Andrew otherwise.
- `bin/speak-local.py` — uv script (torch, Silero v5). Offline Russian voice for
  `speak --local`. Model cached in `~/.local/share/speak/`.
- `src/SayMenu.swift` — the menu bar app. Single file, AppKit, no packages.
- `bin/say-menu` — build output, git ignored.
- `install.sh` — build plus symlinks into `~/.local/bin`.
- `~/.claude/say-prefs.json` — speed, `engine` (`neural`/`system`),
  `neural_voice` (`auto`, an edge-tts id, or `local`), `voice` (Latin),
  `voice_cyrillic`.

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
SAY_MENU_OPEN=1 bin/say-menu "$TMPDIR/t.txt" &   # launch, panel opens itself
ps -x -o args= | grep '[a]fplay'         # neural: -r <speed> and the rendered file
ps -o args= -p "$(pgrep -x say | head -1)"   # macOS voice: -r <wpm> and -v <voice>
pgrep -x say-menu || echo "exited"       # it must quit after the last sentence
say --stop
```

`ps -o args=` on the child is the main check. `speak --print` shows what a
neural voice will read.
The player deletes the text file after reading it, so write a fresh one per run.
`SAY_MENU_OPEN=1` opens the panel at launch, for screenshots and for checking
that playback keeps advancing while the menu is open.

## Rules

1. **Engines: neural (`bin/speak` + `afplay`) by default, `/usr/bin/say` as the
   fallback and the "macOS voice" choice.** The macOS Russian voice read mixed
   Russian and English badly, which is why neural was added. AVSpeechSynthesizer
   only reaches the compact voices and sounds robotic: tried, reverted, do not
   switch to it.
2. **Keep the system-say forwarding path in `bin/say`.** `say` shadows
   `/usr/bin/say` on PATH; breaking the forward breaks the user's shell.
3. **No dependencies in `bin/say` and the Swift app.** Python standard library,
   AppKit, `swiftc`. Third-party code lives only in the uv scripts `bin/speak`
   and `bin/speak-local.py`, and the player works without them (`hasSpeak`).
4. **Nothing speaks unless the user asks.** No hooks, no automatic playback,
   no dictation. The only network call is a neural voice render; the offline
   Silero voice and the macOS voices send nothing.
5. **The player must quit when the text ends**, so the menu bar item goes away.
6. **One process per sentence** is what makes a live speed or voice change
   possible. Do not batch sentences without saying so — the user chose the
   gaps over losing the live controls.
7. **Never call `DispatchQueue.main` for playback callbacks.** The main queue
   does not run while the menu tracks events, so playback stalls as soon as the
   user opens the panel. Use `onMain(_:)` and `onMain(after:_:)`, which run in
   `.eventTracking` too. This bug shipped once and was caught with the panel open.
8. Update `README.md` when behaviour changes, including a new corner case.

## Where things live in the Swift file

- `readVoices()` parses `say -v '?'`; `SKIP` hides novelty voices; `Voice.rank`
  orders Premium > Enhanced > compact.
- `isCyrillic()` counts letters per sentence and picks the language.
- `speakCurrent()` / `play()` / `finished()` / `killCurrent()` drive playback.
  `killed` guards against advancing when we stopped a process on purpose.
- `prefetch()` / `render()` / `rendered()` run `bin/speak -o` up to `PREFETCH`
  sentences ahead. `generation` drops renders started before a voice change;
  `noAudio` marks failed renders, which fall back to `/usr/bin/say`. `waiting`
  is true while the current sentence is still rendering.
- SIGTERM (`say --stop`) goes through `NSApp.terminate`, so
  `applicationWillTerminate` kills `afplay` and the renders and deletes the
  temp folder.
- `buildMenu()` lays the custom `NSView` out from the top down. Frames are
  absolute, so change the heights together, and keep every control inside the
  view bounds — a control placed below y=0 is clipped by the menu.
- `redraw()` updates the title, the play button symbol, the speed selection,
  the progress bar, the label, and the voice checkmarks.
