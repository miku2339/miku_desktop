import AppKit
import QuartzCore

/// Little games to play with Miku from the chat: rock-paper-scissors, a Vocaloid song quiz
/// and tapping along to a beat.
enum MiniGame: String, CaseIterable {
    case rps, quiz, rhythm

    var titleKey: String { "game_\(rawValue)" }

    /// "Let's play rock-paper-scissors" typed in the chat starts the game directly.
    static func requested(in text: String) -> MiniGame? {
        let lowered = text.lowercased()
        let refusals = ["唔玩", "不玩", "唔想", "不想", "don't", "dont", "not now", "やらない", "しない", "いや"]
        guard !refusals.contains(where: lowered.contains) else { return nil }
        if ["包剪揼", "剪刀石頭布", "剪刀石头布", "猜拳", "石頭剪刀布", "rock paper scissors", "rock-paper-scissors", "じゃんけん", "ジャンケン"].contains(where: lowered.contains) {
            return .rps
        }
        if ["歌曲問答", "歌曲问答", "問答", "quiz", "クイズ"].contains(where: lowered.contains) {
            return .quiz
        }
        if ["打拍子", "節奏遊戲", "节奏游戏", "rhythm", "リズム"].contains(where: lowered.contains) {
            return .rhythm
        }
        return nil
    }

    /// The language the games talk in: the reply language if one is chosen, else the app's.
    static var language: String {
        let chosen = UserDefaults.standard.string(forKey: "replyLanguage") ?? "auto"
        if ["zh-Hant", "en", "ja"].contains(chosen) { return chosen }
        return AppLanguage.resolved.rawValue
    }

    static func text(_ zh: String, _ en: String, _ ja: String) -> String {
        switch language {
        case "en": return en
        case "ja": return ja
        default: return zh
        }
    }
}

/// One thing Miku says during a game, with the buttons to answer it (if any).
struct GameLine {
    struct Choice {
        let id: String
        let title: String
    }

    var text: String
    var emotion = "happy"
    var action = "idle"
    var choices: [Choice] = []
    /// Rock-paper-scissors: her hand and how it went for her, for the desktop.
    var rps: (hand: String, outcome: String)?
}

/// A game in progress in the chat.
@MainActor
protocol GameSession: AnyObject {
    var isOver: Bool { get }
    func start() -> [GameLine]
    /// The user's pick: what to show as their message, and her answer.
    func choose(_ id: String) -> (said: String, lines: [GameLine])
}

// MARK: - Rock-paper-scissors

enum RPSHand: String, CaseIterable {
    case rock, scissors, paper

    func beats(_ other: RPSHand) -> Bool {
        switch (self, other) {
        case (.rock, .scissors), (.scissors, .paper), (.paper, .rock): return true
        default: return false
        }
    }

    var emoji: String {
        switch self {
        case .rock: return "✊"
        case .scissors: return "✌️"
        case .paper: return "✋"
        }
    }

    var name: String {
        switch self {
        case .rock: return MiniGame.text("揼", "rock", "グー")
        case .scissors: return MiniGame.text("剪", "scissors", "チョキ")
        case .paper: return MiniGame.text("包", "paper", "パー")
        }
    }
}

/// First to two wins.
@MainActor
final class RPSSession: GameSession {
    private(set) var isOver = false
    private var mine = 0
    private var yours = 0
    private let pick: () -> RPSHand

    init(pick: @escaping () -> RPSHand = { RPSHand.allCases.randomElement() ?? .rock }) {
        self.pick = pick
    }

    private var choices: [GameLine.Choice] {
        RPSHand.allCases.map { GameLine.Choice(id: $0.rawValue, title: "\($0.emoji) \($0.name)") }
    }

    func start() -> [GameLine] {
        [GameLine(
            text: MiniGame.text("嚟玩包剪揼！三盤兩勝～包、剪、揼！你出咩？", "Rock-paper-scissors! Best of three~ Rock, paper, scissors… what's yours?", "じゃんけんしよ！三本勝負～じゃん、けん…何出す？"),
            emotion: "happy", action: "cheer", choices: choices
        )]
    }

