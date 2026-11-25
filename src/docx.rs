use crate::MAX_DOCUMENT;
use anyhow::{Context, Result, bail, ensure};
use quick_xml::{
    XmlVersion, escape::resolve_xml_entity, events::Event, name::ResolveResult, reader::NsReader,
};
use std::io::{Cursor, Read};
use zip::{CompressionMethod, ZipArchive};

pub(super) const MAX_ARCHIVE: u64 = 16 * 1024 * 1024;
const MAX_RELATIONSHIPS: u64 = 128 * 1024;
const MAX_MAIN_XML: u64 = 8 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const MAX_XML_DEPTH: usize = 128;

const PACKAGE_RELATIONSHIPS: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const OFFICE_DOCUMENT: &str =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument";
const STRICT_OFFICE_DOCUMENT: &str =
    "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument";
const WORD: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const STRICT_WORD: &str = "http://purl.oclc.org/ooxml/wordprocessingml/main";

/// Interpret only two parts of the supplied package, in memory. The caller
/// obtains these archive bytes through the local-file availability checks.
pub(super) fn text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_ARCHIVE,
        "DOCX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(Cursor::new(bytes)).context("open DOCX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "DOCX has too many parts");
    let relationships = xml_part(&mut archive, "_rels/.rels", MAX_RELATIONSHIPS)?;
    let main = main_part(&relationships)?;
    document_text(&xml_part(&mut archive, &main, MAX_MAIN_XML)?)
}

fn xml_part(archive: &mut ZipArchive<Cursor<&[u8]>>, name: &str, limit: u64) -> Result<String> {
    let file = archive.by_name(name).context("missing DOCX XML part")?;
    ensure!(
        file.is_file()
            && matches!(
                file.compression(),
                CompressionMethod::Stored | CompressionMethod::Deflated
            )
            && file.size() <= limit,
        "unsupported DOCX part or XML size exceeds limit"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= limit,
        "DOCX XML exceeds decompression limit"
    );
    if let Some(marker) = bytes.first_chunk::<2>() {
        let decode = match marker {
            [0xff, 0xfe] => Some(u16::from_le_bytes as fn([u8; 2]) -> u16),
            [0xfe, 0xff] => Some(u16::from_be_bytes as fn([u8; 2]) -> u16),
            _ => None,
        };
        if let Some(decode) = decode {
            let (units, remainder) = bytes[2..].as_chunks::<2>();
            ensure!(remainder.is_empty(), "truncated UTF-16 DOCX XML");
            let units: Vec<_> = units.iter().copied().map(decode).collect();
            return Ok(String::from_utf16(&units)?);
        }
    }
    Ok(String::from_utf8(bytes)?)
}

fn xml_reader(xml: &str) -> NsReader<&[u8]> {
    let mut reader = NsReader::from_str(xml);
    reader.config_mut().expand_empty_elements = true;
    reader
}

