use crate::MAX_DOCUMENT;
use anyhow::{Context, Result, bail, ensure};
use quick_xml::{
    XmlVersion, escape::resolve_xml_entity, events::Event, name::ResolveResult, reader::NsReader,
};
use std::io::{Cursor, Read};
use zip::{CompressionMethod, ZipArchive};

pub(super) const MAX_ARCHIVE: u64 = 16 * 1024 * 1024;
pub(super) const MAX_PPTX_ARCHIVE: u64 = 64 * 1024 * 1024;
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

const MAX_OFFICE_PARTS: usize = 128;
const MAX_SHARED_STRINGS_XML: u64 = 16 * 1024 * 1024;
const MAX_SHEET_XML: u64 = 16 * 1024 * 1024;
const MAX_SLIDE_XML: u64 = 4 * 1024 * 1024;

fn append_bounded(body: &mut String, separator: &mut &str, text: &str) -> bool {
    if text.is_empty() {
        return true;
    }
    let sep = if body.is_empty() { "" } else { *separator };
    let budget = MAX_DOCUMENT as usize;
    if body.len() + sep.len() + text.len() <= budget {
        body.push_str(sep);
        body.push_str(text);
        *separator = "";
        return true;
    }
    let remaining = budget.saturating_sub(body.len() + sep.len());
    if remaining > 0 {
        body.push_str(sep);
        let mut end = remaining.min(text.len());
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        body.push_str(&text[..end]);
        *separator = "";
    }
    false
}

fn numbered_parts(archive: &ZipArchive<Cursor<&[u8]>>, prefix: &str, suffix: &str) -> Vec<String> {
    let mut parts: Vec<(u32, String)> = archive
        .file_names()
        .filter_map(|name| {
            let name = name.ok()?;
            let middle = name.strip_prefix(prefix)?.strip_suffix(suffix)?;
            let number = middle.parse::<u32>().ok()?;
            Some((number, name.into_owned()))
        })
        .collect();
    parts.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    parts
        .into_iter()
        .take(MAX_OFFICE_PARTS)
        .map(|(_, name)| name)
        .collect()
}

fn decode_xml_ref(reference: quick_xml::events::BytesRef<'_>) -> Result<String> {
    if let Some(ch) = reference.resolve_char_ref()? {
        Ok(ch.to_string())
    } else {
        let name = reference.into_inner();
        let value =
            resolve_xml_entity(&name).context("custom XML entities are forbidden in Office XML")?;
        Ok(value.to_owned())
    }
}

