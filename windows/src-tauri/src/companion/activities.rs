//! Games, sleep and calendar rules shared with the macOS companion.

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Timelike};
use serde_json::{json, Value};

fn contains_any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|word| text.contains(*word))
}

fn words<'a>(language: &str, values: [&'a str; 5]) -> &'a str {
    values[match language {
        "yue" => 1,
        "en" => 2,
        "ja" => 3,
        "ko" => 4,
        _ => 0,
    }]
}

fn game_language(value: &Value) -> String {
    let chosen = value["language"]
        .as_str()
        .or_else(|| value["replyLanguage"].as_str())
        .unwrap_or("auto");
    if ["zh-Hant", "yue", "en", "ja", "ko"].contains(&chosen) {
        return chosen.into();
    }
    match value["interfaceLanguage"].as_str().unwrap_or("zh-Hant") {
        "zh-Hant" => "yue".into(),
        "en" => "en".into(),
        "ja" => "ja".into(),
        "ko" => "ko".into(),
        _ => "zh-Hant".into(),
    }
}

fn random_index(length: usize) -> usize {
    (rand::random::<u64>() % length as u64) as usize
}

fn shuffled<T>(mut values: Vec<T>) -> Vec<T> {
    for index in (1..values.len()).rev() {
        values.swap(index, random_index(index + 1));
    }
    values
}

fn line(text: String, emotion: &str, action: &str, choices: Value) -> Value {
    json!({"text":text,"emotion":emotion,"action":action,"choices":choices})
}

pub fn requested_game(text: &str) -> Option<&'static str> {
    let text = text.to_lowercase();
    if contains_any(
        &text,
        &[
            "唔玩",
            "不玩",
            "唔想",
            "不想",
            "don't",
            "dont",
            "not now",
            "やらない",
            "しない",
            "いや",
            "안 하",
            "안하",
            "안 할",
            "안할",
            "하기 싫",
            "하지 마",
            "하지마",
            "안 해",
            "안해",
            "싫어",
            "나중에",
        ],
    ) {
        return None;
    }
    if contains_any(
        &text,
        &[
            "包剪揼",
            "剪刀石頭布",
            "剪刀石头布",
            "猜拳",
            "石頭剪刀布",
            "rock paper scissors",
            "rock-paper-scissors",
            "じゃんけん",
            "ジャンケン",
            "가위바위보",
            "가위 바위 보",
        ],
    ) {
        Some("rps")
    } else if contains_any(
        &text,
        &["歌曲問答", "歌曲问答", "問答", "quiz", "クイズ", "퀴즈"],
    ) {
        Some("quiz")
    } else if contains_any(
        &text,
        &[
            "打拍子",
            "節奏遊戲",
            "节奏游戏",
            "rhythm",
            "リズム",
            "리듬 게임",
            "리듬게임",
            "박자 맞추기",
        ],
    ) {
        Some("rhythm")
    } else {
        None
    }
}

fn hand_name<'a>(hand: &str, language: &str) -> (&'static str, &'a str) {
    match hand {
        "rock" => (
            "✊",
            words(language, ["石頭", "揼", "rock", "グー", "바위"]),
        ),
        "scissors" => (
            "✌️",
            words(language, ["剪刀", "剪", "scissors", "チョキ", "가위"]),
        ),
        _ => ("✋", words(language, ["布", "包", "paper", "パー", "보"])),
    }
}

fn rps_choices(language: &str) -> Value {
    Value::Array(
        ["rock", "scissors", "paper"]
            .iter()
            .map(|hand| {
                let (emoji, name) = hand_name(hand, language);
                json!({"id":hand,"title":format!("{emoji} {name}")})
            })
            .collect(),
    )
}

fn rps_choose(current: &mut Value, choice: &str, hers: &str, language: &str) -> Vec<Value> {
    let mut mine = current["mine"].as_u64().unwrap_or(0);
    let mut yours = current["yours"].as_u64().unwrap_or(0);
    let outcome = if hers == choice {
        "draw"
    } else if matches!(
        (hers, choice),
        ("rock", "scissors") | ("scissors", "paper") | ("paper", "rock")
    ) {
        mine += 1;
        "win"
    } else {
        yours += 1;
        "lose"
    };
    current["mine"] = json!(mine);
    current["yours"] = json!(yours);
    let over = mine >= 2 || yours >= 2;
    current["isOver"] = json!(over);
    let (emoji, name) = hand_name(hers, language);
    let result = match outcome {
        "draw" => words(
            language,
            [
                "平手～再來！",
                "打和～再嚟！",
                "A draw~ again!",
                "あいこ～もう一回！",
                "비겼네~ 다시 하자!",
            ],
        ),
        "win" => words(
            language,
            ["我贏了～", "我贏咗～", "I win~", "勝った～", "내가 이겼어~"],
        ),
        _ => words(
            language,
            [
                "你贏了！",
                "你贏咗！",
                "You win!",
                "負けた！",
                "네가 이겼어!",
            ],
        ),
    };
    let text = match language {
        "en" => format!("I threw {emoji} {name}! {result} ({mine}–{yours})"),
        "ja" => format!("わたしは{emoji}{name}！{result}（{mine}対{yours}）"),
        "ko" => format!("나는 {emoji}{name}! {result} ({mine}:{yours})"),
        _ => format!("我出{emoji}{name}！{result}（{mine}:{yours}）"),
    };
    let mut first = line(
        text,
        if outcome == "draw" {
            "surprised"
        } else if outcome == "win" {
            "happy"
        } else {
            "pout"
        },
        "idle",
        if over {
            json!([])
        } else {
            rps_choices(language)
        },
    );
    first["rps"] = json!({"hand":hers,"outcome":outcome});
    let mut lines = vec![first];
    if over {
        let ending = if mine >= 2 {
            words(
                language,
                [
                    "我贏了這局！嘿嘿，下次再挑戰我吧～",
                    "我贏咗成局！嘿嘿，下次再挑戰我啦～",
                    "I won the match! Hehe, challenge me again sometime~",
                    "わたしの勝ち！えへへ、また挑戦してね～",
                    "이번 승부는 내 승리! 헤헤, 다음에 또 도전해 줘~",
                ],
            )
        } else {
            words(
                language,
                [
                    "你贏了這局…好不甘心！下次一定要贏回來！",
                    "你贏咗成局…好唔甘心！下次一定贏返！",
                    "You won the match… so frustrating! I'll get you next time!",
                    "負けちゃった…くやしい！次は絶対勝つから！",
                    "네가 이겼네… 아쉽다! 다음에는 꼭 이길 거야!",
                ],
            )
        };
        lines.push(line(
            ending.into(),
            if mine >= 2 { "happy" } else { "pout" },
            if mine >= 2 { "cheer" } else { "pout" },
            json!([]),
        ));
    }
    lines
}

const QUIZ_SONGS: &[(&str, &str)] = &[
    ("千本桜", "黒うさP"),
    ("メルト", "ryo (supercell)"),
    ("ワールドイズマイン", "ryo (supercell)"),
    ("ブラック★ロックシューター", "ryo (supercell)"),
    ("恋は戦争", "ryo (supercell)"),
    ("ローリンガール", "wowaka"),
    ("アンノウン・マザーグース", "wowaka"),
    ("裏表ラバーズ", "wowaka"),
    ("砂の惑星", "ハチ"),
    ("マトリョシカ", "ハチ"),
    ("初音ミクの消失", "cosMo@暴走P"),
    ("ヴァンパイア", "DECO*27"),
    ("ゴーストルール", "DECO*27"),
    ("ラビットホール", "DECO*27"),
    ("愛言葉", "DECO*27"),
    ("脳漿炸裂ガール", "れるりり"),
    ("Tell Your World", "livetune"),
    ("みくみくにしてあげる♪【してやんよ】", "ika"),
    ("深海少女", "ゆうゆ"),
    ("天ノ弱", "164"),
    ("桜ノ雨", "halyosy"),
    ("ロキ", "みきとP"),
    ("少女レイ", "みきとP"),
    ("グリーンライツ・セレナーデ", "Omoi"),
    ("Sweet Devil", "八王子P"),
    ("命に嫌われている。", "カンザキイオリ"),
];

