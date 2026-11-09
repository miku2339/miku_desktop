//! Bounded SSE decoding and stable, root-only JSON text for incremental speech.

use std::collections::HashSet;

use serde_json::Value;

const MAX_STREAM_BYTES: usize = 262_144;
const MAX_FIELD_BYTES: usize = 65_536;

fn invalid() -> String {
    "The AI service returned an invalid voice stream.".into()
}

#[derive(Default)]
pub struct VoiceStream {
    content: String,
    done: bool,
    stopped: bool,
    failed: bool,
    received_bytes: usize,
    skips_line_feed: bool,
    line: Vec<u8>,
    event_data: Vec<String>,
    event_bytes: usize,
}

impl VoiceStream {
    /// A network chunk may end in the middle of a UTF-8 scalar or an SSE line.
    pub fn consume(&mut self, bytes: &[u8]) -> Result<Vec<String>, String> {
        if self.failed {
            return Err(invalid());
        }
        let mut prefixes = Vec::new();
        for &byte in bytes {
            match self.consume_byte(byte) {
                Ok(Some(prefix)) => prefixes.push(prefix),
                Ok(None) => {}
                Err(error) => {
                    self.failed = true;
                    return Err(error);
                }
            }
            if self.done {
                break;
            }
        }
        Ok(prefixes)
    }

    pub fn is_done(&self) -> bool {
        self.done && !self.failed
    }

    /// The complete JSON content, for the ordinary reply/schema validation path.
    pub fn finish(&self) -> Result<&str, String> {
        if self.failed || !self.done || !self.stopped || self.content.is_empty() {
            return Err(invalid());
        }
        let text = JsonTextPrefix::new(&self.content)
            .text()?
            .ok_or_else(invalid)?;
        let object: Value = serde_json::from_str(&self.content).map_err(|_| invalid())?;
        if !object.is_object()
            || object["text"].as_str() != Some(text.as_str())
            || text.trim().is_empty()
        {
            return Err(invalid());
        }
        Ok(&self.content)
    }

    fn consume_byte(&mut self, byte: u8) -> Result<Option<String>, String> {
        self.received_bytes += 1;
        if self.received_bytes > MAX_STREAM_BYTES {
            return Err(invalid());
        }
        // The LF belonging to the CR which completed [DONE] is still framing.
        if self.skips_line_feed && byte == b'\n' {
            self.skips_line_feed = false;
            return Ok(None);
        }
        if self.done {
            return Err(invalid());
        }
        self.skips_line_feed = byte == b'\r';
        if byte != b'\r' && byte != b'\n' {
            if self.line.len() >= MAX_FIELD_BYTES {
                return Err(invalid());
            }
            self.line.push(byte);
            return Ok(None);
        }
        let bytes = std::mem::take(&mut self.line);
        let value = String::from_utf8(bytes).map_err(|_| invalid())?;
        if value.is_empty() {
            if self.event_data.is_empty() {
                return Ok(None);
            }
            let data = self.event_data.join("\n");
            self.event_data.clear();
            self.event_bytes = 0;
            return self.consume_event(&data);
        }
        if let Some(data) = value.strip_prefix("data:") {
            let data = data.strip_prefix(' ').unwrap_or(data);
            self.event_bytes += data.len() + usize::from(!self.event_data.is_empty());
            if self.event_bytes > MAX_FIELD_BYTES {
                return Err(invalid());
            }
            self.event_data.push(data.into());
        }
        // Comments, ids and event names never become model content.
        Ok(None)
    }

    fn consume_event(&mut self, data: &str) -> Result<Option<String>, String> {
        if data == "[DONE]" {
            if !self.stopped {
                return Err(invalid());
            }
            self.done = true;
            return Ok(None);
        }
        let object: Value = serde_json::from_str(data).map_err(|_| invalid())?;
        if !object.is_object() || object.get("error").is_some() {
            return Err(invalid());
        }
        let choices = object["choices"].as_array().ok_or_else(invalid)?;
        if choices.iter().any(|choice| !choice.is_object()) {
            return Err(invalid());
        }
        let selected: Vec<_> = choices
            .iter()
            .filter(|choice| choice["index"].as_u64() == Some(0))
            .collect();
        if selected.len() > 1 {
            return Err(invalid());
        }
        let Some(choice) = selected.first() else {
            return Ok(None);
        };
        if self.stopped || !choice["delta"].is_object() {
            return Err(invalid());
        }
        let mut prefix = None;
        if let Some(fragment) = choice["delta"]
            .get("content")
            .filter(|value| !value.is_null())
        {
            let fragment = fragment.as_str().ok_or_else(invalid)?;
            if self.content.len() + fragment.len() > MAX_FIELD_BYTES {
                return Err(invalid());
            }
            self.content.push_str(fragment);
            prefix = JsonTextPrefix::new(&self.content).text()?;
        }
        if let Some(reason) = choice.get("finish_reason").filter(|value| !value.is_null()) {
            if reason.as_str() != Some("stop") {
                return Err(invalid());
            }
            self.stopped = true;
        }
        Ok(prefix)
    }
}

