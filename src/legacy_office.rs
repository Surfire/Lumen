//! Pure-Rust, zero-dependency, zero-subprocess extractors for legacy Microsoft
//! Office OLE2 containers (`.doc`, `.xls`, `.ppt`), Rich Text Format (`.rtf`),
//! and subtitle transcripts (`.srt`, `.vtt`).

use crate::MAX_DOCUMENT;
use anyhow::{Context, Result, bail, ensure};
use std::io::{Read, Seek, SeekFrom};

pub(super) const MAX_LEGACY_OFFICE: u64 = 64 * 1024 * 1024;
pub(super) const MAX_RTF: u64 = 16 * 1024 * 1024;
pub(super) const MAX_SUBTITLE: u64 = 8 * 1024 * 1024;

const MAX_STREAM_BYTES: usize = 32 * 1024 * 1024;
const MAX_PPT_DEPTH: usize = 64;
const MAX_RTF_DEPTH: usize = 256;

const CFBF_MAGIC: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
const MAXREGSECT: u32 = 0xFFFF_FFFA;
const DIFSECT: u32 = 0xFFFF_FFFC;
const FATSECT: u32 = 0xFFFF_FFFD;
const ENDOFCHAIN: u32 = 0xFFFF_FFFE;
const FREESECT: u32 = 0xFFFF_FFFF;

const CP1252_HIGH: [char; 32] = [
    '\u{20AC}', '\u{0081}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{02C6}', '\u{2030}', '\u{0160}', '\u{2039}', '\u{0152}', '\u{008D}', '\u{017D}', '\u{008F}',
    '\u{0090}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{02DC}', '\u{2122}', '\u{0161}', '\u{203A}', '\u{0153}', '\u{009D}', '\u{017E}', '\u{0178}',
];

pub(crate) fn cp1252_byte(b: u8) -> char {
    if (0x80..=0x9F).contains(&b) {
        CP1252_HIGH[(b - 0x80) as usize]
    } else {
        b as char
    }
}

fn read_u16_le(buf: &[u8], off: usize) -> Result<u16> {
    let slice = buf
        .get(off..off + 2)
        .context("unexpected EOF reading u16")?;
    Ok(u16::from_le_bytes([slice[0], slice[1]]))
}