fn next_question(current: &mut Value, language: &str) -> Value {
    let asked = current["asked"].as_array().cloned().unwrap_or_default();
    let mut pool: Vec<_> = QUIZ_SONGS
        .iter()
        .filter(|song| !asked.iter().any(|entry| entry.as_str() == Some(song.0)))
        .copied()
        .collect();
    if pool.is_empty() {
        pool = QUIZ_SONGS.to_vec();
    }
    let (title, producer) = pool[random_index(pool.len())];
    let by_producer = rand::random::<bool>();
    let mut options: Vec<&str> = if by_producer {
        let mut producers: Vec<&str> = QUIZ_SONGS
            .iter()
            .map(|entry| entry.1)
            .filter(|name| *name != producer)
            .collect();
        producers.sort_unstable();
        producers.dedup();
        shuffled(producers).into_iter().take(3).collect()
    } else {
        shuffled(
            QUIZ_SONGS
                .iter()
                .filter(|entry| entry.1 != producer)
                .map(|entry| entry.0)
                .collect(),
        )
        .into_iter()
        .take(3)
        .collect()
    };
    let answer_text = if by_producer { producer } else { title };
    options.push(answer_text);
    let options = shuffled(options);
    let answer = options
        .iter()
        .position(|entry| *entry == answer_text)
        .unwrap_or(0);
    let number = current["number"].as_u64().unwrap_or(0) + 1;
    current["number"] = json!(number);
    let mut asked = asked;
    asked.push(json!(title));
    current["asked"] = json!(asked);
    current["question"] =
        json!({"title":title,"producer":producer,"options":options,"answer":answer});
    let prompt = if by_producer {
        match language {
            "en" => format!("Who made “{title}”?"),
            "ja" => format!("「{title}」を作ったのは誰？"),
            "ko" => format!("「{title}」을 만든 프로듀서는 누구일까?"),
            "yue" => format!("「{title}」係邊位 P主嘅作品？"),
            _ => format!("「{title}」是哪位 P 主的作品？"),
        }
    } else {
        match language {
            "en" => format!("Which of these is by {producer}?"),
            "ja" => format!("{producer}の曲はどれ？"),
            "ko" => format!("다음 중 {producer}의 곡은 어느 걸까?"),
            "yue" => format!("以下邊首係 {producer} 嘅歌？"),
            _ => format!("以下哪首是 {producer} 的歌？"),
        }
    };
    line(
        format!("Q{number}. {prompt}"),
        "curious",
        "think",
        json!(options
            .iter()
            .enumerate()
            .map(|(i, title)| json!({"id":i.to_string(),"title":title}))
            .collect::<Vec<_>>()),
    )
}

pub fn game_action(state: &mut Value, action: &str, payload: &Value) -> Result<Value, String> {
    if !state.is_object() {
        *state = json!({});
    }
    let action = action.strip_prefix("game.").unwrap_or(action);
    let mut current = state["current"].clone();
    let language = if action == "start" {
        game_language(payload)
    } else {
        current["language"].as_str().unwrap_or("zh-Hant").to_owned()
    };
    let mut said = String::new();
    let lines = if action == "start" {
        let game = payload["game"]
            .as_str()
            .or_else(|| payload["type"].as_str())
            .ok_or("Choose a game.")?;
        current = json!({"type":game,"language":language,"isOver":false});
        match game {
            "rps" => {
                current["mine"] = json!(0);
                current["yours"] = json!(0);
                vec![line(words(&language, ["來玩剪刀石頭布！三局兩勝～剪刀、石頭、布！你出什麼？", "嚟玩包剪揼！三盤兩勝～包、剪、揼！你出咩？", "Rock-paper-scissors! Best of three~ Rock, paper, scissors… what's yours?", "じゃんけんしよ！三本勝負～じゃん、けん…何出す？", "가위바위보 하자! 세 판 중 두 판 먼저 이기기야~ 가위, 바위, 보! 뭘 냈어?"]).into(), "happy", "cheer", rps_choices(&language))]
            }
            "quiz" => {
                current["number"] = json!(0);
                current["score"] = json!(0);
                current["asked"] = json!([]);
                vec![line(words(&language, ["Vocaloid 歌曲問答！一共 5 題，看看你有多熟～", "Vocaloid 歌曲問答！一共 5 題，睇吓你有幾熟～", "Vocaloid song quiz! 5 questions — let's see how well you know them~", "ボカロ曲クイズ！全5問、どれだけ知ってるかな～", "보컬로이드 곡 퀴즈! 총 5문제야. 얼마나 알고 있는지 볼까~"]).into(), "happy", "clap", json!([])), next_question(&mut current, &language)]
            }
            "rhythm" => {
                current["bpm"] = json!(104);
                current["countIn"] = json!(4);
                current["beats"] = json!(16);
                current["grades"] = json!({});
                vec![line(
                    words(
                        &language,
                        [
                            "跟著節拍打拍子！先數四拍，再一起開始♪",
                            "跟住節拍打拍子！先數四拍，再一齊開始♪",
                            "Tap along! Four count-in beats, then let's start♪",
                            "リズムに合わせて叩こう！4つ数えたらスタート♪",
                            "박자에 맞춰 눌러 봐! 네 박자 세고 시작이야♪",
                        ],
                    )
                    .into(),
                    "happy",
                    "clap",
                    json!([]),
                )]
            }
            _ => return Err("Unknown game.".into()),
        }
    } else if action == "cancel" {
        current["isOver"] = json!(true);
        vec![]
    } else {
        if !current.is_object() || current["isOver"] == true {
            return Err("There is no active game.".into());
        }
        let game = current["type"].as_str().unwrap_or("").to_owned();
        match (game.as_str(), action) {
            ("rps", "choose") => {
                let choice = payload["choice"]
                    .as_str()
                    .or_else(|| payload["id"].as_str())
                    .ok_or("Choose a hand.")?;
                if !["rock", "scissors", "paper"].contains(&choice) {
                    return Err("Unknown hand.".into());
                }
                let (emoji, name) = hand_name(choice, &language);
                said = format!("{emoji} {name}");
                rps_choose(
                    &mut current,
                    choice,
                    ["rock", "scissors", "paper"][random_index(3)],
                    &language,
                )
            }
            ("quiz", "choose") => {
                let index = payload["choice"]
                    .as_str()
                    .or_else(|| payload["id"].as_str())
                    .and_then(|value| value.parse::<usize>().ok())
                    .or_else(|| payload["choice"].as_u64().map(|v| v as usize))
                    .ok_or("Choose an answer.")?;
                let question = current["question"].clone();
                let options = question["options"]
                    .as_array()
                    .ok_or("The quiz has no current question.")?;
                if index >= options.len() {
                    return Err("Unknown answer.".into());
                }
                said = options[index].as_str().unwrap_or("").into();
                let correct = question["answer"].as_u64() == Some(index as u64);
                let score = current["score"].as_u64().unwrap_or(0) + u64::from(correct);
                current["score"] = json!(score);
                let fact = format!(
                    "「{}」— {}",
                    question["title"].as_str().unwrap_or(""),
                    question["producer"].as_str().unwrap_or("")
                );
                let prefix = if correct {
                    words(
                        &language,
                        ["答對了！", "答啱喇！", "Correct! ", "正解！", "정답이야! "],
                    )
                } else {
                    words(
                        &language,
                        [
                            "不是喔～答案是：",
                            "唔係喔～答案係：",
                            "Not quite~ it's ",
                            "ざんねん～正解は",
                            "아쉽지만~ 정답은 ",
                        ],
                    )
                };
                let mut lines = vec![line(
                    format!("{prefix}{fact}{}", if correct { " ♪" } else { "" }),
                    if correct { "happy" } else { "sad" },
                    if correct { "clap" } else { "shakeHead" },
                    json!([]),
                )];
                if current["number"].as_u64().unwrap_or(0) < 5 {
                    lines.push(next_question(&mut current, &language));
                } else {
                    current["isOver"] = json!(true);
                    current["question"] = Value::Null;
                    let tail = if score == 5 {
                        words(
                            &language,
                            [
                                "你真的很熟 Vocaloid 喔！",
                                "你真係好熟 Vocaloid 喔！",
                                "You really know your Vocaloid!",
                                "すっごく詳しいね！",
                                "보컬로이드를 정말 잘 아는구나!",
                            ],
                        )
                    } else if score >= 3 {
                        words(
                            &language,
                            ["很厲害呀！", "好叻呀！", "Nice!", "やるね！", "대단해!"],
                        )
                    } else {
                        words(
                            &language,
                            [
                                "沒關係，下次我們一起多聽一些歌！",
                                "唔緊要，下次我哋一齊聽多啲歌！",
                                "That's okay, let's listen to more songs together!",
                                "大丈夫、もっと一緒に曲を聴こう！",
                                "괜찮아, 다음엔 같이 노래를 더 들어 보자!",
                            ],
                        )
                    };
                    lines.push(line(
                        format!("{score}/5～{tail}"),
                        if score >= 3 { "happy" } else { "calm" },
                        if score == 5 {
                            "cheer"
                        } else if score >= 3 {
                            "clap"
                        } else {
                            "nod"
                        },
                        json!([]),
                    ));
                }
                lines
            }
            ("rhythm", "tap") => {
                let elapsed = payload["elapsedSeconds"]
                    .as_f64()
                    .filter(|value| value.is_finite())
                    .ok_or("A rhythm tap needs elapsedSeconds.")?;
                let interval = 60.0 / 104.0;
                let beat = (elapsed / interval).round() as i64 - 4;
                if !(0..16).contains(&beat) {
                    return Err("The tap is outside the song.".into());
                }
                let key = beat.to_string();
                if !current["grades"][&key].is_null() {
                    return Err("This beat was already played.".into());
                }
                let offset = elapsed - (beat + 4) as f64 * interval;
                let grade = rhythm_grade(offset);
                current["grades"][&key] = json!(grade);
                current["lastGrade"] = json!(grade);
                current["lastBeat"] = json!(beat);
                vec![]
            }
            ("rhythm", "finish") => {
                let grades: Vec<_> = (0..16)
                    .map(|i| {
                        current["grades"][i.to_string()]
                            .as_str()
                            .unwrap_or("miss")
                            .to_owned()
                    })
                    .collect();
                let score = rhythm_score(&grades.iter().map(String::as_str).collect::<Vec<_>>());
                let perfect = grades
                    .iter()
                    .filter(|grade| grade.as_str() == "perfect")
                    .count();
                current["isOver"] = json!(true);
                current["score"] = json!(score);
                current["result"] = json!({"grades":grades,"perfect":perfect});
                vec![line(
                    format!("{score}/100 ♪"),
                    if score >= 70 { "happy" } else { "calm" },
                    if score >= 70 { "cheer" } else { "nod" },
                    json!([]),
                )]
            }
            _ => return Err("This action does not belong to the active game.".into()),
        }
    };
    state["current"] = current.clone();
    state["supported"] = json!(["rps", "quiz", "rhythm"]);
    let mut result = lines
        .last()
        .cloned()
        .unwrap_or_else(|| json!({"text":"","emotion":"happy","action":"idle","choices":[]}));
    result["game"] = current["type"].clone();
    result["isOver"] = current["isOver"].clone();
    result["language"] = json!(language);
    result["said"] = json!(said);
    result["lines"] = json!(lines);
    result["state"] = current;
    Ok(result)
}

