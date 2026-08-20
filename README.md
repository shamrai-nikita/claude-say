# claude-say

Listen to a Claude Code response instead of reading it. You pick which one.

Type `!say` in Claude Code. The previous response is spoken aloud, and a player
appears in the macOS menu bar with play/pause, stop, sentence skip, speed, and
voice. The menu bar item disappears when the text ends.

Nothing speaks on its own: there is no hook, no daemon, no login item, and no
microphone use. `!say` is the only trigger.

## Install

```sh
./install.sh
```

It compiles `src/SayMenu.swift` into `bin/say-menu` and links `bin/say` into
`~/.local/bin`. Requirements: macOS, Xcode Command Line Tools (`swiftc`), and
`~/.local/bin` on your PATH.

## Use

| Command | What it does |
|---|---|
| `!say` | speak the last response |
| `!say 3` | speak the 3rd-from-last response |
| `!say -l` | list the last 10 responses, first line of each |
| `!say -t` | print the cleaned text, speak nothing |
| `!say --stop` | stop playback, remove the menu bar item |
| `!say-last` | same script, kept for muscle memory |

The `!` prefix runs a shell command inside Claude Code, so the output lands in
the conversation. Outside Claude Code, drop the `!`.

### Menu bar player

- Four buttons: back one sentence, play/pause, stop, skip one sentence.
- Speed row: 0.75x, 1x, 1.25x, 1.5x, 1.75x, 2x. 1x is 190 words per minute.
- Progress bar plus a line reading `Sentence 12 of 48 · Milena (Enhanced)`.
- `Voice` submenu with two sections: **Latin text** and **Cyrillic text**.
- The status item title shows the state: `🔊 1.5x` playing, `⏸ 1.5x` paused.

Speed and voice choices are saved and reused by the next run.

### Languages

Each sentence picks its own voice. A sentence with more Cyrillic letters than
Latin ones uses the Cyrillic voice; everything else uses the Latin voice. Mixed
responses switch back and forth by themselves.

The Cyrillic default is the best installed Russian voice, ranked Premium >
Enhanced > compact. Download better voices in System Settings → Accessibility →
Read & Speak → System voice → Manage Voices. Check what landed:

```sh
say -v '?' | grep ru_RU
```

## How it works

```
!say                     bin/say (Python)
                           reads ~/.claude/projects/<project>/<session>.jsonl
                           picks one assistant turn, strips markdown
                           writes the text to $TMPDIR/say-menu-text.txt
                           launches bin/say-menu detached
bin/say-menu (Swift)     NSStatusItem + a custom NSView with the controls
                           splits the text into sentences
                           runs /usr/bin/say once per sentence, text on stdin
                           pause = SIGSTOP, resume = SIGCONT
                           quits itself after the last sentence
```

Layout:

```
bin/say            launcher and transcript reader (Python 3, stdlib only)
bin/say-menu       compiled binary, not in git
src/SayMenu.swift  the menu bar player
install.sh         build + symlink
~/.claude/say-prefs.json   saved speed and voice
```

### Two design choices worth knowing

**It shells out to `/usr/bin/say` instead of using AVSpeechSynthesizer.**
AVSpeechSynthesizer only reaches the *compact* voices on this Mac
(`com.apple.voice.compact.en-US.Samantha`), which sound robotic. The `say`
binary uses the system voice from Spoken Content and every downloaded voice.
Do not "modernise" this back to AVSpeechSynthesizer.

**One process per sentence.** That is what makes a speed or voice change apply
immediately: the current sentence is killed and replayed with the new setting.
The cost is a short gap between sentences.

## Corner cases and debugging

Symptoms first, so you can find yours fast.

### `say` prints "no assistant responses in this session yet"

The transcript has no assistant text yet, or the format changed. Check what the
launcher sees:

```sh
say -l                      # the turns it found
say -t | head               # the cleaned text of the last one
ls -lt ~/.claude/projects/$(pwd | tr '/_.' '-')/ | head
```

`bin/say` reads JSONL entries with `type: "assistant"` and content blocks of
`type: "text"`, and treats a `type: "user"` entry without a `tool_result` block
as the start of a new turn. A Claude Code update that renames those fields
breaks the parse. Fix is in `turns()` and `is_user_prompt()`.

### It speaks the wrong response

- **Two Claude sessions in the same folder.** The launcher confirms the `cwd`
  field inside each transcript, then takes the most recently written match.
  With two live sessions in one directory, that can be the other one.
- **The response has not been flushed yet.** Rare. Run `!say` again.
- Run `!say -l` and speak by number: `!say 2`.

### It runs from a subdirectory but finds nothing

`transcript_path()` tries the folder named after the current directory, then
searches every project transcript for a matching `cwd`, then walks up to a
parent directory. If all three fail it exits with the directory name in the
message.

### `say hello` no longer reaches the system command

`~/.local/bin/say` shadows `/usr/bin/say` in interactive shells. The launcher
forwards to the real binary when it sees anything that is not its own flags:
text arguments, system flags like `-o` or `-f`, or piped input. Only these
belong to the launcher: no arguments, an integer, `-l`, `-t`, `--stop`, `-h`.

Edge: `cat file | say` forwards (stdin is a pipe or a file), but a shell where
stdin is `/dev/null` or a terminal is treated as ours. If a script needs the
real thing with certainty, call `/usr/bin/say` by full path.

Voice names hold spaces and brackets — `say -v "Milena (Enhanced)"` needs the
quotes in a shell. The Swift app passes argv directly, so it needs none.

### Every sentence flies past with no sound

A voice saved in `~/.claude/say-prefs.json` no longer exists — you deleted it in
System Settings, or the name changed. `say -v <gone>` exits at once, and the
player treats that as "sentence finished" and moves on. Reset:

```sh
rm ~/.claude/say-prefs.json
```

The same file is ignored silently when its JSON is corrupt, which is by design.

### The menu bar item is missing while audio plays

The menu bar is full, or the notch hides the item. The app is running:

```sh
pgrep -x say-menu && say --stop
```

### A `say` process is stuck and silent

If the player is force-killed while paused, its child stays in state `T`
(stopped) forever:

```sh
ps -o pid,stat,args -x | grep '[s]ay'
pkill -CONT -x say ; pkill -x say
```

### Pause reacts late

Pause is `SIGSTOP` on the `say` process. Audio already inside the CoreAudio
buffer keeps playing for about a quarter second, then stops. There is no way
around it short of a different speech engine.

### A speed or voice change repeats a few words

By design. The current sentence restarts with the new setting.

### Sentence splitting looks wrong

Splitting uses Foundation's `.bySentences`, which breaks on abbreviations such
as "e.g." or "Mr.". A wrong split costs you a short gap, nothing more.

### Code and symbols

The launcher replaces fenced code blocks with the words "code block skipped",
drops link URLs, headers, list markers, table rows, and emoji. It keeps inline
code text, and it keeps Cyrillic. See `clean()` in `bin/say`.

### Only one response plays at a time

Launching `!say` kills the previous `say-menu`. Two projects cannot play at
once, on purpose — two voices at once are unusable.

### After a macOS upgrade

The binary should keep running. If it refuses:

```sh
./install.sh
```

If `swiftc` is missing, run `xcode-select --install` first.

### Nothing survives that I should worry about?

No background process, no launch agent, no network access. `!say` starts a
process that exits when the text ends or when you press Stop.
