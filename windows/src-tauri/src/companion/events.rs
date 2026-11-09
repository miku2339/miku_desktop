//! Official event pages and the Mac-compatible three-day `events.json` cache.

use std::collections::{BTreeMap, HashSet};
use std::future::Future;
use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Datelike, Local, NaiveDate};
use regex::Regex;
use reqwest::Url;
use serde_json::{json, Value};
use unicode_normalization::UnicodeNormalization;

use super::storage;

const MAX_HTML_BYTES: usize = 2_000_000;
const REFRESH_SECONDS: i64 = 3 * 24 * 3600;
const EXPO_INDEX: &str = "https://mikuexpo.com/";
const WITH_YOU_INDEX: &str = "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/82/ip/16.html";
const WITH_YOU_2026: &str = "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/4728/ip/16.html";

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("static event parser expression")
}

pub fn plain_text(html: &str) -> String {
    let mut text = html.to_owned();
    for pattern in [
        r"(?is)<script\b.*?</script\s*>",
        r"(?is)<style\b.*?</style\s*>",
        r"(?s)<!--.*?-->",
    ] {
        text = regex(pattern).replace_all(&text, " ").into_owned();
    }
    text = regex(r"(?i)<br\s*/?>|</(?:p|div|li|h[1-6]|dt|dd|tr|section|table)\s*>")
        .replace_all(&text, "\n")
        .into_owned();
    text = regex(r"<[^>]+>").replace_all(&text, " ").into_owned();
    for (entity, value) in [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&#12316;", "〜"),
        ("&#65374;", "～"),
    ] {
        text = text.replace(entity, value);
    }
    text = regex(r"&#(?:x[0-9a-fA-F]+|[0-9]+);")
        .replace_all(&text, " ")
        .into_owned();
    let text: String = text.nfkc().collect();
    regex(r"[ \t\u{3000}]+")
        .replace_all(&text, " ")
        .into_owned()
}