/// Parses incomplete JSON without exposing strings in keys, nested objects or reasoning.
struct JsonTextPrefix {
    scalars: Vec<char>,
    position: usize,
}

impl JsonTextPrefix {
    fn new(value: &str) -> Self {
        Self {
            scalars: value.chars().collect(),
            position: 0,
        }
    }

    fn text(mut self) -> Result<Option<String>, String> {
        self.whitespace();
        if self.at_end() {
            return Ok(None);
        }
        if !self.take('{') {
            return Err(invalid());
        }
        let mut result = None;
        let mut keys = HashSet::new();
        loop {
            self.whitespace();
            if self.at_end() {
                return Ok(result);
            }
            if self.take('}') {
                self.whitespace();
                if !self.at_end() {
                    return Err(invalid());
                }
                return Ok(result);
            }
            let (key, closed) = self.string()?;
            if !closed {
                return Ok(result);
            }
            if !keys.insert(key.clone()) {
                return Err(invalid());
            }
            self.whitespace();
            if self.at_end() {
                return Ok(result);
            }
            if !self.take(':') {
                return Err(invalid());
            }
            self.whitespace();
            if self.at_end() {
                return Ok(result);
            }
            if key == "text" {
                let (value, complete) = self.string()?;
                result = Some(value);
                if !complete {
                    return Ok(result);
                }
            } else if !self.skip_value()? {
                return Ok(result);
            }
            self.whitespace();
            if self.at_end() {
                return Ok(result);
            }
            if self.take(',') {
                self.whitespace();
                if self.scalars.get(self.position) == Some(&'}') {
                    return Err(invalid());
                }
            } else if self.scalars.get(self.position) != Some(&'}') {
                return Err(invalid());
            }
        }
    }

    fn string(&mut self) -> Result<(String, bool), String> {
        if !self.take('"') {
            return Err(invalid());
        }
        let mut result = String::new();
        while let Some(&scalar) = self.scalars.get(self.position) {
            self.position += 1;
            if scalar == '"' {
                return Ok((result, true));
            }
            if scalar < '\u{20}' {
                return Err(invalid());
            }
            if scalar != '\\' {
                result.push(scalar);
                continue;
            }
            let Some(&escaped) = self.scalars.get(self.position) else {
                return Ok((result, false));
            };
            self.position += 1;
            match escaped {
                '"' | '\\' | '/' => result.push(escaped),
                'b' => result.push('\u{8}'),
                'f' => result.push('\u{c}'),
                'n' => result.push('\n'),
                'r' => result.push('\r'),
                't' => result.push('\t'),
                'u' => {
                    let Some(first) = self.hex_unit()? else {
                        return Ok((result, false));
                    };
                    let value = if (0xd800..=0xdbff).contains(&first) {
                        if self.at_end() {
                            return Ok((result, false));
                        }
                        if !self.take('\\') {
                            return Err(invalid());
                        }
                        if self.at_end() {
                            return Ok((result, false));
                        }
                        if !self.take('u') {
                            return Err(invalid());
                        }
                        let Some(second) = self.hex_unit()? else {
                            return Ok((result, false));
                        };
                        if !(0xdc00..=0xdfff).contains(&second) {
                            return Err(invalid());
                        }
                        0x10000 + (first - 0xd800) * 0x400 + second - 0xdc00
                    } else {
                        if (0xdc00..=0xdfff).contains(&first) {
                            return Err(invalid());
                        }
                        first
                    };
                    result.push(char::from_u32(value).ok_or_else(invalid)?);
                }
                _ => return Err(invalid()),
            }
        }
        Ok((result, false))
    }