    func choose(_ id: String) -> (said: String, lines: [GameLine]) {
        guard !isOver, let theirs = RPSHand(rawValue: id) else { return ("", []) }
        let hers = pick()
        let said = "\(theirs.emoji) \(theirs.name)"
        var line: GameLine
        if hers == theirs {
            line = GameLine(
                text: MiniGame.text("我出\(hers.emoji)\(hers.name)！打和～再嚟！", "I threw \(hers.emoji) \(hers.name)! A draw~ again!", "わたしは\(hers.emoji)\(hers.name)！あいこ～もう一回！"),
                emotion: "surprised", action: "idle", choices: choices, rps: (hers.rawValue, "draw")
            )
        } else if hers.beats(theirs) {
            mine += 1
            line = GameLine(
                text: MiniGame.text("我出\(hers.emoji)\(hers.name)！我贏咗～（\(mine):\(yours)）", "I threw \(hers.emoji) \(hers.name)! I win~ (\(mine)–\(yours))", "わたしは\(hers.emoji)\(hers.name)！勝った～（\(mine)対\(yours)）"),
                emotion: "happy", action: "idle", choices: choices, rps: (hers.rawValue, "win")
            )
        } else {
            yours += 1
            line = GameLine(
                text: MiniGame.text("我出\(hers.emoji)\(hers.name)…你贏咗！（\(mine):\(yours)）", "I threw \(hers.emoji) \(hers.name)… you win! (\(mine)–\(yours))", "わたしは\(hers.emoji)\(hers.name)…負けた！（\(mine)対\(yours)）"),
                emotion: "pout", action: "idle", choices: choices, rps: (hers.rawValue, "lose")
            )
        }
        guard mine == 2 || yours == 2 else { return (said, [line]) }
        isOver = true
        line.choices = []
        let end = mine == 2
            ? GameLine(text: MiniGame.text("我贏咗成局！嘿嘿，下次再挑戰我啦～", "I won the match! Hehe, challenge me again sometime~", "わたしの勝ち！えへへ、また挑戦してね～"), emotion: "happy", action: "cheer")
            : GameLine(text: MiniGame.text("你贏咗成局…好唔甘心！下次一定贏返！", "You won the match… so frustrating! I'll get you next time!", "負けちゃった…くやしい！次は絶対勝つから！"), emotion: "pout", action: "pout")
        return (said, [line, end])
    }
}

// MARK: - Vocaloid song quiz

/// Well-known Miku songs and their producers (only ones we're sure of).
enum SongQuiz {
    struct Song {
        let title: String
        let producer: String
    }

    static let songs: [Song] = [
        Song(title: "千本桜", producer: "黒うさP"),
        Song(title: "メルト", producer: "ryo (supercell)"),
        Song(title: "ワールドイズマイン", producer: "ryo (supercell)"),
        Song(title: "ブラック★ロックシューター", producer: "ryo (supercell)"),
        Song(title: "恋は戦争", producer: "ryo (supercell)"),
        Song(title: "ローリンガール", producer: "wowaka"),
        Song(title: "アンノウン・マザーグース", producer: "wowaka"),
        Song(title: "裏表ラバーズ", producer: "wowaka"),
        Song(title: "砂の惑星", producer: "ハチ"),
        Song(title: "マトリョシカ", producer: "ハチ"),
        Song(title: "初音ミクの消失", producer: "cosMo@暴走P"),
        Song(title: "ヴァンパイア", producer: "DECO*27"),
        Song(title: "ゴーストルール", producer: "DECO*27"),
        Song(title: "ラビットホール", producer: "DECO*27"),
        Song(title: "愛言葉", producer: "DECO*27"),
        Song(title: "脳漿炸裂ガール", producer: "れるりり"),
        Song(title: "Tell Your World", producer: "livetune"),
        Song(title: "みくみくにしてあげる♪【してやんよ】", producer: "ika"),
        Song(title: "深海少女", producer: "ゆうゆ"),
        Song(title: "天ノ弱", producer: "164"),
        Song(title: "桜ノ雨", producer: "halyosy"),
        Song(title: "ロキ", producer: "みきとP"),
        Song(title: "少女レイ", producer: "みきとP"),
        Song(title: "グリーンライツ・セレナーデ", producer: "Omoi"),
        Song(title: "Sweet Devil", producer: "八王子P"),
        Song(title: "命に嫌われている。", producer: "カンザキイオリ")
    ]

    struct Question {
        let prompt: String
        let options: [String]
        let answer: Int
        let song: Song
    }