fn rhythm_grade(offset: f64) -> &'static str {
    if offset.abs() <= 0.07 {
        "perfect"
    } else if offset.abs() <= 0.15 {
        "good"
    } else {
        "miss"
    }
}

fn rhythm_score(grades: &[&str]) -> u64 {
    if grades.is_empty() {
        return 0;
    }
    let points: u64 = grades
        .iter()
        .map(|grade| match *grade {
            "perfect" => 2,
            "good" => 1,
            _ => 0,
        })
        .sum();
    (points as f64 / (grades.len() * 2) as f64 * 100.0).round() as u64
}

fn parse_day(value: &Value) -> Option<NaiveDate> {
    if let Some(text) = value.as_str() {
        return NaiveDate::parse_from_str(text, "%Y-%m-%d")
            .ok()
            .or_else(|| {
                DateTime::parse_from_rfc3339(text)
                    .ok()
                    .map(|date| date.with_timezone(&Local).date_naive())
            });
    }
    value
        .as_i64()
        .and_then(|seconds| Local.timestamp_opt(seconds, 0).single())
        .map(|date| date.date_naive())
}

const EVENT_KINDS: [&str; 4] = ["magicalMirai", "mikuWithYou", "mikuExpo", "snowMiku"];

pub fn event_query(text: &str, events: &[Value], now: DateTime<Local>) -> Option<Value> {
    let normalized: String = text
        .chars()
        .map(|c| {
            if ('\u{ff01}'..='\u{ff5e}').contains(&c) {
                char::from_u32(c as u32 - 0xfee0).unwrap_or(c)
            } else {
                c
            }
        })
        .flat_map(char::to_lowercase)
        .collect();
    let chars: Vec<_> = normalized.chars().collect();
    let year = chars.windows(4).enumerate().find_map(|(index, digits)| {
        if digits[0] != '2'
            || digits[1] != '0'
            || !digits.iter().all(char::is_ascii_digit)
            || index > 0 && chars[index - 1].is_ascii_digit()
            || chars
                .get(index + 4)
                .map(char::is_ascii_digit)
                .unwrap_or(false)
        {
            return None;
        }
        digits.iter().collect::<String>().parse::<i64>().ok()
    });
    let compact: String = normalized.chars().filter(|c| !c.is_whitespace()).collect();
    let aliases: [(&str, &[&str]); 4] = [
        (
            "magicalMirai",
            &[
                "魔法未來",
                "魔法未来",
                "マジカルミライ",
                "magicalmirai",
                "매지컬미라이",
            ],
        ),
        (
            "mikuWithYou",
            &["未來有你", "未来有你", "mikuwithyou", "미쿠위드유"],
        ),
        ("mikuExpo", &["mikuexpo", "미쿠엑스포", "ミクエキスポ"]),
        (
            "snowMiku",
            &[
                "snowmiku",
                "雪ミク",
                "雪初音",
                "雪未來",
                "雪未来",
                "스노우미쿠",
                "유키미쿠",
            ],
        ),
    ];
    let mut kinds: Vec<_> = aliases
        .iter()
        .filter(|(_, names)| {
            names.iter().any(|alias| {
                compact.match_indices(*alias).any(|(index, matched)| {
                    if !alias.as_bytes()[0].is_ascii() {
                        return true;
                    }
                    let before = compact[..index].chars().next_back();
                    let after = compact[index + matched.len()..].chars().next();
                    !before.map(|c| c.is_ascii_alphabetic()).unwrap_or(false)
                        && !after.map(|c| c.is_ascii_alphabetic()).unwrap_or(false)
                })
            })
        })
        .map(|(kind, _)| *kind)
        .collect();
    if kinds.is_empty() {
        let browsing = normalized.trim().trim_end_matches('年');
        if !browsing.is_empty()
            && year
                .map(|year| browsing != year.to_string())
                .unwrap_or(true)
        {
            return None;
        }
        kinds = EVENT_KINDS.to_vec();
    }
    let today = now.date_naive();
    let mut matches: Vec<_> = events
        .iter()
        .filter(|event| {
            if !kinds.contains(&event["kind"].as_str().unwrap_or("")) {
                return false;
            }
            let (Some(start), Some(end)) = (parse_day(&event["start"]), parse_day(&event["end"]))
            else {
                return false;
            };
            end >= start
                && event["year"].as_i64() == Some(start.year() as i64)
                && year
                    .map(|year| event["year"].as_i64() == Some(year))
                    .unwrap_or(end >= today)
        })
        .cloned()
        .collect();
    matches.sort_by(|a, b| {
        a["start"]
            .as_str()
            .cmp(&b["start"].as_str())
            .then(a["kind"].as_str().cmp(&b["kind"].as_str()))
            .then(a["city"].as_str().cmp(&b["city"].as_str()))
            .then(a["venue"].as_str().cmp(&b["venue"].as_str()))
    });
    for event in &mut matches {
        event["status"] = json!(if parse_day(&event["end"])
            .map(|end| end < today)
            .unwrap_or(false)
        {
            "ended"
        } else {
            "upcomingOrOngoing"
        });
    }
    let unknown: Vec<_> = kinds
        .iter()
        .copied()
        .filter(|kind| {
            !matches
                .iter()
                .any(|event| event["kind"].as_str() == Some(*kind))
        })
        .collect();
    Some(
        json!({"kinds":kinds,"year":year,"events":matches,"unknownKinds":unknown,"fromCache":true}),
    )
}