    fn hex_unit(&mut self) -> Result<Option<u32>, String> {
        let end = (self.position + 4).min(self.scalars.len());
        let mut value = 0;
        for scalar in &self.scalars[self.position..end] {
            if !scalar.is_ascii_hexdigit() {
                return Err(invalid());
            }
            value = value * 16 + scalar.to_digit(16).ok_or_else(invalid)?;
        }
        if end - self.position < 4 {
            return Ok(None);
        }
        self.position = end;
        Ok(Some(value))
    }

    fn skip_value(&mut self) -> Result<bool, String> {
        let start = self.position;
        if self.scalars.get(self.position) == Some(&'"') {
            return self.string().map(|(_, closed)| closed);
        }
        let mut depth = 0usize;
        while let Some(&scalar) = self.scalars.get(self.position) {
            if scalar == '"' {
                if !self.string()?.1 {
                    return Ok(false);
                }
                continue;
            }
            if scalar == '{' || scalar == '[' {
                depth += 1;
            }
            if scalar == '}' || scalar == ']' {
                if depth == 0 {
                    break;
                }
                depth -= 1;
                self.position += 1;
                if depth == 0 {
                    break;
                }
                continue;
            }
            if depth == 0 && (scalar == ',' || scalar.is_whitespace()) {
                break;
            }
            if depth > 32 {
                return Err(invalid());
            }
            self.position += 1;
        }
        if self.at_end() {
            return Ok(false);
        }
        let raw: String = self.scalars[start..self.position].iter().collect();
        if raw.is_empty() || serde_json::from_str::<Value>(&raw).is_err() {
            return Err(invalid());
        }
        Ok(true)
    }

    fn whitespace(&mut self) {
        while self
            .scalars
            .get(self.position)
            .is_some_and(|scalar| matches!(scalar, ' ' | '\t' | '\n' | '\r'))
        {
            self.position += 1;
        }
    }

    fn take(&mut self, scalar: char) -> bool {
        if self.scalars.get(self.position) == Some(&scalar) {
            self.position += 1;
            true
        } else {
            false
        }
    }

    fn at_end(&self) -> bool {
        self.position >= self.scalars.len()
    }
}

pub fn stable_sentence_prefix(text: &str) -> Result<String, String> {
    let text = text.trim();
    let lower = text.to_lowercase();
    if text.len() > MAX_FIELD_BYTES
        || ["```", "{", "}"]
            .iter()
            .any(|marker| text.contains(*marker))
        || [
            "<think",
            "</think",
            "<analysis",
            "</analysis",
            "<|",
            "relationship_outcome",
        ]
        .iter()
        .any(|marker| lower.contains(*marker))
    {
        return Err(invalid());
    }
    let Some((last, _)) = text.char_indices().next_back() else {
        return Ok(String::new());
    };
    let stable = &text[..last];
    let mut end = None;
    for (index, scalar) in stable.char_indices() {
        if !"。！？.!?\n".contains(scalar) {
            continue;
        }
        if scalar == '.' && conservative_period(text, index) {
            continue;
        }
        end = Some(index + scalar.len_utf8());
    }
    Ok(end.map(|end| stable[..end].to_owned()).unwrap_or_default())
}

fn conservative_period(text: &str, index: usize) -> bool {
    let before = &text[..index];
    let after = &text[index + 1..];
    let previous = before.chars().next_back();
    let next = after.chars().next();
    if previous.is_some_and(|c| c.is_ascii_digit()) && next.is_some_and(|c| c.is_ascii_digit()) {
        return true;
    }
    if next == Some('.') || previous == Some('.') {
        return true;
    }
    if previous.is_some_and(|c| c.is_ascii_alphabetic())
        && next.is_some_and(|c| c.is_ascii_alphabetic())
    {
        return true;
    }
    let token = before
        .rsplit(|c: char| c.is_whitespace() || ",;:!?。！？".contains(c))
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "u.s", "u.k",
        "a.m", "p.m",
    ]
    .contains(&token.as_str())
        || token.chars().count() == 1 && token.chars().all(|c| c.is_ascii_alphabetic())
}

/// Completed spoken phrases, preserving a single monotonic generated reply.
#[derive(Default)]
pub struct VoiceReplyBuffer {
    text: String,
    pending: String,
    finished: bool,
}

impl VoiceReplyBuffer {
    pub fn append(&mut self, cumulative: &str, final_: bool) -> Result<Vec<String>, String> {
        self.append_internal(cumulative, final_, false)
    }

