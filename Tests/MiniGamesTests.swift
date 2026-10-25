import Foundation

@main
struct MiniGamesTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    @MainActor
    static func main() async {
        let defaults = UserDefaults.standard
        let previousReplyLanguage = defaults.object(forKey: "replyLanguage")
        let previousInterfaceLanguage = defaults.object(forKey: "interfaceLanguage")
        defer {
            if let previousReplyLanguage {
                defaults.set(previousReplyLanguage, forKey: "replyLanguage")
            } else {
                defaults.removeObject(forKey: "replyLanguage")
            }
            if let previousInterfaceLanguage {
                defaults.set(previousInterfaceLanguage, forKey: "interfaceLanguage")
            } else {
                defaults.removeObject(forKey: "interfaceLanguage")
            }
        }

        // Asking for a game in the chat.
        expect(MiniGame.requested(in: "嚟玩包剪揼！") == .rps, "包剪揼 starts rock-paper-scissors")
        expect(MiniGame.requested(in: "じゃんけんしよう") == .rps, "じゃんけん")
        expect(MiniGame.requested(in: "Let's do a quiz") == .quiz, "quiz")
        expect(MiniGame.requested(in: "玩打拍子") == .rhythm, "rhythm")
        expect(MiniGame.requested(in: "我唔想玩包剪揼") == nil, "not when you say you don't want to")
        expect(MiniGame.requested(in: "今日好攰") == nil, "ordinary chat is not a game")

        // Fixed reply languages keep Mandarin and Cantonese game copy separate.
        defaults.set("zh-Hant", forKey: "replyLanguage")
        expect(MiniGame.text("國語", yue: "粵語", "English", "日本語") == "國語", "Mandarin game text")
        expect(RPSHand.rock.name == "石頭", "Mandarin hand name")
        expect(RPSSession().start().first?.text.contains("剪刀石頭布") == true, "Mandarin rock-paper-scissors copy")
        defaults.set("yue", forKey: "replyLanguage")
        expect(MiniGame.text("國語", yue: "粵語", "English", "日本語") == "粵語", "Cantonese game text")
        expect(RPSHand.rock.name == "揼", "Cantonese hand name")
        expect(RPSSession().start().first?.text.contains("嚟玩包剪揼") == true, "Cantonese rock-paper-scissors copy")
        defaults.set("en", forKey: "replyLanguage")
        expect(MiniGame.text("國語", yue: "粵語", "English", "日本語") == "English", "English game text")
        defaults.set("ja", forKey: "replyLanguage")
        expect(MiniGame.text("國語", yue: "粵語", "English", "日本語") == "日本語", "Japanese game text")
        defaults.set("auto", forKey: "replyLanguage")
        defaults.set("zh-Hant", forKey: "interfaceLanguage")
        expect(MiniGame.text("國語", yue: "粵語", "English", "日本語") == "粵語", "automatic Traditional Chinese keeps existing Cantonese copy")

        // Rock-paper-scissors rules and a whole match.
        expect(RPSHand.rock.beats(.scissors) && RPSHand.scissors.beats(.paper) && RPSHand.paper.beats(.rock), "who beats whom")
        expect(!RPSHand.rock.beats(.rock) && !RPSHand.rock.beats(.paper), "no win on a draw or a loss")
        let alwaysRock = RPSSession(pick: { .rock })
        expect(alwaysRock.start().first?.choices.count == 3, "three hands to choose from")
        let first = alwaysRock.choose("paper")
        expect(first.lines.first?.rps?.outcome == "lose" && !alwaysRock.isOver, "paper beats her rock, match goes on")
        let draw = alwaysRock.choose("rock")
        expect(draw.lines.first?.rps?.outcome == "draw", "a draw")
        let last = alwaysRock.choose("paper")
        expect(alwaysRock.isOver && last.lines.count == 2 && last.lines.last?.choices.isEmpty == true, "two wins end the match")

        // Quiz: every question has four different options and the right answer among them.
        var generator = SystemRandomNumberGenerator()
        var asked: Set<String> = []
        for _ in 0..<40 {
            let question = SongQuiz.question(avoiding: asked, using: &generator)
            asked.insert(question.song.title)
            expect(question.options.count == 4 && Set(question.options).count == 4, "four distinct options: \(question.options)")
            let answer = question.options[question.answer]
            expect(answer == question.song.producer || answer == question.song.title, "the marked answer is right")
            let wrong = question.options.enumerated().filter { $0.offset != question.answer }.map(\.element)
            expect(!wrong.contains(question.song.producer) || answer == question.song.title, "no second right answer")
            if answer == question.song.title {
                let others = wrong.compactMap { title in SongQuiz.songs.first { $0.title == title } }
                expect(!others.contains { $0.producer == question.song.producer }, "other songs are by other producers")
            }
        }
        let quiz = QuizSession()
        var lines = quiz.start()
        var rounds = 0
        while !quiz.isOver, let choice = lines.last?.choices.first, rounds < 10 {
            lines = quiz.choose(choice.id).lines
            rounds += 1
        }
        expect(quiz.isOver && rounds == QuizSession.length, "the quiz ends after \(QuizSession.length) questions")

        // Rhythm judging.
        expect(RhythmJudge.grade(offset: 0.03) == .perfect && RhythmJudge.grade(offset: -0.1) == .good && RhythmJudge.grade(offset: 0.3) == .miss, "grades")
        expect(RhythmJudge.score(Array(repeating: .perfect, count: 16)) == 100, "all perfect is 100")
        expect(RhythmJudge.score(Array(repeating: .good, count: 16)) == 50, "all good is 50")
        expect(RhythmJudge.score([]) == 0, "nothing played is 0")

        if failures.isEmpty {
            print("mini games: \(checks) checks passed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(EXIT_FAILURE)
        }
    }
}
