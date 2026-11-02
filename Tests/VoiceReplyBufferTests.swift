import Foundation

@main
struct VoiceReplyBufferTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        var progress = VoiceReplyProgress()
        progress.started()
        check(progress.hasStarted && progress.completedText.isEmpty, "說到一半的句子不冒充已播完")
        progress.segmentFinished("第一句。")
        check(progress.completedText == "第一句。", "下一句仍在生成時也保留已聽完的前一句")
        progress.started()
        check(progress.completedText == "第一句。", "下一句只開始還不算已聽完")
        progress.segmentFinished("第二句。")
        check(progress.completedText == "第一句。第二句。", "最後一段真正完成時確認最後一句")
        var reply = VoiceReplyBuffer()
        check(try reply.append("好呀，我") == [], "半句不會送去語音生成")
        check(try reply.append("好呀，我陪你。接著") == ["好呀，我陪你。"], "整段結束前先取出第一句")
        check(try reply.append("好呀，我陪你。接著") == [], "重複prefix不會重複朗讀")
        check(try reply.append("好呀，我陪你。接著慢慢說吧", final: true) == ["接著慢慢說吧"], "驗證完的尾句只補一次")
        do {
            _ = try reply.append("好呀，我陪你。接著慢慢說吧", final: true)
            check(false, "已結束的回覆不能再加字")
        } catch VoiceReplyBuffer.Failure.alreadyFinished { checks += 1 }
        var rewritten = VoiceReplyBuffer()
        _ = try rewritten.append("今天很好。")
        do {
            _ = try rewritten.append("今天不好。", final: true)
            check(false, "不同回覆不得當作原回覆繼續播")
        } catch VoiceReplyBuffer.Failure.changedPrefix { checks += 1 }
        var english = VoiceReplyBuffer()
        check(try english.append("It is 3.") == [], "串流尾端的小數點不會過早切句")
        check(try english.append("It is 3.14. You can rest.") == ["It is 3.14."], "小數保留完整")
        check(try english.append("It is 3.14. You can rest.", final: true) == ["You can rest."], "最後的英文句點可交句")
        var japanese = VoiceReplyBuffer()
        check(try japanese.append("「大丈夫！」次は") == ["「大丈夫！」"], "句尾引號和句子一起播放")
        check(try japanese.append("「大丈夫！」次はゆっくり♪", final: true) == ["次はゆっくり♪"], "保留角色語氣標記供既有清理")
        var punctuation = VoiceReplyBuffer()
        check(try punctuation.append("！？\n") == [], "只有標點不會產生音訊")
        var long = VoiceReplyBuffer()
        let phrase = String(repeating: "字", count: 81) + "，"
        check(try long.append(phrase + "後半句") == [phrase], "長句可在語意短句邊界開始播")
        var oversized = VoiceReplyBuffer()
        do {
            _ = try oversized.append(String(repeating: "字", count: 16_001))
            check(false, "累積字幕有上限")
        } catch VoiceReplyBuffer.Failure.tooLong { checks += 1 }
        print("VoiceReplyBuffer: \(checks) checks passed")
    }
}
