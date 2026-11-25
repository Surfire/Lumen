use crate::{ArgumentInfo, ClipboardIntent, RunOutput};
use anyhow::{Context, Result, bail, ensure};
use std::collections::BTreeMap;

const MAX_TERMS: usize = 16;
const MAX_TRANSFORMS: usize = 8;
const MAX_OUTPUT_BYTES: usize = 4096;

#[derive(Debug)]
enum Operand {
    Literal(String),
    Argument(String),
}

#[derive(Debug)]
enum Transform {
    Trim,
    ReplaceAll { needle: String, replacement: String },
}

#[derive(Debug)]
struct Term {
    operand: Operand,
    transforms: Vec<Transform>,
}

#[derive(Debug, Clone, Copy)]
enum Action {
    Hud,
    ClipboardCopy,
}

impl Action {
    fn label(self) -> &'static str {
        match self {
            Self::Hud => "HUD",
            Self::ClipboardCopy => "clipboard text",
        }
    }

    fn check_size(self, bytes: usize) -> Result<()> {
        ensure!(
            bytes <= MAX_OUTPUT_BYTES,
            "{} exceeds {MAX_OUTPUT_BYTES} bytes",
            self.label()
        );
        Ok(())
    }
}

#[derive(Debug)]
pub(crate) struct Program {
    action: Action,
    terms: Vec<Term>,
}

impl Program {
    pub(crate) fn compile(source: &str, arguments: &[ArgumentInfo]) -> Result<Self> {
        let mut parser = Parser { source, cursor: 0 };
        parser.word("import")?;
        parser.symbol("{")?;
        let action = match parser.identifier()? {
            "showHUD" => Action::Hud,
            "Clipboard" => Action::ClipboardCopy,
            _ => bail!("only showHUD or Clipboard may be imported"),
        };
        parser.symbol("}")?;
        parser.word("from")?;
        ensure!(
            parser.string()? == "@raycast/api",
            "only @raycast/api may be imported"
        );
        if parser.skip_space() {
            parser.take(";");
        } else {
            parser.symbol(";")?;
        }
        parser.word("export")?;
        parser.word("default")?;
        parser.word("async")?;
        ensure!(
            !parser.skip_space(),
            "async function must appear on the same line"
        );
        parser.word("function")?;
        parser.word("Command")?;
        parser.symbol("(")?;
        let has_props = !parser.take(")");
        if has_props {
            parser.word("props")?;
            parser.symbol(")")?;
        }
        parser.symbol("{")?;
        parser.word("await")?;
        match action {
            Action::Hud => parser.word("showHUD")?,
            Action::ClipboardCopy => {
                parser.word("Clipboard")?;
                parser.symbol(".")?;
                parser.word("copy")?;
            }
        }
        parser.symbol("(")?;
        let mut terms = Vec::new();
        loop {
            ensure!(
                terms.len() < MAX_TERMS,
                "text expression exceeds {MAX_TERMS} terms"
            );
            parser.skip_space();
            let operand = if parser.remaining().starts_with('"') {
                Operand::Literal(parser.string()?)
            } else {
                ensure!(has_props, "text expression requires a string literal");
                parser.word("props")?;
                parser.symbol(".")?;
                parser.word("arguments")?;
                parser.symbol(".")?;
                let name = parser.identifier()?;
                ensure!(
                    arguments.iter().any(|argument| argument.name == name),
                    "text expression references an undeclared argument"
                );
                Operand::Argument(name.to_owned())
            };
            let mut transforms = Vec::new();
            while parser.take(".") {
                ensure!(
                    transforms.len() < MAX_TRANSFORMS,
                    "text term exceeds {MAX_TRANSFORMS} transforms"
                );
                transforms.push(parser.transform()?);
            }
            terms.push(Term {
                operand,
                transforms,
            });
            if !parser.take("+") {
                break;
            }
        }
        parser.symbol(")")?;
        parser.take(";");
        parser.symbol("}")?;
        parser.skip_space();
        ensure!(
            parser.remaining().is_empty(),
            "unexpected content after Command"
        );
        Ok(Self { action, terms })
    }

