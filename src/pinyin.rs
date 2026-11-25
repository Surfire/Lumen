use serde::Serialize;

struct Reading {
    phrase: &'static str,
    syllables: &'static str,
    full: &'static str,
    old_full: &'static str,
    initials: &'static str,
    old_initials: &'static str,
}

const READINGS: &[Reading] = &[
    Reading::new("成都", "cheng du", "chengdu", "chengdou", "cd", "cd"),
    Reading::new("重庆", "chong qing", "chongqing", "chongqing", "cq", "cq"),
    Reading::new("厦门", "xia men", "xiamen", "shamen", "xm", "sm"),
    Reading::new("长沙", "chang sha", "changsha", "zhangsha", "cs", "zs"),
    Reading::new("长春", "chang chun", "changchun", "zhangchun", "cc", "zc"),
    Reading::new("长安", "chang an", "changan", "zhangan", "ca", "za"),
    Reading::new("长治", "chang zhi", "changzhi", "zhangzhi", "cz", "zz"),
    Reading::new("六安", "lu an", "luan", "liuan", "la", "la"),
    Reading::new("西藏", "xi zang", "xizang", "xicang", "xz", "xc"),
    Reading::new("银行", "yin hang", "yinhang", "yinxing", "yh", "yx"),
    Reading::new("音乐", "yin yue", "yinyue", "yinle", "yy", "yl"),
];

impl Reading {
    const fn new(
        phrase: &'static str,
        syllables: &'static str,
        full: &'static str,
        old_full: &'static str,
        initials: &'static str,
        old_initials: &'static str,
    ) -> Self {
        Self {
            phrase,
            syllables,
            full,
            old_full,
            initials,
            old_initials,
        }
    }
}

#[cfg(target_os = "macos")]
pub(super) fn contextual_input(name: &str) -> std::borrow::Cow<'_, str> {
    let mut text = std::borrow::Cow::Borrowed(name);
    for reading in READINGS {
        if text.contains(reading.phrase) {
            text = text
                .replace(reading.phrase, &format!(" {} ", reading.syllables))
                .into();
        }
    }
    text
}

#[derive(Serialize)]
pub(super) struct LegacyReading {
    pub key: String,
    pub phrases: Vec<&'static str>,
    pub initials: bool,
}

/// Older catalogs can answer the corrected reading without updating rows.
/// A compatible key is valid only on a basename containing its Han context.
pub(super) fn legacy(term: &str) -> Option<LegacyReading> {
    if !term.is_ascii() {
        return None;
    }
    let mut full = None;
    let mut phrases = Vec::new();
    for reading in READINGS {
        if reading.full != reading.old_full && term.contains(reading.full) {
            let key = full.get_or_insert_with(|| term.to_owned());
            *key = key.replace(reading.full, reading.old_full);
            phrases.push(reading.phrase);
        }
    }
    if let Some(key) = full {
        return Some(LegacyReading {
            key,
            phrases,
            initials: false,
        });
    }
    READINGS
        .iter()
        .find(|reading| term == reading.initials && term != reading.old_initials)
        .map(|reading| LegacyReading {
            key: reading.old_initials.to_owned(),
            phrases: vec![reading.phrase],
            initials: true,
        })
}