fn read_u32_le(buf: &[u8], off: usize) -> Result<u32> {
    let slice = buf
        .get(off..off + 4)
        .context("unexpected EOF reading u32")?;
    Ok(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_u64_le(buf: &[u8], off: usize) -> Result<u64> {
    let slice = buf
        .get(off..off + 8)
        .context("unexpected EOF reading u64")?;
    Ok(u64::from_le_bytes([
        slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
    ]))
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

fn append_char_bounded(body: &mut String, ch: char) -> bool {
    let mut encoded = [0u8; 4];
    let s = ch.encode_utf8(&mut encoded);
    if body.len() + s.len() > MAX_DOCUMENT as usize {
        return false;
    }
    body.push_str(s);
    true
}

#[derive(Debug, Clone)]
struct DirEntry {
    name: String,
    obj_type: u8,
    start_sector: u32,
    size: u64,
}

/// Streaming MS-CFB / OLE2 Compound File Binary reader with strict DIFAT, FAT,
/// and MiniFAT cycle detection and per-stream memory bounds.
pub(crate) struct Ole2Archive<R: Read + Seek> {
    reader: R,
    file_len: u64,
    sector_size: usize,
    mini_sector_size: usize,
    mini_cutoff: u64,
    fat: Vec<u32>,
    mini_fat: Vec<u32>,
    entries: Vec<DirEntry>,
    mini_stream: Option<Vec<u8>>,
}

impl<R: Read + Seek> Ole2Archive<R> {
    pub(crate) fn open(mut reader: R) -> Result<Self> {
        let file_len = reader.seek(SeekFrom::End(0))?;
        ensure!(
            (512..=MAX_LEGACY_OFFICE).contains(&file_len),
            "OLE2 file size out of bounds"
        );
        reader.seek(SeekFrom::Start(0))?;
        let mut header = [0u8; 512];
        reader
            .read_exact(&mut header)
            .context("read OLE2 CFBF header")?;
        ensure!(header[0..8] == CFBF_MAGIC, "invalid OLE2 CFBF signature");

        let major_version = read_u16_le(&header, 26)?;
        let byte_order = read_u16_le(&header, 28)?;
        let sector_shift = read_u16_le(&header, 30)?;
        let mini_sector_shift = read_u16_le(&header, 32)?;
        ensure!(byte_order == 0xFFFE, "unsupported OLE2 byte order");
        ensure!(
            (major_version == 3 && sector_shift == 9) || (major_version == 4 && sector_shift == 12),
            "unsupported OLE2 version or sector shift"
        );
        ensure!(mini_sector_shift == 6, "unsupported OLE2 mini-sector shift");

        let sector_size = 1usize << sector_shift;
        let mini_sector_size = 1usize << mini_sector_shift;
        ensure!(file_len >= sector_size as u64, "truncated OLE2 header");

        let num_fat_sectors = read_u32_le(&header, 44)? as usize;
        let first_dir_sector = read_u32_le(&header, 48)?;
        let mini_cutoff = read_u32_le(&header, 56)? as u64;
        let first_mini_fat_sector = read_u32_le(&header, 60)?;
        let num_mini_fat_sectors = read_u32_le(&header, 64)? as usize;
        let first_difat_sector = read_u32_le(&header, 68)?;
        let num_difat_sectors = read_u32_le(&header, 72)? as usize;

        ensure!(mini_cutoff <= 65_536, "invalid OLE2 mini-stream cutoff");
        let total_sectors = (file_len - sector_size as u64).div_ceil(sector_size as u64) as usize;
        ensure!(
            num_fat_sectors > 0
                && num_fat_sectors <= total_sectors.max(1)
                && num_fat_sectors <= 4096,
            "invalid OLE2 FAT sector count"
        );
        ensure!(
            num_difat_sectors <= total_sectors && num_difat_sectors <= 1024,
            "invalid OLE2 DIFAT sector count"
        );
        ensure!(
            num_mini_fat_sectors <= total_sectors && num_mini_fat_sectors <= 4096,
            "invalid OLE2 MiniFAT sector count"
        );

        // Collect FAT sector IDs from header DIFAT (109 entries) + DIFAT chain.
        let mut fat_sector_ids = Vec::with_capacity(num_fat_sectors);
        for i in 0..109 {
            if fat_sector_ids.len() >= num_fat_sectors {
                break;
            }
            let sid = read_u32_le(&header, 76 + i * 4)?;
            if sid == FREESECT || sid == ENDOFCHAIN {
                continue;
            }
            ensure!(
                sid <= MAXREGSECT && (sid as usize) < total_sectors,
                "OLE2 header DIFAT sector out of bounds"
            );
            fat_sector_ids.push(sid);
        }

        if fat_sector_ids.len() < num_fat_sectors
            && first_difat_sector != ENDOFCHAIN
            && first_difat_sector != FREESECT
        {
            let mut visited_difat = vec![false; total_sectors];
            let mut cur = first_difat_sector;
            let mut steps = 0usize;
            let entries_per_difat = (sector_size / 4) - 1;
            let mut sec_buf = vec![0u8; sector_size];
            while cur != ENDOFCHAIN && cur != FREESECT {
                ensure!(
                    cur <= MAXREGSECT && (cur as usize) < total_sectors,
                    "OLE2 DIFAT sector out of bounds"
                );
                ensure!(!visited_difat[cur as usize], "cyclic OLE2 DIFAT chain");
                visited_difat[cur as usize] = true;
                steps += 1;
                ensure!(
                    steps <= num_difat_sectors.max(1),
                    "OLE2 DIFAT chain exceeds header count"
                );
                read_sector_into(&mut reader, file_len, sector_size, cur, &mut sec_buf)?;
                for i in 0..entries_per_difat {
                    if fat_sector_ids.len() >= num_fat_sectors {
                        break;
                    }
                    let sid = read_u32_le(&sec_buf, i * 4)?;
                    if sid == FREESECT || sid == ENDOFCHAIN {
                        continue;
                    }
                    ensure!(
                        sid <= MAXREGSECT && (sid as usize) < total_sectors,
                        "OLE2 DIFAT entry out of bounds"
                    );
                    fat_sector_ids.push(sid);
                }
                cur = read_u32_le(&sec_buf, entries_per_difat * 4)?;
            }
        }
        ensure!(
            fat_sector_ids.len() == num_fat_sectors,
            "OLE2 DIFAT missing FAT sectors"
        );

        // Read all FAT sectors.
        let entries_per_fat = sector_size / 4;
        let mut fat = Vec::with_capacity(fat_sector_ids.len() * entries_per_fat);
        let mut sec_buf = vec![0u8; sector_size];
        for sid in fat_sector_ids {
            read_sector_into(&mut reader, file_len, sector_size, sid, &mut sec_buf)?;
            for &chunk in sec_buf.as_chunks::<4>().0 {
                fat.push(u32::from_le_bytes(chunk));
            }
        }

        // Read Directory stream following FAT chain with cycle detection.
        let max_dir_sectors = (MAX_STREAM_BYTES / sector_size).min(total_sectors.max(1));
        let dir_chain = collect_chain(&fat, first_dir_sector, max_dir_sectors, "Directory FAT")?;
        ensure!(!dir_chain.is_empty(), "missing OLE2 directory stream");
        let dir_bytes = read_chain_bytes(
            &mut reader,
            file_len,
            sector_size,
            &dir_chain,
            dir_chain.len() * sector_size,
        )?;
        let mut entries = Vec::with_capacity(dir_bytes.len() / 128);
        for raw in dir_bytes.as_chunks::<128>().0 {
            let obj_type = raw[66];
            if obj_type == 0 {
                entries.push(DirEntry {
                    name: String::new(),
                    obj_type,
                    start_sector: ENDOFCHAIN,
                    size: 0,
                });
                continue;
            }
            let name_len = (read_u16_le(raw, 64)? as usize).min(64);
            let char_bytes = name_len.saturating_sub(2) & !1;
            let units: Vec<u16> = raw[..char_bytes]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|&c| u16::from_le_bytes(c))
                .collect();
            let name = String::from_utf16_lossy(&units);
            let start_sector = read_u32_le(raw, 116)?;
            let size = if major_version == 3 {
                read_u32_le(raw, 120)? as u64
            } else {
                read_u64_le(raw, 120)?
            };
            entries.push(DirEntry {
                name,
                obj_type,
                start_sector,
                size,
            });
        }
        ensure!(
            entries.first().is_some_and(|e| e.obj_type == 5),
            "missing OLE2 root storage entry"
        );

        // Read MiniFAT if present.
        let mut mini_fat = Vec::new();
        if first_mini_fat_sector != ENDOFCHAIN
            && first_mini_fat_sector != FREESECT
            && num_mini_fat_sectors > 0
        {
            let max_mf = num_mini_fat_sectors.min(MAX_STREAM_BYTES / sector_size);
            let mf_chain = collect_chain(&fat, first_mini_fat_sector, max_mf, "MiniFAT")?;
            let mf_bytes = read_chain_bytes(
                &mut reader,
                file_len,
                sector_size,
                &mf_chain,
                mf_chain.len() * sector_size,
            )?;
            mini_fat.reserve(mf_bytes.len() / 4);
            for &chunk in mf_bytes.as_chunks::<4>().0 {
                mini_fat.push(u32::from_le_bytes(chunk));
            }
        }

        Ok(Self {
            reader,
            file_len,
            sector_size,
            mini_sector_size,
            mini_cutoff,
            fat,
            mini_fat,
            entries,
            mini_stream: None,
        })
    }

    pub(crate) fn read_stream(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        let Some(entry) = self
            .entries
            .iter()
            .find(|e| e.obj_type == 2 && e.name.eq_ignore_ascii_case(name))
            .cloned()
        else {
            return Ok(None);
        };
        ensure!(
            entry.size <= MAX_STREAM_BYTES as u64,
            "OLE2 stream exceeds 32 MiB cap"
        );
        let size = entry.size as usize;
        if size == 0 {
            return Ok(Some(Vec::new()));
        }
        if entry.size < self.mini_cutoff {
            self.ensure_mini_stream()?;
            let mini_stream = self.mini_stream.as_deref().unwrap_or(&[]);
            let max_mini_sectors = (MAX_STREAM_BYTES / self.mini_sector_size) + 2;
            let chain = collect_chain(
                &self.mini_fat,
                entry.start_sector,
                max_mini_sectors,
                "MiniFAT",
            )?;
            ensure!(
                chain.len().saturating_mul(self.mini_sector_size) >= size,
                "truncated OLE2 mini-stream chain"
            );
            let mut out = Vec::with_capacity(size);
            let mut left = size;
            for sid in chain {
                if left == 0 {
                    break;
                }
                let start = (sid as usize)
                    .checked_mul(self.mini_sector_size)
                    .context("OLE2 mini-sector offset overflow")?;
                let take = left.min(self.mini_sector_size);
                let slice = mini_stream
                    .get(start..start + take)
                    .context("OLE2 mini-sector out of bounds")?;
                out.extend_from_slice(slice);
                left -= take;
            }
            return Ok(Some(out));
        }

        let max_sectors = (MAX_STREAM_BYTES / self.sector_size) + 2;
        let chain = collect_chain(&self.fat, entry.start_sector, max_sectors, "FAT")?;
        ensure!(
            chain.len().saturating_mul(self.sector_size) >= size,
            "truncated OLE2 FAT stream chain"
        );
        let data = read_chain_bytes(
            &mut self.reader,
            self.file_len,
            self.sector_size,
            &chain,
            size,
        )?;
        Ok(Some(data))
    }

    fn ensure_mini_stream(&mut self) -> Result<()> {
        if self.mini_stream.is_some() {
            return Ok(());
        }
        let root = self.entries[0].clone();
        ensure!(
            root.size <= MAX_STREAM_BYTES as u64,
            "OLE2 mini-stream exceeds size cap"
        );
        if root.size == 0 || root.start_sector == ENDOFCHAIN || root.start_sector == FREESECT {
            self.mini_stream = Some(Vec::new());
            return Ok(());
        }
        let max_sectors = (MAX_STREAM_BYTES / self.sector_size) + 2;
        let chain = collect_chain(&self.fat, root.start_sector, max_sectors, "MiniStream FAT")?;
        let data = read_chain_bytes(
            &mut self.reader,
            self.file_len,
            self.sector_size,
            &chain,
            root.size as usize,
        )?;
        self.mini_stream = Some(data);
        Ok(())
    }
}

fn read_sector_into<R: Read + Seek>(
    reader: &mut R,
    file_len: u64,
    sector_size: usize,
    sid: u32,
    buf: &mut [u8],
) -> Result<()> {
    let offset = (sid as u64 + 1)
        .checked_mul(sector_size as u64)
        .context("OLE2 sector offset overflow")?;
    ensure!(offset < file_len, "OLE2 sector offset beyond EOF");
    let avail = (file_len - offset).min(sector_size as u64) as usize;
    reader.seek(SeekFrom::Start(offset))?;
    reader
        .read_exact(&mut buf[..avail])
        .context("read OLE2 sector")?;
    if avail < sector_size {
        buf[avail..].fill(0);
    }
    Ok(())
}

fn read_chain_bytes<R: Read + Seek>(
    reader: &mut R,
    file_len: u64,
    sector_size: usize,
    chain: &[u32],
    size: usize,
) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(size);
    let mut left = size;
    for &sid in chain {
        if left == 0 {
            break;
        }
        let offset = (sid as u64 + 1)
            .checked_mul(sector_size as u64)
            .context("OLE2 sector offset overflow")?;
        let take = left.min(sector_size);
        ensure!(
            offset
                .checked_add(take as u64)
                .is_some_and(|end| end <= file_len),
            "truncated OLE2 sector data"
        );
        reader.seek(SeekFrom::Start(offset))?;
        let start = out.len();
        out.resize(start + take, 0);
        reader
            .read_exact(&mut out[start..start + take])
            .context("read OLE2 stream sector")?;
        left -= take;
    }
    ensure!(out.len() == size, "truncated OLE2 stream");
    Ok(out)
}

fn collect_chain(table: &[u32], start: u32, max_sectors: usize, label: &str) -> Result<Vec<u32>> {
    if start == ENDOFCHAIN || start == FREESECT {
        return Ok(Vec::new());
    }
    let mut visited = vec![false; table.len()];
    let mut chain = Vec::new();
    let mut cur = start;
    while cur != ENDOFCHAIN {
        ensure!(
            cur <= MAXREGSECT && (cur as usize) < table.len(),
            "OLE2 {label} sector out of range"
        );
        ensure!(!visited[cur as usize], "cyclic OLE2 {label} chain");
        visited[cur as usize] = true;
        chain.push(cur);
        ensure!(
            chain.len() <= max_sectors,
            "OLE2 {label} chain exceeds limit"
        );
        let next = table[cur as usize];
        if next == ENDOFCHAIN {
            break;
        }
        ensure!(
            next != FREESECT && next != FATSECT && next != DIFSECT,
            "corrupt OLE2 {label} chain entry"
        );
        cur = next;
    }
    Ok(chain)
}

/// Extract body text from a Word 97–2003 (`.doc`) OLE2 file via its FIB and
/// `Clx`/`Pcdt`/`PlcPcd` piece table.
pub(super) fn doc_text<R: Read + Seek>(reader: R) -> Result<String> {
    let mut archive = Ole2Archive::open(reader)?;
    let word_doc = archive
        .read_stream("WordDocument")?
        .context("missing WordDocument stream")?;
    ensure!(word_doc.len() >= 154, "truncated WordDocument FIB");

    let w_ident = read_u16_le(&word_doc, 0)?;
    ensure!(w_ident == 0xA5EC, "invalid Word 97-2003 FIB signature");
    let flags = read_u16_le(&word_doc, 10)?;
    ensure!(flags & 0x0100 == 0, "encrypted DOC document");
    let table_name = if flags & 0x0200 != 0 {
        "1Table"
    } else {
        "0Table"
    };

    // Walk variable-length FIB sections to locate FibRgFcLcb[33] = (fcClx, lcbClx).
    let mut pos = 32usize;
    let csw = read_u16_le(&word_doc, pos)? as usize;
    pos = pos
        .checked_add(2 + csw * 2)
        .context("DOC FIB fibRgW overflow")?;
    let cslw = read_u16_le(&word_doc, pos)? as usize;
    pos = pos
        .checked_add(2 + cslw * 4)
        .context("DOC FIB fibRgLw overflow")?;
    let cb_rg_fc_lcb = read_u16_le(&word_doc, pos)? as usize;
    pos += 2;
    ensure!(cb_rg_fc_lcb > 33, "DOC FIB missing Clx table entry");
    let clx_entry = pos + 33 * 8;
    let fc_clx = read_u32_le(&word_doc, clx_entry)? as usize;
    let lcb_clx = read_u32_le(&word_doc, clx_entry + 4)? as usize;
    ensure!(lcb_clx > 0, "empty DOC Clx table");

    let table = archive
        .read_stream(table_name)?
        .with_context(|| format!("missing DOC {table_name} stream"))?;
    let clx_end = fc_clx
        .checked_add(lcb_clx)
        .context("DOC Clx offset overflow")?;
    let clx = table
        .get(fc_clx..clx_end)
        .context("DOC Clx slice out of bounds")?;

    // Skip optional Prc (0x01) records until Pcdt (0x02).
    let mut cpos = 0usize;
    while cpos < clx.len() && clx[cpos] == 0x01 {
        let cb_grpprl = read_u16_le(clx, cpos + 1)? as usize;
        cpos = cpos
            .checked_add(3 + cb_grpprl)
            .context("DOC Prc length overflow")?;
    }
    ensure!(
        clx.get(cpos) == Some(&0x02),
        "missing Pcdt marker in DOC Clx"
    );
    let pcdt_lcb = read_u32_le(clx, cpos + 1)? as usize;
    let plc_end = (cpos + 5)
        .checked_add(pcdt_lcb)
        .context("DOC PlcPcd length overflow")?;
    let plc_pcd = clx
        .get(cpos + 5..plc_end)
        .context("DOC PlcPcd out of bounds")?;
    ensure!(
        pcdt_lcb >= 4 && (pcdt_lcb - 4).is_multiple_of(12),
        "invalid DOC PlcPcd size"
    );
    let pieces = (pcdt_lcb - 4) / 12;

    let mut out = String::new();
    let mut field_stack: Vec<bool> = Vec::new();
    let mut prev_cell = false;

    let mut push_doc_char = |ch: char| -> bool {
        match ch {
            '\u{0013}' => {
                prev_cell = false;
                field_stack.push(true);
                return true;
            }
            '\u{0014}' => {
                prev_cell = false;
                if let Some(top) = field_stack.last_mut() {
                    *top = false;
                }
                return true;
            }
            '\u{0015}' => {
                prev_cell = false;
                field_stack.pop();
                return true;
            }
            _ => {}
        }
        if field_stack.iter().any(|&in_instruction| in_instruction) {
            return true;
        }
        match ch {
            '\u{0007}' => {
                let emit = if prev_cell {
                    prev_cell = false;
                    '\n'
                } else {
                    prev_cell = true;
                    '\t'
                };
                append_char_bounded(&mut out, emit)
            }
            '\r' | '\u{000B}' | '\u{000C}' => {
                prev_cell = false;
                append_char_bounded(&mut out, '\n')
            }
            '\n' | '\t' => {
                prev_cell = false;
                append_char_bounded(&mut out, ch)
            }
            '\u{001E}' => {
                prev_cell = false;
                append_char_bounded(&mut out, '-')
            }
            c if (c as u32) < 0x20 => {
                prev_cell = false;
                true
            }
            c => {
                prev_cell = false;
                append_char_bounded(&mut out, c)
            }
        }
    };

    'pieces: for i in 0..pieces {
        let cp_start = read_u32_le(plc_pcd, i * 4)?;
        let cp_end = read_u32_le(plc_pcd, (i + 1) * 4)?;
        ensure!(cp_end >= cp_start, "invalid DOC piece CP range");
        let char_count = (cp_end - cp_start) as usize;
        let pcd_off = (pieces + 1) * 4 + i * 8;
        let fc_raw = read_u32_le(plc_pcd, pcd_off + 2)?;
        let compressed = (fc_raw & 0x4000_0000) != 0;
        let fc_val = (fc_raw & 0x3FFF_FFFF) as usize;
        if compressed {
            let start = fc_val / 2;
            let end = start
                .checked_add(char_count)
                .context("DOC compressed piece overflow")?;
            let slice = word_doc
                .get(start..end)
                .context("DOC compressed piece out of bounds")?;
            for &b in slice {
                if !push_doc_char(cp1252_byte(b)) {
                    break 'pieces;
                }
            }
        } else {
            let byte_len = char_count
                .checked_mul(2)
                .context("DOC UTF-16 piece overflow")?;
            let end = fc_val
                .checked_add(byte_len)
                .context("DOC UTF-16 piece end overflow")?;
            let slice = word_doc
                .get(fc_val..end)
                .context("DOC UTF-16 piece out of bounds")?;
            let units = slice
                .as_chunks::<2>()
                .0
                .iter()
                .map(|&c| u16::from_le_bytes(c));
            for decoded in char::decode_utf16(units) {
                let ch = decoded.unwrap_or('\u{FFFD}');
                if !push_doc_char(ch) {
                    break 'pieces;
                }
            }
        }
    }

    Ok(out.trim().to_owned())
}

