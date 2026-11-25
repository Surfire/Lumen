# Offline image search backend

Image search has an explicit local folder separate from the name and document
indexes. The engine supports single-frame PNG and JPEG on Apple Silicon.
ImageIO downsamples already-read bytes to at most 512 pixels per side. The
worker encodes those pixels into the same 768-dimensional space as text queries
using the pinned EmbeddingGemma 2 Q8 model and vision projector. Input filenames,
OCR and extracted document text are never sent to the image encoder.

Use the existing local Gemma 2 installation and stage the optional
[official GGUF projector](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/tree/6ea3e3a309d12a4779cfda98b8c19800d2d5da71)
separately. The pinned file is `mmproj-embeddinggemma-2-Q8_0.gguf`
(554,821,056 bytes, SHA-256
`0531309472a6bc6f4b146c3736eee7795ec9db1903c25490d3c937490cef6dd8`).
No model download occurs at runtime. The worker is a verified child with an
authenticated private Unix socket and a bounded request deadline.

```sh
lumen --db "$db" index --root "$synthetic_name_root"
lumen --db "$db" image-scope "$chosen_image_folder"
lumen --db "$db" image-status
lumen --db "$db" image-index --projector "$projector" --max 8
lumen --db "$db" image-serve --projector "$projector"
lumen --db "$db" image-scope --clear
```

`image-index` returns `indexed`, `reused`, `skipped`, `limited`, and
`next_after`. Pass a non-null cursor back with `--after`, then restart without
a cursor for a later refresh. Unchanged image vectors are reused. There are at
most 4,096 stored vectors. Input files are capped at 12 MiB and 32 megapixels.
Cloud-only, provider-managed, denied, and symlinked files stay outside the
image index. Image indexing cannot add entries to the filename catalog.

`image-serve` accepts the existing `{"id":1,"query":"red sailboat","limit":5}`
newline-delimited request and returns `{id,hits}`. Matching hits have
`matched_by: "image_embedding"`, a cosine score, and the indexed
`document_stamp`. Run the existing `validate-hit` before display/activation
with that stamp. Clearing or replacing the image scope drops cached image
vectors and takes effect for existing sessions. Search candidates use a 0.65
cosine floor. The score is a similarity value, and the engineering fixture
does not establish general retrieval accuracy or dependable abstention.

In the native app, choose the folder and projector under Index & Privacy,
then build the image index explicitly. Type \`img description\` in the regular
launcher field. Name and document search remain available without the vision
asset. For reproducible local verification, pass the
synthetic handoff pack's `preview-fixtures` folder:

```sh
cargo build --release --offline
python3 tests/image_retrieval.py target/release/lumen "$fixtures" "$projector"
```
