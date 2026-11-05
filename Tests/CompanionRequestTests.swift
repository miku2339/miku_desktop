import Foundation

@main
struct CompanionRequestTests {
    static func main() {
        let requests = ["過來一下", "Miku，過來一下～", "請你走過來", "能不能過來陪我", "可不可以過來一下", "过来看看", "過來一下，我想跟你說件事", "come here", "Miku, come over here!", "Could you please come closer?", "ミク、こっちに来て", "そばに来てね", "ここにおいで", "미쿠야, 여기로 와 줘", "이리 와", "내 옆으로 와줄래?", "가까이 와 주세요"]
        let other = ["不要過來", "Miku，不用過來", "別走過來", "don't come here", "Please do not come over", "こっちに来ないで", "そばに来てほしくない", "「過來」這首歌是誰寫的", "過來這首歌很好聽", "她剛才走過來", "come home", "the song is called come here", "", "晚安", "여기로 오지 마", "미쿠야, 오지마", "‘이리 와’라는 노래 알아?", "친구가 여기로 왔어", "여기로 와 주지 마"]
        for text in requests { precondition(CompanionRequest.isComeOver(text), "Missed request: \(text)") }
        for text in other { precondition(!CompanionRequest.isComeOver(text), "Unexpected request: \(text)") }
        let musicChecks = MusicRequestChecks.run()
        print("PASS: \(requests.count + other.count + musicChecks) companion request checks")
    }
}

enum MusicRequestChecks {
    static let titles = ["Tell Your World", "メルト", "melt", "千本桜", "Senbonzakura"]