fn parse_shared_strings(xml: &str) -> Result<Vec<String>> {
    let mut reader = xml_reader(xml);
    let mut depth = 0usize;
    let mut in_si = false;
    let mut in_t = false;
    let mut current = String::new();
    let mut strings = Vec::new();
    loop {
        let (_, event) = reader.read_resolved_event()?;
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(depth <= MAX_XML_DEPTH, "XLSX XML nesting exceeds limit");
                match node.local_name().as_ref() {
                    "si" => {
                        in_si = true;
                        current.clear();
                    }
                    "t" if in_si => in_t = true,
                    _ => {}
                }
            }
            Event::End(node) => {
                match node.local_name().as_ref() {
                    "t" => in_t = false,
                    "si" if in_si => {
                        in_si = false;
                        strings.push(std::mem::take(&mut current));
                    }
                    _ => {}
                }
                depth -= 1;
            }
            Event::Text(text) if in_t => current.push_str(&text.xml10_content()),
            Event::CData(text) if in_t => current.push_str(&text.xml10_content()),
            Event::GeneralRef(reference) if in_t => current.push_str(&decode_xml_ref(reference)?),
            Event::DocType(_) => bail!("DTD is forbidden in XLSX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(strings)
}

/// Extract searchable cell text from an `.xlsx` workbook in memory without
/// touching the filesystem or adding third-party dependencies.
pub(super) fn xlsx_text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_ARCHIVE,
        "XLSX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(Cursor::new(bytes)).context("open XLSX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "XLSX has too many parts");
    let shared = match xml_part(&mut archive, "xl/sharedStrings.xml", MAX_SHARED_STRINGS_XML) {
        Ok(xml) => parse_shared_strings(&xml)?,
        Err(_) => Vec::new(),
    };
    let sheets = numbered_parts(&archive, "xl/worksheets/sheet", ".xml");
    ensure!(!sheets.is_empty(), "XLSX has no worksheets");

    let mut body = String::new();
    let mut separator = "";
    'sheets: for sheet_name in sheets {
        let Ok(xml) = xml_part(&mut archive, &sheet_name, MAX_SHEET_XML) else {
            continue;
        };
        let mut reader = xml_reader(&xml);
        let mut depth = 0usize;
        let mut cell_type = String::new();
        let mut in_value = false;
        let mut in_inline_text = false;
        let mut cell_buf = String::new();
        loop {
            let (_, event) = reader.read_resolved_event()?;
            match event {
                Event::Start(node) => {
                    depth += 1;
                    ensure!(depth <= MAX_XML_DEPTH, "XLSX XML nesting exceeds limit");
                    match node.local_name().as_ref() {
                        "c" => {
                            cell_type.clear();
                            if let Some(attr) = node.try_get_attribute("t")? {
                                cell_type =
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned();
                            }
                            cell_buf.clear();
                        }
                        "v" => {
                            in_value = true;
                            cell_buf.clear();
                        }
                        "t" if cell_type == "inlineStr" => {
                            in_inline_text = true;
                            cell_buf.clear();
                        }
                        _ => {}
                    }
                }
                Event::End(node) => {
                    match node.local_name().as_ref() {
                        "v" if in_value => {
                            in_value = false;
                            let resolved = if cell_type == "s" {
                                cell_buf
                                    .trim()
                                    .parse::<usize>()
                                    .ok()
                                    .and_then(|idx| shared.get(idx))
                                    .map(String::as_str)
                                    .unwrap_or("")
                            } else if cell_type == "b" {
                                ""
                            } else {
                                cell_buf.trim()
                            };
                            if !resolved.is_empty() {
                                if !append_bounded(&mut body, &mut separator, resolved) {
                                    break 'sheets;
                                }
                                separator = "\t";
                            }
                        }
                        "t" if in_inline_text => {
                            in_inline_text = false;
                            let text = cell_buf.trim();
                            if !text.is_empty() {
                                if !append_bounded(&mut body, &mut separator, text) {
                                    break 'sheets;
                                }
                                separator = "\t";
                            }
                        }
                        "row" => {
                            if !body.is_empty() {
                                separator = "\n";
                            }
                        }
                        "c" => cell_type.clear(),
                        _ => {}
                    }
                    depth -= 1;
                }
                Event::Text(text) if in_value || in_inline_text => {
                    cell_buf.push_str(&text.xml10_content());
                }
                Event::CData(text) if in_value || in_inline_text => {
                    cell_buf.push_str(&text.xml10_content());
                }
                Event::GeneralRef(reference) if in_value || in_inline_text => {
                    cell_buf.push_str(&decode_xml_ref(reference)?);
                }
                Event::DocType(_) => bail!("DTD is forbidden in XLSX XML"),
                Event::Eof => break,
                _ => {}
            }
        }
        if !body.is_empty() {
            separator = "\n\n";
        }
    }
    Ok(body)
}

