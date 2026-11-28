use crate::MAX_DOCUMENT;
use anyhow::{Context, Result, bail, ensure};
use quick_xml::{
    XmlVersion, escape::resolve_xml_entity, events::Event, name::ResolveResult, reader::NsReader,
};
use std::io::{Cursor, Read, Seek, SeekFrom};
use zip::{CompressionMethod, ZipArchive, result::ZipError};

pub(super) const MAX_ARCHIVE: u64 = 64 * 1024 * 1024;
pub(super) const MAX_PPTX_ARCHIVE: u64 = 256 * 1024 * 1024;
const MAX_TOTAL_XML_BYTES: u64 = 32 * 1024 * 1024;
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

fn stream_len<R: Seek>(reader: &mut R) -> Result<u64> {
    let len = reader.seek(SeekFrom::End(0))?;
    reader.seek(SeekFrom::Start(0))?;
    Ok(len)
}

/// Interpret only two parts of the supplied package, in memory. The caller
/// obtains these archive bytes through the local-file availability checks.
#[allow(dead_code)]
pub(super) fn text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_ARCHIVE,
        "DOCX exceeds the archive limit"
    );
    text_from_reader(Cursor::new(bytes))
}

/// Stream only the relationship and main document XML parts directly from a
/// seekable archive without buffering unrelated package entries.
pub(super) fn text_from_reader<R: Read + Seek>(mut reader: R) -> Result<String> {
    ensure!(
        stream_len(&mut reader)? <= MAX_ARCHIVE,
        "DOCX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(reader).context("open DOCX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "DOCX has too many parts");
    let mut remaining_xml = MAX_TOTAL_XML_BYTES;
    let relationships = xml_part(
        &mut archive,
        "_rels/.rels",
        MAX_RELATIONSHIPS,
        &mut remaining_xml,
    )?;
    let main = main_part(&relationships)?;
    document_text(&xml_part(
        &mut archive,
        &main,
        MAX_MAIN_XML,
        &mut remaining_xml,
    )?)
}

fn xml_part<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    limit: u64,
    remaining_xml: &mut u64,
) -> Result<String> {
    let file = archive.by_name(name).context("missing DOCX XML part")?;
    decode_xml_entry(file, limit, remaining_xml)
}

fn optional_xml_part<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    limit: u64,
    remaining_xml: &mut u64,
) -> Result<Option<String>> {
    match archive.by_name(name) {
        Ok(file) => decode_xml_entry(file, limit, remaining_xml).map(Some),
        Err(ZipError::FileNotFound) => Ok(None),
        Err(error) => Err(error).context("open Office XML part"),
    }
}

fn decode_xml_entry<R: Read>(
    file: zip::read::ZipFile<'_, R>,
    limit: u64,
    remaining_xml: &mut u64,
) -> Result<String> {
    ensure!(
        file.is_file()
            && matches!(
                file.compression(),
                CompressionMethod::Stored | CompressionMethod::Deflated
            )
            && file.size() <= limit,
        "unsupported DOCX part or XML size exceeds limit"
    );
    ensure!(
        file.size() <= *remaining_xml,
        "Office XML exceeds aggregate decompression budget"
    );
    let cap = limit.min(*remaining_xml);
    let mut bytes = Vec::new();
    file.take(cap + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= limit,
        "DOCX XML exceeds decompression limit"
    );
    ensure!(
        bytes.len() as u64 <= *remaining_xml,
        "Office XML exceeds aggregate decompression budget"
    );
    *remaining_xml -= bytes.len() as u64;
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
const MAX_WORKBOOK_XML: u64 = 4 * 1024 * 1024;
const MAX_SLIDE_XML: u64 = 4 * 1024 * 1024;
const MAX_PREVIEW_SHEETS: usize = 24;
const MAX_PREVIEW_ROWS: usize = 1500;
const MAX_PREVIEW_COLS: usize = 64;
const MAX_CELL_CHARS: usize = 500;
const MAX_TOTAL_CELLS: usize = 40_000;

#[derive(serde::Serialize)]
struct XlsxPreview {
    sheets: Vec<XlsxPreviewSheet>,
}

#[derive(serde::Serialize)]
struct XlsxPreviewSheet {
    name: String,
    rows: Vec<Vec<String>>,
    truncated: bool,
}

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

fn numbered_parts<R: Read + Seek>(
    archive: &ZipArchive<R>,
    prefix: &str,
    suffix: &str,
) -> Vec<String> {
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
#[cfg_attr(not(test), allow(dead_code))]
pub(super) fn xlsx_text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_ARCHIVE,
        "XLSX exceeds the archive limit"
    );
    xlsx_text_from_reader(Cursor::new(bytes))
}