fn clean_field(html: &str) -> String {
    plain_text(html)
        .replace("arrow_forward_ios", "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(160)
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FoundRange {
    pub start: NaiveDate,
    pub end: NaiveDate,
    pub before: String,
    pub after: String,
}

fn suffix(text: &str, length: usize) -> String {
    text.chars()
        .rev()
        .take(length)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}

pub fn date_ranges(text: &str, page_year: i32) -> Vec<FoundRange> {
    let ymd = r"(?:(20\d{2})\s*[年./]\s*)?(\d{1,2})\s*[月./]\s*(\d{1,2})\s*日?";
    let weekday = r"(?:\s*[(][^()\n]{1,8}[)])?";
    let dash = r"\s*[~〜\-–—―ー－]\s*";
    let end = r"(?:(20\d{2})\s*[年./]\s*)?(?:(\d{1,2})\s*[月./]\s*)?(\d{1,2})\s*日?";
    let expression = regex(&format!("{ymd}{weekday}{dash}{end}{weekday}"));
    expression
        .captures_iter(text)
        .filter_map(|capture| {
            let int = |index| {
                capture
                    .get(index)
                    .and_then(|m| m.as_str().parse::<u32>().ok())
            };
            let start_year = int(1).map(|year| year as i32).unwrap_or(page_year);
            let start_month = int(2)?;
            let end_month = int(5).unwrap_or(start_month);
            let end_year = int(4)
                .map(|year| year as i32)
                .unwrap_or(start_year + i32::from(end_month < start_month));
            let start = NaiveDate::from_ymd_opt(start_year, start_month, int(3)?)?;
            let end = NaiveDate::from_ymd_opt(end_year, end_month, int(6)?)?;
            let days = (end - start).num_days();
            if !(1..=60).contains(&days) {
                return None;
            }
            let whole = capture.get(0)?;
            Some(FoundRange {
                start,
                end,
                before: suffix(&text[..whole.start()], 120),
                after: text[whole.end()..].chars().take(60).collect(),
            })
        })
        .collect()
}

fn ticket_dates(before: &str) -> bool {
    let near = suffix(before, 40);
    [
        "受付",
        "販売",
        "抽選",
        "応募",
        "申込",
        "申し込み",
        "締切",
        "配信",
        "発売",
        "予約",
        "募集",
        "エントリー",
        "投稿",
    ]
    .iter()
    .any(|word| near.contains(*word))
}

const PLACES: &[(&str, &str, Option<&str>)] = &[
    ("アクトシティ浜松", "hamamatsu", Some("アクトシティ浜松")),
    ("浜松", "hamamatsu", None),
    ("HAMAMATSU", "hamamatsu", None),
    ("インテックス大阪", "osaka", Some("インテックス大阪")),
    ("大阪", "osaka", None),
    ("OSAKA", "osaka", None),
    ("幕張メッセ", "tokyo", Some("幕張メッセ")),
    ("幕張", "tokyo", None),
    ("東京", "tokyo", None),
    ("TOKYO", "tokyo", None),
    ("仙台", "sendai", None),
    ("SENDAI", "sendai", None),
    ("札幌", "sapporo", None),
    ("SAPPORO", "sapporo", None),
    ("名古屋", "nagoya", None),
    ("NAGOYA", "nagoya", None),
    ("福岡", "fukuoka", None),
    ("FUKUOKA", "fukuoka", None),
    ("横浜", "yokohama", None),
    ("YOKOHAMA", "yokohama", None),
];

pub fn place(before: &str, after: &str) -> Option<(String, Option<String>)> {
    let before_upper = before.to_uppercase();
    let after_upper = after.to_uppercase();
    let mut best: Option<(usize, &str)> = None;
    for &(word, city, _) in PLACES {
        let word = word.to_uppercase();
        if let Some(index) = before_upper.rfind(word.as_str()) {
            let distance = before_upper[index + word.len()..].chars().count();
            if best.map(|best| distance < best.0).unwrap_or(true) {
                best = Some((distance, city));
            }
        }
        if let Some(index) = after_upper.find(word.as_str()) {
            let distance = after_upper[..index].chars().count() + 10;
            if best.map(|best| distance < best.0).unwrap_or(true) {
                best = Some((distance, city));
            }
        }
    }
    let city = best?.1;
    let nearby = suffix(before, 80) + after;
    let venue = PLACES
        .iter()
        .find(|&&(word, entry_city, venue)| {
            entry_city == city && venue.is_some() && nearby.contains(word)
        })
        .and_then(|entry| entry.2)
        .map(str::to_owned);
    Some((city.to_owned(), venue))
}

fn event(
    kind: &str,
    year: i32,
    city: Option<&str>,
    venue: Option<&str>,
    start: NaiveDate,
    end: NaiveDate,
    source: &str,
) -> Value {
    let mut event = json!({"kind":kind,"year":year,"start":start.to_string(),"end":end.to_string(),"source":source});
    if let Some(city) = city {
        event["city"] = json!(city);
    }
    if let Some(venue) = venue {
        event["venue"] = json!(venue);
    }
    event
}

pub fn magical_mirai(html: &str, year: i32, source: &str) -> Vec<Value> {
    let mut events: Vec<Value> = Vec::new();
    for found in date_ranges(&plain_text(html), year) {
        if found.start.year() != year
            || !(5..=11).contains(&found.start.month())
            || !(1..=4).contains(&(found.end - found.start).num_days())
            || ticket_dates(&found.before)
        {
            continue;
        }
        let Some((city, venue)) = place(&found.before, &found.after) else {
            continue;
        };
        let value = event(
            "magicalMirai",
            year,
            Some(&city),
            venue.as_deref(),
            found.start,
            found.end,
            source,
        );
        if let Some(old) = events
            .iter_mut()
            .find(|old| old["start"] == value["start"] && old["end"] == value["end"])
        {
            if old["venue"].is_null() && !value["venue"].is_null() && old["city"] == value["city"] {
                old["venue"] = value["venue"].clone();
            }
        } else if !events.iter().any(|old| old["city"] == value["city"]) {
            events.push(value);
        }
    }
    events.sort_by(|a, b| a["start"].as_str().cmp(&b["start"].as_str()));
    events
}

pub fn snow_miku(html: &str, year: i32, source: &str) -> Option<Value> {
    let candidates: Vec<_> = date_ranges(&plain_text(html), year)
        .into_iter()
        .filter(|found| {
            found.start.year() == year
                && ((found.start.month() == 1 && found.start.day() >= 15)
                    || found.start.month() == 2)
                && found.end.year() == year
                && found.end.month() <= 3
                && !ticket_dates(&found.before)
        })
        .collect();
    let preference = |found: &FoundRange| {
        let context = suffix(&found.before, 120).to_uppercase();
        let line = context.rsplit('\n').next().unwrap_or(&context);
        if line.contains("SNOW MIKU") || line.contains("雪ミク") {
            3
        } else if line.contains("雪まつり") {
            0
        } else if context.contains("SNOW MIKU") || context.contains("雪ミク") {
            2
        } else if ["開催", "会期", "期間"]
            .iter()
            .any(|word| line.contains(*word))
        {
            1
        } else {
            0
        }
    };
    let highest = candidates.iter().map(preference).max().unwrap_or(0);
    let best = candidates
        .iter()
        .filter(|found| highest == 0 || preference(found) == highest)
        .min_by_key(|found| found.start)?;
    Some(event(
        "snowMiku",
        year,
        Some("sapporo"),
        None,
        best.start,
        best.end,
        source,
    ))
}

struct Element<'a> {
    name: String,
    attrs: &'a str,
    inner: &'a str,
    position: usize,
}
struct OpenElement<'a> {
    name: String,
    attrs: &'a str,
    start: usize,
    position: usize,
}