pub fn special_days(now: DateTime<Local>, custom: &Value) -> Value {
    let date = now.date_naive();
    let first_met = parse_day(&custom["firstMet"]);
    let events = custom["events"].as_array().cloned().unwrap_or_default();
    let mut all = Vec::new();
    for year in [date.year() - 1, date.year(), date.year() + 1] {
        for (key, month, first, last) in [
            ("newYear", 1, 1, 3),
            ("mikuDay", 3, 9, 9),
            ("tanabata", 7, 7, 7),
            ("birthday", 8, 31, 31),
            ("halloween", 10, 31, 31),
            ("christmas", 12, 24, 25),
            ("newYearsEve", 12, 31, 31),
        ] {
            if let (Some(start), Some(end)) = (
                NaiveDate::from_ymd_opt(year, month, first),
                NaiveDate::from_ymd_opt(year, month, last),
            ) {
                all.push(json!({"key":key,"start":start.to_string(),"end":end.to_string(),"fetched":false}));
            }
        }
        all.push(json!({"key":"summerFestival","start":format!("{year}-07-15"),"end":format!("{year}-08-31"),"fetched":false}));
        if let Some(first_met) = first_met.filter(|met| year > met.year()) {
            let anniversary = NaiveDate::from_ymd_opt(year, first_met.month(), first_met.day())
                .or_else(|| {
                    NaiveDate::from_ymd_opt(
                        year,
                        first_met.month(),
                        first_met.day().saturating_sub(1),
                    )
                });
            if let Some(day) = anniversary {
                all.push(json!({"key":"anniversary","start":day.to_string(),"end":day.to_string(),"years":year-first_met.year(),"fetched":false}));
            }
        }
    }
    for event in events {
        let kind = event["kind"].as_str().unwrap_or("");
        let start = parse_day(&event["start"]);
        let end = parse_day(&event["end"]);
        let source = event["source"].as_str().unwrap_or("");
        let official = match kind {
            "magicalMirai" => "https://magicalmirai.com/",
            "mikuWithYou" => "https://www.scla.com.cn/",
            "mikuExpo" => "https://mikuexpo.com/",
            "snowMiku" => "https://snowmiku.com/",
            _ => "",
        };
        if let (Some(start), Some(end)) = (start, end) {
            if official.is_empty()
                || !source.starts_with(official)
                || end < start
                || event["year"].as_i64() != Some(start.year() as i64)
            {
                continue;
            }
            all.push(json!({"key":kind,"start":start.to_string(),"end":end.to_string(),"city":event["city"],"venue":event["venue"],"source":source,"fetched":true}));
        }
    }
    all.sort_by(|a, b| {
        a["start"]
            .as_str()
            .cmp(&b["start"].as_str())
            .then(a["key"].as_str().cmp(&b["key"].as_str()))
    });
    let today: Vec<_> = all
        .iter()
        .filter(|item| {
            parse_day(&item["start"])
                .map(|start| start <= date)
                .unwrap_or(false)
                && parse_day(&item["end"])
                    .map(|end| end >= date)
                    .unwrap_or(false)
        })
        .cloned()
        .collect();
    let upcoming: Vec<_> = all
        .iter()
        .filter(|item| {
            parse_day(&item["start"])
                .map(|start| (1..=14).contains(&(start - date).num_days()))
                .unwrap_or(false)
        })
        .cloned()
        .collect();
    let known: Vec<_> = all
        .iter()
        .filter(|item| {
            item["fetched"] == true
                && parse_day(&item["end"])
                    .map(|end| end >= date)
                    .unwrap_or(false)
        })
        .cloned()
        .collect();
    let unknown: Vec<_> = EVENT_KINDS
        .iter()
        .copied()
        .filter(|kind| {
            !known
                .iter()
                .any(|event| event["key"].as_str() == Some(*kind))
        })
        .collect();
    json!({"today":today,"upcoming":upcoming,"known":known,"unknown":unknown,"all":all})
}

pub fn sleep_status(settings: &Value, now: DateTime<Local>, wake_until: Option<i64>) -> Value {
    let until = settings["sleep.override.until"]
        .as_i64()
        .or_else(|| settings["sleepOverride"]["until"].as_i64())
        .or_else(|| settings["sleepOverrideUntil"].as_i64());
    let override_asleep = settings["sleep.override.asleep"]
        .as_bool()
        .or_else(|| settings["sleepOverride"]["asleep"].as_bool())
        .or_else(|| match settings["sleepOverrideKind"].as_str() {
            Some("sleep" | "asleep") => Some(true),
            Some("wake" | "awake") => Some(false),
            _ => None,
        });
    let active = until
        .zip(override_asleep)
        .filter(|(until, _)| *until > now.timestamp());
    let active = if let Some(until) = wake_until.filter(|until| *until > now.timestamp()) {
        Some((until, false))
    } else {
        active
    };
    let start = schedule_minutes(settings, "sleepStartHour", "quietStart", 60);
    let end = schedule_minutes(settings, "sleepEndHour", "quietEnd", 7 * 60);
    let minute = now.hour() * 60 + now.minute();
    let enabled = settings["sleepEnabled"] != false && settings["sleepScheduleEnabled"] != false;
    let scheduled = enabled
        && if start < end {
            minute >= start && minute < end
        } else if start > end {
            minute >= start || minute < end
        } else {
            false
        };
    json!({"asleep":active.map(|(_,asleep)|asleep).unwrap_or(scheduled),"scheduledAsleep":scheduled,"startHour":start/60,"endHour":end/60,"startMinutes":start,"endMinutes":end,"enabled":enabled,"override":active.map(|(until,asleep)|json!({"asleep":asleep,"until":until*1000}))})
}

fn schedule_minutes(settings: &Value, hour_key: &str, clock_key: &str, fallback: u32) -> u32 {
    if let Some(hour) = settings[hour_key].as_u64().filter(|hour| *hour < 24) {
        return hour as u32 * 60;
    }
    for value in [&settings[hour_key], &settings[clock_key]] {
        if let Some(clock) = value.as_str() {
            let parts: Vec<_> = clock.trim().split(':').collect();
            if let Some(hour) = parts
                .first()
                .and_then(|hour| hour.parse::<u32>().ok())
                .filter(|hour| *hour < 24)
            {
                let minute = if parts.len() == 1 {
                    Some(0)
                } else if parts.len() == 2 {
                    parts[1].parse::<u32>().ok().filter(|minute| *minute < 60)
                } else {
                    None
                };
                if let Some(minute) = minute {
                    return hour * 60 + minute;
                }
            }
        }
    }
    fallback
}

fn next_hour(now: DateTime<Local>, hour: u32) -> DateTime<Local> {
    let date = now.date_naive();
    let same = Local
        .with_ymd_and_hms(date.year(), date.month(), date.day(), hour, 0, 0)
        .earliest()
        .unwrap_or(now + Duration::hours(24));
    if same > now {
        same
    } else {
        let date = date.succ_opt().unwrap_or(date);
        Local
            .with_ymd_and_hms(date.year(), date.month(), date.day(), hour, 0, 0)
            .earliest()
            .unwrap_or(now + Duration::hours(24))
    }
}

pub fn sleep_override(action: &str, now: DateTime<Local>, minutes: f64) -> Value {
    let (asleep, until) = match action {
        "bed" | "sleep" | "goodNight" => (
            true,
            if now.hour() >= 20 || now.hour() < 7 {
                next_hour(now, 7)
            } else {
                now + Duration::minutes(45)
            },
        ),
        "morning" | "goodMorning" => (false, next_hour(now, 1)),
        _ => (
            false,
            now + Duration::seconds(
                (if minutes.is_finite() {
                    minutes.clamp(1.0, 120.0)
                } else {
                    20.0
                } * 60.0) as i64,
            ),
        ),
    };
    json!({"sleep.override.asleep":asleep,"sleep.override.until":until.timestamp()})
}