fn main_part(xml: &str) -> Result<String> {
    let mut reader = xml_reader(xml);
    let mut depth = 0;
    let mut root = false;
    let mut main = None;
    loop {
        let (namespace, event) = reader.read_resolved_event()?;
        let package =
            matches!(namespace, ResolveResult::Bound(ns) if ns.0 == PACKAGE_RELATIONSHIPS);
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(depth <= MAX_XML_DEPTH, "DOCX XML nesting exceeds limit");
                let name = node.local_name();
                if depth == 1 {
                    ensure!(
                        !root && package && name.as_ref() == "Relationships",
                        "invalid DOCX package relationships"
                    );
                    root = true;
                }
                if depth == 2 && package && name.as_ref() == "Relationship" {
                    let attribute = |key| -> Result<Option<String>> {
                        node.try_get_attribute(key)?
                            .map(|value| {
                                value
                                    .normalized_value(XmlVersion::Implicit1_0)
                                    .map(|s| s.into_owned())
                                    .map_err(Into::into)
                            })
                            .transpose()
                    };
                    if matches!(
                        attribute("Type")?.as_deref(),
                        Some(OFFICE_DOCUMENT | STRICT_OFFICE_DOCUMENT)
                    ) {
                        ensure!(main.is_none(), "ambiguous DOCX main document relationship");
                        ensure!(
                            matches!(attribute("TargetMode")?.as_deref(), None | Some("Internal")),
                            "external DOCX main document relationship"
                        );
                        let target =
                            attribute("Target")?.context("missing DOCX main document target")?;
                        let part = target.strip_prefix('/').unwrap_or(&target);
                        ensure!(
                            !part.contains(['\\', ':', '#', '?'])
                                && !part.chars().any(char::is_control)
                                && part
                                    .split('/')
                                    .all(|component| !matches!(component, "" | "." | "..")),
                            "invalid DOCX main document target"
                        );
                        main = Some(part.to_owned());
                    }
                }
            }
            Event::End(_) => depth -= 1,
            Event::DocType(_) => bail!("DTD is forbidden in DOCX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    ensure!(depth == 0, "unclosed DOCX package relationships");
    main.context("missing DOCX main document relationship")
}

fn document_text(xml: &str) -> Result<String> {
    let mut reader = xml_reader(xml);
    let mut depth = 0;
    let mut root = false;
    let mut seen_body = false;
    let mut in_body = false;
    let mut paragraph = 0;
    let mut reading_text = false;
    let mut body = String::new();
    let mut separator = "";
    let append = |body: &mut String, separator: &mut &str, text: &str| -> Result<()> {
        if !text.is_empty() {
            ensure!(
                body.len() + separator.len() + text.len() <= MAX_DOCUMENT as usize,
                "DOCX exceeds text limit"
            );
            if !body.is_empty() {
                body.push_str(separator);
            }
            body.push_str(text);
            *separator = "";
        }
        Ok(())
    };
    loop {
        let (namespace, event) = reader.read_resolved_event()?;
        let word =
            matches!(namespace, ResolveResult::Bound(ns) if matches!(ns.0, WORD | STRICT_WORD));
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(
                    depth <= MAX_XML_DEPTH && !reading_text,
                    "invalid DOCX text element or nesting"
                );
                let name = node.local_name();
                if depth == 1 {
                    ensure!(
                        !root && word && name.as_ref() == "document",
                        "invalid DOCX main document"
                    );
                    root = true;
                }
                if depth == 2 && word && name.as_ref() == "body" {
                    ensure!(!seen_body, "duplicate DOCX body");
                    seen_body = true;
                    in_body = true;
                }
                if in_body && word {
                    match name.as_ref() {
                        "p" => paragraph += 1,
                        "t" if paragraph != 0 => reading_text = true,
                        "tab" if paragraph != 0 => append(&mut body, &mut separator, "\t")?,
                        "br" | "cr" if paragraph != 0 => append(&mut body, &mut separator, "\n")?,
                        _ => {}
                    }
                }
            }
            Event::End(node) => {
                if in_body && word {
                    match node.local_name().as_ref() {
                        "body" if depth == 2 => in_body = false,
                        "t" => reading_text = false,
                        "p" => {
                            paragraph -= 1;
                            separator = "\n\n";
                        }
                        "tc" => separator = "\t",
                        "tr" => separator = "\n\n",
                        _ => {}
                    }
                }
                depth -= 1;
            }
            Event::Text(text) if reading_text => {
                append(&mut body, &mut separator, &text.xml10_content())?
            }
            Event::CData(text) if reading_text => {
                append(&mut body, &mut separator, &text.xml10_content())?
            }
            Event::GeneralRef(reference) if reading_text => {
                if let Some(ch) = reference.resolve_char_ref()? {
                    append(&mut body, &mut separator, ch.encode_utf8(&mut [0; 4]))?;
                } else {
                    let name = reference.into_inner();
                    let value = resolve_xml_entity(&name)
                        .context("custom XML entities are forbidden in DOCX")?;
                    append(&mut body, &mut separator, value)?;
                }
            }
            Event::DocType(_) => bail!("DTD is forbidden in DOCX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    ensure!(depth == 0 && seen_body, "missing or unclosed DOCX body");
    Ok(body)
}
