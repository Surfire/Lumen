#ifndef LUMEN_CORE_H
#define LUMEN_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LumenSessionHandle LumenSessionHandle;

/* Open a read-only catalog. Paths must be nonempty NUL-terminated UTF-8. root_path may
 * be NULL; the saved catalog scope is authoritative, as with lumen serve.
 * Returns NULL on failure. Serialize all calls on each handle, including close. */
LumenSessionHandle *lumen_session_open(const char *database_path, const char *root_path);

/* One NUL-terminated UTF-8 JSON request (no line framing). Use the lumen serve
 * name/text search or cached-hit validation fields; op may be omitted, otherwise
 * it must match the function. Replies carry id and hits/valid, or error (with id
 * if decoded). Free every reply with lumen_string_free. */
char *lumen_session_search_json(LumenSessionHandle *handle, const char *request_json);
char *lumen_session_validate_json(LumenSessionHandle *handle, const char *request_json);

/* NULL is a no-op. Release each non-NULL handle and reply exactly once. */
void lumen_session_close(LumenSessionHandle *handle);
void lumen_string_free(char *ptr);

#ifdef __cplusplus
}
#endif
#endif