    pub(crate) fn run(&self, arguments: &BTreeMap<String, String>) -> Result<RunOutput> {
        let mut output = String::new();
        for term in &self.terms {
            let mut value = match &term.operand {
                Operand::Literal(value) => value.clone(),
                Operand::Argument(name) => arguments
                    .get(name)
                    .context("missing required argument")?
                    .clone(),
            };
            self.action.check_size(value.len())?;
            for transform in &term.transforms {
                value = match transform {
                    Transform::Trim => value.trim_matches(js_whitespace).to_owned(),
                    Transform::ReplaceAll {
                        needle,
                        replacement,
                    } => {
                        let matches = value.matches(needle).count();
                        let bytes =
                            value.len() - matches * needle.len() + matches * replacement.len();
                        self.action.check_size(bytes)?;
                        value.replace(needle, replacement)
                    }
                };
            }
            self.action.check_size(output.len() + value.len())?;
            output.push_str(&value);
        }
        Ok(match self.action {
            Action::Hud => RunOutput::Hud { hud: output },
            Action::ClipboardCopy => RunOutput::Clipboard {
                clipboard: ClipboardIntent { text: output },
            },
        })
    }
}

fn js_whitespace(character: char) -> bool {
    matches!(
        character,
        '\u{0009}'..='\u{000D}' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}'
            | '\u{2028}' | '\u{2029}' | '\u{202F}' | '\u{205F}' | '\u{3000}' | '\u{FEFF}'
    )
}

struct Parser<'a> {
    source: &'a str,
    cursor: usize,
}

impl<'a> Parser<'a> {
    fn transform(&mut self) -> Result<Transform> {
        let name = self.identifier()?;
        self.symbol("(")?;
        let transform = match name {
            "trim" => Transform::Trim,
            "replaceAll" => {
                let needle = self.string()?;
                self.symbol(",")?;
                let replacement = self.string()?;
                ensure!(
                    !needle.is_empty(),
                    "replaceAll search text must not be empty"
                );
                ensure!(
                    !replacement.contains('$'),
                    "replaceAll replacement tokens are unsupported"
                );
                Transform::ReplaceAll {
                    needle,
                    replacement,
                }
            }
            _ => bail!("only trim and literal replaceAll text transforms are supported"),
        };
        self.symbol(")")?;
        Ok(transform)
    }

    fn remaining(&self) -> &'a str {
        &self.source[self.cursor..]
    }

    fn skip_space(&mut self) -> bool {
        let whitespace = self.remaining().trim_start_matches([' ', '\t', '\r', '\n']);
        let end = self.source.len() - whitespace.len();
        let newline = self.source[self.cursor..end].contains(['\r', '\n']);
        self.cursor = end;
        newline
    }

    fn take(&mut self, symbol: &str) -> bool {
        self.skip_space();
        if self.remaining().starts_with(symbol) {
            self.cursor += symbol.len();
            true
        } else {
            false
        }
    }

    fn symbol(&mut self, symbol: &str) -> Result<()> {
        ensure!(
            self.take(symbol),
            "expected {symbol:?} near byte {}",
            self.cursor
        );
        Ok(())
    }

    fn word(&mut self, keyword: &str) -> Result<()> {
        let word = self.identifier()?;
        ensure!(
            word == keyword,
            "expected {keyword:?} near byte {}",
            self.cursor - word.len()
        );
        Ok(())
    }

    fn identifier(&mut self) -> Result<&'a str> {
        self.skip_space();
        let remaining = self.remaining();
        let len = remaining
            .bytes()
            .take_while(|&byte| identifier_byte(byte))
            .count();
        let word = &remaining[..len];
        ensure!(
            is_identifier(word),
            "expected an identifier at byte {}",
            self.cursor
        );
        self.cursor += len;
        Ok(word)
    }

    fn string(&mut self) -> Result<String> {
        self.symbol("\"")?;
        let start = self.cursor - 1;
        let mut escaped = false;
        for (offset, byte) in self.remaining().bytes().enumerate() {
            if byte == b'"' && !escaped {
                self.cursor += offset + 1;
                return serde_json::from_str(&self.source[start..self.cursor])
                    .with_context(|| format!("invalid string literal at byte {start}"));
            }
            escaped = byte == b'\\' && !escaped;
        }
        bail!("unclosed string literal at byte {start}")
    }
}

fn identifier_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'$')
}

pub(crate) fn is_identifier(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(|&byte| identifier_byte(byte) && !byte.is_ascii_digit())
        && value.bytes().all(identifier_byte)
}
