#ifndef LUMEN_CORE_H
#define LUMEN_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct LumenSessionHandle LumenSessionHandle;

/* Open a read-only catalog. Paths must be nonempty NUL-terminated UTF-8. root_path may
 * be NULL; the saved catalog scope is authoritative, as with lumen serve.
 * Returns NULL on failure. Serialize all calls on each handle, including close. */
LumenSessionHandle *lumen_session_open(const char *database_path, const char *root_path);
LumenSessionHandle *lumen_session_open_lane(const char *database_path, const char *root_path,
                                            bool with_name_index);

/* One NUL-terminated UTF-8 JSON request (no line framing). Use the lumen serve
 * name/text search, cached-hit validation, status, or excerpt fields; op may be omitted,
 * otherwise it must match the function. Replies carry id and hits/valid/status/context,
 * or error (with id if decoded). Free every reply with lumen_string_free. */
char *lumen_session_search_json(LumenSessionHandle *handle, const char *request_json);
char *lumen_session_validate_json(LumenSessionHandle *handle, const char *request_json);
char *lumen_session_status_json(LumenSessionHandle *handle, const char *request_json);
char *lumen_session_excerpt_json(LumenSessionHandle *handle, const char *request_json);
char *lumen_preview_xlsx_json(const uint8_t *bytes, size_t len);

/* NULL is a no-op. Release each non-NULL handle and reply exactly once. */
void lumen_session_close(LumenSessionHandle *handle);
void lumen_string_free(char *ptr);

/* macOS ships libarchive without SDK headers; expose only the ZIP reader ABI used by LauncherUpdater. */
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, unsigned long);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_extract(struct archive *, struct archive_entry *, int);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_EXTRACT_NO_OVERWRITE 0x0008
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200

#ifdef __cplusplus
}
#endif
#endif