struct BiffChunkReader<'a> {
    chunks: Vec<&'a [u8]>,
    idx: usize,
    off: usize,
}

impl<'a> BiffChunkReader<'a> {
    fn new(chunks: Vec<&'a [u8]>) -> Self {
        Self {
            chunks,
            idx: 0,
            off: 0,
        }
    }

    fn advance_empty(&mut self) {
        while self.idx < self.chunks.len() && self.off >= self.chunks[self.idx].len() {
            self.idx += 1;
            self.off = 0;
        }
    }

    fn read_raw_bytes(&mut self, mut n: usize, out: &mut Vec<u8>) -> Result<()> {
        while n > 0 {
            self.advance_empty();
            ensure!(self.idx < self.chunks.len(), "truncated BIFF record data");
            let chunk = self.chunks[self.idx];
            let take = n.min(chunk.len() - self.off);
            out.extend_from_slice(&chunk[self.off..self.off + take]);
            self.off += take;
            n -= take;
        }
        Ok(())
    }

    fn skip_raw_bytes(&mut self, mut n: usize) -> Result<()> {
        while n > 0 {
            self.advance_empty();
            ensure!(self.idx < self.chunks.len(), "truncated BIFF trailing data");
            let chunk = self.chunks[self.idx];
            let take = n.min(chunk.len() - self.off);
            self.off += take;
            n -= take;
        }
        Ok(())
    }

    fn read_u8(&mut self) -> Result<u8> {
        self.advance_empty();
        ensure!(self.idx < self.chunks.len(), "truncated BIFF u8");
        let b = self.chunks[self.idx][self.off];
        self.off += 1;
        Ok(b)
    }

    fn read_u16_le(&mut self) -> Result<u16> {
        let mut buf = Vec::with_capacity(2);
        self.read_raw_bytes(2, &mut buf)?;
        Ok(u16::from_le_bytes([buf[0], buf[1]]))
    }

    fn read_u32_le(&mut self) -> Result<u32> {
        let mut buf = Vec::with_capacity(4);
        self.read_raw_bytes(4, &mut buf)?;
        Ok(u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]))
    }

    fn read_xl_unicode_string(&mut self, rich_ext_allowed: bool) -> Result<String> {
        self.advance_empty();
        let cch = self.read_u16_le()? as usize;
        let flags = self.read_u8()?;
        let mut is_utf16 = (flags & 0x01) != 0;
        let has_ext = rich_ext_allowed && (flags & 0x04) != 0;
        let has_rich = rich_ext_allowed && (flags & 0x08) != 0;
        let c_run = if has_rich {
            self.read_u16_le()? as usize
        } else {
            0
        };
        let cb_ext_rst = if has_ext {
            self.read_u32_le()? as usize
        } else {
            0
        };

        let mut units = Vec::with_capacity(cch.min(4096));
        let mut chars_left = cch;
        while chars_left > 0 {
            if self.idx >= self.chunks.len() {
                bail!("truncated BIFF string across CONTINUE");
            }
            if self.off >= self.chunks[self.idx].len() {
                // Stepping into a CONTINUE chunk mid-string: the first byte is the
                // continuation grbit flag (bit 0 = fHighByte for the resumed slice).
                self.idx += 1;
                self.off = 0;
                ensure!(
                    self.idx < self.chunks.len() && !self.chunks[self.idx].is_empty(),
                    "missing BIFF CONTINUE continuation flag"
                );
                let cont_flags = self.chunks[self.idx][0];
                self.off = 1;
                is_utf16 = (cont_flags & 0x01) != 0;
                continue;
            }
            let chunk = self.chunks[self.idx];
            let avail = chunk.len() - self.off;
            if is_utf16 {
                let take = chars_left.min(avail / 2);
                ensure!(
                    take > 0,
                    "misaligned UTF-16 BIFF string at CONTINUE boundary"
                );
                for &pair in chunk[self.off..self.off + take * 2].as_chunks::<2>().0 {
                    units.push(u16::from_le_bytes(pair));
                }
                self.off += take * 2;
                chars_left -= take;
            } else {
                let take = chars_left.min(avail);
                for &b in &chunk[self.off..self.off + take] {
                    units.push(b as u16);
                }
                self.off += take;
                chars_left -= take;
            }
        }

        // Rich-text formatting runs (4 bytes each) and phonetic ext data span
        // CONTINUE boundaries as raw bytes with NO continuation flag byte.
        let skip_runs = c_run
            .checked_mul(4)
            .context("BIFF rich-text run count overflow")?;
        if skip_runs > 0 {
            self.skip_raw_bytes(skip_runs)?;
        }
        if cb_ext_rst > 0 {
            self.skip_raw_bytes(cb_ext_rst)?;
        }

        Ok(String::from_utf16_lossy(&units))
    }
}

fn decode_biff5_string(codepage: u32, raw: &[u8]) -> String {
    crate::platform::decode_codepage(codepage, raw)
        .unwrap_or_else(|| raw.iter().map(|&b| cp1252_byte(b)).collect())
}

fn decode_biff_rk(rk: u32) -> f64 {
    let base = if (rk & 2) != 0 {
        ((rk as i32) >> 2) as f64
    } else {
        f64::from_bits(((rk & 0xFFFF_FFFC) as u64) << 32)
    };
    if (rk & 1) != 0 { base / 100.0 } else { base }
}

fn format_biff_number(val: f64) -> Option<String> {
    if !val.is_finite() {
        return None;
    }
    let val = if val == 0.0 { 0.0 } else { val };
    if val.fract() == 0.0 && val.abs() <= 9_007_199_254_740_991.0 {
        Some(format!("{}", val as i64))
    } else {
        Some(format!("{val}"))
    }
}

