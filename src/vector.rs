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

fn unpack_into(bytes: &[u8], dims: usize, values: &mut Vec<u16>) -> bool {
    if Some(bytes.len()) == dims.checked_mul(2) {
        values.extend(
            bytes
                .as_chunks::<2>()
                .0
                .iter()
                .map(|b| u16::from_le_bytes(*b)),
        );
    } else if Some(bytes.len()) == dims.checked_mul(4) {
        values.extend(
            bytes
                .as_chunks::<4>()
                .0
                .iter()
                .map(|b| to_half(f32::from_le_bytes(*b))),
        );
    } else {
        return false;
    }
    true
}

#[cfg(any(not(target_arch = "aarch64"), test))]
#[inline]
fn dot_f16_f32_scalar(row: &[u16], query: &[f32]) -> f32 {
    assert_eq!(row.len(), query.len());
    row.iter()
        .zip(query)
        .map(|(&bits, &q)| from_half(bits) * q)
        .sum()
}

#[cfg(target_arch = "aarch64")]
#[inline]
fn f16x8_to_f32x4x2(
    src: std::arch::aarch64::uint16x8_t,
) -> (
    std::arch::aarch64::float32x4_t,
    std::arch::aarch64::float32x4_t,
) {
    use std::arch::aarch64::float32x4_t;
    let lo: float32x4_t;
    let hi: float32x4_t;
    // SAFETY: `fcvtl` and `fcvtl2` are ARMv8 baseline NEON instructions that
    // operate purely on vector registers with no memory access or side effects.
    // `lo` uses `out` so it cannot alias `src` before `fcvtl2` reads `src.8h`.
    unsafe {
        core::arch::asm!(
            "fcvtl {lo:v}.4s, {src:v}.4h",
            "fcvtl2 {hi:v}.4s, {src:v}.8h",
            src = in(vreg) src,
            lo = out(vreg) lo,
            hi = lateout(vreg) hi,
            options(pure, nomem, nostack),
        );
    }
    (lo, hi)
}

#[cfg(target_arch = "aarch64")]
#[inline]
fn dot_f16_f32(row: &[u16], query: &[f32]) -> f32 {
    use std::arch::aarch64::{vaddq_f32, vaddvq_f32, vdupq_n_f32, vfmaq_f32, vld1q_f32, vld1q_u16};

    assert_eq!(row.len(), query.len());
    let (row_chunks, row_tail) = row.as_chunks::<16>();
    let (query_chunks, query_tail) = query.as_chunks::<16>();

    // SAFETY: `as_chunks::<16>` ensures each chunk contains 16 valid elements,
    // keeping all 8-u16 and 4-f32 NEON loads within slice bounds.
    let mut sum = unsafe {
        let mut acc0 = vdupq_n_f32(0.0);
        let mut acc1 = vdupq_n_f32(0.0);
        let mut acc2 = vdupq_n_f32(0.0);
        let mut acc3 = vdupq_n_f32(0.0);

        for (r, q) in row_chunks.iter().zip(query_chunks) {
            let rp = r.as_ptr();
            let qp = q.as_ptr();

            let h0 = vld1q_u16(rp);
            let h1 = vld1q_u16(rp.add(8));
            let (a0, a1) = f16x8_to_f32x4x2(h0);
            let (a2, a3) = f16x8_to_f32x4x2(h1);

            let q0 = vld1q_f32(qp);
            let q1 = vld1q_f32(qp.add(4));
            let q2 = vld1q_f32(qp.add(8));
            let q3 = vld1q_f32(qp.add(12));

            acc0 = vfmaq_f32(acc0, a0, q0);
            acc1 = vfmaq_f32(acc1, a1, q1);
            acc2 = vfmaq_f32(acc2, a2, q2);
            acc3 = vfmaq_f32(acc3, a3, q3);
        }

        let acc01 = vaddq_f32(acc0, acc1);
        let acc23 = vaddq_f32(acc2, acc3);
        vaddvq_f32(vaddq_f32(acc01, acc23))
    };

    for (&bits, &q) in row_tail.iter().zip(query_tail) {
        sum += from_half(bits) * q;
    }
    sum
}

