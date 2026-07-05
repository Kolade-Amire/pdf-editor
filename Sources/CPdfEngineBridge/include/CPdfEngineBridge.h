#ifndef CPdfEngineBridge_h
#define CPdfEngineBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pdf_bridge_document pdf_bridge_document;

typedef enum {
    PDF_BRIDGE_BACKEND_MUPDF_EDITABLE = 0,
    PDF_BRIDGE_BACKEND_MUPDF_READ_ONLY = 1,
} pdf_bridge_backend_kind;

typedef enum {
    PDF_BRIDGE_SAVE_MODE_AUTOMATIC = 0,
    PDF_BRIDGE_SAVE_MODE_INCREMENTAL = 1,
    PDF_BRIDGE_SAVE_MODE_FULL_REWRITE = 2,
} pdf_bridge_save_mode;

typedef enum {
    PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE = 0,
    PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK = 1,
    PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED = 2,
} pdf_bridge_persistence_mode;

typedef enum {
    PDF_BRIDGE_ISSUE_ENCRYPTED = 0,
    PDF_BRIDGE_ISSUE_IMAGE_ONLY = 1,
    PDF_BRIDGE_ISSUE_SIGNED = 2,
    PDF_BRIDGE_ISSUE_UNSUPPORTED_FONT = 3,
    PDF_BRIDGE_ISSUE_UNSUPPORTED_STRUCTURE = 4,
    PDF_BRIDGE_ISSUE_UNSUPPORTED_TRANSFORM = 5,
    PDF_BRIDGE_ISSUE_MISSING_FONT_METRICS = 6,
    PDF_BRIDGE_ISSUE_RIGHTS_RESTRICTED = 7,
    PDF_BRIDGE_ISSUE_PASSWORD_REQUIRED = 8,
    PDF_BRIDGE_ISSUE_TEXT_OVERFLOW = 9,
    PDF_BRIDGE_ISSUE_VALIDATION_FAILED = 10,
    PDF_BRIDGE_ISSUE_ENGINE_UNAVAILABLE = 11,
} pdf_bridge_issue_kind;

typedef enum {
    PDF_BRIDGE_FALLBACK_FAMILY_SANS = 0,
    PDF_BRIDGE_FALLBACK_FAMILY_SERIF = 1,
    PDF_BRIDGE_FALLBACK_FAMILY_MONOSPACE = 2,
} pdf_bridge_fallback_family;

typedef enum {
    PDF_BRIDGE_FALLBACK_SOURCE_ORIGINAL = 0,
    PDF_BRIDGE_FALLBACK_SOURCE_BASE14 = 1,
} pdf_bridge_fallback_source;

typedef enum {
    PDF_BRIDGE_FONT_MODE_READ_ONLY = 0,
    PDF_BRIDGE_FONT_MODE_ORIGINAL = 1,
    PDF_BRIDGE_FONT_MODE_BASE14 = 2,
} pdf_bridge_font_mode;

typedef enum {
    PDF_BRIDGE_TEXT_ENCODING_LATIN = 0,
    PDF_BRIDGE_TEXT_ENCODING_GREEK = 1,
    PDF_BRIDGE_TEXT_ENCODING_CYRILLIC = 2,
    PDF_BRIDGE_TEXT_ENCODING_IDENTITY = 3,
} pdf_bridge_text_encoding;

typedef struct {
    double x;
    double y;
} pdf_bridge_point;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} pdf_bridge_rect;

typedef struct {
    pdf_bridge_point top_left;
    pdf_bridge_point top_right;
    pdf_bridge_point bottom_left;
    pdf_bridge_point bottom_right;
} pdf_bridge_quad;

typedef struct {
    double red;
    double green;
    double blue;
    double alpha;
} pdf_bridge_color;

typedef struct {
    pdf_bridge_issue_kind kind;
    char *message;
    int32_t page_index;
    int32_t native_block_id;
} pdf_bridge_issue;

typedef struct {
    int32_t page_index;
    bool is_editable;
    size_t issue_count;
    pdf_bridge_issue *issues;
} pdf_bridge_page_report;

typedef struct {
    bool is_editable;
    size_t issue_count;
    pdf_bridge_issue *issues;
    size_t page_report_count;
    pdf_bridge_page_report *page_reports;
} pdf_bridge_editability_report;

typedef struct {
    char *source_path;
    char *title;
    int32_t page_count;
    bool is_encrypted;
    bool is_locked;
    bool can_edit;
    bool is_signed;
    pdf_bridge_backend_kind backend_kind;
} pdf_bridge_document_info;