    /// A question: who made a song, or which song is by a producer.
    static func question(avoiding asked: Set<String>, using generator: inout some RandomNumberGenerator) -> Question {
        let pool = songs.filter { !asked.contains($0.title) }
        let song = (pool.isEmpty ? songs : pool).randomElement(using: &generator) ?? songs[0]
        if Bool.random(using: &generator) {
            let producers = Array(Set(songs.map(\.producer)).subtracting([song.producer])).shuffled(using: &generator).prefix(3)
            var options = Array(producers) + [song.producer]
            options.shuffle(using: &generator)
            let prompt = MiniGame.text("「\(song.title)」係邊位 P主嘅作品？", "Who made “\(song.title)”?", "「\(song.title)」を作ったのは誰？")
            return Question(prompt: prompt, options: options, answer: options.firstIndex(of: song.producer) ?? 0, song: song)
        }
        let others = songs.filter { $0.producer != song.producer }.shuffled(using: &generator).prefix(3).map(\.title)
        var options = Array(others) + [song.title]
        options.shuffle(using: &generator)
        let prompt = MiniGame.text("以下邊首係 \(song.producer) 嘅歌？", "Which of these is by \(song.producer)?", "\(song.producer)の曲はどれ？")
        return Question(prompt: prompt, options: options, answer: options.firstIndex(of: song.title) ?? 0, song: song)
    }
}

@MainActor
final class QuizSession: GameSession {
    static let length = 5
    private(set) var isOver = false
    private var number = 0
    private var score = 0
    private var asked: Set<String> = []
    private var current: SongQuiz.Question?
    private var generator = SystemRandomNumberGenerator()

    func start() -> [GameLine] {
        let intro = GameLine(
            text: MiniGame.text("Vocaloid 歌曲問答！一共 \(Self.length) 題，睇吓你有幾熟～", "Vocaloid song quiz! \(Self.length) questions — let's see how well you know them~", "ボカロ曲クイズ！全\(Self.length)問、どれだけ知ってるかな～"),
            emotion: "happy", action: "clap"
        )
        return [intro, nextQuestion()]
    }

    private func nextQuestion() -> GameLine {
        number += 1
        let question = SongQuiz.question(avoiding: asked, using: &generator)
        asked.insert(question.song.title)
        current = question
        let choices = question.options.enumerated().map { GameLine.Choice(id: String($0.offset), title: $0.element) }
        return GameLine(text: "Q\(number). \(question.prompt)", emotion: "curious", action: "think", choices: choices)
    }

    func choose(_ id: String) -> (said: String, lines: [GameLine]) {
        guard !isOver, let question = current, let index = Int(id), question.options.indices.contains(index) else { return ("", []) }
        current = nil
        let fact = "「\(question.song.title)」— \(question.song.producer)"
        var lines: [GameLine] = []
        if index == question.answer {
            score += 1
            lines.append(GameLine(text: MiniGame.text("答啱喇！\(fact) ♪", "Correct! \(fact) ♪", "正解！\(fact)♪"), emotion: "happy", action: "clap"))
        } else {
            lines.append(GameLine(text: MiniGame.text("唔係喔～答案係：\(fact)", "Not quite~ it's \(fact)", "ざんねん～正解は\(fact)"), emotion: "sad", action: "shakeHead"))
        }
        if number < Self.length {
            lines.append(nextQuestion())
        } else {
            isOver = true
            let end: GameLine
            switch score {
            case Self.length:
                end = GameLine(text: MiniGame.text("全中！\(score)/\(Self.length)！你真係好熟 Vocaloid 喔！", "Perfect, \(score)/\(Self.length)! You really know your Vocaloid!", "全問正解！\(score)/\(Self.length)！すっごく詳しいね！"), emotion: "happy", action: "cheer")
            case 3...:
                end = GameLine(text: MiniGame.text("\(score)/\(Self.length)，好叻呀！", "\(score)/\(Self.length) — nice!", "\(score)/\(Self.length)、やるね！"), emotion: "happy", action: "clap")
            default:
                end = GameLine(text: MiniGame.text("\(score)/\(Self.length)～唔緊要，下次我哋一齊聽多啲歌！", "\(score)/\(Self.length)~ That's okay, let's listen to more songs together!", "\(score)/\(Self.length)～大丈夫、もっと一緒に曲を聴こう！"), emotion: "calm", action: "nod")
            }
            lines.append(end)
        }
        let said = question.options[index]
        return (said, lines)
    }
}