    /// Only for a prefix whose trailing period has already passed lookahead validation.
    pub fn append_stable(&mut self, cumulative: &str) -> Result<Vec<String>, String> {
        self.append_internal(cumulative, false, true)
    }

    fn append_internal(
        &mut self,
        cumulative: &str,
        final_: bool,
        stable_period: bool,
    ) -> Result<Vec<String>, String> {
        if self.finished {
            return Err("The voice reply buffer is already finished.".into());
        }
        if cumulative.chars().count() > 16_000 {
            return Err("The voice reply is too long.".into());
        }
        if !cumulative.starts_with(&self.text) {
            return Err("The AI changed voice prefix after speech started.".into());
        }
        self.pending.push_str(&cumulative[self.text.len()..]);
        self.text = cumulative.to_owned();
        let mut phrases = Vec::new();
        while let Some(boundary) = self.phrase_boundary(final_, stable_period) {
            let phrase = self.pending[..boundary].trim().to_owned();
            self.pending.drain(..boundary);
            if phrase.chars().any(char::is_alphanumeric) {
                phrases.push(phrase);
            }
        }
        if final_ {
            self.finished = true;
            let tail = self.pending.trim();
            if tail.chars().any(char::is_alphanumeric) {
                phrases.push(tail.to_owned());
            }
            self.pending.clear();
        }
        Ok(phrases)
    }