/// Extract searchable strings from an Excel 97–2003 (`.xls`) BIFF8 workbook.
pub(super) fn xls_text<R: Read + Seek>(reader: R) -> Result<String> {
    let mut archive = Ole2Archive::open(reader)?;
    let stream = match archive.read_stream("Workbook")? {
        Some(data) => data,
        None => archive
            .read_stream("Book")?
            .context("missing XLS Workbook/Book stream")?,
    };
    ensure!(stream.len() >= 4, "truncated XLS workbook stream");

    const REC_FORMULA: u16 = 0x0006;
    const REC_FILEPASS: u16 = 0x002F;
    const REC_CONTINUE: u16 = 0x003C;
    const REC_CODEPAGE: u16 = 0x0042;
    const REC_MULRK: u16 = 0x00BD;
    const REC_RSTRING: u16 = 0x00D6;
    const REC_SST: u16 = 0x00FC;
    const REC_NUMBER: u16 = 0x0203;
    const REC_LABEL: u16 = 0x0204;
    const REC_STRING: u16 = 0x0207;
    const REC_RK: u16 = 0x027E;
    const REC_BOF: u16 = 0x0809;

    let mut pos = 0usize;
    let mut biff8 = true;
    let mut seen_bof = false;
    let mut codepage = 1252u32;
    let mut body = String::new();
    let mut separator = "";

    while pos + 4 <= stream.len() {
        let rec_id = read_u16_le(&stream, pos)?;
        let rec_len = read_u16_le(&stream, pos + 2)? as usize;
        let payload_start = pos + 4;
        let payload_end = payload_start
            .checked_add(rec_len)
            .context("XLS BIFF record length overflow")?;
        ensure!(payload_end <= stream.len(), "truncated XLS BIFF record");
        let payload = &stream[payload_start..payload_end];
        pos = payload_end;

        match rec_id {
            REC_FILEPASS => bail!("encrypted XLS workbook"),
            REC_BOF => {
                if !seen_bof && payload.len() >= 2 {
                    biff8 = read_u16_le(payload, 0)? == 0x0600;
                    seen_bof = true;
                }
            }
            REC_CODEPAGE => {
                if payload.len() >= 2 {
                    let cp = read_u16_le(payload, 0)? as u32;
                    if cp > 0 {
                        codepage = cp;
                    }
                }
            }
            REC_SST => {
                ensure!(payload.len() >= 8, "truncated XLS SST header");
                let unique = read_u32_le(payload, 4)? as usize;
                let mut chunks = vec![&payload[8..]];
                while pos + 4 <= stream.len() && read_u16_le(&stream, pos)? == REC_CONTINUE {
                    let clen = read_u16_le(&stream, pos + 2)? as usize;
                    let cend = (pos + 4)
                        .checked_add(clen)
                        .context("XLS CONTINUE length overflow")?;
                    ensure!(cend <= stream.len(), "truncated XLS CONTINUE record");
                    chunks.push(&stream[pos + 4..cend]);
                    pos = cend;
                }
                let total_bytes: usize = chunks.iter().map(|c| c.len()).sum();
                ensure!(
                    unique <= total_bytes / 3 + 1,
                    "XLS SST unique string count exceeds payload size"
                );
                let mut reader = BiffChunkReader::new(chunks);
                for _ in 0..unique {
                    let s = reader.read_xl_unicode_string(true)?;
                    let trimmed = s.trim();
                    if !trimmed.is_empty() {
                        if !append_bounded(&mut body, &mut separator, trimmed) {
                            return Ok(body);
                        }
                        separator = "\n";
                    }
                }
            }
            REC_LABEL | REC_RSTRING => {
                let mut chunks = Vec::new();
                if payload.len() > 6 {
                    chunks.push(&payload[6..]);
                }
                while pos + 4 <= stream.len() && read_u16_le(&stream, pos)? == REC_CONTINUE {
                    let clen = read_u16_le(&stream, pos + 2)? as usize;
                    let cend = (pos + 4)
                        .checked_add(clen)
                        .context("XLS CONTINUE length overflow")?;
                    ensure!(cend <= stream.len(), "truncated XLS CONTINUE record");
                    chunks.push(&stream[pos + 4..cend]);
                    pos = cend;
                }
                if chunks.is_empty() {
                    continue;
                }
                let text = if biff8 {
                    let mut reader = BiffChunkReader::new(chunks);
                    reader.read_xl_unicode_string(rec_id == REC_RSTRING)?
                } else {
                    let slice = chunks[0];
                    ensure!(slice.len() >= 2, "truncated BIFF5 LABEL/RSTRING");
                    let cch = read_u16_le(slice, 0)? as usize;
                    let raw = slice
                        .get(2..2 + cch)
                        .context("BIFF5 LABEL/RSTRING out of bounds")?;
                    decode_biff5_string(codepage, raw)
                };
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !append_bounded(&mut body, &mut separator, trimmed) {
                        return Ok(body);
                    }
                    separator = "\n";
                }
            }
            REC_STRING => {
                let mut chunks = vec![payload];
                while pos + 4 <= stream.len() && read_u16_le(&stream, pos)? == REC_CONTINUE {
                    let clen = read_u16_le(&stream, pos + 2)? as usize;
                    let cend = (pos + 4)
                        .checked_add(clen)
                        .context("XLS CONTINUE length overflow")?;
                    ensure!(cend <= stream.len(), "truncated XLS CONTINUE record");
                    chunks.push(&stream[pos + 4..cend]);
                    pos = cend;
                }
                let text = if biff8 {
                    let mut reader = BiffChunkReader::new(chunks);
                    reader.read_xl_unicode_string(false)?
                } else {
                    ensure!(payload.len() >= 2, "truncated BIFF5 STRING");
                    let cch = read_u16_le(payload, 0)? as usize;
                    let raw = payload
                        .get(2..2 + cch)
                        .context("BIFF5 STRING out of bounds")?;
                    decode_biff5_string(codepage, raw)
                };
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !append_bounded(&mut body, &mut separator, trimmed) {
                        return Ok(body);
                    }
                    separator = "\n";
                }
            }
            REC_NUMBER => {
                if payload.len() < 14 {
                    continue;
                }
                let val = f64::from_bits(read_u64_le(payload, 6)?);
                if let Some(text) = format_biff_number(val) {
                    if !append_bounded(&mut body, &mut separator, &text) {
                        return Ok(body);
                    }
                    separator = "\n";
                }
            }
            REC_RK => {
                if payload.len() < 10 {
                    continue;
                }
                let val = decode_biff_rk(read_u32_le(payload, 6)?);
                if let Some(text) = format_biff_number(val) {
                    if !append_bounded(&mut body, &mut separator, &text) {
                        return Ok(body);
                    }
                    separator = "\n";
                }
            }
            REC_MULRK => {
                let mut off = 4usize;
                while off + 8 <= payload.len() {
                    let val = decode_biff_rk(read_u32_le(payload, off + 2)?);
                    if let Some(text) = format_biff_number(val) {
                        if !append_bounded(&mut body, &mut separator, &text) {
                            return Ok(body);
                        }
                        separator = "\n";
                    }
                    off += 6;
                }
            }
            REC_FORMULA => {
                if payload.len() < 14 || payload[12..14] == [0xFF, 0xFF] {
                    continue;
                }
                let val = f64::from_bits(read_u64_le(payload, 6)?);
                if let Some(text) = format_biff_number(val) {
                    if !append_bounded(&mut body, &mut separator, &text) {
                        return Ok(body);
                    }
                    separator = "\n";
                }
            }
            _ => {}
        }
    }

    Ok(body)
}

/// Extract slide and note text from a PowerPoint 97–2003 (`.ppt`) OLE2 file.
pub(super) fn ppt_text<R: Read + Seek>(reader: R) -> Result<String> {
    let mut archive = Ole2Archive::open(reader)?;
    let stream = archive
        .read_stream("PowerPoint Document")?
        .context("missing PowerPoint Document stream")?;
    let mut body = String::new();
    let mut separator = "";
    walk_ppt_records(&stream, 0, &mut body, &mut separator)?;
    Ok(body)
}

fn walk_ppt_records(
    data: &[u8],
    depth: usize,
    body: &mut String,
    separator: &mut &str,
) -> Result<bool> {
    ensure!(depth <= MAX_PPT_DEPTH, "PPT record nesting exceeds limit");
    const TEXT_CHARS_ATOM: u16 = 0x0FA0;
    const TEXT_BYTES_ATOM: u16 = 0x0FA8;
    const CRYPT_SESSION_CONTAINER: u16 = 0x2F14;

    let mut pos = 0usize;
    while pos + 8 <= data.len() {
        let ver_inst = read_u16_le(data, pos)?;
        let rec_ver = ver_inst & 0x000F;
        let rec_type = read_u16_le(data, pos + 2)?;
        let rec_len = read_u32_le(data, pos + 4)? as usize;
        let payload_start = pos + 8;
        let payload_end = payload_start
            .checked_add(rec_len)
            .context("PPT record length overflow")?;
        ensure!(payload_end <= data.len(), "truncated PPT record");
        let payload = &data[payload_start..payload_end];
        pos = payload_end;

        if rec_type == CRYPT_SESSION_CONTAINER {
            bail!("encrypted PPT presentation");
        }
        if rec_ver == 0x0F {
            if !walk_ppt_records(payload, depth + 1, body, separator)? {
                return Ok(false);
            }
            continue;
        }
        match rec_type {
            TEXT_CHARS_ATOM => {
                let units = payload
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|&c| u16::from_le_bytes(c));
                let mut text = String::new();
                for decoded in char::decode_utf16(units) {
                    let ch = decoded.unwrap_or('\u{FFFD}');
                    match ch {
                        '\r' | '\u{000B}' => text.push('\n'),
                        '\n' | '\t' => text.push(ch),
                        c if (c as u32) < 0x20 => {}
                        c => text.push(c),
                    }
                }
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !append_bounded(body, separator, trimmed) {
                        return Ok(false);
                    }
                    *separator = "\n";
                }
            }
            TEXT_BYTES_ATOM => {
                let mut text = String::with_capacity(payload.len());
                for &b in payload {
                    match cp1252_byte(b) {
                        '\r' | '\u{000B}' => text.push('\n'),
                        '\n' | '\t' => text.push(b as char),
                        c if (c as u32) < 0x20 => {}
                        c => text.push(c),
                    }
                }
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !append_bounded(body, separator, trimmed) {
                        return Ok(false);
                    }
                    *separator = "\n";
                }
            }
            _ => {}
        }
    }
    Ok(true)
}

#[derive(Clone, Copy)]
struct RtfGroup {
    uc: usize,
    skip: bool,
    codepage: u32,
}

