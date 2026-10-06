import Cocoa

// Two engines, one sentence per process either way:
//  - neural: bin/speak renders each sentence to an audio file (Microsoft neural
//    voices online, or Silero offline), a few sentences ahead, and afplay plays it.
//  - system: /usr/bin/say, the same voices the plain `say` command uses.
//    AVSpeechSynthesizer only reaches the compact voices, which sound robotic.
// A sentence the neural engine fails to render falls back to the system engine.

let PREFS = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/say-prefs.json")

let SPEEDS: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
let BASE_WPM: Float = 190

/// Novelty and low quality voices, hidden from the menu.
let SKIP: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
                         "Good News", "Jester", "Organ", "Superstar", "Trinoids", "Whisper",
                         "Wobble", "Zarvox", "Deranged", "Hysterical", "Pipe Organ", "Junior",
                         "Ralph", "Fred", "Kathy", "Princess", "Bruce", "Agnes", "Victoria"]

let CYRILLIC_LANGS = ["ru", "uk", "be", "bg", "sr", "mk"]

/// bin/speak, next to this binary.
let SPEAK = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("speak").path

/// Neural voices. Multilingual ones read Russian with English terms inside well.
/// "local" is Silero: offline, nothing leaves the machine.
let NEURAL: [(id: String, title: String)] = [
    ("en-US-AndrewMultilingualNeural", "Andrew — multilingual"),
    ("en-US-AvaMultilingualNeural", "Ava — multilingual"),
    ("en-US-BrianMultilingualNeural", "Brian — multilingual"),
    ("en-US-EmmaMultilingualNeural", "Emma — multilingual"),
    ("ru-RU-DmitryNeural", "Dmitry — ru"),
    ("ru-RU-SvetlanaNeural", "Svetlana — ru"),
    ("local", "Offline — Silero, ru (nothing sent)"),
]
/// Sentences rendered ahead of the one playing, so there is no gap between them.
let PREFETCH = 2

struct Voice {
    let name: String
    let lang: String
    /// Premium beats enhanced beats compact.
    var rank: Int {
        if name.contains("Premium") { return 2 }
        if name.contains("Enhanced") { return 1 }
        return 0
    }
    var isCyrillic: Bool { CYRILLIC_LANGS.contains(where: { lang.hasPrefix($0) }) }
}

func speedLabel(_ s: Float) -> String {
    s == Float(Int(s)) ? "\(Int(s))x" : String(format: "%gx", s)
}

/// True when the text holds more Cyrillic letters than Latin ones.
func isCyrillic(_ s: String) -> Bool {
    var cyr = 0, lat = 0
    for u in s.unicodeScalars {
        if u.value >= 0x0400 && u.value <= 0x04FF { cyr += 1 }
        else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
    }
    return cyr > lat
}