    fn phrase_boundary(&self, final_: bool, stable_period: bool) -> Option<usize> {
        let mut characters = self.pending.char_indices().peekable();
        let mut length = 0;
        while let Some((index, character)) = characters.next() {
            length += 1;
            let next = index + character.len_utf8();
            let is_full_stop = character == '.'
                && characters
                    .peek()
                    .map(|(_, next)| next.is_whitespace())
                    .unwrap_or(final_ || stable_period)
                && (!stable_period || !conservative_period(&self.pending, index));
            let is_sentence = "。！？!?\n".contains(character) || is_full_stop;
            let is_phrase = length >= 80 && "，,；;".contains(character);
            if !is_sentence && !is_phrase {
                continue;
            }
            let mut end = next;
            for (offset, closer) in self.pending[next..].char_indices() {
                if "」』）)\"”’。！？!?".contains(closer) {
                    end = next + offset + closer.len_utf8();
                } else {
                    break;
                }
            }
            return Some(end);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(content: Option<&str>, reason: Option<&str>) -> String {
        format!(
            "data: {}\n\n",
            json!({"choices":[{"index":0,"delta":{"content":content},"finish_reason":reason}]})
        )
    }

    fn complete(content: &str) -> Vec<u8> {
        format!(
            "{}{}data: [DONE]\n\n",
            event(Some(content), None),
            event(None, Some("stop"))
        )
        .into_bytes()
    }

    #[test]
    fn every_network_split_and_byte_split_preserve_unicode() {
        let content = r#"{"text":"你好♪ 미쿠 😀！","emotion":"happy","action":"idle"}"#;
        let bytes = complete(content);
        for split in 0..=bytes.len() {
            let mut stream = VoiceStream::default();
            stream.consume(&bytes[..split]).unwrap();
            stream.consume(&bytes[split..]).unwrap();
            assert!(stream.is_done());
            assert_eq!(stream.finish().unwrap(), content);
        }
        let mut stream = VoiceStream::default();
        let mut prefixes = Vec::new();
        for byte in bytes {
            prefixes.extend(stream.consume(&[byte]).unwrap());
        }
        assert_eq!(prefixes.last().unwrap(), "你好♪ 미쿠 😀！");
        stream.finish().unwrap();
    }

    #[test]
    fn only_choice_zero_root_text_is_exposed() {
        let mut stream = VoiceStream::default();
        let other = format!(
            "data: {}\n\n",
            json!({"choices":[{"index":1,"delta":{"content":"private"}},{"index":0,"delta":{"reasoning_content":"hidden","tool_calls":[{"text":"secret"}]}}]})
        );
        assert!(stream.consume(other.as_bytes()).unwrap().is_empty());
        let content = r#"{"reasoning":"do not expose","nested":{"text":"not the reply"},"text":"Hello!","action":"idle"}"#;
        let prefixes = stream.consume(&complete(content)).unwrap();
        assert_eq!(prefixes, vec!["Hello!"]);
        assert_eq!(stream.finish().unwrap(), content);
    }

    #[test]
    fn partial_root_strings_decode_escapes_and_utf16_pairs() {
        let fragments = [
            r#"{"other":["not text"],"text":"A\n\"\\\/\b\f\t\u4f60\uD83D"#,
            r#"\uDE00!"}"#,
        ];
        let mut stream = VoiceStream::default();
        let first = stream
            .consume(event(Some(fragments[0]), None).as_bytes())
            .unwrap();
        assert_eq!(first[0], "A\n\"\\/\u{8}\u{c}\t你");
        let second = stream
            .consume(event(Some(fragments[1]), Some("stop")).as_bytes())
            .unwrap();
        assert_eq!(second[0], "A\n\"\\/\u{8}\u{c}\t你😀!");
        stream.consume(b"data: [DONE]\n\n").unwrap();
        stream.finish().unwrap();
    }

    #[test]
    fn crlf_multiline_events_comments_and_usage_are_framing() {
        let mut stream = VoiceStream::default();
        let data =
            ": comment\r\nid: 1\r\nevent: message\r\ndata: {\r\ndata: \"choices\": []}\r\n\r\n";
        assert!(stream.consume(data.as_bytes()).unwrap().is_empty());
        let content = r#"{"text":"Hello!"}"#;
        let bytes = String::from_utf8(complete(content))
            .unwrap()
            .replace('\n', "\r\n");
        assert_eq!(stream.consume(bytes.as_bytes()).unwrap(), vec!["Hello!"]);
        assert_eq!(stream.finish().unwrap(), content);
    }

    #[test]
    fn duplicate_root_keys_and_invalid_json_never_finish_successfully() {
        for content in [
            r#"{"text":"one","text":"two"}"#,
            r#"{"a":1,"a":2,"text":"reply"}"#,
            r#"{"text":"hi",}"#,
            r#"{"text":42}"#,
            r#"{"text":"bad\q"}"#,
            r#"{"text":"bad\uDC00"}"#,
            r#"{"text":"bad\uD800x"}"#,
            r#"{"text":"hi","meta":[}"#,
            r#"{"text":"hi"} trailing"#,
        ] {
            let mut stream = VoiceStream::default();
            let consumed = stream.consume(&complete(content));
            assert!(consumed.is_err() || stream.finish().is_err(), "{content}");
        }
        let mut stream = VoiceStream::default();
        stream.consume(&complete(r#"{"text":"unfinished"#)).unwrap();
        assert!(stream.finish().is_err());
    }

    #[test]
    fn stop_done_and_errors_are_required_in_order() {
        for reason in ["length", "tool_calls", "content_filter", "error"] {
            assert!(VoiceStream::default()
                .consume(event(Some(r#"{"text":"Hi!"}"#), Some(reason)).as_bytes())
                .is_err());
        }
        let mut stream = VoiceStream::default();
        stream
            .consume(event(Some(r#"{"text":"Hi!"}"#), None).as_bytes())
            .unwrap();
        assert!(stream.finish().is_err());
        assert!(stream.consume(b"data: [DONE]\n\n").is_err());
        let mut stream = VoiceStream::default();
        stream
            .consume(event(Some(r#"{"text":"Hi!"}"#), Some("stop")).as_bytes())
            .unwrap();
        assert!(stream
            .consume(event(Some("more"), None).as_bytes())
            .is_err());
        assert!(VoiceStream::default()
            .consume(b"data: {\"error\":\"failed\",\"choices\":[]}\n\n")
            .is_err());
        assert!(VoiceStream::default()
            .consume(
                b"data: {\"choices\":[{\"index\":0,\"delta\":{}},{\"index\":0,\"delta\":{}}]}\n\n"
            )
            .is_err());
    }

    #[test]
    fn incomplete_events_invalid_utf8_and_bounds_fail_closed() {
        let mut stream = VoiceStream::default();
        stream.consume(b"data: {\"choices\":[]}").unwrap();
        assert!(stream.finish().is_err());
        assert!(VoiceStream::default().consume(b"data: \xff\n\n").is_err());
        assert!(VoiceStream::default()
            .consume(&vec![b'x'; MAX_FIELD_BYTES + 1])
            .is_err());
        let mut stream = VoiceStream::default();
        let comment = vec![b':'; MAX_FIELD_BYTES];
        for _ in 0..3 {
            stream.consume(&comment).unwrap();
            stream.consume(b"\n").unwrap();
        }
        assert!(stream.consume(&comment).is_err());
        let mut stream = VoiceStream::default();
        let half_event = format!("data: {}\n", "a".repeat(33_000));
        stream.consume(half_event.as_bytes()).unwrap();
        assert!(stream.consume(half_event.as_bytes()).is_err());
        let mut stream = VoiceStream::default();
        let huge = "x".repeat(33_000);
        stream
            .consume(event(Some(&format!("{{\"text\":\"{huge}")), None).as_bytes())
            .unwrap();
        assert!(stream.consume(event(Some(&huge), None).as_bytes()).is_err());
    }

    #[test]
    fn stable_prefix_keeps_unfinished_sentence_and_last_character() {
        assert_eq!(stable_sentence_prefix("你好。下一句").unwrap(), "你好。");
        assert_eq!(stable_sentence_prefix("你好。").unwrap(), "");
        assert_eq!(
            stable_sentence_prefix("Hello! More text").unwrap(),
            "Hello!"
        );
        assert_eq!(
            stable_sentence_prefix("The value is 3.14 and Dr. Miku").unwrap(),
            ""
        );
        assert_eq!(stable_sentence_prefix("It is 3.1").unwrap(), "");
        assert_eq!(stable_sentence_prefix(" 你好！ 還沒完 ").unwrap(), "你好！");
        assert_eq!(stable_sentence_prefix("").unwrap(), "");
        for text in [
            "```code```",
            "Hello {json}",
            "<think>secret",
            "</analysis>",
            "<|analysis",
            "relationship_outcome: accepted",
        ] {
            assert!(stable_sentence_prefix(text).is_err(), "{text}");
        }
    }

    #[test]
    fn spoken_buffer_preserves_monotonic_prefix_and_finishes_once() {
        let mut buffer = VoiceReplyBuffer::default();
        assert_eq!(
            buffer.append("好呀，我", false).unwrap(),
            Vec::<String>::new()
        );
        assert_eq!(
            buffer.append("好呀，我陪你。接著", false).unwrap(),
            vec!["好呀，我陪你。"]
        );
        assert!(buffer
            .append("好呀，我陪你。接著", false)
            .unwrap()
            .is_empty());
        assert_eq!(
            buffer.append("好呀，我陪你。接著慢慢說吧", true).unwrap(),
            vec!["接著慢慢說吧"]
        );
        assert!(buffer.append("好呀，我陪你。接著慢慢說吧", true).is_err());
        let mut changed = VoiceReplyBuffer::default();
        changed.append("今天很好。", false).unwrap();
        assert!(changed
            .append("今天不好。", true)
            .unwrap_err()
            .contains("changed voice prefix"));
        assert!(VoiceReplyBuffer::default()
            .append(&"字".repeat(16_001), false)
            .is_err());
    }

    #[test]
    fn spoken_buffer_keeps_decimals_closers_and_long_semantic_phrases() {
        let mut english = VoiceReplyBuffer::default();
        assert!(english.append("It is 3.", false).unwrap().is_empty());
        assert_eq!(
            english.append("It is 3.14. You can rest.", false).unwrap(),
            vec!["It is 3.14."]
        );
        assert_eq!(
            english.append("It is 3.14. You can rest.", true).unwrap(),
            vec!["You can rest."]
        );
        let mut japanese = VoiceReplyBuffer::default();
        assert_eq!(
            japanese.append("「大丈夫！」次は", false).unwrap(),
            vec!["「大丈夫！」"]
        );
        assert_eq!(
            japanese.append("「大丈夫！」次はゆっくり♪", true).unwrap(),
            vec!["次はゆっくり♪"]
        );
        assert!(VoiceReplyBuffer::default()
            .append("！？\n", false)
            .unwrap()
            .is_empty());
        let phrase = "字".repeat(81) + "，";
        assert_eq!(
            VoiceReplyBuffer::default()
                .append(&(phrase.clone() + "後半句"), false)
                .unwrap(),
            vec![phrase]
        );
    }

    #[test]
    fn stable_buffer_can_emit_a_lookahead_validated_trailing_period() {
        let mut buffer = VoiceReplyBuffer::default();
        assert_eq!(buffer.append_stable("Hello.").unwrap(), vec!["Hello."]);
        assert!(buffer.append_stable("Hello.").unwrap().is_empty());
        assert_eq!(
            buffer.append_stable("Hello. Dr. Miku is here.").unwrap(),
            vec!["Dr. Miku is here."]
        );
        assert_eq!(
            buffer.append("Hello. Dr. Miku is here. Bye", true).unwrap(),
            vec!["Bye"]
        );
    }
}
