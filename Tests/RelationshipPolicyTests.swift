import Foundation

@main
struct RelationshipPolicyTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func main() {
        let directConfessions: [(String, String)] = [
            ("繁體中文告白", "我喜歡你"),
            ("繁體中文告白並邀請", "我喜歡你，可以做我女朋友嗎？"),
            ("繁體中文告白並請求交往", "我喜歡你，跟我交往吧"),
            ("粵語道歉後告白並請求交往", "對唔住，我喜歡你，跟我交往吧"),
            ("詢問成為女朋友", "你可以做我女朋友嗎？"),
            ("詢問成為我的女朋友", "你可以當我的女朋友嗎？"),
            ("詢問是否願意交往", "你願意和我交往嗎？"),
            ("粵語詢問成為女朋友", "Miku，願唔願意做我女朋友？"),
            ("告白後禮貌請求交往", "我很喜歡你，請和我交往"),
            ("帶語氣詞中文告白", "我喜歡你呀"),
            ("繁體中文坦白", "其實我喜歡你"),
            ("初音稱呼告白", "初音，我愛你"),
            ("中文程度副詞告白", "我很喜歡你"),
            ("粵語告白", "Miku，我真係好鍾意你"),
            ("簡體中文告白", "我喜欢你，想和你交往"),
            ("邀請交往", "我想同你交往"),
            ("女朋友邀請", "Miku，做我女朋友好嗎？"),
            ("繁體中文愛意", "我愛你"),
            ("簡體中文愛意", "我爱你"),
            ("英文告白", "I love you, Miku."),
            ("英文道歉後告白", "sorry, I love you"),
            ("英文外出邀請", "Miku, will you go out with me?"),
            ("英文約會邀請", "Will you date me?"),
            ("英文交往邀請", "Will you be my girlfriend?"),
            ("英文浪漫喜歡", "I like you romantically"),
            ("日文告白", "ミク、好きです。"),
            ("日文強烈告白", "ミク、大好きだよ"),
            ("日文交往請求", "ミク、私と付き合ってください"),
            ("日文交往邀請", "付き合ってください")
        ]

        for (name, text) in directConfessions {
            expectEqual(
                ConfessionPolicy.evaluate(text, friendship: 75, status: .friends, offended: false, justForgiven: false),
                .accepted,
                name
            )
        }

        let nonConfessions: [(String, String)] = [
            ("普通對話", "今日天氣幾好"),
            ("只表達自己想交往", "我想交往"),
            ("沒有對象的交往意願", "想交往"),
            ("請求協助追求別人", "你可以幫我追女朋友嗎？"),
            ("請求教授表白", "你願意教我怎樣表白嗎？"),
            ("詢問對方是否想交往", "你想交往嗎？"),
            ("轉述朋友的交往問題", "我朋友問你願意和我交往嗎？"),
            ("第三人稱分享", "我喜歡她，但唔知點同佢講"),
            ("轉述朋友告白", "朋友話：『我鍾意你』"),
            ("歌曲名稱", "《我喜歡你》呢首歌幾好聽"),
            ("英文歌名", "I Love You is my favorite song"),
            ("否定中文", "我不喜歡你"),
            ("否定粵語", "我唔鍾意你"),
            ("否定英文", "I don't love you"),
            ("否定日文", "好きじゃないです"),
            ("拒絕中文交往", "我不想同你交往"),
            ("拒絕成為女朋友", "請不要做我女朋友"),
            ("拒絕英文女朋友", "I don't want you to be my girlfriend"),
            ("拒絕英文約會", "I do not want to date you"),
            ("日文朋友式喜歡", "あなたが好きです。友達として"),
            ("朋友式喜歡", "我只是作為朋友喜歡你"),
            ("粉絲式喜歡", "我作為粉絲鍾意你"),
            ("假設中文", "如果我話我喜歡你，你會點？"),
            ("假設英文", "If I said I love you, what would happen?"),
            ("引用句子", "『我喜歡你』英文點講？"),
            ("詢問表白意思", "表白是甚麼？"),
            ("喜歡歌曲", "我喜歡你唱嗰首歌"),
            ("喜歡對方歌曲", "我喜歡你的歌"),
            ("喜歡對方歌聲", "我鍾意你嘅歌聲"),
            ("喜歡角色設定", "我喜歡你的人設"),
            ("第三人稱粵語", "佢鍾意你"),
            ("否認曾經告白", "我冇話過我鍾意你"),
            ("否認說過喜歡", "我冇話我中意你"),
            ("英文引用問意思", "'I love you' 是甚麼意思？"),
            ("日文詢問喜歡", "好きですか？"),
            ("日文無標點詢問", "好きですか"),
            ("日文詢問喜歡初音", "ミクが好きですか？"),
            ("喜歡動物的日文", "猫が好きです")
        ]

        for (name, text) in nonConfessions {
            expectNil(
                ConfessionPolicy.evaluate(text, friendship: 100, status: .friends, offended: false, justForgiven: false),
                name
            )
        }

        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: 74.9, status: .friends, offended: false, justForgiven: false),
            .notReady,
            "74.9 不可四捨五入接受"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: 75, status: .friends, offended: false, justForgiven: false),
            .accepted,
            "75 達到接受門檻"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: .nan, status: .friends, offended: false, justForgiven: false),
            .notReady,
            "NaN 不可接受"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: .infinity, status: .friends, offended: false, justForgiven: false),
            .notReady,
            "Infinity 不可接受"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: 100, status: .dating, offended: true, justForgiven: true),
            .upset,
            "冒犯狀態優先"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: 100, status: .dating, offended: false, justForgiven: true),
            .recovering,
            "剛原諒時暫不接受"
        )
        expectEqual(
            ConfessionPolicy.evaluate("我喜歡你", friendship: 10, status: .dating, offended: false, justForgiven: false),
            .alreadyDating,
            "已交往不因低分自動分手"
        )
        expectEqual(
            ConfessionPolicy.evaluate("今日食咩？", friendship: 100, status: .dating, offended: false, justForgiven: false),
            nil,
            "已交往的普通對話仍不是告白"
        )

        do {
            let known = try JSONDecoder().decode(RelationshipStatus.self, from: Data("\"dating\"".utf8))
            expectEqual(known, .dating, "解碼已知關係狀態")

            let unknown = try JSONDecoder().decode(RelationshipStatus.self, from: Data("\"engaged\"".utf8))
            expectEqual(unknown, .friends, "未知舊記憶狀態退回朋友")
        } catch {
            failures.append("關係狀態解碼不應拋錯：\(error)")
        }

        if failures.isEmpty {
            print("PASS: \(checks) checks")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("FAILED: \(failures.count) of \(checks) checks\n", stderr)
        exit(1)
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        checks += 1
        if actual != expected {
            failures.append("\(name)：得到 \(actual)，預期 \(expected)")
        }
    }

    private static func expectNil<T>(_ actual: T?, _ name: String) {
        checks += 1
        if actual != nil {
            failures.append("\(name)：得到 \(String(describing: actual))，預期 nil")
        }
    }
}