final class Controller: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var menu = NSMenu()
    var sentences: [String] = []
    var index = 0
    var speed: Float = 1.0
    var voiceLatin: String?          // nil = system voice
    var voiceCyrillic: String?       // nil = best installed Cyrillic voice
    var paused = false
    var voices: [Voice] = []

    var proc: Process?
    var killed = false               // true while we stop a process on purpose

    // neural engine
    let hasSpeak = FileManager.default.isExecutableFile(atPath: SPEAK)
    var engine = "neural"            // "neural" or "system"
    var neuralVoice = NEURAL[0].id
    var audio: [Int: String] = [:]   // sentence index -> rendered file
    var rendering: [Int: Process] = [:]
    var noAudio: Set<Int> = []       // render failed: system voice for these
    var generation = 0               // bumped on a voice change, drops stale renders
    var waiting = false              // the current sentence is still rendering
    let workDir = NSTemporaryDirectory() + "say-menu-\(getpid())"
    var termSource: DispatchSourceSignal?

    // player controls
    var playButton: NSButton!
    var speedControl: NSSegmentedControl!
    var progressLabel: NSTextField!
    var progressBar: NSProgressIndicator!
    var voiceMenu = NSMenu()

    // MARK: setup

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadPrefs()
        if !hasSpeak { engine = "system" }
        voices = readVoices()
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        // `say --stop` sends SIGTERM: quit cleanly, so afplay and the renders stop too.
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource?.setEventHandler { [weak self] in self?.onMain { NSApp.terminate(nil) } }
        termSource?.resume()

        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8), !raw.isEmpty else {
            NSApp.terminate(nil); return
        }
        try? FileManager.default.removeItem(atPath: path)
        sentences = split(raw)
        if sentences.isEmpty { NSApp.terminate(nil); return }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        item.menu = menu
        redraw()
        speakCurrent()

        // Docs and testing: open the panel by itself, so a screenshot can catch it.
        if ProcessInfo.processInfo.environment["SAY_MENU_OPEN"] == "1" {
            onMain(after: 0.6) { self.item.button?.performClick(nil) }
        }
    }

    func split(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        return out.isEmpty ? [text] : out
    }

    func readVoices() -> [Voice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let sysLang = String((Locale.current.identifier.split(separator: "_").first ?? "en").prefix(2))

        var out: [Voice] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.components(separatedBy: "#")
            guard parts.count >= 2 else { continue }
            let head = parts[0].trimmingCharacters(in: .whitespaces)
            guard let r = head.range(of: "\\s{2,}", options: .regularExpression) else { continue }
            let name = String(head[head.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let lang = String(head[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if SKIP.contains(where: { name == $0 || name.hasPrefix($0 + " (") }) { continue }
            let v = Voice(name: name, lang: lang)
            if v.isCyrillic || lang.hasPrefix("en") || lang.hasPrefix(sysLang) { out.append(v) }
        }
        return out.sorted { ($0.rank, $1.name) > ($1.rank, $0.name) }
    }

    /// The voice to speak this sentence with: nil means the system voice.
    func voiceFor(_ sentence: String) -> String? {
        guard isCyrillic(sentence) else { return voiceLatin }
        if let v = voiceCyrillic { return v }
        // Russian first, then any other Cyrillic voice. The list is rank sorted,
        // so a downloaded premium voice wins over the compact one.
        return (voices.first(where: { $0.lang.hasPrefix("ru") })
                ?? voices.first(where: { $0.isCyrillic }))?.name
    }

    // MARK: prefs

    func loadPrefs() {
        guard let d = try? Data(contentsOf: PREFS),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let s = j["speed"] as? Double { speed = Float(s) }
        if let v = j["voice"] as? String, !v.isEmpty { voiceLatin = v }
        if let v = j["voice_cyrillic"] as? String, !v.isEmpty { voiceCyrillic = v }
        if let e = j["engine"] as? String, e == "system" || e == "neural" { engine = e }
        if let v = j["neural_voice"] as? String, NEURAL.contains(where: { $0.id == v }) { neuralVoice = v }
    }

    func savePrefs() {
        var j: [String: Any] = ["speed": Double(speed), "engine": engine, "neural_voice": neuralVoice]
        if let v = voiceLatin { j["voice"] = v }
        if let v = voiceCyrillic { j["voice_cyrillic"] = v }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: .prettyPrinted) {
            try? d.write(to: PREFS)
        }
    }

    // MARK: playback

    // The main queue does not run while a menu tracks events, so a plain
    // DispatchQueue.main call would stall playback whenever the panel is open.
    // These two helpers run in the tracking mode too.

    /// Thread safe: callable from a process termination handler.
    func onMain(_ block: @escaping () -> Void) {
        let modes = [CFRunLoopMode.commonModes.rawValue,
                     RunLoop.Mode.eventTracking.rawValue as CFString] as CFArray
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Main thread only.
    func onMain(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
    }

    var usesNeural: Bool { engine == "neural" && !noAudio.contains(index) }

    func speakCurrent() {
        guard index < sentences.count else { NSApp.terminate(nil); return }
        if usesNeural {
            prefetch()
            guard let file = audio[index] else { waiting = true; redraw(); return }
            waiting = false
            play("/usr/bin/afplay", ["-q", "1", "-r", String(speed), file], input: nil)
        } else {
            waiting = false
            var args = ["-r", String(Int(BASE_WPM * speed))]
            if let v = voiceFor(sentences[index]) { args += ["-v", v] }
            play("/usr/bin/say", args, input: sentences[index])
        }
    }

    func play(_ exe: String, _ args: [String], input: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let stdin = Pipe()
        if input != nil { p.standardInput = stdin }
        p.terminationHandler = { [weak self] _ in
            self?.onMain { self?.finished() }
        }
        guard (try? p.run()) != nil else { NSApp.terminate(nil); return }
        if let text = input {
            stdin.fileHandleForWriting.write(text.data(using: .utf8) ?? Data())
            stdin.fileHandleForWriting.closeFile()
        }
        proc = p
        paused = false
        redraw()
    }

    // MARK: neural rendering

    func prefetch() {
        for i in index..<min(index + 1 + PREFETCH, sentences.count)
            where audio[i] == nil && rendering[i] == nil && !noAudio.contains(i) {
            render(i)
        }
    }

    func render(_ i: Int) {
        let gen = generation
        let local = neuralVoice == "local"
        let file = workDir + "/\(gen)-\(i)." + (local ? "wav" : "mp3")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SPEAK)
        p.arguments = ["--raw", "-o", file] + (local ? ["--local"] : ["-v", neuralVoice])
            + ["--", sentences[i]]
        // speak is a uv script: make sure uv is found even with a thin PATH.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] pr in
            let ok = pr.terminationStatus == 0
            self?.onMain { self?.rendered(i, gen, file, ok) }
        }
        guard (try? p.run()) != nil else { noAudio.insert(i); return }
        rendering[i] = p
    }

    func rendered(_ i: Int, _ gen: Int, _ file: String, _ ok: Bool) {
        guard gen == generation else { try? FileManager.default.removeItem(atPath: file); return }
        rendering[i] = nil
        if ok && FileManager.default.fileExists(atPath: file) { audio[i] = file } else { noAudio.insert(i) }
        if waiting && i == index { speakCurrent() }
    }

    /// Drop every rendered or rendering sentence, after a voice change.
    func resetAudio() {
        generation += 1
        rendering.values.forEach { $0.terminate() }
        rendering.removeAll()
        audio.values.forEach { try? FileManager.default.removeItem(atPath: $0) }
        audio.removeAll()
        noAudio.removeAll()
    }

    func applicationWillTerminate(_ note: Notification) {
        killCurrent()
        rendering.values.forEach { $0.terminate() }
        try? FileManager.default.removeItem(atPath: workDir)
    }

    func finished() {
        if killed { killed = false; return }   // we stopped it, do not advance
        index += 1
        if index < sentences.count { speakCurrent() } else { NSApp.terminate(nil) }
    }

    func killCurrent() {
        guard let p = proc, p.isRunning else { return }
        killed = true
        if paused { kill(p.processIdentifier, SIGCONT) }   // a stopped process must run to die
        p.terminate()
    }

    /// Replay the current sentence — used after a speed, voice, or position change.
    func restartCurrent() {
        killCurrent()
        onMain(after: 0.12) { self.speakCurrent() }
    }

    // MARK: actions

    @objc func togglePlay() {
        guard let p = proc, p.isRunning else { return }
        kill(p.processIdentifier, paused ? SIGCONT : SIGSTOP)
        paused.toggle()
        redraw()
    }

    @objc func stopAll() {
        menu.cancelTracking()
        killCurrent()
        NSApp.terminate(nil)
    }

    @objc func back() { index = max(0, index - 1); restartCurrent() }

    @objc func forward() {
        if index + 1 >= sentences.count { stopAll(); return }
        index += 1
        restartCurrent()
    }

    @objc func speedChanged(_ sender: NSSegmentedControl) {
        speed = SPEEDS[sender.selectedSegment]
        savePrefs()
        restartCurrent()
    }

    /// Tags: -1 = system voice for Latin, -2 = automatic Cyrillic voice,
    /// 0..999 = a Latin voice, 1000..1999 = a Cyrillic voice, 2000+ = a neural voice.
    @objc func setVoice(_ sender: NSMenuItem) {
        let t = sender.tag
        if t >= 2000 {
            engine = "neural"
            neuralVoice = NEURAL[t - 2000].id
            resetAudio()
            savePrefs()
            restartCurrent()
            return
        }
        let wasNeural = usesNeural
        engine = "system"
        let cyrillic = t == -2 || t >= 1000
        if cyrillic {
            voiceCyrillic = t == -2 ? nil : voices[t - 1000].name
        } else {
            voiceLatin = t == -1 ? nil : voices[t].name
        }
        savePrefs()
        redraw()
        if wasNeural || isCyrillic(sentences[index]) == cyrillic { restartCurrent() }
    }

    // MARK: menu

    func button(_ symbol: String, _ sel: Selector, _ x: CGFloat, _ y: CGFloat, _ tip: String) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        let b = NSButton(frame: NSRect(x: x, y: y, width: 52, height: 30))
        b.image = img
        b.imageScaling = .scaleProportionallyDown
        b.bezelStyle = .texturedRounded
        b.target = self
        b.action = sel
        b.toolTip = tip
        return b
    }

    func buildMenu() {
        // Frames run from the top down: pad 6, buttons, speed, bar, label, pad 6.
        let W: CGFloat = 244, H: CGFloat = 100
        let view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let rowY = H - 6 - 30
        view.addSubview(button("backward.end.fill", #selector(back), 10, rowY, "Back one sentence"))
        playButton = button("pause.fill", #selector(togglePlay), 66, rowY, "Pause")
        view.addSubview(playButton)
        view.addSubview(button("stop.fill", #selector(stopAll), 122, rowY, "Stop"))
        view.addSubview(button("forward.end.fill", #selector(forward), 178, rowY, "Skip one sentence"))

        speedControl = NSSegmentedControl(
            labels: SPEEDS.map { speedLabel($0) },
            trackingMode: .selectOne, target: self, action: #selector(speedChanged(_:)))
        speedControl.frame = NSRect(x: 10, y: rowY - 8 - 22, width: W - 20, height: 22)
        speedControl.controlSize = .small
        speedControl.font = .systemFont(ofSize: 10)
        view.addSubview(speedControl)

        progressBar = NSProgressIndicator(frame: NSRect(x: 10, y: rowY - 8 - 22 - 10 - 4,
                                                        width: W - 20, height: 4))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.controlSize = .small
        view.addSubview(progressBar)

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.frame = NSRect(x: 10, y: 6, width: W - 20, height: 15)
        progressLabel.font = .systemFont(ofSize: 10)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .center
        progressLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(progressLabel)

        let player = NSMenuItem()
        player.view = view
        menu.addItem(player)
        menu.addItem(.separator())

        buildVoiceMenu()
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
    }

    func header(_ m: NSMenu, _ title: String) {
        if #available(macOS 14.0, *) {
            m.addItem(NSMenuItem.sectionHeader(title: title))
        } else {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            m.addItem(mi)
        }
    }

    func voiceEntry(_ title: String, tag: Int) {
        let mi = NSMenuItem(title: title, action: #selector(setVoice(_:)), keyEquivalent: "")
        mi.target = self
        mi.tag = tag
        voiceMenu.addItem(mi)
    }

    /// Neural voices first, then the macOS voices: one for Latin text, one for Cyrillic.
    func buildVoiceMenu() {
        if hasSpeak {
            header(voiceMenu, "Neural voices")
            for (i, v) in NEURAL.enumerated() { voiceEntry(v.title, tag: 2000 + i) }
        }
        header(voiceMenu, "macOS voice, Latin text")
        voiceEntry("System voice (Spoken Content)", tag: -1)
        for (i, v) in voices.enumerated() where !v.isCyrillic {
            voiceEntry("\(v.name) — \(v.lang)", tag: i)
        }
        header(voiceMenu, "macOS voice, Cyrillic text")
        voiceEntry("Best installed voice", tag: -2)
        for (i, v) in voices.enumerated() where v.isCyrillic {
            voiceEntry("\(v.name) — \(v.lang)", tag: i + 1000)
        }
    }

    func redraw() {
        item.button?.title = (paused ? "⏸ " : "🔊 ") + speedLabel(speed)

        playButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: paused ? "Play" : "Pause")
        playButton.toolTip = paused ? "Play" : "Pause"

        speedControl.selectedSegment = SPEEDS.firstIndex(of: speed) ?? 1

        progressBar.maxValue = Double(sentences.count)
        progressBar.doubleValue = Double(index + 1)

        let neuralName = NEURAL.first(where: { $0.id == neuralVoice })?.title
            .components(separatedBy: " —").first ?? neuralVoice
        let voiceName = waiting ? "loading…"
            : usesNeural ? neuralName : (voiceFor(sentences[index]) ?? "system voice")
        progressLabel.stringValue = "Sentence \(index + 1) of \(sentences.count) · \(voiceName)"

        let system = engine == "system"
        for mi in voiceMenu.items where mi.action != nil {
            let t = mi.tag
            switch t {
            case 2000...: mi.state = !system && NEURAL[t - 2000].id == neuralVoice ? .on : .off
            case -1: mi.state = system && voiceLatin == nil ? .on : .off
            case -2: mi.state = system && voiceCyrillic == nil ? .on : .off
            case 1000...: mi.state = system && voices[t - 1000].name == voiceCyrillic ? .on : .off
            default: mi.state = system && voices[t].name == voiceLatin ? .on : .off
            }
        }
    }
}

let app = NSApplication.shared
let c = Controller()
app.delegate = c
app.run()