// Matching a tag stack also handles nested divs; Rust regex has no HTML backreferences.
fn elements(html: &str) -> Vec<Element<'_>> {
    let tags = regex(r"(?is)<\s*(/?)\s*([a-z][a-z0-9]*)\b([^>]*)>");
    let mut stack: Vec<OpenElement<'_>> = Vec::new();
    let mut result = Vec::new();
    for capture in tags.captures_iter(html) {
        let whole = capture.get(0).unwrap();
        let name = capture[2].to_lowercase();
        if &capture[1] == "/" {
            if let Some(index) = stack.iter().rposition(|entry| entry.name == name) {
                let open = stack.remove(index);
                stack.truncate(index);
                result.push(Element {
                    name,
                    attrs: open.attrs,
                    inner: &html[open.start..whole.start()],
                    position: open.position,
                });
            }
        } else if !capture[3].trim_end().ends_with('/')
            && ![
                "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                "param", "source", "track", "wbr",
            ]
            .contains(&name.as_str())
        {
            stack.push(OpenElement {
                name,
                attrs: capture.get(3).unwrap().as_str(),
                start: whole.end(),
                position: whole.start(),
            });
        }
    }
    result.sort_by_key(|entry| entry.position);
    result
}

fn attribute<'a>(attrs: &'a str, name: &str) -> Option<&'a str> {
    regex(&format!(
        r#"(?i)(?:^|\s){}\s*=\s*["']([^"']*)["']"#,
        regex::escape(name)
    ))
    .captures(attrs)?
    .get(1)
    .map(|m| m.as_str())
}

fn class_contents<'a>(name: &str, html: &'a str) -> Vec<&'a str> {
    elements(html)
        .into_iter()
        .filter(|entry| {
            attribute(entry.attrs, "class")
                .map(|classes| classes.split_whitespace().any(|class| class == name))
                .unwrap_or(false)
        })
        .map(|entry| entry.inner)
        .collect()
}

fn tag_contents<'a>(name: &str, html: &'a str) -> Vec<&'a str> {
    elements(html)
        .into_iter()
        .filter(|entry| entry.name == name)
        .map(|entry| entry.inner)
        .collect()
}

pub fn miku_expo(html: &str, year: i32, source: &str) -> Vec<Value> {
    let months = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ];
    let dates = regex(
        r"(?i)\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:st|nd|rd|th)?\b",
    );
    let mut result = Vec::new();
    for list in class_contents("concert_list", html) {
        for item in tag_contents("li", list) {
            let Some(city_html) = class_contents("city_txt", item).first().copied() else {
                continue;
            };
            let city = clean_field(city_html);
            let venue = class_contents("venue_txt", item)
                .first()
                .map(|html| clean_field(html))
                .or_else(|| {
                    class_contents("venue", item).first().and_then(|html| {
                        tag_contents("p", html)
                            .into_iter()
                            .map(clean_field)
                            .find(|text| !text.is_empty() && text.to_uppercase() != "VENUE")
                    })
                });
            let Some(venue) = venue.filter(|venue| !venue.is_empty()) else {
                continue;
            };
            if city.is_empty() {
                continue;
            }
            let mut blocks = class_contents("date_txt", item);
            for block in class_contents("concert_list_datetime", item) {
                if let Some(paragraph) = tag_contents("p", block).first().copied() {
                    blocks.push(paragraph);
                }
            }
            for block in blocks {
                let date = clean_field(block).to_lowercase();
                for capture in dates.captures_iter(&date) {
                    let Some(month) = months
                        .iter()
                        .position(|month| *month == &capture[1])
                        .map(|month| month as u32 + 1)
                    else {
                        continue;
                    };
                    let Some(day) = capture[2]
                        .parse::<u32>()
                        .ok()
                        .and_then(|day| NaiveDate::from_ymd_opt(year, month, day))
                    else {
                        continue;
                    };
                    let value = event(
                        "mikuExpo",
                        year,
                        Some(&city),
                        Some(&venue),
                        day,
                        day,
                        source,
                    );
                    if !result.contains(&value) {
                        result.push(value);
                    }
                }
            }
        }
    }
    result.sort_by(|a, b| {
        a["start"]
            .as_str()
            .cmp(&b["start"].as_str())
            .then(a["city"].as_str().cmp(&b["city"].as_str()))
    });
    result
}