// MARK: - Rhythm game

/// Judging taps against the beat (pure, so it can be tested).
enum RhythmJudge {
    static let perfect: TimeInterval = 0.07
    static let good: TimeInterval = 0.15

    enum Grade: String { case perfect, good, miss }

    static func grade(offset: TimeInterval) -> Grade {
        let distance = abs(offset)
        return distance <= perfect ? .perfect : distance <= good ? .good : .miss
    }

    /// Points out of 100 for a list of grades.
    static func score(_ grades: [Grade]) -> Int {
        guard !grades.isEmpty else { return 0 }
        let points = grades.reduce(0) { $0 + ($1 == .perfect ? 2 : $1 == .good ? 1 : 0) }
        return Int((Double(points) / Double(grades.count * 2) * 100).rounded())
    }
}

/// Tap (space bar or click) on every beat while Miku bounces along on the desktop.
@MainActor
final class RhythmGameWindowController: NSWindowController, NSWindowDelegate {
    static let bpm: Double = 104
    static let countIn = 4
    static let beats = 16

    var onBeat: (() -> Void)?
    var onFinish: ((Int, [RhythmJudge.Grade]) -> Void)?

    private let pad = RhythmPadView()
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var lastBeatIndex = -1
    private var grades: [Int: RhythmJudge.Grade] = [:]
    private var finished = false
    private let tick = NSSound(named: "Tink")
    private let accent = NSSound(named: "Pop")

    private var interval: TimeInterval { 60 / Self.bpm }

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = L10n.text("game_rhythm")
        let background = MikuBackgroundView()
        window.contentView = background
        super.init(window: window)
        window.delegate = self
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.onTap = { [weak self] in self?.tap() }
        background.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            pad.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            pad.topAnchor.constraint(equalTo: background.topAnchor, constant: 28),
            pad.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(pad)
        finished = false
        grades = [:]
        lastBeatIndex = -1
        startTime = CACurrentMediaTime() + 0.8
        pad.reset()
        pad.message = L10n.text("rhythmReady")
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Beat index (count-in beats are negative) and how far into it we are.
    private func position(at time: CFTimeInterval) -> (index: Int, phase: Double) {
        let beatsSinceStart = (time - startTime) / interval
        let index = Int(floor(beatsSinceStart)) - Self.countIn
        return (index, beatsSinceStart - floor(beatsSinceStart))
    }

    private func step() {
        let now = CACurrentMediaTime()
        guard now >= startTime else { return }
        let (index, phase) = position(at: now)
        if index != lastBeatIndex {
            lastBeatIndex = index
            if index < Self.beats {
                (index < 0 ? accent : tick)?.stop()
                (index < 0 ? accent : tick)?.play()
                onBeat?()
            }
            if index < 0 {
                pad.message = "\(index + Self.countIn + 1)"
            } else if index < Self.beats {
                pad.message = ""
                // A beat nobody tapped for, once it can no longer be hit.
                if index >= 1, grades[index - 1] == nil, now - beatTime(index - 1) > RhythmJudge.good {
                    record(.miss, beat: index - 1)
                }
            }
        }
        pad.pulse = index < Self.beats ? max(0, 1 - phase * 2.4) : 0
        pad.progress = Double(max(0, min(Self.beats, index))) / Double(Self.beats)
        pad.needsDisplay = true
        if index >= Self.beats, !finished, now - beatTime(Self.beats - 1) > RhythmJudge.good {
            for beat in 0..<Self.beats where grades[beat] == nil { grades[beat] = .miss }
            finish()
        }
    }

    private func beatTime(_ index: Int) -> CFTimeInterval {
        startTime + Double(index + Self.countIn) * interval
    }

    private func tap() {
        guard !finished else { return }
        let now = CACurrentMediaTime()
        let nearest = Int(((now - startTime) / interval).rounded()) - Self.countIn
        guard nearest >= 0, nearest < Self.beats, grades[nearest] == nil else {
            pad.flash(.miss)
            return
        }
        let grade = RhythmJudge.grade(offset: now - beatTime(nearest))
        record(grade, beat: nearest)
    }

