# Troubleshooting

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

- **Claude answered your `!say`.** `!say` lands in the chat and Claude often
  comments on it ("You ran say..."). Those comments are skipped: a reply to a
  `!say` is never a turn, so the real answer stays at `-1`.

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

### It reads with the old macOS voice instead of the neural one

- `uv` is not on PATH, or `bin/speak` is not executable: the player hides the
  neural voices. Check `command -v uv` and `ls -l bin/speak`.
- No network, or the service failed: each failed sentence falls back to the
  macOS voice. Test by hand: `speak -o /tmp/t.mp3 "проверка" && afplay /tmp/t.mp3`.
- `edge-tts` uses an unofficial endpoint. When Microsoft changes it, update the
  package: `uv cache clean edge-tts`, then run `speak` again.
- You picked a macOS voice earlier: choose a neural voice under **Voice**.

### A Russian word sounds wrong ("ждёт" as "ждиет")

The multilingual voices (Andrew, Ava, Brian, Emma) read Russian with an English
accent when the sentence holds an English word or acronym. Use **Auto** or
**Dmitry**. For one word read wrong by every voice, add a rule to
`~/.config/claude-say/pronounce.txt`.

### A long pause before the first sentence

The first neural sentence is rendered before playback starts: about 1-2 seconds.
The next ones are rendered while the current one plays. The offline Silero voice
loads torch on each render; its first run ever also downloads the model.

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

Pause is `SIGSTOP` on the `say` or `afplay` process. Audio already inside the CoreAudio
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

No background process, no launch agent. `!say` starts a process that exits
when the text ends or when you press Stop. A neural voice sends each sentence
to Microsoft (see README); choose the offline Silero voice or a macOS voice to
send nothing. Rendered audio lives in `$TMPDIR/say-menu-<pid>/` and is deleted
when the player quits.
