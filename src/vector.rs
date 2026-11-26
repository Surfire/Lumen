//! Packed IEEE-754 binary16 storage, with a reader for legacy binary32 blobs.
use anyhow::Result;
use rusqlite::Connection;

fn to_half(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exponent = ((bits >> 23) & 0xff) as i32 - 127;
    let fraction = bits & 0x7fffff;
    let magnitude = match exponent {
        128 if fraction != 0 => 0x7c00 | ((fraction >> 13) as u16).max(1),
        16..=128 => 0x7c00,
        -14..=15 => (((exponent + 15) as u16) << 10) + round_shift(fraction, 13),
        -25..=-15 => round_shift(fraction | 0x800000, (-exponent - 1) as u32),
        _ => 0,
    };
    sign | magnitude
}

fn round_shift(value: u32, shift: u32) -> u16 {
    // Round to nearest, breaking ties toward an even significand.
    ((value + (1 << (shift - 1)) - 1 + ((value >> shift) & 1)) >> shift) as u16
}

fn from_half(bits: u16) -> f32 {
    let sign = u32::from(bits & 0x8000) << 16;
    let fraction = u32::from(bits & 0x03ff);
    let magnitude = match (bits >> 10) & 0x1f {
        0 if fraction == 0 => 0,
        0 => {
            let shift = fraction.leading_zeros() - 21;
            ((113 - shift) << 23) | (((fraction << shift) & 0x03ff) << 13)
        }
        31 => 0x7f800000 | (fraction << 13),
        exponent => ((u32::from(exponent) + 112) << 23) | (fraction << 13),
    };
    f32::from_bits(sign | magnitude)
}

pub(super) fn pack(values: &[f32]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|&f| to_half(f).to_le_bytes())
        .collect()
}

fn unpack_into(bytes: &[u8], dims: usize, values: &mut Vec<f32>) -> bool {
    if bytes.len() == dims * 2 {
        values.extend(
            bytes
                .chunks_exact(2)
                .map(|b| from_half(u16::from_le_bytes([b[0], b[1]]))),
        );
    } else if bytes.len() == dims * 4 {
        values.extend(
            bytes
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])),
        );
    } else {
        return false;
    }
    true
}

pub(super) struct Matrix<T> {
    dims: usize,
    values: Vec<f32>,
    pub rows: Vec<T>,
}

impl<T> Matrix<T> {
    pub fn new(dims: usize) -> Self {
        Self {
            dims,
            values: Vec::new(),
            rows: Vec::new(),
        }
    }

    pub fn push(&mut self, row: T, bytes: &[u8]) -> bool {
        if !unpack_into(bytes, self.dims, &mut self.values) {
            return false;
        }
        self.rows.push(row);
        true
    }

    pub fn scores<'a>(&'a self, query: &'a [f32]) -> impl Iterator<Item = f32> + 'a {
        assert_eq!(query.len(), self.dims);
        self.values
            .chunks_exact(self.dims)
            .map(move |row| row.iter().zip(query).map(|(a, b)| a * b).sum())
    }
}

/// Owned by one search connection, with the model fixed by its loader. Read
/// data_version inside the ranking transaction before other catalog reads so
/// matrix rows, scope rules and hit metadata all belong to the same snapshot.
pub(super) struct MatrixCache<T>(Option<(i64, Matrix<T>)>);

impl<T> Default for MatrixCache<T> {
    fn default() -> Self {
        Self(None)
    }
}

impl<T> MatrixCache<T> {
    fn get_with_version(
        &mut self,
        snapshot: &Connection,
        version: i64,
        load: impl FnOnce(&Connection) -> Result<Matrix<T>>,
    ) -> Result<&Matrix<T>> {
        debug_assert!(!snapshot.is_autocommit());
        if self.0.as_ref().is_none_or(|(saved, _)| *saved != version) {
            // Drop the old matrix before allocating its replacement.
            self.0 = None;
            self.0 = Some((version, load(snapshot)?));
        }
        Ok(&self.0.as_ref().expect("loaded matrix").1)
    }