    static func run() -> Int {
        var count = 0
        func expect(_ text: String, _ query: String, _ platform: MusicPlatform?, after assistant: String? = nil) {
            let request = MusicRequestParser.parse(text, previousAssistant: assistant, knownTitles: titles)
            precondition(request == MusicRequest(query: query, platform: platform),
                         "Music request \(text): got \(String(describing: request))")
            count += 1
        }
        func reject(_ text: String, after assistant: String? = nil) {
            let request = MusicRequestParser.parse(text, previousAssistant: assistant, knownTitles: titles)
            precondition(request == nil, "Unexpected music request \(text): \(String(describing: request))")
            count += 1
        }

        // Asking outright, with or without a service.
        expect("幫我用 Spotify 播 Tell Your World", "Tell Your World", .spotify)
        expect("Miku，幫我喺YouTube播千本桜", "千本桜", .youtube)
        expect("播放《メルト》", "メルト", nil)
        expect("可以幫我播 tell your world 嗎？", "tell your world", nil)
        expect("我想聽 Tell Your World", "Tell Your World", nil)
        expect("來一首千本桜吧", "千本桜", nil)
        expect("用apple music放「ODDS&ENDS」", "ODDS&ENDS", .appleMusic)
        expect("applemusi播melt", "melt", .appleMusic)
        expect("play melt on youtube", "melt", .youtube)
        expect("Could you play Tell Your World for me?", "Tell Your World", nil)
        expect("Can you put on Senbonzakura on Spotify please", "Senbonzakura", .spotify)
        expect("メルトをSpotifyで流して", "メルト", .spotify)
        expect("千本桜を再生して", "千本桜", nil)
        expect("打開 Spotify", "", .spotify)
        expect("open youtube", "", .youtube)

        expect("유튜브에서 Tell Your World 틀어 줘", "Tell Your World", .youtube)
        expect("스포티파이에서 メルト를 재생해 줘", "メルト", .spotify)
        expect("애플 뮤직에서 千本桜 틀어 줘", "千本桜", .appleMusic)
        expect("유튜브 열어 줘", "", .youtube)
        expect("Tell Your World 듣고 싶어", "Tell Your World", nil)
        expect("그 노래 틀어 줘", "Tell Your World", nil, after: "Tell Your World를 들어 볼래?")
        expect("응", "Tell Your World", nil, after: "Tell Your World를 들어 볼래?")
        expect("メルト", "メルト", nil, after: "어떤 노래를 듣고 싶어?")
        expect("응", "달빛", nil, after: "「달빛」을 들어 볼래?")
        expect("그 노래 틀어 줘", "달빛", nil, after: "〈달빛〉을 추천해!")
        reject("응", after: "‘혼자가 아니야’라는 말이 참 좋지?")
        reject("노래 틀지 마")
        reject("Tell Your World 재생하지 마")
        reject("게임 틀어 줘")
        reject("이야기 들려줘")
        reject("아무거나", after: "어떤 노래를 듣고 싶어?")

        // Answering her "what would you like to hear?".
        let asked = "真乖～♪ 那我們繼續聽歌吧！你想聽哪一首？Miku 隨時準備好為你獻唱喔～♪"
        expect("tell your world", "tell your world", nil, after: asked)
        expect("千本桜 用 YouTube", "千本桜", .youtube, after: asked)
        expect("Melt please", "Melt", nil, after: "Which song would you like to hear?")
        reject("隨便啦", after: asked)
        reject("好啊", after: asked)
        reject("你推薦一首？", after: asked)
        reject("tell your world", after: "今天過得怎樣？")

        // Pointing at the song she just recommended.
        let recommended = "既然你喜歡《Tell Your World》那種溫暖的感覺，Miku 推薦你聽《ロストワンの號哭》（Lost One's Weeping）！ ♪ 要試試看嗎？ ♪"
        expect("好啊，在 youtube 打開吧", "ロストワンの號哭", .youtube, after: recommended)
        expect("好啊，在youtube打開", "ロストワンの號哭", .youtube, after: recommended)
        expect("播吧", "ロストワンの號哭", nil, after: recommended)
        expect("用 Spotify 播佢", "ロストワンの號哭", .spotify, after: recommended)
        expect("播這首歌", "ロストワンの號哭", nil, after: recommended)
        expect("好啊！", "ロストワンの號哭", nil, after: recommended)
        expect("ok", "ロストワンの號哭", nil, after: recommended)
        expect("play it on youtube", "Tell Your World", .youtube, after: "You might like Tell Your World. Want to give it a listen?")
        expect("打開 Spotify", "", .spotify, after: "今天過得怎樣？")
        reject("好", after: "那 Miku 就陪你一起聽～♪ 記得跟著節奏搖擺喔！")
        reject("好啊", after: "好喜歡那種「你並不孤單」的感覺呢！")
        reject("播吧", after: "今天過得怎樣？")
        precondition(MusicRequestParser.lastTitle(in: recommended, knownTitles: titles) == "ロストワンの號哭", "last 《》 title")
        precondition(MusicRequestParser.lastTitle(in: "我最喜歡 melt 同千本桜！", knownTitles: titles) == "千本桜", "last known title")
        precondition(MusicRequestParser.lastTitle(in: "好喜歡那種「你並不孤單」的感覺", knownTitles: titles) == nil, "「」 is not a title")
        count += 3

        // The screenshot: the song was named two replies back, the last reply names none.
        let searched = "好喔！Miku 幫你點開 YouTube 搜尋「ロストワンの號哭」～♪ 記得選那個 MV 畫面超帥的版本喔！"
        let chatty = "那 Miku 就陪你一起聽～♪ 記得跟著節奏搖擺喔！要是覺得太刺激，隨時可以換首溫柔的歌。"
        let screenshot = MusicRequestParser.parse(
            "好呀，在youtube打開吧", previousAssistant: chatty, recentAssistant: [searched, recommended], knownTitles: titles)
        precondition(screenshot == MusicRequest(query: "ロストワンの號哭", platform: .youtube), "screenshot: \(String(describing: screenshot))")
        let older = MusicRequestParser.parse(
            "播吧", previousAssistant: chatty, recentAssistant: [recommended], knownTitles: titles)
        precondition(older == MusicRequest(query: "ロストワンの號哭", platform: nil), "older reply: \(String(describing: older))")
        precondition(MusicRequestParser.lastTitle(in: searched, knownTitles: titles) == "ロストワンの號哭", "搜尋「」 is a title")
        precondition(MusicRequestParser.lastTitle(in: "Miku 推薦你聽「Hand in Hand」！", knownTitles: titles) == "Hand in Hand", "聽「」 is a title")
        count += 4

        // The screenshot: she asked which song, and "你看看！？" was a question back, not a title.
        let whichOne = "好呀，我準備好了～♪ 是哪一首呢？"
        reject("你看看！？", after: whichOne)
        reject("你看看", after: whichOne)
        reject("猜猜看？", after: whichOne)
        reject("你說呢？", after: whichOne)
        reject("Tell Your World?", after: whichOne)
        reject("guess", after: "Which song would you like to hear?")
        reject("当ててみて", after: "どの曲？")
        expect("Tell Your World", "Tell Your World", nil, after: whichOne)

        // Not requests to play music.
        reject("放心啦")
        reject("開心！")
        reject("我想聽你講故事")
        reject("let's play a game")
        reject("play rock paper scissors with me")
        reject("不要播歌")
        reject("stop the music")
        reject("這首歌是誰寫的？")
        reject("我昨天在 YouTube 看到你")
        reject("直播好好看")
        reject("播")
        reject("")

        // Links.
        precondition(MusicLinks.officialYouTubeVideo("https://www.youtube.com/watch?v=PqJNc9KVIZE")?.absoluteString
                     == "https://www.youtube.com/watch?v=PqJNc9KVIZE", "official YouTube link")
        precondition(MusicLinks.officialYouTubeVideo("https://www.nicovideo.jp/watch/sm1715919") == nil, "Niconico is not YouTube")
        precondition(MusicLinks.officialYouTubeVideo("http://www.youtube.com/watch?v=PqJNc9KVIZE") == nil, "only https")
        precondition(MusicLinks.officialYouTubeVideo("https://evil.example/watch?v=PqJNc9KVIZE") == nil, "only YouTube hosts")
        precondition(MusicLinks.youtubeSearch("Tell Your World livetune")?.absoluteString
                     == "https://www.youtube.com/results?search_query=Tell%20Your%20World%20livetune", "YouTube search")
        precondition(MusicLinks.spotifyAppSearch("千本桜 黒うさP")?.absoluteString.hasPrefix("spotify:search:%E5%8D%83") == true, "Spotify search")
        precondition(MusicLinks.appleMusicSearch("メルト")?.host == "music.apple.com", "Apple Music search")
        return count + 7
    }
}