/// Stream shared strings and worksheet XML directly from a seekable `.xlsx`
/// archive without buffering media or other unrelated package entries.
pub(super) fn xlsx_text_from_reader<R: Read + Seek>(mut reader: R) -> Result<String> {
    ensure!(
        stream_len(&mut reader)? <= MAX_ARCHIVE,
        "XLSX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(reader).context("open XLSX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "XLSX has too many parts");
    let mut remaining_xml = MAX_TOTAL_XML_BYTES;
    let shared = match optional_xml_part(
        &mut archive,
        "xl/sharedStrings.xml",
        MAX_SHARED_STRINGS_XML,
        &mut remaining_xml,
    )? {
        Some(xml) => parse_shared_strings(&xml)?,
        None => Vec::new(),
    };
    let sheets = numbered_parts(&archive, "xl/worksheets/sheet", ".xml");
    ensure!(!sheets.is_empty(), "XLSX has no worksheets");

    let mut body = String::new();
    let mut separator = "";
    'sheets: for sheet_name in sheets {
        let xml = xml_part(&mut archive, &sheet_name, MAX_SHEET_XML, &mut remaining_xml)?;
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

fn normalize_workbook_target(target: &str) -> Option<String> {
    let trimmed = target.trim().strip_prefix('/').unwrap_or(target.trim());
    if trimmed.is_empty()
        || trimmed.contains(['\\', ':', '#', '?'])
        || trimmed.chars().any(char::is_control)
        || trimmed
            .split('/')
            .any(|component| matches!(component, "" | "." | ".."))
    {
        return None;
    }
    if trimmed.starts_with("xl/") {
        Some(trimmed.to_owned())
    } else {
        Some(format!("xl/{trimmed}"))
    }
}

fn parse_workbook_rels(xml: &str) -> Result<std::collections::HashMap<String, String>> {
    let mut reader = xml_reader(xml);
    let mut depth = 0usize;
    let mut rels = std::collections::HashMap::new();
    loop {
        let (_, event) = reader.read_resolved_event()?;
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(depth <= MAX_XML_DEPTH, "XLSX XML nesting exceeds limit");
                if node.local_name().as_ref() == "Relationship" {
                    let mut id = None;
                    let mut target = None;
                    let mut target_mode = None;
                    for attr in node.attributes() {
                        let attr = attr?;
                        match attr.key.local_name().as_ref() {
                            "Id" => {
                                id = Some(
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned(),
                                );
                            }
                            "Target" => {
                                target = Some(
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned(),
                                );
                            }
                            "TargetMode" => {
                                target_mode = Some(
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned(),
                                );
                            }
                            _ => {}
                        }
                    }
                    if matches!(target_mode.as_deref(), None | Some("Internal"))
                        && let (Some(id), Some(target)) = (id, target)
                        && let Some(normalized) = normalize_workbook_target(&target)
                    {
                        rels.insert(id, normalized);
                    }
                }
            }
            Event::End(_) => depth -= 1,
            Event::DocType(_) => bail!("DTD is forbidden in XLSX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(rels)
}

fn parse_workbook_sheets(xml: &str) -> Result<Vec<(String, String)>> {
    let mut reader = xml_reader(xml);
    let mut depth = 0usize;
    let mut sheets = Vec::new();
    loop {
        let (_, event) = reader.read_resolved_event()?;
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(depth <= MAX_XML_DEPTH, "XLSX XML nesting exceeds limit");
                if node.local_name().as_ref() == "sheet" {
                    let mut name = None;
                    let mut rel_id = None;
                    for attr in node.attributes() {
                        let attr = attr?;
                        match attr.key.local_name().as_ref() {
                            "name" => {
                                name = Some(
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned(),
                                );
                            }
                            "id" => {
                                rel_id = Some(
                                    attr.normalized_value(XmlVersion::Implicit1_0)?.into_owned(),
                                );
                            }
                            _ => {}
                        }
                    }
                    if let Some(rel_id) = rel_id {
                        let sheet_name = name
                            .filter(|s| !s.trim().is_empty())
                            .unwrap_or_else(|| format!("Sheet {}", sheets.len() + 1));
                        sheets.push((sheet_name, rel_id));
                    }
                }
            }
            Event::End(_) => depth -= 1,
            Event::DocType(_) => bail!("DTD is forbidden in XLSX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(sheets)
}

fn parse_cell_col(reference: &str) -> Option<usize> {
    let mut col = 0usize;
    let mut seen_letter = false;
    for b in reference.bytes() {
        match b {
            b'$' if !seen_letter => continue,
            b'A'..=b'Z' => {
                seen_letter = true;
                col = col
                    .saturating_mul(26)
                    .saturating_add((b - b'A' + 1) as usize);
            }
            b'a'..=b'z' => {
                seen_letter = true;
                col = col
                    .saturating_mul(26)
                    .saturating_add((b - b'a' + 1) as usize);
            }
            _ => break,
        }
    }
    seen_letter.then(|| col - 1)
}

fn truncate_cell_text(text: &str) -> String {
    match text.char_indices().nth(MAX_CELL_CHARS) {
        Some((byte_idx, _)) => {
            let mut out = String::with_capacity(byte_idx + '…'.len_utf8());
            out.push_str(&text[..byte_idx]);
            out.push('…');
            out
        }
        None => text.to_owned(),
    }
}

fn parse_preview_sheet(
    xml: &str,
    shared: &[String],
    total_cells: &mut usize,
    initial_truncated: bool,
) -> Result<(Vec<Vec<String>>, bool)> {
    let mut reader = xml_reader(xml);
    let mut depth = 0usize;
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut current_row: Vec<String> = Vec::new();
    let mut in_row = false;
    let mut next_col = 0usize;
    let mut in_c = false;
    let mut cell_col = 0usize;
    let mut cell_type = String::new();
    let mut in_v = false;
    let mut in_is = false;
    let mut in_is_t = false;
    let mut v_buf = String::new();
    let mut is_buf = String::new();
    let mut truncated = initial_truncated;

    loop {
        let (_, event) = reader.read_resolved_event()?;
        match event {
            Event::Start(node) => {
                depth += 1;
                ensure!(depth <= MAX_XML_DEPTH, "XLSX XML nesting exceeds limit");
                match node.local_name().as_ref() {
                    "row" => {
                        in_row = true;
                        current_row.clear();
                        next_col = 0;
                    }
                    "c" if in_row => {
                        in_c = true;
                        in_v = false;
                        in_is = false;
                        in_is_t = false;
                        cell_type.clear();
                        v_buf.clear();
                        is_buf.clear();
                        let mut parsed_col = None;
                        for attr in node.attributes() {
                            let attr = attr?;
                            match attr.key.local_name().as_ref() {
                                "t" => {
                                    cell_type = attr
                                        .normalized_value(XmlVersion::Implicit1_0)?
                                        .into_owned();
                                }
                                "r" => {
                                    let r_val = attr.normalized_value(XmlVersion::Implicit1_0)?;
                                    parsed_col = parse_cell_col(&r_val);
                                }
                                _ => {}
                            }
                        }
                        cell_col = parsed_col.unwrap_or(next_col);
                        next_col = cell_col.saturating_add(1);
                    }
                    "v" if in_c => {
                        in_v = true;
                        v_buf.clear();
                    }
                    "is" if in_c => {
                        in_is = true;
                    }
                    "t" if in_c && (in_is || cell_type == "inlineStr") => {
                        in_is_t = true;
                    }
                    _ => {}
                }
            }
            Event::End(node) => {
                match node.local_name().as_ref() {
                    "v" if in_v => {
                        in_v = false;
                    }
                    "t" if in_is_t => {
                        in_is_t = false;
                    }
                    "is" if in_is => {
                        in_is = false;
                        in_is_t = false;
                    }
                    "c" if in_c => {
                        in_c = false;
                        in_v = false;
                        in_is = false;
                        in_is_t = false;
                        let resolved = if cell_type == "inlineStr" || !is_buf.is_empty() {
                            is_buf.trim()
                        } else if cell_type == "s" {
                            v_buf
                                .trim()
                                .parse::<usize>()
                                .ok()
                                .and_then(|idx| shared.get(idx))
                                .map(|s| s.trim())
                                .unwrap_or("")
                        } else if cell_type == "b" {
                            match v_buf.trim() {
                                "1" | "true" | "TRUE" => "TRUE",
                                "0" | "false" | "FALSE" => "FALSE",
                                other => other,
                            }
                        } else {
                            v_buf.trim()
                        };
                        if !resolved.is_empty() {
                            if cell_col >= MAX_PREVIEW_COLS {
                                truncated = true;
                            } else {
                                if current_row.len() <= cell_col {
                                    current_row.resize_with(cell_col + 1, String::new);
                                }
                                current_row[cell_col] = truncate_cell_text(resolved);
                            }
                        } else if cell_col >= MAX_PREVIEW_COLS {
                            truncated = true;
                        }
                        cell_type.clear();
                    }
                    "row" if in_row => {
                        in_row = false;
                        while current_row.last().is_some_and(String::is_empty) {
                            current_row.pop();
                        }
                        if !current_row.is_empty() {
                            if rows.len() >= MAX_PREVIEW_ROWS || *total_cells >= MAX_TOTAL_CELLS {
                                truncated = true;
                            } else {
                                let remaining_cells = MAX_TOTAL_CELLS - *total_cells;
                                if current_row.len() > remaining_cells {
                                    current_row.truncate(remaining_cells);
                                    truncated = true;
                                }
                                *total_cells += current_row.len();
                                rows.push(std::mem::take(&mut current_row));
                            }
                        }
                    }
                    _ => {}
                }
                depth -= 1;
            }
            Event::Text(text) if in_v || in_is_t => {
                let target = if in_v { &mut v_buf } else { &mut is_buf };
                target.push_str(&text.xml10_content());
            }
            Event::CData(text) if in_v || in_is_t => {
                let target = if in_v { &mut v_buf } else { &mut is_buf };
                target.push_str(&text.xml10_content());
            }
            Event::GeneralRef(reference) if in_v || in_is_t => {
                let decoded = decode_xml_ref(reference)?;
                let target = if in_v { &mut v_buf } else { &mut is_buf };
                target.push_str(&decoded);
            }
            Event::DocType(_) => bail!("DTD is forbidden in XLSX XML"),
            Event::Eof => break,
            _ => {}
        }
    }
    Ok((rows, truncated))
}

/// Extract bounded structured preview sheets and rows from an `.xlsx` workbook
/// in memory as compact JSON for native table rendering.
pub fn xlsx_preview_json(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_ARCHIVE,
        "XLSX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(Cursor::new(bytes)).context("open XLSX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "XLSX has too many parts");
    let mut remaining_xml = MAX_TOTAL_XML_BYTES;
    let shared = match optional_xml_part(
        &mut archive,
        "xl/sharedStrings.xml",
        MAX_SHARED_STRINGS_XML,
        &mut remaining_xml,
    )? {
        Some(xml) => parse_shared_strings(&xml)?,
        None => Vec::new(),
    };

    let workbook_xml = optional_xml_part(
        &mut archive,
        "xl/workbook.xml",
        MAX_WORKBOOK_XML,
        &mut remaining_xml,
    )?;
    let workbook_rels_xml = optional_xml_part(
        &mut archive,
        "xl/_rels/workbook.xml.rels",
        MAX_RELATIONSHIPS,
        &mut remaining_xml,
    )?;

    let mut resolved = Vec::new();
    if let (Some(wb_xml), Some(rels_xml)) = (workbook_xml.as_deref(), workbook_rels_xml.as_deref())
    {
        let rels = parse_workbook_rels(rels_xml)?;
        for (name, rel_id) in parse_workbook_sheets(wb_xml)? {
            if let Some(target) = rels.get(&rel_id)
                && archive.index_for_name(target).is_some()
            {
                resolved.push((name, target.clone()));
            }
        }
    }
    if resolved.is_empty() {
        resolved = numbered_parts(&archive, "xl/worksheets/sheet", ".xml")
            .into_iter()
            .enumerate()
            .map(|(idx, part)| (format!("Sheet {}", idx + 1), part))
            .collect();
    }
    ensure!(!resolved.is_empty(), "XLSX has no worksheets");

    let sheets_truncated = resolved.len() > MAX_PREVIEW_SHEETS;
    if sheets_truncated {
        resolved.truncate(MAX_PREVIEW_SHEETS);
    }

    let mut total_cells = 0usize;
    let mut sheets = Vec::with_capacity(resolved.len());
    for (sheet_name, part_name) in resolved {
        let xml = xml_part(&mut archive, &part_name, MAX_SHEET_XML, &mut remaining_xml)?;
        let (rows, truncated) =
            parse_preview_sheet(&xml, &shared, &mut total_cells, sheets_truncated)?;
        sheets.push(XlsxPreviewSheet {
            name: truncate_cell_text(&sheet_name),
            rows,
            truncated,
        });
    }

    Ok(serde_json::to_string(&XlsxPreview { sheets })?)
}

/// Extract searchable slide and speaker-note text from a `.pptx` presentation in memory.
#[cfg_attr(not(test), allow(dead_code))]
pub(super) fn pptx_text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_PPTX_ARCHIVE,
        "PPTX exceeds the archive limit"
    );
    pptx_text_from_reader(Cursor::new(bytes))
}