    pub fn get(
        &mut self,
        snapshot: &Connection,
        load: impl FnOnce(&Connection) -> Result<Matrix<T>>,
    ) -> Result<&Matrix<T>> {
        let version = crate::name_fast::data_version(snapshot)?;
        self.get_with_version(snapshot, version, load)
    }

    #[allow(dead_code)] // Wired by semantic and image_search after Phase 3 merge.
    pub fn get_for_bucket(
        &mut self,
        snapshot: &Connection,
        bucket_key: &str,
        load: impl FnOnce(&Connection) -> Result<Matrix<T>>,
    ) -> Result<&Matrix<T>> {
        let version = crate::bucket_generation(snapshot, bucket_key)?;
        self.get_with_version(snapshot, version, load)
    }
}

/// The gate is max(min_cosine, mean + z_threshold * stddev). Use population
/// variance over the finite candidates, before grouping by document or top-k.
pub(super) fn adaptive_floor(scores: &[f32], min_cosine: f32, z_threshold: f64) -> f64 {
    let (mut count, mut mean, mut m2) = (0_u32, 0.0_f64, 0.0_f64);
    for score in scores.iter().copied().filter(|n| n.is_finite()) {
        let score = f64::from(score);
        count += 1;
        let delta = score - mean;
        mean += delta / f64::from(count);
        m2 += delta * (score - mean);
    }
    let min_cosine = f64::from(min_cosine);
    if count >= 8 {
        let stddev = (m2 / f64::from(count)).sqrt();
        if stddev > 1e-6 {
            return min_cosine.max(mean + z_threshold * stddev);
        }
    }
    min_cosine
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_half_roundtrips_and_known_ieee_values_decode() {
        for bits in 0..=u16::MAX {
            assert_eq!(to_half(from_half(bits)), bits, "{bits:04x}");
        }
        for (bits, expected) in [
            (0x0001, 2_f32.powi(-24)),
            (0x03ff, 1023.0 * 2_f32.powi(-24)),
            (0x0400, 2_f32.powi(-14)),
            (0x3555, 0.33325195),
            (0xbc00, -1.0),
            (0x7bff, 65504.0),
            (0x8000, -0.0),
        ] {
            assert_eq!(from_half(bits).to_bits(), expected.to_bits());
        }
        assert_eq!(to_half(1.0 + 2_f32.powi(-11)), 0x3c00);
        assert_eq!(to_half(1.0 + 3.0 * 2_f32.powi(-11)), 0x3c02);
        assert_eq!(to_half(2_f32.powi(-25)), 0);
        assert_eq!(to_half(3.0 * 2_f32.powi(-25)), 2);
        assert_eq!(to_half(65520.0), 0x7c00);
        assert!(from_half(to_half(f32::NAN)).is_nan());
        assert_eq!(pack(&[1.0, -2.0]), [0x00, 0x3c, 0x00, 0xc0]);
    }

    #[test]
    fn adaptive_gate_keeps_only_outliers_when_there_is_enough_signal() {
        let scores = [0.72, 0.73, 0.69, 0.74, 0.72, 0.71, 0.70, 0.94, f32::NAN];
        let floor = adaptive_floor(&scores, 0.65, 1.0);
        assert!(floor > 0.74 && floor < 0.94);
        assert_eq!(adaptive_floor(&scores[..7], 0.65, 1.0), f64::from(0.65_f32));
        assert_eq!(adaptive_floor(&[0.8; 8], 0.65, 1.0), f64::from(0.65_f32));
        assert_eq!(
            adaptive_floor(&[0.0, 0.1, 0.1, 0.2, 0.2, 0.1, 0.1, 0.3], 0.65, 1.0),
            f64::from(0.65_f32)
        );
    }

    #[test]
    fn get_for_bucket_ignores_unrelated_writes_and_falls_back_on_legacy_dbs() {
        let dir = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-vector-bucket-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("index.sqlite");

        // Legacy DB without bucket counters falls back to PRAGMA data_version.
        let legacy_db = dir.join("legacy.sqlite");
        let legacy_writer = Connection::open(&legacy_db).unwrap();
        legacy_writer
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 CREATE TABLE info(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 CREATE TABLE other(n INTEGER);",
            )
            .unwrap();
        let legacy_reader =
            Connection::open_with_flags(&legacy_db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .unwrap();
        let mut legacy_cache = MatrixCache::<i64>::default();
        let mut legacy_loads = 0;
        let load_const = |loads: &mut usize, marker: i64| {
            *loads += 1;
            let mut m = Matrix::new(1);
            m.push(marker, &pack(&[1.0]));
            Ok(m)
        };
        let tx = legacy_reader.unchecked_transaction().unwrap();
        tx.prepare_cached("SELECT 1 FROM main.sqlite_schema LIMIT 1")
            .unwrap()
            .exists([])
            .unwrap();
        assert_eq!(
            legacy_cache
                .get_for_bucket(&tx, "vec_generation", |_| load_const(&mut legacy_loads, 1))
                .unwrap()
                .rows,
            [1]
        );
        tx.commit().unwrap();
        assert_eq!(legacy_loads, 1);

        legacy_writer
            .execute("INSERT INTO other VALUES (1)", [])
            .unwrap();
        let tx = legacy_reader.unchecked_transaction().unwrap();
        tx.prepare_cached("SELECT 1 FROM main.sqlite_schema LIMIT 1")
            .unwrap()
            .exists([])
            .unwrap();
        assert_eq!(
            legacy_cache
                .get_for_bucket(&tx, "vec_generation", |_| load_const(&mut legacy_loads, 2))
                .unwrap()
                .rows,
            [2]
        );
        tx.commit().unwrap();
        assert_eq!(legacy_loads, 2);

        // Full Lumen DB with independent buckets does not evict on unrelated writes.
        let (writer, _) = crate::open_write(&db, false).unwrap();
        let reader = crate::open_read(&db).unwrap();
        let mut cache = MatrixCache::<i64>::default();
        let mut loads = 0;

        let read_once = |cache: &mut MatrixCache<i64>, loads: &mut usize, marker: i64| {
            let tx = reader.unchecked_transaction().unwrap();
            tx.prepare_cached("SELECT 1 FROM main.sqlite_schema LIMIT 1")
                .unwrap()
                .exists([])
                .unwrap();
            let rows = cache
                .get_for_bucket(&tx, "vec_generation", |_| load_const(loads, marker))
                .unwrap()
                .rows
                .clone();
            tx.commit().unwrap();
            rows
        };

        assert_eq!(read_once(&mut cache, &mut loads, 10), [10]);
        assert_eq!(loads, 1);

        // Unrelated item + image writes advance data_version and other buckets, NOT vec_generation.
        writer
            .execute_batch(
                "INSERT INTO item VALUES(1,'/a','a','file','local','a','','','/a',0);
                 INSERT INTO image_scope VALUES(1,'/img',1);",
            )
            .unwrap();
        assert_eq!(read_once(&mut cache, &mut loads, 20), [10]);
        assert_eq!(loads, 1);

        // Semantic write advances vec_generation and reloads the matrix.
        writer
            .execute_batch(
                "INSERT INTO document VALUES(1,'body','body');
                 INSERT INTO semantic_chunk(id,document_id,start_byte,end_byte) VALUES(1,1,0,4);",
            )
            .unwrap();
        assert_eq!(read_once(&mut cache, &mut loads, 30), [30]);
        assert_eq!(loads, 2);

        drop((legacy_reader, legacy_writer, reader, writer));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