pub fn declines_bedtime(text: &str) -> bool {
    let lower = text.to_lowercase().replace(['’', '‘'], "'");
    let imperative = contains_any(
        &lower,
        &["why don't you go to sleep", "why don't you go to bed"],
    );
    let declines = contains_any(
        &lower,
        &[
            "不想睡",
            "不想去睡",
            "不要睡",
            "不要去睡",
            "不用睡",
            "不用去睡",
            "不需要睡",
            "不需要去睡",
            "別睡",
            "别睡",
            "不能睡",
            "我不睡",
            "睡不著",
            "睡不着",
            "不睏",
            "不困",
            "唔想瞓",
            "唔想去瞓",
            "唔好瞓",
            "唔使瞓",
            "唔使去瞓",
            "我唔瞓",
            "瞓唔着",
            "瞓唔著",
            "眠れない",
            "眠くない",
            "寝たくない",
            "眠りたくない",
            "寝られない",
            "寝ないで",
            "まだ寝ない",
            "寝る気はない",
            "寝る必要はない",
            "can't sleep",
            "cannot sleep",
            "don't want to sleep",
            "do not want to sleep",
            "don't want to go to sleep",
            "do not want to go to sleep",
            "don't want to go to bed",
            "do not want to go to bed",
            "don't go to sleep",
            "do not go to sleep",
            "don't go to bed",
            "do not go to bed",
            "not going to sleep",
            "not going to bed",
            "not going to go to sleep",
            "not going to go to bed",
            "won't go to sleep",
            "won't go to bed",
            "don't need to sleep",
            "do not need to sleep",
            "don't need to go to bed",
            "do not need to go to bed",
            "not sleepy",
            "not tired",
            "잠이 안 와",
            "잠이 안와",
            "졸리지 않",
            "안 졸려",
            "안졸려",
            "자고 싶지 않",
            "자기 싫",
            "자지 마",
            "자지마",
            "안 잘",
            "안잘",
            "안 자",
            "못 자",
            "못자",
            "자러 가지 마",
            "자러가지 마",
            "자러 가지마",
            "자러가지마",
            "잠들지 마",
            "잠들지마",
            "자러 가기 싫",
            "자지 않",
            "자러 가는 건 아니",
        ],
    );
    declines && !imperative
}

pub fn is_good_night_farewell(text: &str) -> bool {
    let lower = text.to_lowercase().replace(['’', '‘'], "'");
    let good_night = contains_any(
        &lower,
        &[
            "晚安",
            "早唞",
            "good night",
            "goodnight",
            "nighty night",
            "おやすみ",
            "お休み",
            "잘 자",
            "잘자",
            "안녕히 주무세요",
        ],
    );
    let explanatory = contains_any(
        &lower,
        &[
            "晚安的",
            "晚安是",
            "晚安英文",
            "晚安日文",
            "怎麼說",
            "怎么说",
            "翻譯",
            "翻译",
            "意思",
            "說法",
            "说法",
            "不說晚安",
            "不说晚安",
            "別說晚安",
            "别说晚安",
            "不要說晚安",
            "不要说晚安",
            "還不是晚安",
            "还不是晚安",
            "good night mean",
            "what is good night",
            "good night in ",
            "how to say good night",
            "how do you say good night",
            "don't say good night",
            "do not say good night",
            "not saying good night",
            "won't say good night",
            "translate",
            "translation",
            "the phrase",
            "the words",
            "the word",
            "뜻",
            "의미",
            "번역",
            "어떻게 말",
            "어떻게 해",
            "영어로",
            "일본어로",
            "중국어로",
            "라고 말하지",
            "라고 하지",
            "라는 말",
            "라는 노래",
            "노래 제목",
            "잘 자는",
            "おやすみの意味",
            "おやすみは",
            "おやすみとは",
            "おやすみという",
            "おやすみと言わない",
            "おやすみじゃない",
            "英語で",
            "中国語で",
            "翻訳",
            "言い方",
            "「",
            "」",
            "『",
            "』",
            "\"good night\"",
            "“good night”",
            "'good night'",
        ],
    );
    good_night && !explanatory
}

pub fn should_automatically_sleep(reply: &str, user_text: &str, now: DateTime<Local>) -> bool {
    !declines_bedtime(user_text)
        && (now.hour() >= 22 || now.hour() < 7)
        && is_good_night_farewell(reply)
}

pub fn sleep_intent(text: &str) -> Option<&'static str> {
    let lower = text.to_lowercase().replace(['’', '‘'], "'");
    if contains_any(
        &lower,
        &[
            "早晨",
            "早安",
            "早上好",
            "good morning",
            "morning!",
            "おはよう",
            "좋은 아침",
            "좋은아침",
            "잘 잤어",
            "잘잤어",
        ],
    ) {
        return Some("goodMorning");
    }
    if declines_bedtime(text) {
        return None;
    }
    if is_good_night_farewell(text) {
        return Some("goodNight");
    }
    if contains_any(
        &lower,
        &[
            "去睡",
            "快睡",
            "睡吧",
            "睡覺吧",
            "睡觉吧",
            "上床",
            "該睡",
            "该睡",
            "早點睡",
            "早点睡",
            "要睡了",
            "要睡覺了",
            "要睡觉了",
            "想睡了",
            "想睡覺了",
            "想睡觉了",
            "我睡了",
            "準備睡",
            "准备睡",
            "去瞓",
            "瞓覺",
            "瞓啦",
            "瞓喇",
            "想瞓",
            "要瞓",
            "準備瞓",
            "寝よう",
            "寝てね",
            "寝なよ",
            "寝なさい",
            "もう寝る",
            "寝るね",
            "寝るよ",
            "寝るわ",
            "寝ます",
            "眠ります",
            "そろそろ寝",
            "go to sleep",
            "go to bed",
            "going to sleep",
            "going to bed",
            "gonna sleep",
            "gonna go to bed",
            "time for bed",
            "time to sleep",
            "off to bed",
            "heading to bed",
            "get some sleep",
            "should sleep",
            "need to sleep",
            "자러 가",
            "자러가",
            "잘게",
            "잘 거야",
            "잘거야",
            "자야겠",
            "자야 겠",
            "이제 자",
            "이제자",
            "일찍 자",
            "어서 자",
            "잠자리에",
            "자러 갈",
            "자야지",
            "자자",
        ],
    ) {
        Some("goodNight")
    } else {
        None
    }
}

pub fn proactive_allowed(
    settings: &Value,
    context: &Value,
    asleep: bool,
    last_at: Option<i64>,
    now: i64,
) -> bool {
    if asleep {
        return false;
    }
    let enabled = settings["proactiveEnabled"].as_bool().unwrap_or(false)
        || ["activity", "media", "video", "screen", "random"]
            .iter()
            .any(|source| settings[format!("awareness.{source}")].as_bool() == Some(true));
    if !enabled {
        return false;
    }
    for key in [
        "muted",
        "quiet",
        "isChatting",
        "isCalling",
        "inCall",
        "fullscreen",
        "fullScreen",
        "focusMode",
        "doNotDisturb",
        "locked",
        "sleeping",
    ] {
        if context[key].as_bool() == Some(true) {
            return false;
        }
    }
    if settings["muted"].as_bool() == Some(true) {
        return false;
    }
    let unanswered = context["unanswered"]
        .as_u64()
        .or_else(|| context["unansweredLines"].as_u64())
        .unwrap_or(0);
    if unanswered >= 2 {
        return false;
    }
    let casual_gap = context["casualGap"]
        .as_i64()
        .unwrap_or(20 * 60)
        .clamp(20 * 60, 30 * 60);
    let gap = if unanswered == 0 && context["urgent"].as_bool() == Some(true) {
        3 * 60
    } else {
        casual_gap
    };
    last_at
        .map(|last| now.saturating_sub(last) >= gap)
        .unwrap_or(true)
}

pub fn is_repeat(line: &str, recent: &[String]) -> bool {
    let normalize = |value: &str| {
        value
            .chars()
            .flat_map(char::to_lowercase)
            .filter(|value| value.is_alphanumeric())
            .collect::<Vec<_>>()
    };
    let new = normalize(line);
    if new.len() < 2 {
        return false;
    }
    recent.iter().any(|value| {
        let old = normalize(value);
        if old.len() < 2 {
            return false;
        }
        if new.windows(old.len()).any(|v| v == old) || old.windows(new.len()).any(|v| v == new) {
            return true;
        }
        let opening = 6.min(new.len()).min(old.len());
        if opening >= 4 && new[..opening] == old[..opening] {
            return true;
        }
        let mut previous = vec![0usize; old.len() + 1];
        let mut best = 0;
        for a in &new {
            let mut current = vec![0usize; old.len() + 1];
            for (j, b) in old.iter().enumerate() {
                if a == b {
                    current[j + 1] = previous[j] + 1;
                    best = best.max(current[j + 1]);
                }
            }
            previous = current;
        }
        best >= 5 && best as f64 >= new.len().min(old.len()) as f64 * 0.6
    })
}