typedef struct {
    char *requested_font_postscript_name;
    char *resolved_font_name;
    pdf_bridge_fallback_family family;
    pdf_bridge_fallback_source source;
    char *warning;
    pdf_bridge_font_mode font_mode;
    pdf_bridge_text_encoding encoding;
} pdf_bridge_font_plan;

typedef struct {
    int32_t native_line_id;
    pdf_bridge_rect bounds;
    size_t quad_count;
    pdf_bridge_quad *quads;
    char *text;
} pdf_bridge_line_fragment;

typedef struct {
    int32_t page_index;
    int32_t native_block_id;
    pdf_bridge_rect bounds;
    char *text;
    char *font_postscript_name;
    double font_size;
    pdf_bridge_color color;
    double character_spacing;
    double horizontal_scale;
    double rise;
    bool is_bold;
    bool is_italic;
    bool is_monospaced;
    bool is_serif;
    bool is_editable;
    bool has_failure_reason;
    pdf_bridge_issue failure_reason;
    pdf_bridge_font_plan fallback_plan;
    pdf_bridge_persistence_mode persistence_mode;
    char *persistence_message;
    size_t line_count;
    pdf_bridge_line_fragment *lines;
} pdf_bridge_text_block;

typedef struct {
    size_t count;
    pdf_bridge_text_block *items;
} pdf_bridge_text_block_array;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t stride;
    unsigned char *pixels;
} pdf_bridge_rendered_page;

typedef struct {
    int32_t page_index;
    int32_t native_block_id;
    const char *replacement_text;
} pdf_bridge_text_edit;

typedef struct {
    int32_t page_index;
    int32_t native_block_id;
    pdf_bridge_persistence_mode mode;
    char *message;
} pdf_bridge_block_outcome;

typedef struct {
    size_t outcome_count;
    pdf_bridge_block_outcome *outcomes;
    size_t warning_count;
    char **warnings;
    int32_t true_rewrite_count;
    int32_t overlay_fallback_count;
    int32_t blocked_count;
} pdf_bridge_save_preflight_report;

typedef struct {
    bool is_valid;
    char *validator;
    size_t message_count;
    char **messages;
} pdf_bridge_validation_report;

typedef struct {
    int32_t applied_edit_count;
    int32_t true_rewrite_count;
    int32_t overlay_fallback_count;
    pdf_bridge_save_mode used_save_mode;
    size_t outcome_count;
    pdf_bridge_block_outcome *outcomes;
    pdf_bridge_validation_report validation;
} pdf_bridge_save_result;

bool pdf_engine_bridge_is_available(void);

int pdf_bridge_open_document(
    const char *path,
    pdf_bridge_document **out_document,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
);

int pdf_bridge_unlock_document(
    pdf_bridge_document *document,
    const char *password,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
);

void pdf_bridge_close_document(pdf_bridge_document *document);

int pdf_bridge_render_page(
    pdf_bridge_document *document,
    int32_t page_index,
    double scale,
    pdf_bridge_rendered_page *out_page,
    char **out_error
);

int pdf_bridge_extract_blocks(
    pdf_bridge_document *document,
    int32_t page_index,
    pdf_bridge_text_block_array *out_blocks,
    char **out_error
);

int pdf_bridge_extract_blocks_with_report(
    pdf_bridge_document *document,
    int32_t page_index,
    pdf_bridge_text_block_array *out_blocks,
    pdf_bridge_page_report *out_page_report,
    char **out_error
);

int pdf_bridge_save_document(
    pdf_bridge_document *document,
    const char *destination_path,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_mode requested_mode,
    bool allow_overlay_fallback,
    pdf_bridge_save_result *out_result,
    char **out_error
);

int pdf_bridge_preflight_save(
    pdf_bridge_document *document,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_preflight_report *out_report,
    char **out_error
);

int pdf_bridge_validate_file(
    const char *path,
    pdf_bridge_validation_report *out_report,
    char **out_error
);

void pdf_bridge_free_document_info(pdf_bridge_document_info *info);
void pdf_bridge_free_editability_report(pdf_bridge_editability_report *report);
void pdf_bridge_free_page_report(pdf_bridge_page_report *report);
void pdf_bridge_free_text_block_array(pdf_bridge_text_block_array *blocks);
void pdf_bridge_free_rendered_page(pdf_bridge_rendered_page *page);
void pdf_bridge_free_save_preflight_report(pdf_bridge_save_preflight_report *report);
void pdf_bridge_free_validation_report(pdf_bridge_validation_report *report);
void pdf_bridge_free_save_result(pdf_bridge_save_result *result);
void pdf_bridge_free_error(char *error_message);

#ifdef __cplusplus
}
#endif

#endif /* CPdfEngineBridge_h */