pub fn miku_with_you(html: &str, year: i32, source: &str) -> Vec<Value> {
    let text = plain_text(html);
    if !(text.contains("未来有你") || text.contains("未來有你"))
        || !text.contains(year.to_string().as_str())
    {
        return vec![];
    }
    let blocks = regex(
        r"(?:^|\n)\s*(?:时间|時間)\s*[:：]\s*([^\n]{1,120})(?:\n|\s)*(?:地点|地點)\s*[:：]\s*([^\n]{1,160})",
    );
    let single = regex(r"^(?:(20\d{2})年)?(\d{1,2})月(\d{1,2})日");
    let mut result = Vec::new();
    for capture in blocks.captures_iter(&text) {
        let time = capture[1].trim();
        let venue = clean_field(&capture[2]);
        if venue.is_empty() {
            continue;
        }
        let ranges = date_ranges(time, year);
        let mut dates: Vec<_> = ranges
            .iter()
            .filter(|found| found.start.year() == year)
            .map(|found| (found.start, found.end))
            .collect();
        if ranges.is_empty() && !regex(r"[~〜–—-]").is_match(time) {
            if let Some(capture) = single.captures(time) {
                let stated_year = capture
                    .get(1)
                    .and_then(|m| m.as_str().parse::<i32>().ok())
                    .unwrap_or(year);
                if stated_year == year {
                    if let (Ok(month), Ok(day)) =
                        (capture[2].parse::<u32>(), capture[3].parse::<u32>())
                    {
                        if let Some(date) = NaiveDate::from_ymd_opt(year, month, day) {
                            dates.push((date, date));
                        }
                    }
                }
            }
        }
        let city = [
            ("上海", "shanghai"),
            ("北京", "beijing"),
            ("广州", "guangzhou"),
            ("廣州", "guangzhou"),
            ("成都", "chengdu"),
        ]
        .iter()
        .find(|(word, _)| venue.contains(*word))
        .map(|(_, city)| *city);
        for (start, end) in dates {
            let value = event("mikuWithYou", year, city, Some(&venue), start, end, source);
            if !result.contains(&value) {
                result.push(value);
            }
        }
    }
    result.sort_by(|a, b| a["start"].as_str().cmp(&b["start"].as_str()));
    result
}

pub fn is_official_url(url: &Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(
            url.host_str(),
            Some(
                "magicalmirai.com"
                    | "snowmiku.com"
                    | "mikuexpo.com"
                    | "www.scla.com.cn"
                    | "scla.com.cn"
            )
        )
}

pub fn event_pages(html: &str, kind: &str, base: &Url, years: &[i32]) -> Vec<(i32, Url)> {
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for link in elements(html).into_iter().filter(|entry| entry.name == "a") {
        let Some(href) = attribute(link.attrs, "href") else {
            continue;
        };
        let Ok(url) = base.join(href) else {
            continue;
        };
        if !is_official_url(&url) || url.host_str() != base.host_str() {
            continue;
        }
        let title = clean_field(link.inner);
        let year = if kind == "mikuExpo" && url.host_str() == Some("mikuexpo.com") {
            regex(r"(?i)^/[a-z][a-z0-9-]*(20\d{2})/?$")
                .captures(url.path())
                .and_then(|c| c[1].parse::<i32>().ok())
        } else if kind == "mikuWithYou"
            && matches!(url.host_str(), Some("www.scla.com.cn" | "scla.com.cn"))
            && regex(r"^/Cn/Index/pageView/catid/\d+/id/\d+/ip/\d+\.html$").is_match(url.path())
            && (title.contains("未来有你") || title.contains("未來有你"))
            && ["官宣", "演唱会", "演唱會"]
                .iter()
                .any(|word| title.contains(*word))
        {
            regex(r"(20\d{2})")
                .captures(&title)
                .and_then(|c| c[1].parse::<i32>().ok())
        } else {
            None
        };
        if let Some(year) = year.filter(|year| years.contains(year)) {
            if seen.insert(url.as_str().to_owned()) {
                result.push((year, url));
            }
        }
        if result.len() >= if kind == "mikuExpo" { 6 } else { 3 } {
            break;
        }
    }
    result
}

fn load(directory: &Path) -> Result<Value, String> {
    let path = directory.join("events.json");
    if !path.exists() {
        return Ok(json!({"checked":null,"events":[],"lastResult":{}}));
    }
    if std::fs::metadata(&path)
        .map_err(|_| "The event cache could not be read.")?
        .len()
        > 4_000_000
    {
        return Err("The event cache is too large; the original file was preserved.".into());
    }
    let bytes = std::fs::read(&path).map_err(|_| "The event cache could not be read.")?;
    let mut value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "The event cache is damaged; the original file was preserved.")?;
    if !value["events"].is_array() {
        return Err("The event cache has no events list; the original file was preserved.".into());
    }
    if !value["lastResult"].is_object() {
        value["lastResult"] = json!({});
    }
    if value["lastResult"].get("mikuExpo index").is_none()
        || value["lastResult"].get("mikuWithYou index").is_none()
    {
        value["checked"] = Value::Null;
    }
    Ok(value)
}

