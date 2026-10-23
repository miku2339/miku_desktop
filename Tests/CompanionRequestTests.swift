import Foundation

@main
struct CompanionRequestTests {
    static func main() {
        let requests = ["過來一下", "Miku，過來一下～", "請你走過來", "能不能過來陪我", "可不可以過來一下", "过来看看", "過來一下，我想跟你說件事", "come here", "Miku, come over here!", "Could you please come closer?", "ミク、こっちに来て", "そばに来てね", "ここにおいで"]
        let other = ["不要過來", "Miku，不用過來", "別走過來", "don't come here", "Please do not come over", "こっちに来ないで", "そばに来てほしくない", "「過來」這首歌是誰寫的", "過來這首歌很好聽", "她剛才走過來", "come home", "the song is called come here", "", "晚安"]
        for text in requests { precondition(CompanionRequest.isComeOver(text), "Missed request: \(text)") }
        for text in other { precondition(!CompanionRequest.isComeOver(text), "Unexpected request: \(text)") }
        print("PASS: \(requests.count + other.count) companion request checks")
    }
}