#[cfg(not(target_arch = "aarch64"))]
#[inline]
fn dot_f16_f32(row: &[u16], query: &[f32]) -> f32 {
    dot_f16_f32_scalar(row, query)
}

pub(super) struct Matrix<T> {
    dims: usize,
    values: Vec<u16>,
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

    pub fn scores(&self, query: &[f32]) -> std::vec::IntoIter<f32> {
        const PARALLEL_THRESHOLD: usize = 4096;
        assert_eq!(query.len(), self.dims);
        let n_rows = self.rows.len();
        if self.dims == 0 || n_rows == 0 {
            return vec![0.0_f32; n_rows].into_iter();
        }
        let mut out = vec![0.0_f32; n_rows];
        if n_rows < PARALLEL_THRESHOLD {
            for (row, dst) in self.values.chunks_exact(self.dims).zip(&mut out) {
                *dst = dot_f16_f32(row, query);
            }
        } else {
            let dims = self.dims;
            let threads = std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(4)
                .clamp(2, 8);
            let rows_per_chunk = n_rows.div_ceil(threads);
            let vals_per_chunk = rows_per_chunk * dims;
            std::thread::scope(|s| {
                let mut val_chunks = self.values.chunks(vals_per_chunk);
                let mut out_chunks = out.chunks_mut(rows_per_chunk);
                let first = val_chunks.next().zip(out_chunks.next());
                for (val_chunk, out_chunk) in val_chunks.zip(out_chunks) {
                    s.spawn(move || {
                        for (row, dst) in val_chunk.chunks_exact(dims).zip(out_chunk) {
                            *dst = dot_f16_f32(row, query);
                        }
                    });
                }
                if let Some((val_chunk, out_chunk)) = first {
                    for (row, dst) in val_chunk.chunks_exact(dims).zip(out_chunk) {
                        *dst = dot_f16_f32(row, query);
                    }
                }
            });
        }
        out.into_iter()
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

    #[test]
    fn packed_u16_storage_and_legacy_f32_push() {
        let mut matrix = Matrix::new(4);
        let row0 = [1.0_f32, -2.5, 0.25, 2_f32.powi(-20)];
        let row1 = [-0.5_f32, 3.0, 0.0, -2_f32.powi(-18)];

        // Packed binary16 push copies 2 bytes per dimension directly.
        assert!(matrix.push(0_usize, &pack(&row0)));
        assert_eq!(matrix.values.len(), 4);
        assert_eq!(std::mem::size_of_val(matrix.values.as_slice()), 8);

        // Legacy 4-byte f32 blob push converts via to_half into u16 storage.
        let legacy_bytes: Vec<u8> = row1.iter().flat_map(|f| f.to_le_bytes()).collect();
        assert!(matrix.push(1_usize, &legacy_bytes));
        assert_eq!(matrix.rows, [0, 1]);
        assert_eq!(matrix.values.len(), 8);
        assert_eq!(
            &matrix.values[4..8],
            &row1.map(to_half),
            "legacy f32 blob should convert via to_half"
        );

        // Mismatched byte lengths must be rejected without mutating rows or values.
        assert!(!matrix.push(2_usize, &[0_u8; 6]));
        assert!(!matrix.push(2_usize, &[0_u8; 12]));
        assert_eq!(matrix.rows, [0, 1]);
        assert_eq!(matrix.values.len(), 8);

        let query = [0.5_f32, -1.0, 4.0, 1024.0];
        let got: Vec<f32> = matrix.scores(&query).collect();
        let expected: Vec<f32> = matrix
            .values
            .as_chunks::<4>()
            .0
            .iter()
            .map(|row| dot_f16_f32_scalar(row, &query))
            .collect();
        for (g, e) in got.iter().zip(&expected) {
            assert!((g - e).abs() < 1e-4, "got={g} expected={e}");
        }
    }

    #[cfg(target_arch = "aarch64")]
    #[test]
    fn neon_fcvtl_matches_from_half_for_all_u16() {
        use std::arch::aarch64::vld1q_u16;

        let all_bits: Vec<u16> = (0..=u16::MAX).collect();
        for chunk in all_bits.as_chunks::<8>().0 {
            let v = unsafe { vld1q_u16(chunk.as_ptr()) };
            let (lo, hi) = f16x8_to_f32x4x2(v);
            let converted: [f32; 8] = unsafe {
                let lo_arr: [f32; 4] = std::mem::transmute(lo);
                let hi_arr: [f32; 4] = std::mem::transmute(hi);
                [
                    lo_arr[0], lo_arr[1], lo_arr[2], lo_arr[3], hi_arr[0], hi_arr[1], hi_arr[2],
                    hi_arr[3],
                ]
            };
            for (&bits, &got) in chunk.iter().zip(&converted) {
                let expected = from_half(bits);
                if expected.is_nan() {
                    assert!(got.is_nan(), "expected NaN for {bits:#06x}");
                } else {
                    assert_eq!(
                        got.to_bits(),
                        expected.to_bits(),
                        "mismatch for half {bits:#06x}"
                    );
                }
            }
        }
    }

    #[test]
    fn dot_parity_across_dims_with_negatives_and_subnormals() {
        let special = [
            -0.0_f32,
            2_f32.powi(-24),           // smallest positive binary16 subnormal
            -1023.0 * 2_f32.powi(-24), // largest negative binary16 subnormal
            0.333_251_95,
            -1.75,
            12.5,
            -0.0625,
            2_f32.powi(-14), // smallest normal
        ];
        for dims in [1_usize, 7, 15, 16, 17, 768] {
            let mut matrix = Matrix::new(dims);
            // Push multiple rows so odd dimensions exercise unaligned 2-byte row starts.
            for row_idx in 0..5 {
                let raw: Vec<f32> = (0..dims)
                    .map(|j| {
                        let base = special[(j + row_idx) % special.len()];
                        if j % 5 == 0 {
                            base
                        } else {
                            let sign = if (j + row_idx) % 2 == 0 { 1.0 } else { -1.0 };
                            sign * (((j * 13 + row_idx * 7) % 100) as f32 / 257.0)
                        }
                    })
                    .collect();
                assert!(matrix.push(row_idx, &pack(&raw)));
            }
            let query: Vec<f32> = (0..dims)
                .map(|j| {
                    let sign = if j % 3 == 0 { -1.0 } else { 1.0 };
                    sign * (((j * 17 + 3) % 89) as f32 / 113.0 + 0.05)
                })
                .collect();

            let actual: Vec<f32> = matrix.scores(&query).collect();
            assert_eq!(actual.len(), 5);
            for (row_idx, &got) in actual.iter().enumerate() {
                let row = &matrix.values[row_idx * dims..(row_idx + 1) * dims];
                let expected = dot_f16_f32_scalar(row, &query);
                assert!(
                    (got - expected).abs() < 1e-4,
                    "dims={dims} row={row_idx}: got={got} expected={expected}"
                );
            }
        }
    }

    #[test]
    fn parallel_scores_parity_above_threshold() {
        const ROWS: usize = 5000;
        const DIMS: usize = 35; // Exercises multi-16 NEON loop + tail + unaligned row offsets.
        let mut matrix = Matrix::new(DIMS);
        for row_idx in 0..ROWS {
            let raw: Vec<f32> = (0..DIMS)
                .map(|j| {
                    let sign = if (row_idx + j) % 2 == 0 { 1.0 } else { -1.0 };
                    let mag = ((row_idx * 31 + j * 17) % 120) as f32 / 300.0;
                    if j == 0 && row_idx % 9 == 0 {
                        sign * 2_f32.powi(-21)
                    } else {
                        sign * mag
                    }
                })
                .collect();
            assert!(matrix.push(row_idx, &pack(&raw)));
        }
        let query: Vec<f32> = (0..DIMS)
            .map(|j| ((j as f32) * 0.13 - 1.5) * 0.25)
            .collect();

        let scores: Vec<f32> = matrix.scores(&query).collect();
        assert_eq!(scores.len(), ROWS);
        for (row_idx, &got) in scores.iter().enumerate() {
            let row = &matrix.values[row_idx * DIMS..(row_idx + 1) * DIMS];
            let expected = dot_f16_f32_scalar(row, &query);
            assert!(
                (got - expected).abs() < 1e-4,
                "row={row_idx}: got={got} expected={expected}"
            );
        }
    }
}