fn due(cache: &Value, now: DateTime<Local>) -> bool {
    cache["checked"]
        .as_str()
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|checked| now.signed_duration_since(checked).num_seconds() >= REFRESH_SECONDS)
        .unwrap_or(true)
}

async fn page_html(client: &reqwest::Client, url: Url) -> Result<String, String> {
    if !is_official_url(&url) {
        return Err("redirect".into());
    }
    let mut response = client
        .get(url.clone())
        .send()
        .await
        .map_err(|_| "unreachable")?;
    if !response.status().is_success() {
        return Err(if response.status().as_u16() == 404 {
            "missing".into()
        } else if response.status().is_redirection() {
            "redirect".into()
        } else {
            format!("HTTP {}", response.status().as_u16())
        });
    }
    let final_url = response.url();
    if !is_official_url(final_url)
        || final_url.host_str() != url.host_str()
        || final_url.path() != url.path()
    {
        return Err("redirect".into());
    }
    if response
        .content_length()
        .is_some_and(|size| size > MAX_HTML_BYTES as u64)
    {
        return Err("too large".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "unreachable")? {
        if bytes.len() + chunk.len() > MAX_HTML_BYTES {
            return Err("too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn merge_cache(
    mut cache: Value,
    found: Vec<(String, i32, Vec<Value>)>,
    results: BTreeMap<String, String>,
    now: DateTime<Local>,
) -> Value {
    let mut events = cache["events"].as_array().cloned().unwrap_or_default();
    for (kind, year, values) in found {
        let sources: HashSet<_> = values
            .iter()
            .filter_map(|event| event["source"].as_str())
            .collect();
        events.retain(|old| {
            !(old["kind"] == kind
                && old["year"] == year
                && old["source"]
                    .as_str()
                    .is_some_and(|source| sources.contains(source)))
        });
        events.extend(values);
    }
    let previous_year = NaiveDate::from_ymd_opt(now.year() - 1, now.month(), now.day())
        .or_else(|| {
            NaiveDate::from_ymd_opt(now.year() - 1, now.month(), now.day().saturating_sub(1))
        })
        .unwrap_or(now.date_naive());
    events.retain(|event| {
        event["end"]
            .as_str()
            .and_then(|value| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok())
            .map(|end| end >= previous_year)
            .unwrap_or(true)
    });
    events.sort_by(|a, b| a["start"].as_str().cmp(&b["start"].as_str()));
    if results
        .values()
        .any(|result| ["ok", "nothing", "missing"].contains(&result.as_str()))
    {
        cache["checked"] = json!(now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    }
    cache["events"] = json!(events);
    cache["lastResult"] = json!(results);
    cache
}

async fn refresh_cache<F, Fut>(cache: Value, now: DateTime<Local>, mut fetch: F) -> Value
where
    F: FnMut(Url) -> Fut,
    Fut: Future<Output = Result<String, String>>,
{
    let year = now.year();
    let years = [year, year + 1];
    let mut results = BTreeMap::new();
    let mut found = Vec::new();
    for (kind, host) in [
        ("magicalMirai", "magicalmirai.com"),
        ("snowMiku", "snowmiku.com"),
    ] {
        for year in years {
            let source = format!("https://{host}/{year}/");
            let value = match fetch(Url::parse(&source).unwrap()).await {
                Ok(html) => {
                    let events = if kind == "magicalMirai" {
                        magical_mirai(&html, year, &source)
                    } else {
                        snow_miku(&html, year, &source).into_iter().collect()
                    };
                    let status = if events.is_empty() { "nothing" } else { "ok" };
                    if !events.is_empty() {
                        found.push((kind.to_owned(), year, events));
                    }
                    status.to_owned()
                }
                Err(error) => error,
            };
            results.insert(format!("{kind} {year}"), value);
        }
    }
    for (kind, index) in [("mikuExpo", EXPO_INDEX), ("mikuWithYou", WITH_YOU_INDEX)] {
        let base = Url::parse(index).unwrap();
        let mut pages = match fetch(base.clone()).await {
            Ok(html) => {
                let pages = event_pages(&html, kind, &base, &years);
                results.insert(
                    format!("{kind} index"),
                    if pages.is_empty() { "nothing" } else { "ok" }.into(),
                );
                pages
            }
            Err(error) => {
                results.insert(format!("{kind} index"), error);
                vec![]
            }
        };
        if kind == "mikuWithYou"
            && years.contains(&2026)
            && !pages.iter().any(|(_, url)| url.as_str() == WITH_YOU_2026)
        {
            pages.truncate(2);
            pages.push((2026, Url::parse(WITH_YOU_2026).unwrap()));
        }
        let mut by_year: BTreeMap<i32, Vec<Value>> = BTreeMap::new();
        for (year, url) in pages {
            let last = url
                .path_segments()
                .and_then(|segments| segments.filter(|part| !part.is_empty()).next_back())
                .unwrap_or("");
            let label = format!("{kind} {year} {last}");
            match fetch(url.clone()).await {
                Ok(html) => {
                    let events = if kind == "mikuExpo" {
                        miku_expo(&html, year, url.as_str())
                    } else {
                        miku_with_you(&html, year, url.as_str())
                    };
                    results.insert(
                        label,
                        if events.is_empty() { "nothing" } else { "ok" }.into(),
                    );
                    if !events.is_empty() {
                        by_year.entry(year).or_default().extend(events);
                    }
                }
                Err(error) => {
                    results.insert(label, error);
                }
            }
        }
        for (year, events) in by_year {
            found.push((kind.to_owned(), year, events));
        }
    }
    merge_cache(cache, found, results, now)
}

pub async fn refresh(directory: &Path, force: bool) -> Result<Value, String> {
    let cache = load(directory)?;
    let now = Local::now();
    if !force && !due(&cache, now) {
        return Ok(cache);
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(25))
        .connect_timeout(Duration::from_secs(20))
        .user_agent("MikuDesktop/1.0 (Windows; personal desktop companion)")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let allowed = attempt
                .previous()
                .first()
                .map(|first| {
                    is_official_url(attempt.url())
                        && attempt.url().host_str() == first.host_str()
                        && attempt.url().path() == first.path()
                })
                .unwrap_or(false);
            if allowed && attempt.previous().len() < 6 {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .map_err(|_| "The official-event HTTP client could not be initialized.")?;
    let updated = refresh_cache(cache, now, |url| page_html(&client, url)).await;
    storage::atomic_write(&directory.join("events.json"), &updated)?;
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    const MIRAI: &str = r#"<html><head><style>.x{}</style><script>var d="2026年1月1日~2日";</script></head><body>
        <h2>マジカルミライ 2026</h2>
        <section><h3>HAMAMATSU</h3><p>2026.7.24(金)-26(日)</p><p>アクトシティ浜松</p></section>
        <section><h3>OSAKA</h3><p>2026年8月14日(金)～8月16日(日)</p><p>インテックス大阪 6号館</p></section>
        <section><h3>TOKYO</h3><p>２０２６年８月２８日（金）〜３０日（日）</p><p>幕張メッセ 国際展示場</p></section>
        <p>チケット抽選受付 2026年5月1日(金)～5月10日(日)</p>
        <p>東京公演 先行抽選受付 2026年6月1日～6月3日</p></body></html>"#;

    const EXPO: &str = r#"<p>Tickets on sale November 1st</p><ul class="concert_list">
        <li><div class="concert_list_city"><h3 class="city"><span class="city_txt">London</span></h3></div>
        <div class="concert_list_info"><div class="date"><p>DATE</p><div class="concert_list_datetime"><p>November 12th (Thu.)</p><div class="times">20:00</div></div></div>
        <div class="venue"><p>VENUE</p><p><a href="https://venue.invalid">Sample Hall<span>arrow_forward_ios</span></a></p></div><div class="ticket">November 2nd</div></div></li>
        <li><span class="city_txt">Madrid</span><div class="concert_list_datetime"><p>November 24th (Tue.)</p><div>20:00</div></div>
        <div class="concert_list_datetime"><p>November 25th (Wed.)</p><div>20:00</div></div><div class="venue"><p>VENUE</p><p>Sample Arena</p></div></li>
        <li><span class="city_txt">No date</span><div class="venue_txt">Other Hall</div></li>
        <li><span class="city_txt">No venue</span><p class="date_txt">November 28th</p></li></ul>"#;

    const NORTH_AMERICA: &str = r#"<ul class='concert_list'><li><div class='city'><p class='city_txt'>Chicago, IL</p></div>
        <div class='venue'><p class='venue_txt'>Sample Theatre</p></div><div class='info_area'><div class='date'><p class='date_txt'>April 12th Sun.</p></div></div>
        <div class='info_area'><div class='date'><p class='date_txt'>April 13th Mon.</p></div></div></li>
        <li><p class='city_txt'>Denver, CO</p><p class='venue_txt'>Sample Ballroom</p><p class='date_txt'>April 15th Wed.</p></li>
        <li><p class='city_txt'>Invalid City</p><p class='venue_txt'>Sample Venue</p><p class='date_txt'>February 30th</p></li></ul>"#;

    const WITH_YOU: &str = r#"<h1>初音未来·未来有你2026｜正式官宣</h1><p>发布：2026年9月12日</p><p>售票时间：2026年9月20日</p>
        <p>时间：2026年10月31日-11月1日（日场&amp;夜场）</p><p>地点：上海静安体育中心</p>"#;

    const DISCOVERY: &str = r#"<a href="europe2026/">2026 EUROPE</a><a href="/na2026/">North America</a>
        <a href="asia2025/">2025 ASIA</a><a href="/europe2027/">2027 EUROPE</a><a href="https://evil.example/europe2026/">Other</a>
        <a href="//evil.example/na2026/">Other</a><a href="http://mikuexpo.com/na2026/">Insecure</a><a href="/na2026/?token=x">Query</a>
        <a href="/na2026/#ticket">Fragment</a><a href="https://user@mikuexpo.com/na2026/">Credentials</a>"#;

    #[test]
    fn mirai_dates_are_local_city_runs_not_ticket_periods() {
        let events = magical_mirai(MIRAI, 2026, "https://magicalmirai.com/2026/");
        assert_eq!(events.len(), 3);
        assert_eq!(events[0]["city"], "hamamatsu");
        assert_eq!(events[0]["start"], "2026-07-24");
        assert_eq!(events[0]["end"], "2026-07-26");
        assert_eq!(events[0]["venue"], "アクトシティ浜松");
        assert!(events
            .iter()
            .any(|event| event["city"] == "osaka" && event["venue"] == "インテックス大阪"));
        assert!(events.iter().any(|event| event["city"] == "tokyo"
            && event["start"] == "2026-08-28"
            && event["end"] == "2026-08-30"));
        assert!(!events.iter().any(|event| event["start"] == "2026-06-01"));
        assert!(magical_mirai(
            "<p>マジカルミライ 2027 開催決定！詳細は後日発表</p>",
            2027,
            "test"
        )
        .is_empty());
    }

    #[test]
    fn snow_miku_prefers_explicit_miku_period_over_orders_and_festival() {
        let snow="<p>グッズ予約受付 2027年1月20日(水)～1月31日(日)</p><p>SNOW MIKU 2027 開催期間：2027年2月5日(金)～3月7日(日)</p><p>さっぽろ雪まつり 2027年2月4日(木)～2月11日(木・祝)</p>";
        let event = snow_miku(snow, 2027, "test").unwrap();
        assert_eq!(event["start"], "2027-02-05");
        assert_eq!(event["end"], "2027-03-07");
        let festival_first="<p>さっぽろ雪まつり 2028年2月4日(金)～2月11日(金・祝)</p><h2>雪ミク</h2><p>開催期間：2028年2月6日(日)～2月12日(土)</p>";
        assert_eq!(
            snow_miku(festival_first, 2028, "test").unwrap()["start"],
            "2028-02-06"
        );
    }

    #[test]
    fn expo_item_city_venue_and_dates_stay_together() {
        let source = "https://mikuexpo.com/europe2026/";
        let events = miku_expo(EXPO, 2026, source);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0]["city"], "London");
        assert_eq!(events[0]["venue"], "Sample Hall");
        assert!(events
            .iter()
            .all(|event| event["start"] == event["end"] && event["source"] == source));
        assert!(!events
            .iter()
            .any(|event| event["start"] == "2026-11-01" || event["start"] == "2026-11-02"));
        let north = miku_expo(NORTH_AMERICA, 2026, "https://mikuexpo.com/na2026/");
        assert_eq!(north.len(), 3);
        assert_eq!(
            north
                .iter()
                .filter(|event| event["city"] == "Chicago, IL")
                .count(),
            2
        );
        assert!(miku_expo("<p>MIKU EXPO 2027 coming soon</p>", 2027, source).is_empty());
    }

    #[test]
    fn with_you_uses_adjacent_performance_labels_and_valid_dates() {
        let events = miku_with_you(WITH_YOU, 2026, WITH_YOU_2026);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["start"], "2026-10-31");
        assert_eq!(events[0]["end"], "2026-11-01");
        assert_eq!(events[0]["city"], "shanghai");
        assert!(miku_with_you(WITH_YOU, 2027, WITH_YOU_2026).is_empty());
        assert!(miku_with_you(
            "<h1>未来有你2027</h1><p>发布时间：2027年1月1日</p>",
            2027,
            "test"
        )
        .is_empty());
        assert!(miku_with_you(
            "<h1>未来有你2027</h1><p>售票时间：2027年9月20日</p><p>地点：上海某场馆</p>",
            2027,
            "test"
        )
        .is_empty());
        assert!(miku_with_you(
            "<h1>未来有你2027</h1><p>时间：2027年2月30日-3月1日</p><p>地点：上海某场馆</p>",
            2027,
            "test"
        )
        .is_empty());
        assert_eq!(
            miku_with_you(
                "<h1>未来有你2027</h1><p>时间：2027年10月30日</p><p>地点：北京某场馆</p>",
                2027,
                "test"
            )
            .len(),
            1
        );
    }

    #[test]
    fn discovery_is_official_bounded_and_year_specific() {
        let base = Url::parse(EXPO_INDEX).unwrap();
        let pages = event_pages(DISCOVERY, "mikuExpo", &base, &[2026, 2027]);
        assert_eq!(pages.len(), 3);
        assert!(pages
            .iter()
            .all(|(_, url)| is_official_url(url) && url.host_str() == Some("mikuexpo.com")));
        let many = (1..=10)
            .map(|i| format!("<a href='/tour{i}2026/'>Tour</a>"))
            .collect::<String>();
        assert_eq!(event_pages(&many, "mikuExpo", &base, &[2026]).len(), 6);
        let articles = r#"<a href="/Cn/Index/pageView/catid/17/id/4728/ip/16.html">未来有你2026｜正式官宣</a><a href="/Cn/Index/pageView/catid/17/id/5000/ip/16.html">未来有你2027演唱会</a><a href="/Cn/Index/pageView/catid/17/id/4000/ip/16.html">未来有你2025｜正式官宣</a><a href="https://evil.example/Cn/Index/pageView/catid/17/id/1/ip/16.html">未来有你2026官宣</a><a href="/Cn/Index/pageView/catid/17/id/3000/ip/16.html">其他活动2026官宣</a>"#;
        let pages = event_pages(
            articles,
            "mikuWithYou",
            &Url::parse(WITH_YOU_INDEX).unwrap(),
            &[2026, 2027],
        );
        assert_eq!(pages.len(), 2);
        assert_eq!(
            pages.iter().map(|entry| entry.0).collect::<Vec<_>>(),
            vec![2026, 2027]
        );
    }

    #[tokio::test]
    async fn refresh_merges_tours_and_failures_preserve_confirmed_cache() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 3, 12, 0, 0)
            .single()
            .unwrap();
        let mut fixtures = BTreeMap::new();
        fixtures.insert(EXPO_INDEX.to_owned(), Ok(DISCOVERY.to_owned()));
        fixtures.insert(
            "https://mikuexpo.com/europe2026/".to_owned(),
            Ok(EXPO.to_owned()),
        );
        fixtures.insert(
            "https://mikuexpo.com/na2026/".to_owned(),
            Ok(NORTH_AMERICA.to_owned()),
        );
        fixtures.insert(WITH_YOU_INDEX.to_owned(), Ok(String::new()));
        fixtures.insert(WITH_YOU_2026.to_owned(), Ok(WITH_YOU.to_owned()));
        fixtures.insert(
            "https://magicalmirai.com/2027/".to_owned(),
            Err("missing".to_owned()),
        );
        fixtures.insert(
            "https://snowmiku.com/2027/".to_owned(),
            Ok("<p>Dates later</p>".to_owned()),
        );
        let empty = json!({"checked":null,"events":[],"lastResult":{}});
        let updated = refresh_cache(empty, now, |url| {
            std::future::ready(
                fixtures
                    .get(url.as_str())
                    .cloned()
                    .unwrap_or(Err("HTTP 503".into())),
            )
        })
        .await;
        assert_eq!(
            updated["events"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|event| event["kind"] == "mikuExpo")
                .count(),
            6
        );
        assert!(updated["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["kind"] == "mikuWithYou" && event["end"] == "2026-11-01"));
        assert_eq!(updated["lastResult"]["magicalMirai 2027"], "missing");
        assert_eq!(updated["lastResult"]["snowMiku 2027"], "nothing");
        let failed = refresh_cache(updated.clone(), now + chrono::Duration::days(1), |_| {
            std::future::ready(Err("HTTP 503".into()))
        })
        .await;
        assert_eq!(failed["events"], updated["events"]);
        assert_eq!(failed["checked"], updated["checked"]);
        assert!(failed["lastResult"]
            .as_object()
            .unwrap()
            .values()
            .all(|value| value == "HTTP 503"));
        assert!(!due(&updated, now + chrono::Duration::days(2)));
        assert!(due(&updated, now + chrono::Duration::days(3)));
    }

    #[test]
    fn source_merge_preserves_an_unreachable_tour_of_the_same_year() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 3, 12, 0, 0)
            .single()
            .unwrap();
        let europe = miku_expo(EXPO, 2026, "https://mikuexpo.com/europe2026/");
        let north = miku_expo(NORTH_AMERICA, 2026, "https://mikuexpo.com/na2026/");
        let all = europe.iter().chain(&north).cloned().collect::<Vec<_>>();
        let cache = json!({"checked":null,"events":all,"lastResult":{}});
        let updated = merge_cache(
            cache,
            vec![("mikuExpo".into(), 2026, europe)],
            BTreeMap::new(),
            now,
        );
        assert_eq!(updated["events"].as_array().unwrap().len(), 6);
    }
}