/// Extract searchable slide and speaker-note text from a `.pptx` presentation in memory.
pub(super) fn pptx_text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_PPTX_ARCHIVE,
        "PPTX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(Cursor::new(bytes)).context("open PPTX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "PPTX has too many parts");
    let mut parts = numbered_parts(&archive, "ppt/slides/slide", ".xml");
    parts.extend(numbered_parts(
        &archive,
        "ppt/notesSlides/notesSlide",
        ".xml",
    ));
    ensure!(!parts.is_empty(), "PPTX has no slides");

    let mut body = String::new();
    let mut separator = "";
    'parts: for part_name in parts {
        let Ok(xml) = xml_part(&mut archive, &part_name, MAX_SLIDE_XML) else {
            continue;
        };
        let mut reader = xml_reader(&xml);
        let mut depth = 0usize;
        let mut in_text = false;
        let mut text_buf = String::new();
        loop {
            let (_, event) = reader.read_resolved_event()?;
            match event {
                Event::Start(node) => {
                    depth += 1;
                    ensure!(depth <= MAX_XML_DEPTH, "PPTX XML nesting exceeds limit");
                    if node.local_name().as_ref() == "t" {
                        in_text = true;
                        text_buf.clear();
                    }
                }
                Event::End(node) => {
                    match node.local_name().as_ref() {
                        "t" if in_text => {
                            in_text = false;
                            if !text_buf.is_empty()
                                && !append_bounded(&mut body, &mut separator, &text_buf)
                            {
                                break 'parts;
                            }
                        }
                        "p" if !body.is_empty() && separator.is_empty() => {
                            separator = "\n";
                        }
                        _ => {}
                    }
                    depth -= 1;
                }
                Event::Text(text) if in_text => text_buf.push_str(&text.xml10_content()),
                Event::CData(text) if in_text => text_buf.push_str(&text.xml10_content()),
                Event::GeneralRef(reference) if in_text => {
                    text_buf.push_str(&decode_xml_ref(reference)?);
                }
                Event::DocType(_) => bail!("DTD is forbidden in PPTX XML"),
                Event::Eof => break,
                _ => {}
            }
        }
        if !body.is_empty() {
            separator = "\n\n";
        }
    }
    Ok(body)
}

#[cfg(test)]
mod office_tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn make_zip(entries: &[(&str, &str)]) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
            for (name, content) in entries {
                zip.start_file(*name, options).unwrap();
                zip.write_all(content.as_bytes()).unwrap();
            }
            zip.finish().unwrap();
        }
        cursor.into_inner()
    }

    #[test]
    fn extracts_xlsx_shared_inline_and_numeric_cells() {
        let bytes = make_zip(&[
            (
                "xl/sharedStrings.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                     <si><t>季度营收汇总</t></si>
                     <si><t>示例科技有限公司</t></si>
                   </sst>"#,
            ),
            (
                "xl/worksheets/sheet1.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                     <sheetData>
                       <row r="1">
                         <c r="A1" t="s"><v>0</v></c>
                         <c r="B1" t="s"><v>1</v></c>
                       </row>
                       <row r="2">
                         <c r="A2" t="inlineStr"><is><t>2026Q3</t></is></c>
                         <c r="B2"><v>128500</v></c>
                       </row>
                     </sheetData>
                   </worksheet>"#,
            ),
        ]);
        let extracted = xlsx_text(&bytes).unwrap();
        assert!(extracted.contains("季度营收汇总"), "{extracted}");
        assert!(extracted.contains("示例科技有限公司"), "{extracted}");
        assert!(extracted.contains("2026Q3"), "{extracted}");
        assert!(extracted.contains("128500"), "{extracted}");
    }

    #[test]
    fn extracts_pptx_slides_and_speaker_notes_in_order() {
        let bytes = make_zip(&[
            (
                "ppt/slides/slide2.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                     <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第二页风险分析</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                   </p:sld>"#,
            ),
            (
                "ppt/slides/slide1.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                     <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第一页年度战略</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                   </p:sld>"#,
            ),
            (
                "ppt/notesSlides/notesSlide1.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                     <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>演讲备注：重点核对现金流</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                   </p:notes>"#,
            ),
        ]);
        let extracted = pptx_text(&bytes).unwrap();
        let pos1 = extracted.find("第一页年度战略").unwrap();
        let pos2 = extracted.find("第二页风险分析").unwrap();
        let pos_note = extracted.find("重点核对现金流").unwrap();
        assert!(pos1 < pos2 && pos2 < pos_note, "{extracted}");
    }
}