pub fn music_request(text: &str) -> Option<Value> {
    music_request_with_context(text, None, &[], &[])
}

pub fn music_request_with_context(
    text: &str,
    previous: Option<&str>,
    recent: &[String],
    known_titles: &[String],
) -> Option<Value> {
    let mut value = text.trim().replace('’', "'");
    if value.is_empty() || value.chars().count() > 160 {
        return None;
    }
    let lower = value.to_lowercase();
    if contains_any(
        &lower,
        &[
            "不要",
            "不用",
            "不想",
            "別",
            "别",
            "唔好",
            "唔使",
            "唔想",
            "停",
            "關掉",
            "关掉",
            "don't",
            "dont",
            "do not",
            "stop",
            "止めて",
            "やめて",
            "ないで",
            "틀지 마",
            "틀지마",
            "재생하지 마",
            "재생하지마",
            "켜지 마",
            "켜지마",
            "열지 마",
            "열지마",
            "듣기 싫",
            "듣고 싶지 않",
            "끄지 마",
            "멈춰",
        ],
    ) {
        return None;
    }
    let platform = if contains_any(
        &lower,
        &[
            "apple music",
            "applemusic",
            "apple 音樂",
            "apple 音乐",
            "蘋果音樂",
            "苹果音乐",
            "アップルミュージック",
            "애플 뮤직",
            "애플뮤직",
        ],
    ) {
        Some("appleMusic")
    } else if contains_any(&lower, &["spotify", "スポティファイ", "스포티파이"]) {
        Some("spotify")
    } else if contains_any(
        &lower,
        &["youtube", "you tube", "油管", "ユーチューブ", "유튜브"],
    ) {
        Some("youtube")
    } else {
        None
    };
    let referenced = previous
        .into_iter()
        .chain(recent.iter().map(String::as_str))
        .find_map(|line| last_song_title(line, known_titles));
    let affirmative = [
        "好啊",
        "好呀",
        "好吖",
        "好的",
        "好喔",
        "好哦",
        "好喇",
        "好啦",
        "好吧",
        "好",
        "可以啊",
        "可以呀",
        "可以",
        "要",
        "想",
        "想聽",
        "想听",
        "聽",
        "听",
        "行",
        "ok",
        "okay",
        "yes",
        "yeah",
        "sure",
        "please",
        "嗯嗯",
        "嗯",
        "うん",
        "いいよ",
        "はい",
        "ええ",
        "聴く",
        "聴きたい",
        "응",
        "네",
        "좋아",
        "좋아요",
        "그래",
        "그래요",
        "들을래",
    ];
    let trimmed = lower.trim_matches(|c: char| c.is_whitespace() || "，、,。.!！~～♪".contains(c));
    if let (Some(title), Some(previous)) = (referenced.as_ref(), previous) {
        if affirmative.contains(&trimmed) && offers_to_play(previous) {
            return Some(json!({"query":title,"platform":platform}));
        }
    }
    for prefix in [
        "miku",
        "初音未來",
        "初音未来",
        "初音ミク",
        "ミク",
        "미쿠야",
        "미쿠",
        "하츠네 미쿠",
    ] {
        if value.to_lowercase().starts_with(prefix) {
            value = value[prefix.len()..]
                .trim_start_matches(|c: char| c.is_whitespace() || "，、,：:!！~～".contains(c))
                .to_owned();
            break;
        }
    }
    for token in [
        "Apple Music",
        "apple music",
        "AppleMusic",
        "applemusic",
        "apple 音樂",
        "apple 音乐",
        "蘋果音樂",
        "苹果音乐",
        "アップルミュージック",
        "애플 뮤직",
        "애플뮤직",
        "Spotify",
        "spotify",
        "スポティファイ",
        "스포티파이",
        "YouTube",
        "youtube",
        "you tube",
        "油管",
        "ユーチューブ",
        "유튜브",
    ] {
        for prefix in [
            "on ", "in ", "with ", "from ", "using ", "via ", "用", "在", "喺", "去", "到",
        ] {
            value = value.replace(format!("{prefix}{token}").as_str(), " ");
        }
        for suffix in [
            "上面", "入面", "裡面", "里面", "에서", "으로", "で", "から", "의",
        ] {
            value = value.replace(format!("{token}{suffix}").as_str(), " ");
        }
        value = value.replace(token, " ");
    }
    value = value.trim().to_owned();
    for prefix in [
        "好啊，",
        "好呀，",
        "好的，",
        "好，",
        "okay, ",
        "ok, ",
        "yes, ",
        "嗯，",
        "うん、",
        "좋아, ",
    ] {
        if value.to_lowercase().starts_with(prefix) {
            value = value[prefix.len()..].trim().into();
            break;
        }
    }
    for prefix in [
        "請",
        "请",
        "麻煩你",
        "麻烦你",
        "麻煩",
        "麻烦",
        "幫我",
        "帮我",
        "幫",
        "帮",
        "替我",
        "同我",
        "你",
        "妳",
        "可以",
        "能不能",
        "可不可以",
        "能",
        "給我",
        "给我",
        "我要",
        "我想",
        "就",
        "先",
        "再",
        "please ",
        "can you ",
        "could you ",
        "would you ",
        "will you ",
        "hey ",
    ] {
        while value.to_lowercase().starts_with(prefix) {
            value = value[prefix.len()..].trim().into();
        }
    }
    let mut command: Option<(String, bool)> = None;
    for (prefix, strong) in [
        ("播放", true),
        ("播", true),
        ("play ", true),
        ("put on ", true),
        ("打開", false),
        ("打开", false),
        ("放", false),
        ("開", false),
        ("點", false),
        ("点", false),
        ("來", false),
        ("来", false),
        ("聽", false),
        ("听", false),
        ("open ", false),
        ("listen to ", false),
        ("i want to hear ", false),
        ("i'd like to hear ", false),
    ] {
        if value.to_lowercase().starts_with(prefix) {
            command = Some((value[prefix.len()..].to_owned(), strong));
            break;
        }
    }
    if command.is_none() {
        for (suffix, strong) in [
            ("流してください", true),
            ("再生してください", true),
            ("流して", true),
            ("再生して", true),
            ("かけて", true),
            ("聴かせて", true),
            ("聞かせて", true),
            ("流そう", true),
            ("再生", true),
            ("開いて", false),
            ("聴きたい", false),
            ("聞きたい", false),
            ("틀어 줘", true),
            ("틀어줘", true),
            ("틀어 주세요", true),
            ("틀어주세요", true),
            ("틀어 줄래", true),
            ("틀어줄래", true),
            ("재생해", true),
            ("들려줘", true),
            ("들려", true),
            ("틀어", true),
            ("열어 줘", false),
            ("열어줘", false),
            ("열어", false),
            ("듣고 싶어", false),
            ("듣고 싶어요", false),
        ] {
            let stripped =
                value.trim_end_matches(|c: char| c.is_whitespace() || "?？!！。〜～".contains(c));
            if let Some(query) = stripped.strip_suffix(suffix) {
                command = Some((query.trim_end_matches(['을', '를', 'を']).into(), strong));
                break;
            }
        }
    }
    let direct_command = command.is_some();
    let (raw, strong) = if let Some(command) = command {
        command
    } else if previous.map(asks_what_to_play).unwrap_or(false) && !value.contains(['?', '？']) {
        (value.clone(), true)
    } else {
        return None;
    };
    let mut query = raw.trim().to_owned();
    for _ in 0..2 {
        query = query
            .trim_matches(|c: char| {
                c.is_whitespace() || "《》「」『』\"'“”‘’〈〉【】，、。.!！?？~～♪".contains(c)
            })
            .into();
        for prefix in [
            "一首",
            "首歌",
            "一下",
            "首",
            "下",
            "些",
            "the song ",
            "a song ",
            "song ",
            "on ",
            "in ",
            "with ",
            "using ",
            "用",
            "在",
            "喺",
        ] {
            if let Some(rest) = query.strip_prefix(prefix) {
                query = rest.trim().into();
            }
        }
        for suffix in [
            "for me",
            "please",
            "好不好",
            "好嗎",
            "好吗",
            "得唔得",
            "一下",
            "來聽",
            "来听",
            "聽聽",
            "听听",
            "給我聽",
            "给我听",
            "俾我聽",
            "這首歌",
            "这首歌",
            "呢首歌",
            "首歌",
            "的歌",
            "嘅歌",
            "歌曲",
            "這首",
            "这首",
            "呢首",
            "的曲",
            "の曲",
            "吧",
            "啦",
            "喇",
            "呀",
            "啊",
            "呢",
            "喔",
            "哦",
            "嘛",
            "嗎",
            "吗",
            "ください",
            "して",
        ] {
            if let Some(rest) = query.strip_suffix(suffix) {
                query = rest.trim().into();
            }
        }
    }
    if query.is_empty() {
        return platform.map(|p| json!({"query":referenced.unwrap_or_default(),"platform":p}));
    }
    let pointer = [
        "它",
        "佢",
        "牠",
        "這首",
        "这首",
        "呢首",
        "那首",
        "嗰首",
        "這個",
        "这个",
        "呢個",
        "那個",
        "那个",
        "這首歌",
        "那首歌",
        "this",
        "that",
        "it",
        "this one",
        "that one",
        "this song",
        "that song",
        "それ",
        "これ",
        "その曲",
        "この曲",
        "그거",
        "이거",
        "그 곡",
        "이 곡",
        "그 노래",
        "이 노래",
    ];
    if pointer.contains(&query.to_lowercase().as_str()) {
        return referenced.map(|title| json!({"query":title,"platform":platform}));
    }
    let query_lower = query.to_lowercase();
    if query.chars().count() > 100
        || contains_any(
            &query_lower,
            &[
                "game",
                "with me",
                "together",
                "遊戲",
                "游戏",
                "ゲーム",
                "게임",
                "이야기",
                "얘기",
                "동화",
                "가위바위보",
                "猜拳",
                "包剪揼",
                "じゃんけん",
            ],
        )
    {
        return None;
    }
    if !direct_command
        && previous.map(asks_what_to_play).unwrap_or(false)
        && (query.chars().count() > 60
            || affirmative.contains(&query_lower.as_str())
            || ["no", "아니"].contains(&query_lower.as_str())
            || contains_any(
                &query_lower,
                &[
                    "隨便",
                    "随便",
                    "都可以",
                    "都得",
                    "是但",
                    "你推薦",
                    "你推荐",
                    "你揀",
                    "你拣",
                    "你決定",
                    "你决定",
                    "你選",
                    "你选",
                    "不知道",
                    "唔知",
                    "whatever",
                    "anything",
                    "you choose",
                    "you pick",
                    "なんでも",
                    "任せる",
                    "まかせる",
                    "わからない",
                    "아무거나",
                    "상관없어",
                    "모르겠어",
                    "추천해",
                    "골라줘",
                    "你看看",
                    "看看",
                    "你看",
                    "你猜",
                    "猜猜",
                    "猜猜看",
                    "你說呢",
                    "你说呢",
                    "你覺得呢",
                    "你觉得呢",
                    "你自己看",
                    "你睇下",
                    "你估",
                    "guess",
                    "you guess",
                    "you tell me",
                    "take a look",
                    "look",
                    "当てて",
                    "当ててみて",
                    "見て",
                    "みて",
                    "맞혀봐",
                    "봐봐",
                ],
            ))
    {
        return None;
    }
    let quoted = contains_any(&raw, &["《", "「", "『", "\"", "“"]);
    if !strong
        && platform.is_none()
        && !quoted
        && !known_titles
            .iter()
            .any(|title| !title.is_empty() && query_lower.contains(title.to_lowercase().as_str()))
    {
        return None;
    }
    Some(json!({"query":query,"platform":platform}))
}