fn is_skipped_rtf_destination(word: &str) -> bool {
    matches!(
        word,
        "fonttbl"
            | "colortbl"
            | "stylesheet"
            | "pict"
            | "object"
            | "info"
            | "header"
            | "headerl"
            | "headerr"
            | "headerf"
            | "footer"
            | "footerl"
            | "footerr"
            | "footerf"
            | "fldinst"
            | "listtable"
            | "listoverridetable"
            | "revtbl"
            | "rsidtbl"
            | "generator"
            | "themedata"
            | "colorschememapping"
            | "datastore"
            | "latentstyles"
            | "pgdsctbl"
            | "xmlnstbl"
            | "datafield"
            | "objdata"
    )
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn flush_rtf_hex(hex_buf: &mut Vec<u8>, codepage: u32, out: &mut String) -> bool {
    if hex_buf.is_empty() {
        return true;
    }
    let decoded = crate::platform::decode_codepage(codepage, hex_buf).unwrap_or_else(|| {
        if codepage == 65001 {
            String::from_utf8_lossy(hex_buf).into_owned()
        } else {
            hex_buf.iter().map(|&b| cp1252_byte(b)).collect()
        }
    });
    hex_buf.clear();
    let mut sep = "";
    append_bounded(out, &mut sep, &decoded)
}

/// Extract plain text from a Rich Text Format (`.rtf`) document, skipping
/// non-body destinations and decoding `\uN` and codepage `\'hh` runs.
pub(super) fn rtf_text(bytes: &[u8]) -> Result<String> {
    ensure!(bytes.len() as u64 <= MAX_RTF, "RTF exceeds size limit");
    let start = bytes
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .context("empty RTF document")?;
    ensure!(
        bytes[start..].starts_with(b"{\\rtf"),
        "invalid RTF header signature"
    );

    let mut stack = Vec::<RtfGroup>::new();
    let mut doc_codepage = 1252u32;
    let mut hex_buf = Vec::<u8>::new();
    let mut pending_surrogate: Option<u16> = None;
    let mut out = String::new();
    let mut i = start;
    let mut at_group_start = false;

    let flush_pending_surrogate = |surrogate: &mut Option<u16>, out: &mut String| -> bool {
        if surrogate.take().is_some() {
            return append_char_bounded(out, '\u{FFFD}');
        }
        true
    };

    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'{' => {
                if let Some(top) = stack.last()
                    && !top.skip
                {
                    if !flush_rtf_hex(&mut hex_buf, top.codepage, &mut out)
                        || !flush_pending_surrogate(&mut pending_surrogate, &mut out)
                    {
                        break;
                    }
                } else {
                    hex_buf.clear();
                    pending_surrogate = None;
                }
                ensure!(
                    stack.len() < MAX_RTF_DEPTH,
                    "RTF group nesting exceeds limit"
                );
                let next = stack.last().copied().unwrap_or(RtfGroup {
                    uc: 1,
                    skip: false,
                    codepage: doc_codepage,
                });
                stack.push(next);
                at_group_start = true;
                i += 1;
            }
            b'}' => {
                if let Some(top) = stack.last()
                    && !top.skip
                {
                    if !flush_rtf_hex(&mut hex_buf, top.codepage, &mut out)
                        || !flush_pending_surrogate(&mut pending_surrogate, &mut out)
                    {
                        break;
                    }
                } else {
                    hex_buf.clear();
                    pending_surrogate = None;
                }
                ensure!(!stack.is_empty(), "unbalanced RTF closing brace");
                stack.pop();
                at_group_start = false;
                i += 1;
                if stack.is_empty() {
                    break;
                }
            }
            b'\r' | b'\n' => {
                i += 1;
            }
            b'\\' => {
                i += 1;
                let Some(&next) = bytes.get(i) else {
                    break;
                };
                if next == b'\'' {
                    // Hex escape \'hh
                    if let (Some(&hi), Some(&lo)) = (bytes.get(i + 1), bytes.get(i + 2))
                        && let (Some(h), Some(l)) = (hex_nibble(hi), hex_nibble(lo))
                    {
                        if stack.last().is_some_and(|g| !g.skip) {
                            if !flush_pending_surrogate(&mut pending_surrogate, &mut out) {
                                break;
                            }
                            hex_buf.push((h << 4) | l);
                        }
                        i += 3;
                    } else {
                        i += 1;
                    }
                    at_group_start = false;
                    continue;
                }

                let skip = stack.last().is_none_or(|g| g.skip);
                let cp = stack.last().map_or(doc_codepage, |g| g.codepage);

                if !next.is_ascii_alphabetic() {
                    // Control symbol
                    if !skip {
                        if !flush_rtf_hex(&mut hex_buf, cp, &mut out)
                            || !flush_pending_surrogate(&mut pending_surrogate, &mut out)
                        {
                            break;
                        }
                    } else {
                        hex_buf.clear();
                        pending_surrogate = None;
                    }
                    match next {
                        b'*' => {
                            if let Some(top) = stack.last_mut()
                                && at_group_start
                            {
                                top.skip = true;
                            }
                        }
                        b'\\' | b'{' | b'}' if !skip => {
                            if !append_char_bounded(&mut out, next as char) {
                                break;
                            }
                        }
                        b'~' if !skip => {
                            if !append_char_bounded(&mut out, ' ') {
                                break;
                            }
                        }
                        b'_' if !skip => {
                            if !append_char_bounded(&mut out, '-') {
                                break;
                            }
                        }
                        b'\r' | b'\n' if !skip && !append_char_bounded(&mut out, '\n') => {
                            break;
                        }
                        _ => {}
                    }
                    i += 1;
                    at_group_start = false;
                    continue;
                }

                // Control word: [a-zA-Z]+ optionally followed by [-]?[0-9]+ and optional single space.
                let word_start = i;
                while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
                    i += 1;
                }
                let word = std::str::from_utf8(&bytes[word_start..i]).unwrap_or("");
                let param_start = i;
                if i < bytes.len() && bytes[i] == b'-' {
                    i += 1;
                }
                let digits_start = i;
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                let param: Option<i32> = if i > digits_start {
                    std::str::from_utf8(&bytes[param_start..i])
                        .ok()
                        .and_then(|s| s.parse::<i32>().ok())
                } else {
                    i = param_start;
                    None
                };
                if bytes.get(i) == Some(&b' ') {
                    i += 1;
                }

                // Handle \binN raw binary payload regardless of skip state so braces inside
                // binary payloads do not desynchronize the group stack.
                if word == "bin" {
                    let n = param.unwrap_or(0).max(0) as usize;
                    i = i.saturating_add(n).min(bytes.len());
                    at_group_start = false;
                    continue;
                }

                if word == "ansicpg"
                    && let Some(cpg) = param
                    && cpg > 0
                {
                    doc_codepage = cpg as u32;
                    for group in &mut stack {
                        group.codepage = doc_codepage;
                    }
                } else if word == "uc"
                    && let Some(uc) = param
                    && let Some(top) = stack.last_mut()
                {
                    top.uc = uc.clamp(0, 16) as usize;
                } else if is_skipped_rtf_destination(word)
                    && let Some(top) = stack.last_mut()
                {
                    top.skip = true;
                    hex_buf.clear();
                    pending_surrogate = None;
                    at_group_start = false;
                    continue;
                }

                if word == "u"
                    && let Some(raw_val) = param
                {
                    if !skip {
                        if !flush_rtf_hex(&mut hex_buf, cp, &mut out) {
                            break;
                        }
                        let unit = (raw_val & 0xFFFF) as u16;
                        if (0xD800..=0xDBFF).contains(&unit) {
                            if !flush_pending_surrogate(&mut pending_surrogate, &mut out) {
                                break;
                            }
                            pending_surrogate = Some(unit);
                        } else if (0xDC00..=0xDFFF).contains(&unit) {
                            let ch = if let Some(hi) = pending_surrogate.take() {
                                let code = 0x10000
                                    + (((hi as u32 - 0xD800) << 10) | (unit as u32 - 0xDC00));
                                char::from_u32(code).unwrap_or('\u{FFFD}')
                            } else {
                                '\u{FFFD}'
                            };
                            if !append_char_bounded(&mut out, ch) {
                                break;
                            }
                        } else {
                            if !flush_pending_surrogate(&mut pending_surrogate, &mut out) {
                                break;
                            }
                            if let Some(ch) = char::from_u32(unit as u32)
                                && !append_char_bounded(&mut out, ch)
                            {
                                break;
                            }
                        }
                    }
                    // Skip `uc` replacement characters following \uN.
                    let mut to_skip = stack.last().map_or(1, |g| g.uc);
                    while to_skip > 0 && i < bytes.len() {
                        match bytes[i] {
                            b'\r' | b'\n' => i += 1,
                            b'{' | b'}' => break,
                            b'\\' => {
                                if bytes.get(i + 1) == Some(&b'\'')
                                    && bytes.get(i + 2).is_some_and(|&c| hex_nibble(c).is_some())
                                    && bytes.get(i + 3).is_some_and(|&c| hex_nibble(c).is_some())
                                {
                                    i += 4;
                                    to_skip -= 1;
                                } else if bytes.get(i + 1).is_some_and(|c| !c.is_ascii_alphabetic())
                                {
                                    i += 2;
                                    to_skip -= 1;
                                } else {
                                    break;
                                }
                            }
                            _ => {
                                i += 1;
                                to_skip -= 1;
                            }
                        }
                    }
                    at_group_start = false;
                    continue;
                }

                if !skip {
                    if !flush_rtf_hex(&mut hex_buf, cp, &mut out)
                        || !flush_pending_surrogate(&mut pending_surrogate, &mut out)
                    {
                        break;
                    }
                    let emit = match word {
                        "par" | "line" => Some('\n'),
                        "tab" => Some('\t'),
                        "emdash" => Some('—'),
                        "endash" => Some('–'),
                        "lquote" => Some('‘'),
                        "rquote" => Some('’'),
                        "ldblquote" => Some('“'),
                        "rdblquote" => Some('”'),
                        "bullet" => Some('•'),
                        _ => None,
                    };
                    if let Some(ch) = emit
                        && !append_char_bounded(&mut out, ch)
                    {
                        break;
                    }
                }
                at_group_start = false;
            }
            other => {
                if let Some(top) = stack.last()
                    && !top.skip
                {
                    if !flush_rtf_hex(&mut hex_buf, top.codepage, &mut out)
                        || !flush_pending_surrogate(&mut pending_surrogate, &mut out)
                    {
                        break;
                    }
                    if !append_char_bounded(&mut out, cp1252_byte(other)) {
                        break;
                    }
                }
                at_group_start = false;
                i += 1;
            }
        }
    }

    if let Some(top) = stack.last()
        && !top.skip
    {
        let _ = flush_rtf_hex(&mut hex_buf, top.codepage, &mut out);
        let _ = flush_pending_surrogate(&mut pending_surrogate, &mut out);
    }

    Ok(out.trim().to_owned())
}

fn decode_subtitle_utf(bytes: &[u8]) -> Result<String> {
    if let Some(marker) = bytes.first_chunk::<2>() {
        let decode = match marker {
            [0xFF, 0xFE] => Some(u16::from_le_bytes as fn([u8; 2]) -> u16),
            [0xFE, 0xFF] => Some(u16::from_be_bytes as fn([u8; 2]) -> u16),
            _ => None,
        };
        if let Some(decode) = decode {
            let (units, remainder) = bytes[2..].as_chunks::<2>();
            ensure!(remainder.is_empty(), "truncated UTF-16 subtitle file");
            let units: Vec<u16> = units.iter().copied().map(decode).collect();
            return Ok(String::from_utf16(&units)?);
        }
    }
    let text = std::str::from_utf8(bytes).context("subtitle file is not valid UTF-8")?;
    Ok(text.strip_prefix('\u{FEFF}').unwrap_or(text).to_owned())
}

fn format_cue_timestamp(raw: &str) -> Option<String> {
    let token = raw.split_whitespace().next()?;
    let main = token.split(['.', ',']).next()?;
    let parts: Vec<&str> = main.split(':').collect();
    match parts.as_slice() {
        [h, m, s] => {
            let h: u32 = h.parse().ok()?;
            let m: u32 = m.parse().ok()?;
            let s: u32 = s.parse().ok()?;
            if m >= 60 || s >= 60 {
                return None;
            }
            if h == 0 {
                Some(format!("[{m:02}:{s:02}]"))
            } else {
                Some(format!("[{h:02}:{m:02}:{s:02}]"))
            }
        }
        [m, s] => {
            let m: u32 = m.parse().ok()?;
            let s: u32 = s.parse().ok()?;
            if m >= 60 || s >= 60 {
                return None;
            }
            Some(format!("[{m:02}:{s:02}]"))
        }
        _ => None,
    }
}