/// Stream only slide and speaker-note XML parts from a seekable `.pptx`
/// archive, skipping `ppt/media/*` without buffering the whole archive.
pub(super) fn pptx_text_from_reader<R: Read + Seek>(mut reader: R) -> Result<String> {
    ensure!(
        stream_len(&mut reader)? <= MAX_PPTX_ARCHIVE,
        "PPTX exceeds the archive limit"
    );
    let mut archive = ZipArchive::new(reader).context("open PPTX archive")?;
    ensure!(archive.len() <= MAX_ENTRIES, "PPTX has too many parts");
    let mut remaining_xml = MAX_TOTAL_XML_BYTES;
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
        let xml = xml_part(&mut archive, &part_name, MAX_SLIDE_XML, &mut remaining_xml)?;
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

    #[test]
    fn streams_large_pptx_file_skipping_media_entries() {
        let root = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-pptx-stream-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("deck.pptx");
        {
            let file = std::fs::File::create(&path).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
            zip.start_file("ppt/media/blob.bin", stored).unwrap();
            let chunk = vec![0xABu8; 1024 * 1024];
            for _ in 0..21 {
                zip.write_all(&chunk).unwrap();
            }
            let deflated =
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
            zip.start_file("ppt/slides/slide1.xml", deflated).unwrap();
            zip.write_all(
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                     <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>流式解析大型演示文稿</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                   </p:sld>"#
                    .as_bytes(),
            )
            .unwrap();
            zip.finish().unwrap();
        }
        assert!(std::fs::metadata(&path).unwrap().len() > 20 * 1024 * 1024);
        let file = std::fs::File::open(&path).unwrap();
        let extracted = pptx_text_from_reader(file).unwrap();
        assert!(extracted.contains("流式解析大型演示文稿"), "{extracted}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_multipart_xml_exceeding_total_decompression_budget() {
        // Each slide is ~3 MiB (< MAX_SLIDE_XML = 4 MiB), but 12 slides total ~36 MiB
        // (> MAX_TOTAL_XML_BYTES = 32 MiB) while compressing to a few kilobytes.
        let padding = " ".repeat(3 * 1024 * 1024);
        let slide_xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
               <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                      xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                 <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>slide</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                 <!--{padding}-->
               </p:sld>"#
        );
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
            for i in 1..=12 {
                zip.start_file(format!("ppt/slides/slide{i}.xml"), options)
                    .unwrap();
                zip.write_all(slide_xml.as_bytes()).unwrap();
            }
            zip.finish().unwrap();
        }
        let err = pptx_text(&cursor.into_inner()).unwrap_err();
        assert!(
            err.to_string().contains("budget"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn extracts_docx_via_slice_and_streaming_reader() {
        let bytes = make_zip(&[
            (
                "_rels/.rels",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                     <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
                   </Relationships>"#,
            ),
            (
                "word/document.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                     <w:body><w:p><w:r><w:t>合同正文摘要</w:t></w:r></w:p></w:body>
                   </w:document>"#,
            ),
        ]);
        assert_eq!(text(&bytes).unwrap(), "合同正文摘要");
        assert_eq!(
            text_from_reader(Cursor::new(&bytes)).unwrap(),
            "合同正文摘要"
        );
    }

    #[test]
    fn xlsx_preview_json_resolves_multi_sheet_chinese_names_sparse_cols_and_cell_types() {
        let bytes = make_zip(&[
            (
                "xl/workbook.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                             xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                     <sheets>
                       <sheet r:id="rId2" sheetId="2" name="季度预算"/>
                       <sheet name="概览" sheetId="1" r:id="rId1"/>
                     </sheets>
                   </workbook>"#,
            ),
            (
                "xl/_rels/workbook.xml.rels",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                     <Relationship Target="/xl/worksheets/sheet2.xml" Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>
                     <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                   </Relationships>"#,
            ),
            (
                "xl/sharedStrings.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                     <si><t>总收入</t></si>
                     <si><r><t>研发</t></r><r><t>预算</t></r></si>
                   </sst>"#,
            ),
            (
                "xl/worksheets/sheet2.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                     <sheetData>
                       <row r="1">
                         <c r="A1" t="s"><v>1</v></c>
                         <c r="C1" t="inlineStr"><is><r><t>1200</t></r><r><t>万</t></r></is></c>
                       </row>
                       <row r="2">
                         <c r="A2" t="b"><v>1</v></c>
                         <c r="B2" t="b"><v>0</v></c>
                         <c r="C2" t="str"><f>A1</f><v>达标</v></c>
                         <c r="D2" t="e"><v>#DIV/0!</v></c>
                         <c r="E2"><v>98.5</v></c>
                       </row>
                     </sheetData>
                   </worksheet>"#,
            ),
            (
                "xl/worksheets/sheet1.xml",
                r#"<?xml version="1.0" encoding="UTF-8"?>
                   <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                     <sheetData>
                       <row r="1">
                         <c t="s" r="A1"><v>0</v></c>
                         <c><v>5000</v></c>
                         <c r="D1"/>
                       </row>
                     </sheetData>
                   </worksheet>"#,
            ),
        ]);

        let json: serde_json::Value =
            serde_json::from_str(&xlsx_preview_json(&bytes).unwrap()).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "sheets": [
                    {
                        "name": "季度预算",
                        "rows": [
                            ["研发预算", "", "1200万"],
                            ["TRUE", "FALSE", "达标", "#DIV/0!", "98.5"]
                        ],
                        "truncated": false
                    },
                    {
                        "name": "概览",
                        "rows": [
                            ["总收入", "5000"]
                        ],
                        "truncated": false
                    }
                ]
            })
        );
    }

    #[test]
    fn xlsx_preview_json_enforces_truncation_bounds_and_fallback_names() {
        let long_cell = "算".repeat(MAX_CELL_CHARS + 25);
        let expected_cell = format!("{}…", "算".repeat(MAX_CELL_CHARS));
        let sheet_xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
               <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                 <sheetData>
                   <row r="1">
                     <c r="A1" t="inlineStr"><is><t>{long_cell}</t></is></c>
                     <c r="BM1" t="inlineStr"><is><t>超出列上限</t></is></c>
                   </row>
                 </sheetData>
               </worksheet>"#
        );
        let bytes = make_zip(&[("xl/worksheets/sheet1.xml", &sheet_xml)]);
        let json: serde_json::Value =
            serde_json::from_str(&xlsx_preview_json(&bytes).unwrap()).unwrap();
        assert_eq!(json["sheets"][0]["name"], "Sheet 1");
        assert_eq!(json["sheets"][0]["truncated"], true);
        assert_eq!(json["sheets"][0]["rows"][0][0], expected_cell);
        assert_eq!(json["sheets"][0]["rows"][0].as_array().unwrap().len(), 1);
    }
}