fn last_song_title(text: &str, known: &[String]) -> Option<String> {
    for (open, close) in [('《', '》'), ('〈', '〉')] {
        if let Some((_, tail)) = text.rsplit_once(open) {
            if let Some((title, _)) = tail.split_once(close) {
                if (1..=60).contains(&title.chars().count()) {
                    return Some(title.trim().into());
                }
            }
        }
    }
    let lower = text.to_lowercase();
    for (open, close) in [('「', '」'), ('“', '”'), ('"', '"')] {
        for (index, _) in text.match_indices(open).rev() {
            let tail = &text[index + open.len_utf8()..];
            if let Some((title, after)) = tail.split_once(close) {
                let before = &text[..index];
                if (1..=60).contains(&title.chars().count())
                    && (contains_any(
                        &before.to_lowercase(),
                        &[
                            "搜尋",
                            "搜索",
                            "搜",
                            "聽",
                            "听",
                            "播放",
                            "播",
                            "推薦",
                            "推荐",
                            "歌曲",
                            "首歌",
                            "search for",
                            "play",
                            "listen to",
                            "検索",
                            "聴いて",
                            "노래",
                            "곡",
                            "추천",
                            "재생",
                            "검색",
                        ],
                    ) || contains_any(
                        after,
                        &["추천", "들어 볼", "들어볼", "틀어 줄", "재생", "검색"],
                    ))
                {
                    return Some(title.trim().into());
                }
            }
        }
    }
    if let Some((_, title)) = known
        .iter()
        .filter(|title| !title.is_empty())
        .filter_map(|title| {
            lower
                .rfind(title.to_lowercase().as_str())
                .map(|i| (i, title))
        })
        .max_by_key(|(i, _)| *i)
    {
        return Some(title.clone());
    }
    text.rsplit_once('『')
        .and_then(|(_, tail)| tail.split_once('』'))
        .map(|(title, _)| title.trim().to_owned())
        .filter(|title| !title.is_empty() && title.chars().count() <= 60)
}

fn offers_to_play(text: &str) -> bool {
    contains_any(
        &text.to_lowercase(),
        &[
            "要不要聽",
            "要不要听",
            "要聽嗎",
            "要听吗",
            "要唔要",
            "聽唔聽",
            "想聽嗎",
            "想听吗",
            "聽聽看",
            "听听看",
            "播給你",
            "放給你",
            "推薦你聽",
            "推荐你听",
            "want to try",
            "want to listen",
            "want to hear",
            "shall i play",
            "shall i put",
            "should i play",
            "give it a try",
            "give it a listen",
            "聴いてみる",
            "聴いてみない",
            "かけようか",
            "流そうか",
            "들어 볼래",
            "들어 볼까",
            "들어볼래",
            "들어볼까",
            "틀어 줄까",
            "재생해 줄까",
        ],
    )
}