fn clean_subtitle_line(raw: &str) -> String {
    let mut stripped = String::with_capacity(raw.len());
    let chars: Vec<char> = raw.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] == '<' {
            if let Some(rel_end) = chars[i + 1..].iter().position(|&c| c == '>') {
                i += rel_end + 2;
                continue;
            }
        } else if chars[i] == '{'
            && chars.get(i + 1) == Some(&'\\')
            && let Some(rel_end) = chars[i + 2..].iter().position(|&c| c == '}')
        {
            i += rel_end + 3;
            continue;
        }
        stripped.push(chars[i]);
        i += 1;
    }

    let decoded = stripped
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");

    decoded.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Extract timestamped transcript lines from `.srt` or `.vtt` subtitle files,
/// stripping headers/notes/styles/tags and deduplicating adjacent lines.
pub(super) fn subtitle_text(bytes: &[u8]) -> Result<String> {
    ensure!(
        bytes.len() as u64 <= MAX_SUBTITLE,
        "subtitle file exceeds size limit"
    );
    let raw = decode_subtitle_utf(bytes)?;
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");

    let mut out = String::new();
    let mut separator = "";
    let mut last_line = String::new();
    let mut last_cue = String::new();
    let mut block: Vec<&str> = Vec::new();
    let mut first_block = true;

    let mut process_block = |lines: &[&str], is_first: bool| -> bool {
        let Some(&first) = lines.first() else {
            return true;
        };
        let first_trim = first.trim();
        if is_first
            && (first_trim == "WEBVTT"
                || first_trim.starts_with("WEBVTT ")
                || first_trim.starts_with("WEBVTT\t"))
        {
            return true;
        }
        if first_trim == "NOTE"
            || first_trim.starts_with("NOTE ")
            || first_trim.starts_with("NOTE\t")
            || first_trim == "STYLE"
            || first_trim.starts_with("STYLE ")
            || first_trim == "REGION"
            || first_trim.starts_with("REGION ")
        {
            return true;
        }
        let Some((ts_idx, ts_line)) = lines
            .iter()
            .enumerate()
            .find(|(_, line)| line.contains("-->"))
        else {
            return true;
        };
        let Some((left, _)) = ts_line.split_once("-->") else {
            return true;
        };
        let Some(stamp) = format_cue_timestamp(left) else {
            return true;
        };
        let mut kept = Vec::new();
        for &text_line in &lines[ts_idx + 1..] {
            let cleaned = clean_subtitle_line(text_line);
            if cleaned.is_empty() || cleaned == last_line {
                continue;
            }
            last_line = cleaned.clone();
            kept.push(cleaned);
        }
        if kept.is_empty() {
            return true;
        }
        let joined = kept.join(" ");
        if joined == last_cue {
            return true;
        }
        last_cue = joined.clone();
        let emitted = format!("{stamp} {joined}");
        if !append_bounded(&mut out, &mut separator, &emitted) {
            return false;
        }
        separator = "\n";
        true
    };

    for line in normalized.lines() {
        if line.trim().is_empty() {
            if !block.is_empty() {
                if !process_block(&block, first_block) {
                    return Ok(out);
                }
                first_block = false;
                block.clear();
            }
        } else {
            block.push(line);
        }
    }
    if !block.is_empty() {
        let _ = process_block(&block, first_block);
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Cursor;

    /// Build a minimal valid CFBF v3 (512-byte sector) OLE2 container storing
    /// the given named streams in regular sectors (using `mini_cutoff = 0`).
    fn build_ole2(streams: &[(&str, &[u8])]) -> Vec<u8> {
        const SECTOR: usize = 512;
        let mut sector_payloads: Vec<Vec<u8>> = Vec::new();
        let mut fat: Vec<u32> = Vec::new();
        let mut dir_entries: Vec<([u8; 128],)> = Vec::new();

        let make_dir_entry = |name: &str, obj_type: u8, start: u32, size: u32| -> [u8; 128] {
            let mut entry = [0u8; 128];
            let units: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            for (i, u) in units.iter().take(32).enumerate() {
                entry[i * 2..i * 2 + 2].copy_from_slice(&u.to_le_bytes());
            }
            let name_bytes = (units.len().min(32) * 2) as u16;
            entry[64..66].copy_from_slice(&name_bytes.to_le_bytes());
            entry[66] = obj_type;
            entry[67] = 1; // black node
            entry[68..72].copy_from_slice(&FREESECT.to_le_bytes());
            entry[72..76].copy_from_slice(&FREESECT.to_le_bytes());
            entry[76..80].copy_from_slice(&FREESECT.to_le_bytes());
            entry[116..120].copy_from_slice(&start.to_le_bytes());
            entry[120..124].copy_from_slice(&size.to_le_bytes());
            entry
        };

        dir_entries.push((make_dir_entry("Root Entry", 5, ENDOFCHAIN, 0),));

        for &(name, data) in streams {
            let start = if data.is_empty() {
                ENDOFCHAIN
            } else {
                let first = sector_payloads.len() as u32;
                let chunks: Vec<&[u8]> = data.chunks(SECTOR).collect();
                for (idx, chunk) in chunks.iter().enumerate() {
                    let mut sec = vec![0u8; SECTOR];
                    sec[..chunk.len()].copy_from_slice(chunk);
                    let sid = sector_payloads.len() as u32;
                    sector_payloads.push(sec);
                    let next = if idx + 1 < chunks.len() {
                        sid + 1
                    } else {
                        ENDOFCHAIN
                    };
                    fat.push(next);
                }
                first
            };
            dir_entries.push((make_dir_entry(name, 2, start, data.len() as u32),));
        }

        // Write directory stream sectors.
        let mut dir_bytes = Vec::with_capacity(dir_entries.len() * 128);
        for (entry,) in &dir_entries {
            dir_bytes.extend_from_slice(entry);
        }
        let first_dir_sector = sector_payloads.len() as u32;
        let dir_chunks: Vec<&[u8]> = dir_bytes.chunks(SECTOR).collect();
        for (idx, chunk) in dir_chunks.iter().enumerate() {
            let mut sec = vec![0u8; SECTOR];
            sec[..chunk.len()].copy_from_slice(chunk);
            let sid = sector_payloads.len() as u32;
            sector_payloads.push(sec);
            let next = if idx + 1 < dir_chunks.len() {
                sid + 1
            } else {
                ENDOFCHAIN
            };
            fat.push(next);
        }

        // Append FAT sector(s).
        let fat_sector_sid = sector_payloads.len() as u32;
        fat.push(FATSECT);
        assert!(fat.len() <= 128, "test fixture exceeds single FAT sector");
        while fat.len() < 128 {
            fat.push(FREESECT);
        }
        let mut fat_sec = vec![0u8; SECTOR];
        for (i, entry) in fat.iter().enumerate() {
            fat_sec[i * 4..i * 4 + 4].copy_from_slice(&entry.to_le_bytes());
        }
        sector_payloads.push(fat_sec);

        // Build 512-byte CFBF header.
        let mut header = vec![0u8; SECTOR];
        header[0..8].copy_from_slice(&CFBF_MAGIC);
        header[24..26].copy_from_slice(&0x003Eu16.to_le_bytes()); // minor
        header[26..28].copy_from_slice(&3u16.to_le_bytes()); // major v3
        header[28..30].copy_from_slice(&0xFFFEu16.to_le_bytes()); // little-endian
        header[30..32].copy_from_slice(&9u16.to_le_bytes()); // 512B sector
        header[32..34].copy_from_slice(&6u16.to_le_bytes()); // 64B mini sector
        header[44..48].copy_from_slice(&1u32.to_le_bytes()); // num_fat_sectors
        header[48..52].copy_from_slice(&first_dir_sector.to_le_bytes());
        header[56..60].copy_from_slice(&0u32.to_le_bytes()); // mini_cutoff = 0 (regular sectors)
        header[60..64].copy_from_slice(&ENDOFCHAIN.to_le_bytes());
        header[68..72].copy_from_slice(&ENDOFCHAIN.to_le_bytes());
        header[76..80].copy_from_slice(&fat_sector_sid.to_le_bytes());
        for i in 1..109 {
            header[76 + i * 4..80 + i * 4].copy_from_slice(&FREESECT.to_le_bytes());
        }

        let mut file = header;
        for sec in sector_payloads {
            file.extend_from_slice(&sec);
        }
        file
    }

    pub(crate) fn build_synthetic_doc(encrypted: bool) -> Vec<u8> {
        // Two pieces: piece 0 compressed CP1252 ("Hello " + field + "World\r"),
        // piece 1 UTF-16LE ("中文合同条款\x07第一行\x07\x07").
        let piece0_bytes: Vec<u8> =
            b"Hello \x13HYPERLINK \"https://example.com\"\x14Click\x15 World\r".to_vec();
        let piece1_text = "中文合同条款\u{0007}单元格\u{0007}\u{0007}";
        let piece1_units: Vec<u16> = piece1_text.encode_utf16().collect();
        let mut piece1_bytes = Vec::with_capacity(piece1_units.len() * 2);
        for u in &piece1_units {
            piece1_bytes.extend_from_slice(&u.to_le_bytes());
        }

        let mut word_doc = vec![0u8; 512];
        word_doc[0..2].copy_from_slice(&0xA5ECu16.to_le_bytes());
        word_doc[2..4].copy_from_slice(&0x00C1u16.to_le_bytes());
        let mut flags = 0x0200u16; // fWhichTblStm = 1 -> 1Table
        if encrypted {
            flags |= 0x0100;
        }
        word_doc[10..12].copy_from_slice(&flags.to_le_bytes());
        word_doc[32..34].copy_from_slice(&14u16.to_le_bytes()); // csw
        word_doc[62..64].copy_from_slice(&22u16.to_le_bytes()); // cslw
        word_doc[152..154].copy_from_slice(&93u16.to_le_bytes()); // cbRgFcLcb

        let p0_off = word_doc.len();
        word_doc.extend_from_slice(&piece0_bytes);
        let p1_off = word_doc.len();
        word_doc.extend_from_slice(&piece1_bytes);

        // Build Clx with 1 Prc skipped + Pcdt with 2 pieces.
        let mut clx = Vec::new();
        clx.push(0x01); // Prc
        clx.extend_from_slice(&2u16.to_le_bytes());
        clx.extend_from_slice(&[0x00, 0x00]);
        clx.push(0x02); // Pcdt
        let pcdt_lcb = 4 + 2 * 12; // 28 bytes
        clx.extend_from_slice(&(pcdt_lcb as u32).to_le_bytes());
        let cp0 = 0u32;
        let cp1 = piece0_bytes.len() as u32;
        let cp2 = cp1 + piece1_units.len() as u32;
        clx.extend_from_slice(&cp0.to_le_bytes());
        clx.extend_from_slice(&cp1.to_le_bytes());
        clx.extend_from_slice(&cp2.to_le_bytes());
        // PCD 0: compressed CP1252 (fc = (p0_off * 2) | 0x4000_0000)
        clx.extend_from_slice(&0u16.to_le_bytes());
        clx.extend_from_slice(&(((p0_off as u32) * 2) | 0x4000_0000).to_le_bytes());
        clx.extend_from_slice(&0u16.to_le_bytes());
        // PCD 1: UTF-16LE (fc = p1_off)
        clx.extend_from_slice(&0u16.to_le_bytes());
        clx.extend_from_slice(&(p1_off as u32).to_le_bytes());
        clx.extend_from_slice(&0u16.to_le_bytes());

        // fcClx at offset 418 (0x01A2), lcbClx at 422
        word_doc[418..422].copy_from_slice(&0u32.to_le_bytes());
        word_doc[422..426].copy_from_slice(&(clx.len() as u32).to_le_bytes());

        build_ole2(&[("WordDocument", &word_doc), ("1Table", &clx)])
    }

    fn biff_record(id: u16, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + payload.len());
        out.extend_from_slice(&id.to_le_bytes());
        out.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    pub(crate) fn build_synthetic_xls(encrypted: bool) -> Vec<u8> {
        let mut wb = Vec::new();
        // BOF BIFF8 (vers = 0x0600, dt = 0x0005 workbook globals)
        wb.extend_from_slice(&biff_record(0x0809, &[0x00, 0x06, 0x05, 0x00, 0, 0, 0, 0]));
        if encrypted {
            wb.extend_from_slice(&biff_record(0x002F, &[0x01, 0x00]));
        }

        // SST with 3 unique strings:
        // 0: compressed + rich-text run + phonetic ext ("Budget")
        // 1: split across CONTINUE boundary, switching from compressed ("Q4 ") to UTF-16LE ("财务报表")!
        // 2: plain UTF-16LE ("汇总") starting inside CONTINUE record.
        let mut sst_part1 = Vec::new();
        sst_part1.extend_from_slice(&3u32.to_le_bytes()); // cstTotal
        sst_part1.extend_from_slice(&3u32.to_le_bytes()); // cstUnique
        // String 0: "Budget" (len=6, flags=0x0C rich+ext, cRun=1, cbExtRst=3)
        sst_part1.extend_from_slice(&6u16.to_le_bytes());
        sst_part1.push(0x0C);
        sst_part1.extend_from_slice(&1u16.to_le_bytes()); // 1 rich run (4 bytes)
        sst_part1.extend_from_slice(&3u32.to_le_bytes()); // 3 phonetic bytes
        sst_part1.extend_from_slice(b"Budget");
        sst_part1.extend_from_slice(&[0, 0, 0, 0]); // rich run
        sst_part1.extend_from_slice(&[1, 2, 3]); // ext bytes
        // String 1 header + first 3 compressed chars ("Q4 "), total 7 chars -> 4 chars in CONTINUE!
        sst_part1.extend_from_slice(&7u16.to_le_bytes());
        sst_part1.push(0x00); // compressed initially
        sst_part1.extend_from_slice(b"Q4 ");

        let mut cont_part = Vec::new();
        cont_part.push(0x01); // continuation grbit: switch to UTF-16LE!
        for u in "财务报表".encode_utf16() {
            cont_part.extend_from_slice(&u.to_le_bytes());
        }
        // String 2: "汇总" (2 UTF-16LE chars)
        cont_part.extend_from_slice(&2u16.to_le_bytes());
        cont_part.push(0x01);
        for u in "汇总".encode_utf16() {
            cont_part.extend_from_slice(&u.to_le_bytes());
        }

        wb.extend_from_slice(&biff_record(0x00FC, &sst_part1));
        wb.extend_from_slice(&biff_record(0x003C, &cont_part));

        // LABEL cell: row=0, col=0, xf=0, "DirectLabel"
        let mut label = vec![0u8; 6];
        label.extend_from_slice(&11u16.to_le_bytes());
        label.push(0x00);
        label.extend_from_slice(b"DirectLabel");
        wb.extend_from_slice(&biff_record(0x0204, &label));

        // STRING formula result: "公式结果"
        let mut formula_str = Vec::new();
        formula_str.extend_from_slice(&4u16.to_le_bytes());
        formula_str.push(0x01);
        for u in "公式结果".encode_utf16() {
            formula_str.extend_from_slice(&u.to_le_bytes());
        }
        wb.extend_from_slice(&biff_record(0x0207, &formula_str));
        wb.extend_from_slice(&biff_record(0x000A, &[])); // EOF

        build_ole2(&[("Workbook", &wb)])
    }

    fn ppt_record(ver_inst: u16, rec_type: u16, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + payload.len());
        out.extend_from_slice(&ver_inst.to_le_bytes());
        out.extend_from_slice(&rec_type.to_le_bytes());
        out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    pub(crate) fn build_synthetic_ppt() -> Vec<u8> {
        let mut utf16_bytes = Vec::new();
        for u in "年度架构评审\r核心目标".encode_utf16() {
            utf16_bytes.extend_from_slice(&u.to_le_bytes());
        }
        let atom1 = ppt_record(0x0000, 0x0FA0, &utf16_bytes);
        let atom2 = ppt_record(0x0000, 0x0FA8, b"Roadmap \x96 Q4");
        let mut container_payload = Vec::new();
        container_payload.extend_from_slice(&atom1);
        container_payload.extend_from_slice(&atom2);
        let slide_container = ppt_record(0x000F, 0x03EE, &container_payload);
        let doc_container = ppt_record(0x000F, 0x03E8, &slide_container);
        build_ole2(&[("PowerPoint Document", &doc_container)])
    }

    #[test]
    fn extracts_synthetic_doc_strips_fields_and_rejects_encrypted() {
        let doc = build_synthetic_doc(false);
        let text = doc_text(Cursor::new(&doc)).unwrap();
        assert!(text.contains("Hello Click World"), "{text}");
        assert!(!text.contains("HYPERLINK"), "{text}");
        assert!(text.contains("中文合同条款\t单元格"), "{text}");

        let enc = build_synthetic_doc(true);
        assert!(doc_text(Cursor::new(&enc)).is_err());
    }

    #[test]
    fn extracts_synthetic_xls_continue_boundary_cjk_and_rejects_encrypted() {
        let xls = build_synthetic_xls(false);
        let text = xls_text(Cursor::new(&xls)).unwrap();
        assert!(text.contains("Budget"), "{text}");
        assert!(text.contains("Q4 财务报表"), "{text}");
        assert!(text.contains("汇总"), "{text}");
        assert!(text.contains("DirectLabel"), "{text}");
        assert!(text.contains("公式结果"), "{text}");

        let enc = build_synthetic_xls(true);
        assert!(xls_text(Cursor::new(&enc)).is_err());
    }

    #[test]
    fn extracts_xls_biff8_numeric_cells_number_rk_mulrk_and_formula() {
        let mut wb = Vec::new();
        // BOF BIFF8 (vers = 0x0600, dt = 0x0005 workbook globals)
        wb.extend_from_slice(&biff_record(0x0809, &[0x00, 0x06, 0x05, 0x00, 0, 0, 0, 0]));

        // 1. REC_NUMBER (0x0203): integer float 310927431.0, decimal 42.875, and -0.0
        let mut num_int = vec![0u8; 6]; // row=0, col=0, xf=0
        num_int.extend_from_slice(&310_927_431.0_f64.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x0203, &num_int));

        let mut num_dec = vec![0, 0, 1, 0, 0, 0]; // row=0, col=1, xf=0
        num_dec.extend_from_slice(&42.875_f64.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x0203, &num_dec));

        let mut num_neg_zero = vec![0, 0, 2, 0, 0, 0]; // row=0, col=2, xf=0
        num_neg_zero.extend_from_slice(&(-0.0_f64).to_le_bytes());
        wb.extend_from_slice(&biff_record(0x0203, &num_neg_zero));

        // 2. REC_RK (0x027E):
        // - 30-bit signed integer: 2026
        let mut rk_pos_int = vec![1, 0, 0, 0, 0, 0];
        let rk_val_pos = ((2026i32 << 2) as u32) | 0x02;
        rk_pos_int.extend_from_slice(&rk_val_pos.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x027E, &rk_pos_int));

        // - 30-bit negative integer: -4096
        let mut rk_neg_int = vec![1, 0, 1, 0, 0, 0];
        let rk_val_neg = ((-4096i32 << 2) as u32) | 0x02;
        rk_neg_int.extend_from_slice(&rk_val_neg.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x027E, &rk_neg_int));

        // - 30-bit integer with /100 flag: 12345 / 100 = 123.45
        let mut rk_div100 = vec![1, 0, 2, 0, 0, 0];
        let rk_val_div100 = ((12345i32 << 2) as u32) | 0x03;
        rk_div100.extend_from_slice(&rk_val_div100.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x027E, &rk_div100));

        // - IEEE-754 float RK (30 MSBs shifted): 6.25
        let mut rk_float = vec![1, 0, 3, 0, 0, 0];
        let rk_val_float = ((6.25_f64.to_bits() >> 32) as u32) & 0xFFFF_FFFC;
        rk_float.extend_from_slice(&rk_val_float.to_le_bytes());
        wb.extend_from_slice(&biff_record(0x027E, &rk_float));

        // 3. REC_MULRK (0x00BD): row=2, colFirst=0..colLast=2 (3 columns: 1001, 2002, 3003.5)
        let mut mulrk = Vec::new();
        mulrk.extend_from_slice(&2u16.to_le_bytes()); // row=2
        mulrk.extend_from_slice(&0u16.to_le_bytes()); // colFirst=0
        for &rk in &[
            ((1001i32 << 2) as u32) | 0x02,
            ((2002i32 << 2) as u32) | 0x02,
            ((300_350i32 << 2) as u32) | 0x03, // 3003.5
        ] {
            mulrk.extend_from_slice(&0u16.to_le_bytes()); // xf=0
            mulrk.extend_from_slice(&rk.to_le_bytes());
        }
        mulrk.extend_from_slice(&2u16.to_le_bytes()); // colLast=2
        wb.extend_from_slice(&biff_record(0x00BD, &mulrk));

        // 4. REC_FORMULA (0x0006):
        // - Cached numeric f64 result: 98765.25
        let mut formula_num = vec![3, 0, 0, 0, 0, 0]; // row=3, col=0, xf=0
        formula_num.extend_from_slice(&98765.25_f64.to_le_bytes());
        formula_num.extend_from_slice(&[0u8; 6]); // grbit + chn + cce
        wb.extend_from_slice(&biff_record(0x0006, &formula_num));

        // - Cached string tag (result[6..8] == [0xFF, 0xFF]) followed by REC_STRING (0x0207)
        let mut formula_str_cell = vec![3, 0, 1, 0, 0, 0]; // row=3, col=1, xf=0
        formula_str_cell.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF]);
        formula_str_cell.extend_from_slice(&[0u8; 6]);
        wb.extend_from_slice(&biff_record(0x0006, &formula_str_cell));

        let mut rec_string = Vec::new();
        rec_string.extend_from_slice(&19u16.to_le_bytes());
        rec_string.push(0x00); // compressed
        rec_string.extend_from_slice(b"FormulaStringResult");
        wb.extend_from_slice(&biff_record(0x0207, &rec_string));

        wb.extend_from_slice(&biff_record(0x000A, &[])); // EOF

        let xls = build_ole2(&[("Workbook", &wb)]);
        let text = xls_text(Cursor::new(&xls)).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(
            lines,
            vec![
                "310927431",
                "42.875",
                "0",
                "2026",
                "-4096",
                "123.45",
                "6.25",
                "1001",
                "2002",
                "3003.5",
                "98765.25",
                "FormulaStringResult",
            ]
        );
    }

    #[test]
    fn extracts_synthetic_ppt_atoms_and_rejects_deep_nesting() {
        let ppt = build_synthetic_ppt();
        let text = ppt_text(Cursor::new(&ppt)).unwrap();
        assert!(text.contains("年度架构评审\n核心目标"), "{text}");
        assert!(text.contains("Roadmap – Q4"), "{text}");

        // Exceed MAX_PPT_DEPTH (64)
        let mut nested = ppt_record(0x0000, 0x0FA8, b"too deep");
        for _ in 0..70 {
            nested = ppt_record(0x000F, 0x03EE, &nested);
        }
        let deep_ppt = build_ole2(&[("PowerPoint Document", &nested)]);
        assert!(ppt_text(Cursor::new(&deep_ppt)).is_err());
    }

    #[test]
    fn rejects_cyclic_fat_truncated_and_oversized_ole2() {
        // Cyclic FAT: patch sector 0's FAT entry to point back to sector 0.
        let mut cyclic = build_ole2(&[("WordDocument", &[0u8; 1024])]);
        // FAT sector is the last 512-byte sector in build_ole2.
        let fat_offset = cyclic.len() - 512;
        cyclic[fat_offset..fat_offset + 4].copy_from_slice(&0u32.to_le_bytes());
        let mut archive = Ole2Archive::open(Cursor::new(&cyclic)).unwrap();
        let err = archive.read_stream("WordDocument").unwrap_err();
        assert!(err.to_string().contains("cyclic"), "{err}");

        // Truncated OLE2 file
        let valid = build_synthetic_doc(false);
        assert!(doc_text(Cursor::new(&valid[..200])).is_err());
        assert!(doc_text(Cursor::new(&valid[..valid.len() - 600])).is_err());

        // Oversized header check via invalid magic and oversized 32 MiB stream cap
        assert!(Ole2Archive::open(Cursor::new(vec![0u8; 512])).is_err());

        let mut oversized_stream = build_ole2(&[("WordDocument", &[0u8; 512])]);
        // Directory entry #1 starts at sector 1 (offset 512 + 512 = 1024), entry 1 at +128, size at +120.
        let dir_entry1_size_off = 512 + 512 + 128 + 120;
        oversized_stream[dir_entry1_size_off..dir_entry1_size_off + 4]
            .copy_from_slice(&(40u32 * 1024 * 1024).to_le_bytes());
        let mut archive = Ole2Archive::open(Cursor::new(&oversized_stream)).unwrap();
        let cap_err = archive.read_stream("WordDocument").unwrap_err();
        assert!(cap_err.to_string().contains("32 MiB"), "{cap_err}");
    }

    #[test]
    fn reads_minifat_stream_and_rejects_cyclic_minifat() {
        // Build a minimal CFBF v3 file with mini_cutoff = 4096:
        // Sector 0: Root mini-stream (128 bytes = 2 mini-sectors of 64 bytes)
        // Sector 1: MiniFAT (mini-sector 0 -> 1, mini-sector 1 -> ENDOFCHAIN)
        // Sector 2: Directory (Root Entry -> start=0,size=128; "Small" -> start=0,size=80)
        // Sector 3: FAT
        const SECTOR: usize = 512;
        let payload: Vec<u8> = (0u8..80).collect();

        let mut s0 = vec![0u8; SECTOR];
        s0[..80].copy_from_slice(&payload);

        let mut s1 = vec![0xFFu8; SECTOR];
        s1[0..4].copy_from_slice(&1u32.to_le_bytes());
        s1[4..8].copy_from_slice(&ENDOFCHAIN.to_le_bytes());

        let make_dir = |name: &str, obj_type: u8, start: u32, size: u32| -> [u8; 128] {
            let mut e = [0u8; 128];
            let units: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            for (i, u) in units.iter().enumerate() {
                e[i * 2..i * 2 + 2].copy_from_slice(&u.to_le_bytes());
            }
            e[64..66].copy_from_slice(&((units.len() * 2) as u16).to_le_bytes());
            e[66] = obj_type;
            e[116..120].copy_from_slice(&start.to_le_bytes());
            e[120..124].copy_from_slice(&size.to_le_bytes());
            e
        };
        let mut s2 = vec![0u8; SECTOR];
        s2[0..128].copy_from_slice(&make_dir("Root Entry", 5, 0, 128));
        s2[128..256].copy_from_slice(&make_dir("Small", 2, 0, 80));

        let mut s3 = vec![0xFFu8; SECTOR];
        s3[0..4].copy_from_slice(&ENDOFCHAIN.to_le_bytes()); // sector 0: mini-stream
        s3[4..8].copy_from_slice(&ENDOFCHAIN.to_le_bytes()); // sector 1: mini-FAT
        s3[8..12].copy_from_slice(&ENDOFCHAIN.to_le_bytes()); // sector 2: dir
        s3[12..16].copy_from_slice(&FATSECT.to_le_bytes()); // sector 3: FAT

        let mut header = vec![0u8; SECTOR];
        header[0..8].copy_from_slice(&CFBF_MAGIC);
        header[26..28].copy_from_slice(&3u16.to_le_bytes());
        header[28..30].copy_from_slice(&0xFFFEu16.to_le_bytes());
        header[30..32].copy_from_slice(&9u16.to_le_bytes());
        header[32..34].copy_from_slice(&6u16.to_le_bytes());
        header[44..48].copy_from_slice(&1u32.to_le_bytes()); // 1 FAT sector
        header[48..52].copy_from_slice(&2u32.to_le_bytes()); // dir at sector 2
        header[56..60].copy_from_slice(&4096u32.to_le_bytes()); // mini_cutoff = 4096
        header[60..64].copy_from_slice(&1u32.to_le_bytes()); // miniFAT at sector 1
        header[64..68].copy_from_slice(&1u32.to_le_bytes()); // 1 miniFAT sector
        header[68..72].copy_from_slice(&ENDOFCHAIN.to_le_bytes());
        header[76..80].copy_from_slice(&3u32.to_le_bytes()); // FAT at sector 3
        for i in 1..109 {
            header[76 + i * 4..80 + i * 4].copy_from_slice(&FREESECT.to_le_bytes());
        }

        let mut file = header;
        file.extend_from_slice(&s0);
        file.extend_from_slice(&s1);
        file.extend_from_slice(&s2);
        file.extend_from_slice(&s3);

        let mut archive = Ole2Archive::open(Cursor::new(&file)).unwrap();
        // Case-insensitive lookup + MiniFAT read
        assert_eq!(archive.read_stream("small").unwrap().unwrap(), payload);

        // Patch MiniFAT sector 1 to loop back to sector 0.
        let minifat_off = 512 + 512;
        file[minifat_off + 4..minifat_off + 8].copy_from_slice(&0u32.to_le_bytes());
        let mut cyclic = Ole2Archive::open(Cursor::new(&file)).unwrap();
        assert!(
            cyclic
                .read_stream("small")
                .unwrap_err()
                .to_string()
                .contains("cyclic")
        );
    }

    #[test]
    fn extracts_rtf_cjk_gbk_unicode_and_skips_non_body_destinations() {
        // GBK bytes for "中文" = D6 D0 CE C4; \u27979? = "测", \u-29608? (0x8C58? wait: "试" = 0x8BD5 = 35797 -> -29739)
        // Verify: 35797i32 - 65536 = -29739 -> (-29739 & 0xFFFF) as u16 = 0x8BD5 = '试'.
        let rtf = concat!(
            r"{\rtf1\ansi\ansicpg936\uc1",
            r"{\fonttbl{\f0 SimSun;}}",
            r"{\colortbl;\red0\green0\blue0;}",
            r"{\*\generator SecretGenerator 1.0;}",
            r"{\header HeaderText}",
            r"{\field{\*\fldinst HYPERLINK https://example.com}{\fldrslt VisibleLink}}",
            r"\par \'d6\'d0\'ce\'c4\u27979?\u-29739? \emdash\~OK}",
        );
        let text = rtf_text(rtf.as_bytes()).unwrap();
        assert!(text.contains("VisibleLink"), "{text}");
        assert!(text.contains("中文测试 — OK"), "{text}");
        assert!(!text.contains("SimSun"), "{text}");
        assert!(!text.contains("SecretGenerator"), "{text}");
        assert!(!text.contains("HeaderText"), "{text}");
        assert!(!text.contains("HYPERLINK"), "{text}");

        // Invalid RTF rejected
        assert!(rtf_text(b"not an rtf file").is_err());
    }

    #[test]
    fn extracts_srt_and_vtt_subtitles_stripping_tags_and_deduplicating() {
        let srt = "\u{FEFF}1\r\n00:00:05,200 --> 00:00:08,000\r\n{\\an8}<i>第一句台词</i>\r\n\r\n2\r\n00:00:08,000 --> 00:00:10,500\r\n第一句台词\r\n\r\n3\r\n01:02:03,000 --> 01:02:05,000\r\nSecond &amp; <b>final</b> line\r\n";
        let srt_out = subtitle_text(srt.as_bytes()).unwrap();
        assert_eq!(
            srt_out,
            "[00:05] 第一句台词\n[01:02:03] Second & final line"
        );

        let vtt = "WEBVTT\nKind: captions\n\nNOTE\nignore this comment\n\nSTYLE\n::cue { color: white; }\n\ncue-1\n00:01.000 --> 00:03.000\n<v Alice>Rolling line one\n\ncue-2\n00:03.000 --> 00:05.000\nRolling line one\nRolling line two\n";
        let vtt_out = subtitle_text(vtt.as_bytes()).unwrap();
        assert_eq!(
            vtt_out,
            "[00:01] Rolling line one\n[00:03] Rolling line two"
        );
    }
}