    private func record(_ grade: RhythmJudge.Grade, beat: Int) {
        grades[beat] = grade
        pad.flash(grade)
    }

    private func finish() {
        finished = true
        timer?.invalidate()
        timer = nil
        let ordered = (0..<Self.beats).map { grades[$0] ?? .miss }
        let score = RhythmJudge.score(ordered)
        let perfect = ordered.filter { $0 == .perfect }.count
        pad.message = L10n.format("rhythmResult", String(score), String(perfect))
        pad.needsDisplay = true
        onFinish?(score, ordered)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        finished = true
    }
}

/// The pad: a ring that pulses on the beat, a progress arc, and the last grade.
final class RhythmPadView: NSView {
    var onTap: (() -> Void)?
    var pulse: Double = 0
    var progress: Double = 0
    var message = "" { didSet { needsDisplay = true } }
    private var grade: RhythmJudge.Grade?
    private var gradeAt: CFTimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    func reset() {
        pulse = 0
        progress = 0
        grade = nil
        needsDisplay = true
    }

    func flash(_ grade: RhythmJudge.Grade) {
        self.grade = grade
        gradeAt = CACurrentMediaTime()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            if !event.isARepeat { onTap?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 10)
        let radius = min(bounds.width, bounds.height) * 0.3
        // Progress arc.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius + 18, startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
        track.lineWidth = 6
        track.lineCapStyle = .round
        MikuTheme.teal.withAlphaComponent(0.8).setStroke()
        track.stroke()
        // Pulsing pad.
        let size = radius * (1 + 0.12 * pulse)
        let pad = NSBezierPath(ovalIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2))
        MikuTheme.teal.withAlphaComponent(0.25 + 0.5 * pulse).setFill()
        pad.fill()
        MikuTheme.teal.setStroke()
        pad.lineWidth = 3
        pad.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        if !message.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: MikuTheme.font(message.count <= 2 ? 44 : 15, .bold),
                .foregroundColor: MikuTheme.deepTeal,
                .paragraphStyle: paragraph
            ]
            let height: CGFloat = message.count <= 2 ? 54 : 60
            (message as NSString).draw(in: CGRect(x: 20, y: center.y - height / 2, width: bounds.width - 40, height: height), withAttributes: attributes)
        }
        if let grade, CACurrentMediaTime() - gradeAt < 0.5 {
            let label: String
            let color: NSColor
            switch grade {
            case .perfect: label = "PERFECT"; color = MikuTheme.pink
            case .good: label = "GOOD"; color = MikuTheme.teal
            case .miss: label = "MISS"; color = MikuTheme.secondaryText
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: MikuTheme.font(18, .heavy),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            (label as NSString).draw(in: CGRect(x: 0, y: center.y + radius + 30, width: bounds.width, height: 26), withAttributes: attributes)
        }
        let hint: [NSAttributedString.Key: Any] = [
            .font: MikuTheme.font(12),
            .foregroundColor: MikuTheme.secondaryText,
            .paragraphStyle: paragraph
        ]
        (L10n.text("rhythmHint") as NSString).draw(in: CGRect(x: 10, y: 14, width: bounds.width - 20, height: 34), withAttributes: hint)
    }
}

extension RhythmJudge {
    /// What Miku says about your score.
    static func comment(score: Int) -> GameLine {
        switch score {
        case 90...:
            return GameLine(text: MiniGame.text("\(score) 分！節奏感一流，可以同我一齊上台喇♪", "\(score) points! Amazing rhythm — come on stage with me ♪", "\(score)点！リズム感バッチリ、一緒にステージ立てるね♪"), emotion: "happy", action: "cheer")
        case 60..<90:
            return GameLine(text: MiniGame.text("\(score) 分～唔錯喔！再練吓就完美喇！", "\(score) points~ Not bad! A little more practice and it's perfect!", "\(score)点～いい感じ！もう少しで完璧だよ！"), emotion: "happy", action: "clap")
        default:
            return GameLine(text: MiniGame.text("\(score) 分…慢慢嚟，跟住我嘅拍子一齊數就得喇！", "\(score) points… take it easy, just count along with me!", "\(score)点…ゆっくりでいいよ、わたしと一緒に数えてみて！"), emotion: "calm", action: "nod")
        }
    }
}