fn asks_what_to_play(text: &str) -> bool {
    contains_any(
        &text.to_lowercase(),
        &[
            "想聽哪",
            "想听哪",
            "聽哪",
            "听哪",
            "想聽甚麼",
            "想聽什麼",
            "想听什么",
            "聽甚麼歌",
            "聽什麼歌",
            "听什么歌",
            "聽咩",
            "聽邊首",
            "哪一首",
            "點歌",
            "点歌",
            "what song",
            "what would you like to hear",
            "what would you like to listen",
            "which song",
            "what should i play",
            "what should we play",
            "何を聴",
            "何聴",
            "どの曲",
            "何の曲",
            "リクエスト",
            "어떤 노래",
            "어떤 곡",
            "무슨 노래",
            "무슨 곡",
            "뭐 들",
            "뭘 들",
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn games_are_requested_in_five_languages_and_refusals_win() {
        for (text, game) in [
            ("嚟玩包剪揼！", "rps"),
            ("じゃんけんしよう", "rps"),
            ("Let's do a quiz", "quiz"),
            ("玩打拍子", "rhythm"),
            ("가위바위보 하자", "rps"),
        ] {
            assert_eq!(requested_game(text), Some(game));
        }
        for text in ["我唔想玩包剪揼", "퀴즈 안 하고 싶어", "今日好攰"] {
            assert_eq!(requested_game(text), None);
        }
    }

    #[test]
    fn rps_draw_does_not_advance_and_first_two_wins_end_the_match() {
        let mut state = json!({"mine":0,"yours":0,"isOver":false});
        rps_choose(&mut state, "paper", "rock", "zh-Hant");
        let draw = rps_choose(&mut state, "rock", "rock", "zh-Hant");
        assert_eq!(draw[0]["rps"]["outcome"], "draw");
        assert_eq!(state["yours"], 1);
        let end = rps_choose(&mut state, "paper", "rock", "zh-Hant");
        assert_eq!(state["isOver"], true);
        assert_eq!(end.len(), 2);
        assert_eq!(end[0]["choices"], json!([]));
    }

    #[test]
    fn quiz_has_distinct_options_and_no_second_correct_answer() {
        let mut state = json!({});
        game_action(&mut state, "start", &json!({"game":"quiz","language":"ko"})).unwrap();
        let mut titles = std::collections::HashSet::new();
        for round in 0..5 {
            let question = state["current"]["question"].clone();
            let options = question["options"].as_array().unwrap();
            assert_eq!(options.len(), 4);
            assert_eq!(
                options
                    .iter()
                    .map(|v| v.as_str().unwrap())
                    .collect::<std::collections::HashSet<_>>()
                    .len(),
                4
            );
            assert!(titles.insert(question["title"].as_str().unwrap().to_owned()));
            let answer = question["answer"].as_u64().unwrap() as usize;
            assert!(
                options[answer] == question["title"] || options[answer] == question["producer"]
            );
            if options[answer] == question["title"] {
                for (i, option) in options.iter().enumerate() {
                    if i != answer {
                        assert_ne!(
                            QUIZ_SONGS
                                .iter()
                                .find(|song| Some(song.0) == option.as_str())
                                .unwrap()
                                .1,
                            question["producer"].as_str().unwrap()
                        );
                    }
                }
            }
            game_action(&mut state, "choose", &json!({"choice":answer})).unwrap();
            assert_eq!(state["current"]["isOver"], round == 4);
        }
        assert_eq!(state["current"]["score"], 5);
    }

    #[test]
    fn rhythm_thresholds_and_score_match_mac() {
        assert_eq!(rhythm_grade(0.03), "perfect");
        assert_eq!(rhythm_grade(-0.1), "good");
        assert_eq!(rhythm_grade(0.3), "miss");
        assert_eq!(rhythm_score(&["perfect"; 16]), 100);
        assert_eq!(rhythm_score(&["good"; 16]), 50);
        assert_eq!(rhythm_score(&[]), 0);
    }

    #[test]
    fn bedtime_negation_translation_and_korean_quotations_are_not_farewells() {
        for text in [
            "我不想去睡",
            "晚安英文怎麼說？",
            "How do you say good night in Japanese?",
            "What does good night mean?",
            "잘 자라는 노래 알아?",
            "잠이 안 와, 잘 자",
            "자러 가지 마",
            "자러 가기 싫어",
            "일찍 자지 않을 거야",
            "자러 가는 건 아니야",
        ] {
            assert_eq!(sleep_intent(text), None, "{text}");
        }
        for text in [
            "晚安",
            "你還不上床睡覺嗎",
            "I'm off to bed",
            "もう寝ます",
            "잘 자, 미쿠",
            "이제 자러 갈게",
            "Why don't you go to bed?",
        ] {
            assert_eq!(sleep_intent(text), Some("goodNight"), "{text}");
        }
    }

    #[test]
    fn wake_override_survives_schedule_and_expires() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 10, 2, 0, 0)
            .single()
            .unwrap();
        assert_eq!(sleep_status(&json!({}), now, None)["asleep"], true);
        let settings = sleep_override("wake", now, 20.0);
        assert_eq!(sleep_status(&settings, now, None)["asleep"], false);
        assert_eq!(
            sleep_status(&settings, now + Duration::minutes(21), None)["asleep"],
            true
        );
        assert_eq!(
            sleep_override("goodMorning", now, 20.0)["sleep.override.until"],
            json!(Local
                .with_ymd_and_hms(2026, 11, 11, 1, 0, 0)
                .single()
                .unwrap()
                .timestamp())
        );
    }

    #[test]
    fn configured_sleep_hours_and_disable_keep_explicit_override() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 10, 23, 45, 0)
            .single()
            .unwrap();
        let settings = json!({"quietStart":"23:30","quietEnd":"06:15"});
        assert_eq!(sleep_status(&settings, now, None)["asleep"], true);
        assert_eq!(
            sleep_status(&json!({"sleepStartHour":1,"quietStart":"23:30"}), now, None)["asleep"],
            false
        );
        assert_eq!(
            sleep_status(&json!({"sleepEnabled":false}), now, None)["asleep"],
            false
        );
        let mut override_settings = sleep_override("goodNight", now, 20.0);
        override_settings["sleepScheduleEnabled"] = json!(false);
        assert_eq!(sleep_status(&override_settings, now, None)["asleep"], true);
        assert_eq!(
            sleep_status(
                &json!({"sleepOverrideKind":"sleep","sleepOverrideUntil":now.timestamp()+60,"sleepEnabled":false}),
                now,
                None
            )["asleep"],
            true
        );
    }

    #[test]
    fn anniversary_february_and_year_boundary_are_calendar_based() {
        let now = Local
            .with_ymd_and_hms(2027, 2, 28, 12, 0, 0)
            .single()
            .unwrap();
        assert!(
            special_days(now, &json!({"firstMet":"2024-02-29"}))["today"]
                .as_array()
                .unwrap()
                .iter()
                .any(|day| day["key"] == "anniversary" && day["years"] == 3)
        );
        let december = Local
            .with_ymd_and_hms(2026, 12, 31, 12, 0, 0)
            .single()
            .unwrap();
        assert!(special_days(december, &json!({}))["upcoming"]
            .as_array()
            .unwrap()
            .iter()
            .any(|day| day["key"] == "newYear" && day["start"] == "2027-01-01"));
    }

    #[test]
    fn unknown_event_dates_are_not_invented() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 10, 12, 0, 0)
            .single()
            .unwrap();
        let dates = special_days(
            now,
            &json!({"events":[{"kind":"magicalMirai","year":2027,"start":"2027-08-01","end":"2027-08-03","source":"https://attacker.test/"}]}),
        );
        assert_eq!(dates["unknown"].as_array().unwrap().len(), 4);
        assert!(dates["known"].as_array().unwrap().is_empty());
    }

    #[test]
    fn event_queries_keep_requested_year_and_do_not_substitute_future_runs() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 10, 12, 0, 0)
            .single()
            .unwrap();
        let events = vec![
            json!({"kind":"magicalMirai","year":2026,"start":"2026-08-01","end":"2026-08-03"}),
            json!({"kind":"magicalMirai","year":2027,"start":"2027-08-01","end":"2027-08-03"}),
        ];
        let result = event_query("魔法未來 2026", &events, now).unwrap();
        assert_eq!(result["events"].as_array().unwrap().len(), 1);
        assert_eq!(result["events"][0]["year"], 2026);
        assert_eq!(result["events"][0]["status"], "ended");
        let missing = event_query("魔法未來 ２０２８", &events, now).unwrap();
        assert!(missing["events"].as_array().unwrap().is_empty());
        assert_eq!(missing["unknownKinds"], json!(["magicalMirai"]));
        assert!(event_query("anything else", &events, now).is_none());
    }

    #[test]
    fn proactive_quiet_and_unanswered_rules_take_priority() {
        let settings = json!({"awareness.random":true});
        assert!(!proactive_allowed(
            &settings,
            &json!({"fullscreen":true}),
            false,
            Some(0),
            1800
        ));
        assert!(!proactive_allowed(
            &settings,
            &json!({"unanswered":2}),
            false,
            Some(0),
            9999
        ));
        assert!(!proactive_allowed(
            &settings,
            &json!({}),
            true,
            Some(0),
            9999
        ));
        assert!(!proactive_allowed(
            &settings,
            &json!({"urgent":true,"unanswered":1}),
            false,
            Some(0),
            180
        ));
        assert!(proactive_allowed(
            &settings,
            &json!({"urgent":true}),
            false,
            Some(0),
            180
        ));
        assert!(is_repeat(
            "回來啦？剛剛去哪裡了呀？",
            &["回來啦，剛剛去哪裡了呀！".into()]
        ));
    }

    #[test]
    fn music_requires_a_real_request_and_resolves_confirmed_titles() {
        assert!(music_request("不要播放千本桜").is_none());
        assert!(music_request("play a game with me").is_none());
        let request = music_request("play Tell Your World on Spotify").unwrap();
        assert_eq!(request["platform"], "spotify");
        assert_eq!(request["query"], "Tell Your World");
        assert_eq!(
            music_request_with_context("好啊", Some("要不要聽《千本桜》？"), &[], &[]).unwrap()
                ["query"],
            "千本桜"
        );
        assert!(music_request_with_context("你看看！？", Some("想聽哪一首？"), &[], &[]).is_none());
        assert!(music_request_with_context("好", Some("想聽哪一首？"), &[], &[]).is_none());
        assert_eq!(music_request("打開 Spotify").unwrap()["query"], "");
    }
}
