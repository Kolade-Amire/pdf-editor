#include "CPdfEngineBridge.h"

#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef PDF_EDITOR_BRIDGE_WITH_MUPDF
#include "mupdf/fitz.h"
#include "mupdf/pdf.h"
#endif

static char *bridge_strdup(const char *value)
{
    size_t length;
    char *copy;

    if (value == NULL) {
        return NULL;
    }

    length = strlen(value);
    copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, value, length + 1);
    return copy;
}

static char *bridge_strndup(const char *value, size_t length)
{
    char *copy;

    copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, value, length);
    copy[length] = '\0';
    return copy;
}

void pdf_bridge_free_error(char *error_message)
{
    free(error_message);
}

static void bridge_set_error(char **out_error, const char *message)
{
    if (out_error == NULL) {
        return;
    }

    *out_error = bridge_strdup(message);
}

static void bridge_free_issue(pdf_bridge_issue *issue)
{
    if (issue == NULL) {
        return;
    }

    free(issue->message);
    issue->message = NULL;
}

static void bridge_free_line_fragment(pdf_bridge_line_fragment *line)
{
    if (line == NULL) {
        return;
    }

    free(line->quads);
    line->quads = NULL;
    line->quad_count = 0;

    free(line->text);
    line->text = NULL;
}

static void bridge_clear_text_block(pdf_bridge_text_block *block)
{
    size_t line_index;

    if (block == NULL) {
        return;
    }

    free(block->text);
    block->text = NULL;

    free(block->font_postscript_name);
    block->font_postscript_name = NULL;

    if (block->has_failure_reason) {
        bridge_free_issue(&block->failure_reason);
        block->has_failure_reason = false;
    }

    free(block->fallback_plan.requested_font_postscript_name);
    block->fallback_plan.requested_font_postscript_name = NULL;
    free(block->fallback_plan.resolved_font_name);
    block->fallback_plan.resolved_font_name = NULL;
    free(block->fallback_plan.warning);
    block->fallback_plan.warning = NULL;
    free(block->persistence_message);
    block->persistence_message = NULL;

    for (line_index = 0; line_index < block->line_count; line_index++) {
        bridge_free_line_fragment(&block->lines[line_index]);
    }
    free(block->lines);
    block->lines = NULL;
    block->line_count = 0;
}

#ifndef PDF_EDITOR_BRIDGE_WITH_MUPDF

bool pdf_engine_bridge_is_available(void)
{
    return false;
}

static int bridge_unavailable(char **out_error)
{
    bridge_set_error(out_error, "MuPDF bridge artifacts are unavailable in this checkout.");
    return 0;
}

int pdf_bridge_open_document(
    const char *path,
    pdf_bridge_document **out_document,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
)
{
    (void)path;
    (void)out_document;
    (void)out_info;
    (void)out_report;
    return bridge_unavailable(out_error);
}

int pdf_bridge_unlock_document(
    pdf_bridge_document *document,
    const char *password,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
)
{
    (void)document;
    (void)password;
    (void)out_info;
    (void)out_report;
    return bridge_unavailable(out_error);
}

void pdf_bridge_close_document(pdf_bridge_document *document)
{
    (void)document;
}

int pdf_bridge_render_page(
    pdf_bridge_document *document,
    int32_t page_index,
    double scale,
    pdf_bridge_rendered_page *out_page,
    char **out_error
)
{
    (void)document;
    (void)page_index;
    (void)scale;
    (void)out_page;
    return bridge_unavailable(out_error);
}

int pdf_bridge_extract_blocks(
    pdf_bridge_document *document,
    int32_t page_index,
    pdf_bridge_text_block_array *out_blocks,
    char **out_error
)
{
    (void)document;
    (void)page_index;
    (void)out_blocks;
    return bridge_unavailable(out_error);
}

int pdf_bridge_save_document(
    pdf_bridge_document *document,
    const char *destination_path,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_mode requested_mode,
    bool allow_overlay_fallback,
    pdf_bridge_save_result *out_result,
    char **out_error
)
{
    (void)document;
    (void)destination_path;
    (void)edits;
    (void)edit_count;
    (void)requested_mode;
    (void)allow_overlay_fallback;
    (void)out_result;
    return bridge_unavailable(out_error);
}

int pdf_bridge_preflight_save(
    pdf_bridge_document *document,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_preflight_report *out_report,
    char **out_error
)
{
    (void)document;
    (void)edits;
    (void)edit_count;
    (void)out_report;
    return bridge_unavailable(out_error);
}

int pdf_bridge_validate_file(
    const char *path,
    pdf_bridge_validation_report *out_report,
    char **out_error
)
{
    (void)path;
    (void)out_report;
    return bridge_unavailable(out_error);
}

#else

struct pdf_bridge_document {
    fz_context *ctx;
    fz_document *document;
    pdf_document *pdf_document;
    char *source_path;
};

typedef struct {
    const char *start;
    const char *end;
} bridge_text_line;

typedef struct {
    bridge_text_line *items;
    size_t count;
} bridge_text_layout_lines;

typedef struct {
    fz_font *font;
    const char *font_name;
    float font_size;
    pdf_bridge_color color;
    bool is_bold;
    bool is_italic;
    bool is_monospaced;
    bool is_serif;
    bool font_metrics_usable;
    bool can_write_original_font;
    pdf_bridge_fallback_family fallback_family;
    const char *base14_font_name;
    pdf_bridge_text_encoding base14_encoding;
} bridge_block_style;

typedef struct {
    bool is_editable;
    pdf_bridge_issue_kind failure_kind;
    const char *failure_message;
    bridge_block_style style;
} bridge_block_analysis;

typedef struct {
    fz_font *font;
    bool drop_font_when_done;
    pdf_bridge_font_mode mode;
    pdf_bridge_text_encoding encoding;
    const char *font_name;
} bridge_selected_font;

typedef struct {
    int32_t page_index;
    int32_t native_block_id;
    char *original_text;
    const char *replacement_text;
    pdf_bridge_persistence_mode mode;
    char *message;
} bridge_resolved_edit;

typedef struct {
    int32_t native_block_id;
    pdf_bridge_rect bounds;
    int matched_text_object_count;
    bool touched_multiple_blocks;
    bool current_touched;
    bool current_candidate_match;
    fz_rect current_bounds;
    bool has_current_bounds;
} bridge_text_object_probe_target;

typedef struct {
    bridge_text_object_probe_target *targets;
    size_t target_count;
    bool remove_matching_text;
    fz_rect page_bounds;
} bridge_text_object_probe_state;

typedef struct {
    int32_t native_block_id;
    pdf_bridge_rect bounds;
    const char *replacement_text;
    bridge_block_analysis analysis;
} bridge_page_edit_analysis;

typedef struct {
    char resource_name[16];
    pdf_obj *font_reference;
    fz_text *layout;
    pdf_bridge_color color;
    float font_size;
    pdf_bridge_text_encoding encoding;
} bridge_true_rewrite_append_spec;

typedef struct {
    fz_rect page_bounds;
    bridge_true_rewrite_append_spec *items;
    size_t count;
} bridge_true_rewrite_complete_state;

static const float bridge_line_height_em = 1.2f;
static int bridge_compare_edits(const void *left, const void *right);
static fz_stext_block *bridge_find_text_block_by_native_id(fz_stext_page *stext_page, int32_t native_block_id);
static int bridge_select_font(
    fz_context *ctx,
    const bridge_block_analysis *analysis,
    const char *replacement_text,
    bridge_selected_font *out_font
);
static void bridge_drop_selected_font(fz_context *ctx, bridge_selected_font *font);

static void bridge_set_mupdf_error(fz_context *ctx, char **out_error, const char *prefix)
{
    const char *message;
    size_t prefix_length;
    size_t message_length;
    char *combined;

    if (out_error == NULL) {
        return;
    }

    message = fz_caught_message(ctx);
    if (prefix == NULL || prefix[0] == '\0') {
        *out_error = bridge_strdup(message);
        return;
    }

    prefix_length = strlen(prefix);
    message_length = strlen(message);
    combined = (char *)malloc(prefix_length + 2 + message_length + 1);
    if (combined == NULL) {
        *out_error = bridge_strdup(message);
        return;
    }

    memcpy(combined, prefix, prefix_length);
    combined[prefix_length] = ':';
    combined[prefix_length + 1] = ' ';
    memcpy(combined + prefix_length + 2, message, message_length + 1);
    *out_error = combined;
}

static void bridge_zero_document_info(pdf_bridge_document_info *info)
{
    if (info != NULL) {
        memset(info, 0, sizeof(*info));
    }
}

static void bridge_zero_editability_report(pdf_bridge_editability_report *report)
{
    if (report != NULL) {
        memset(report, 0, sizeof(*report));
    }
}

static void bridge_zero_block_array(pdf_bridge_text_block_array *blocks)
{
    if (blocks != NULL) {
        memset(blocks, 0, sizeof(*blocks));
    }
}

static void bridge_zero_rendered_page(pdf_bridge_rendered_page *page)
{
    if (page != NULL) {
        memset(page, 0, sizeof(*page));
    }
}

static void bridge_zero_validation_report(pdf_bridge_validation_report *report)
{
    if (report != NULL) {
        memset(report, 0, sizeof(*report));
    }
}

static void bridge_zero_save_preflight_report(pdf_bridge_save_preflight_report *report)
{
    if (report != NULL) {
        memset(report, 0, sizeof(*report));
    }
}

static void bridge_zero_save_result(pdf_bridge_save_result *result)
{
    if (result != NULL) {
        memset(result, 0, sizeof(*result));
    }
}

static pdf_bridge_rect bridge_make_rect(fz_rect rect)
{
    pdf_bridge_rect result;
    result.x = rect.x0;
    result.y = rect.y0;
    result.width = rect.x1 - rect.x0;
    result.height = rect.y1 - rect.y0;
    return result;
}

static fz_rect bridge_to_fz_rect(pdf_bridge_rect rect)
{
    return fz_make_rect(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
}

static bool bridge_rect_contains_point(pdf_bridge_rect rect, fz_point point, float tolerance)
{
    return point.x >= rect.x - tolerance &&
        point.x <= rect.x + rect.width + tolerance &&
        point.y >= rect.y - tolerance &&
        point.y <= rect.y + rect.height + tolerance;
}

static bool bridge_rect_approximately_matches(pdf_bridge_rect target, fz_rect candidate, float tolerance)
{
    return fabsf(candidate.x0 - (float)target.x) <= tolerance &&
        fabsf(candidate.y0 - (float)target.y) <= tolerance &&
        fabsf(candidate.x1 - (float)(target.x + target.width)) <= tolerance &&
        fabsf(candidate.y1 - (float)(target.y + target.height)) <= tolerance;
}

static pdf_bridge_quad bridge_make_quad(fz_quad quad)
{
    pdf_bridge_quad result;
    result.top_left.x = quad.ul.x;
    result.top_left.y = quad.ul.y;
    result.top_right.x = quad.ur.x;
    result.top_right.y = quad.ur.y;
    result.bottom_left.x = quad.ll.x;
    result.bottom_left.y = quad.ll.y;
    result.bottom_right.x = quad.lr.x;
    result.bottom_right.y = quad.lr.y;
    return result;
}

static pdf_bridge_color bridge_make_color(uint32_t argb)
{
    pdf_bridge_color color;
    color.alpha = ((argb >> 24) & 0xFF) / 255.0;
    color.red = ((argb >> 16) & 0xFF) / 255.0;
    color.green = ((argb >> 8) & 0xFF) / 255.0;
    color.blue = (argb & 0xFF) / 255.0;
    return color;
}

static char *bridge_normalize_text_range(fz_context *ctx, const char *start, const char *end)
{
    fz_buffer *buffer = NULL;
    const char *normalized;
    size_t length;
    char *copy = NULL;
    const char *left;
    const char *right;

    buffer = fz_new_buffer(ctx, (size_t)(end - start) + 1);
    fz_try(ctx)
    {
        const char *cursor = start;
        while (cursor < end) {
            int rune;
            cursor += fz_chartorune(&rune, cursor);
            if (rune == 0x00A0) {
                rune = ' ';
            }
            fz_append_rune(ctx, buffer, rune);
        }

        normalized = fz_string_from_buffer(ctx, buffer);
        left = normalized;
        while (*left == ' ' || *left == '\n' || *left == '\r' || *left == '\t') {
            left++;
        }

        right = normalized + strlen(normalized);
        while (right > left && (right[-1] == ' ' || right[-1] == '\n' || right[-1] == '\r' || right[-1] == '\t')) {
            right--;
        }

        length = (size_t)(right - left);
        copy = bridge_strndup(left, length);
    }
    fz_always(ctx)
    {
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx)
    {
        free(copy);
        copy = NULL;
        fz_rethrow(ctx);
    }

    return copy;
}

static char *bridge_normalize_text_from_stext_line(fz_context *ctx, fz_stext_line *line)
{
    fz_buffer *buffer = NULL;
    char *copy = NULL;
    fz_stext_char *character;

    buffer = fz_new_buffer(ctx, 64);
    fz_try(ctx)
    {
        for (character = line->first_char; character != NULL; character = character->next) {
            if (character->c == 0x00A0) {
                fz_append_byte(ctx, buffer, ' ');
            } else if (character->c >= 0) {
                fz_append_rune(ctx, buffer, character->c);
            }
        }

        copy = bridge_normalize_text_range(
            ctx,
            fz_string_from_buffer(ctx, buffer),
            fz_string_from_buffer(ctx, buffer) + strlen(fz_string_from_buffer(ctx, buffer))
        );
    }
    fz_always(ctx)
    {
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx)
    {
        free(copy);
        copy = NULL;
        fz_rethrow(ctx);
    }

    return copy;
}

static char *bridge_normalize_text_from_block(fz_context *ctx, fz_stext_block *block)
{
    fz_buffer *buffer = NULL;
    char *copy = NULL;
    fz_stext_line *line;
    bool wrote_line = false;

    buffer = fz_new_buffer(ctx, 128);
    fz_try(ctx)
    {
        for (line = block->u.t.first_line; line != NULL; line = line->next) {
            fz_stext_char *character;
            fz_buffer *line_buffer;
            const char *line_text;

            line_buffer = fz_new_buffer(ctx, 64);
            fz_try(ctx)
            {
                for (character = line->first_char; character != NULL; character = character->next) {
                    if (character->c == 0x00A0) {
                        fz_append_byte(ctx, line_buffer, ' ');
                    } else if (character->c >= 0) {
                        fz_append_rune(ctx, line_buffer, character->c);
                    }
                }

                line_text = fz_string_from_buffer(ctx, line_buffer);
                while (*line_text == ' ' || *line_text == '\t') {
                    line_text++;
                }
                if (*line_text != '\0') {
                    if (wrote_line) {
                        fz_append_byte(ctx, buffer, '\n');
                    }
                    fz_append_string(ctx, buffer, line_text);
                    wrote_line = true;
                }
            }
            fz_always(ctx)
            {
                fz_drop_buffer(ctx, line_buffer);
            }
            fz_catch(ctx)
            {
                fz_rethrow(ctx);
            }
        }

        copy = bridge_normalize_text_range(
            ctx,
            fz_string_from_buffer(ctx, buffer),
            fz_string_from_buffer(ctx, buffer) + strlen(fz_string_from_buffer(ctx, buffer))
        );
    }
    fz_always(ctx)
    {
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx)
    {
        free(copy);
        copy = NULL;
        fz_rethrow(ctx);
    }

    return copy;
}

static bool bridge_is_nearly_horizontal(fz_stext_line *line)
{
    if (line->wmode != 0) {
        return false;
    }

    return fabsf(line->dir.y) <= 0.05f && fabsf(fabsf(line->dir.x) - 1.0f) <= 0.1f;
}

static pdf_bridge_fallback_family bridge_fallback_family_for_style(bool is_monospaced, bool is_serif)
{
    if (is_monospaced) {
        return PDF_BRIDGE_FALLBACK_FAMILY_MONOSPACE;
    }

    if (is_serif) {
        return PDF_BRIDGE_FALLBACK_FAMILY_SERIF;
    }

    return PDF_BRIDGE_FALLBACK_FAMILY_SANS;
}

static const char *bridge_base14_font_name(bool is_monospaced, bool is_serif, bool is_bold, bool is_italic)
{
    if (is_monospaced) {
        if (is_bold && is_italic) return "Courier-BoldOblique";
        if (is_bold) return "Courier-Bold";
        if (is_italic) return "Courier-Oblique";
        return "Courier";
    }

    if (is_serif) {
        if (is_bold && is_italic) return "Times-BoldItalic";
        if (is_bold) return "Times-Bold";
        if (is_italic) return "Times-Italic";
        return "Times-Roman";
    }

    if (is_bold && is_italic) return "Helvetica-BoldOblique";
    if (is_bold) return "Helvetica-Bold";
    if (is_italic) return "Helvetica-Oblique";
    return "Helvetica";
}

static int bridge_simple_encoding_from_unicode(pdf_bridge_text_encoding encoding, int unicode)
{
    switch (encoding) {
    case PDF_BRIDGE_TEXT_ENCODING_LATIN:
        return fz_windows_1252_from_unicode(unicode);
    case PDF_BRIDGE_TEXT_ENCODING_GREEK:
        return fz_iso8859_7_from_unicode(unicode);
    case PDF_BRIDGE_TEXT_ENCODING_CYRILLIC:
        return fz_koi8u_from_unicode(unicode);
    case PDF_BRIDGE_TEXT_ENCODING_IDENTITY:
    default:
        return -1;
    }
}

static bool bridge_text_fits_simple_encoding(const char *text, pdf_bridge_text_encoding encoding)
{
    int unicode;
    while (*text) {
        text += fz_chartorune(&unicode, text);
        if (unicode == '\n' || unicode == '\r' || unicode == '\t') {
            continue;
        }
        if (bridge_simple_encoding_from_unicode(encoding, unicode) < 0) {
            return false;
        }
    }
    return true;
}

static bool bridge_pick_base14_encoding(const char *text, pdf_bridge_text_encoding *out_encoding)
{
    if (bridge_text_fits_simple_encoding(text, PDF_BRIDGE_TEXT_ENCODING_LATIN)) {
        *out_encoding = PDF_BRIDGE_TEXT_ENCODING_LATIN;
        return true;
    }

    if (bridge_text_fits_simple_encoding(text, PDF_BRIDGE_TEXT_ENCODING_GREEK)) {
        *out_encoding = PDF_BRIDGE_TEXT_ENCODING_GREEK;
        return true;
    }

    if (bridge_text_fits_simple_encoding(text, PDF_BRIDGE_TEXT_ENCODING_CYRILLIC)) {
        *out_encoding = PDF_BRIDGE_TEXT_ENCODING_CYRILLIC;
        return true;
    }

    return false;
}

static bool bridge_can_encode_with_font(fz_context *ctx, fz_font *font, const char *text)
{
    int unicode;
    while (*text) {
        text += fz_chartorune(&unicode, text);
        if (unicode == '\n' || unicode == '\r' || unicode == '\t') {
            continue;
        }
        if (fz_encode_character(ctx, font, unicode) <= 0) {
            return false;
        }
    }
    return true;
}

static bool bridge_document_is_signed(fz_context *ctx, pdf_document *document)
{
    return pdf_count_signatures(ctx, document) > 0;
}

static bool bridge_document_allows_editing(fz_context *ctx, pdf_bridge_document *document)
{
    if (fz_needs_password(ctx, document->document)) {
        return false;
    }

    if (bridge_document_is_signed(ctx, document->pdf_document)) {
        return false;
    }

    return fz_has_permission(ctx, document->document, FZ_PERMISSION_EDIT) != 0;
}

static const char *bridge_document_block_message(fz_context *ctx, pdf_bridge_document *document, pdf_bridge_issue_kind *out_kind)
{
    if (fz_needs_password(ctx, document->document)) {
        *out_kind = PDF_BRIDGE_ISSUE_PASSWORD_REQUIRED;
        return "This PDF requires a password before it can be edited.";
    }

    if (bridge_document_is_signed(ctx, document->pdf_document)) {
        *out_kind = PDF_BRIDGE_ISSUE_SIGNED;
        return "Signed PDFs are opened read-only in this milestone.";
    }

    if (!fz_has_permission(ctx, document->document, FZ_PERMISSION_EDIT)) {
        *out_kind = PDF_BRIDGE_ISSUE_RIGHTS_RESTRICTED;
        return "This PDF disallows content editing under its current permissions.";
    }

    return NULL;
}

static bridge_block_analysis bridge_analyze_text_block(fz_context *ctx, pdf_bridge_document *document, fz_stext_block *block)
{
    bridge_block_analysis analysis;
    fz_stext_line *line;
    fz_stext_char *character;
    fz_font *font = NULL;
    uint32_t color = 0;
    float font_size = 0;
    bool saw_character = false;
    bool doc_allows_editing;
    pdf_bridge_issue_kind document_issue_kind;
    const char *document_issue_message;

    memset(&analysis, 0, sizeof(analysis));

    if (block->type != FZ_STEXT_BLOCK_TEXT) {
        analysis.failure_kind = PDF_BRIDGE_ISSUE_UNSUPPORTED_STRUCTURE;
        analysis.failure_message = "Only MuPDF text blocks are considered editable.";
        return analysis;
    }

    doc_allows_editing = bridge_document_allows_editing(ctx, document);
    document_issue_message = bridge_document_block_message(ctx, document, &document_issue_kind);

    for (line = block->u.t.first_line; line != NULL; line = line->next) {
        if (!bridge_is_nearly_horizontal(line)) {
            analysis.failure_kind = PDF_BRIDGE_ISSUE_UNSUPPORTED_TRANSFORM;
            analysis.failure_message = "Rotated or vertical text blocks are read-only in this milestone.";
            return analysis;
        }

        for (character = line->first_char; character != NULL; character = character->next) {
            if (character->c < 0) {
                continue;
            }

            if (character->flags & (FZ_STEXT_UNICODE_IS_CID | FZ_STEXT_UNICODE_IS_GID)) {
                analysis.failure_kind = PDF_BRIDGE_ISSUE_UNSUPPORTED_STRUCTURE;
                analysis.failure_message = "This text block does not expose stable Unicode text for safe rewriting.";
                return analysis;
            }

            if (character->font == NULL) {
                analysis.failure_kind = PDF_BRIDGE_ISSUE_MISSING_FONT_METRICS;
                analysis.failure_message = "This text block is missing reliable font metrics.";
                return analysis;
            }

            if (fz_font_t3_procs(ctx, character->font) != NULL) {
                analysis.failure_kind = PDF_BRIDGE_ISSUE_UNSUPPORTED_FONT;
                analysis.failure_message = "Type3 or path-backed fonts are read-only in this milestone.";
                return analysis;
            }

            if (!saw_character) {
                saw_character = true;
                font = character->font;
                color = character->argb;
                font_size = character->size;
            } else {
                if (font != character->font ||
                    fabsf(font_size - character->size) > 0.25f ||
                    color != character->argb) {
                    analysis.failure_kind = PDF_BRIDGE_ISSUE_UNSUPPORTED_STRUCTURE;
                    analysis.failure_message = "Mixed-style text blocks are read-only in this milestone.";
                    return analysis;
                }
            }
        }
    }

    if (!saw_character) {
        analysis.failure_kind = PDF_BRIDGE_ISSUE_IMAGE_ONLY;
        analysis.failure_message = "This block contains no extractable digital text.";
        return analysis;
    }

    analysis.style.font = font;
    analysis.style.font_name = fz_font_name(ctx, font);
    analysis.style.font_size = font_size > 0 ? font_size : 12.0f;
    analysis.style.color = bridge_make_color(color);
    analysis.style.is_bold = fz_font_is_bold(ctx, font) != 0;
    analysis.style.is_italic = fz_font_is_italic(ctx, font) != 0;
    analysis.style.is_monospaced = fz_font_is_monospaced(ctx, font) != 0;
    analysis.style.is_serif = fz_font_is_serif(ctx, font) != 0;
    analysis.style.font_metrics_usable = !fz_font_flags(font)->invalid_bbox;
    analysis.style.can_write_original_font = pdf_font_writing_supported(ctx, font) != 0;
    analysis.style.fallback_family = bridge_fallback_family_for_style(
        analysis.style.is_monospaced,
        analysis.style.is_serif
    );
    analysis.style.base14_font_name = bridge_base14_font_name(
        analysis.style.is_monospaced,
        analysis.style.is_serif,
        analysis.style.is_bold,
        analysis.style.is_italic
    );
    analysis.style.base14_encoding = PDF_BRIDGE_TEXT_ENCODING_LATIN;

    if (!analysis.style.font_metrics_usable) {
        analysis.failure_kind = PDF_BRIDGE_ISSUE_MISSING_FONT_METRICS;
        analysis.failure_message = "This text block is missing reliable font metrics.";
        return analysis;
    }

    if (!doc_allows_editing) {
        analysis.failure_kind = document_issue_kind;
        analysis.failure_message = document_issue_message;
        return analysis;
    }

    analysis.is_editable = true;
    return analysis;
}

static pdf_bridge_issue bridge_make_issue(pdf_bridge_issue_kind kind, const char *message, int32_t page_index, int32_t native_block_id)
{
    pdf_bridge_issue issue;
    memset(&issue, 0, sizeof(issue));
    issue.kind = kind;
    issue.message = bridge_strdup(message);
    issue.page_index = page_index;
    issue.native_block_id = native_block_id;
    return issue;
}

static pdf_bridge_font_plan bridge_make_font_plan(const bridge_block_analysis *analysis)
{
    pdf_bridge_font_plan plan;
    memset(&plan, 0, sizeof(plan));
    plan.requested_font_postscript_name = bridge_strdup(analysis->style.font_name);
    plan.family = analysis->style.fallback_family;
    plan.encoding = analysis->style.base14_encoding;

    if (analysis->style.can_write_original_font) {
        plan.resolved_font_name = bridge_strdup(analysis->style.font_name);
        plan.source = PDF_BRIDGE_FALLBACK_SOURCE_ORIGINAL;
        plan.font_mode = PDF_BRIDGE_FONT_MODE_ORIGINAL;
        return plan;
    }

    plan.resolved_font_name = bridge_strdup(analysis->style.base14_font_name);
    plan.source = PDF_BRIDGE_FALLBACK_SOURCE_BASE14;
    plan.font_mode = PDF_BRIDGE_FONT_MODE_BASE14;
    plan.warning = bridge_strdup("The original font will fall back to a family-matched Base14 font when rewritten text cannot be embedded safely.");
    return plan;
}

static int bridge_find_probe_target_index(
    bridge_text_object_probe_state *state,
    fz_rect glyph_bounds
)
{
    fz_point center;
    int best_index = -1;
    double best_area = 0.0;
    size_t index;

    center.x = (glyph_bounds.x0 + glyph_bounds.x1) * 0.5f;
    center.y = (glyph_bounds.y0 + glyph_bounds.y1) * 0.5f;

    for (index = 0; index < state->target_count; index++) {
        pdf_bridge_rect target = state->targets[index].bounds;
        double area;

        if (!bridge_rect_contains_point(target, center, 1.5f)) {
            continue;
        }

        area = target.width * target.height;
        if (best_index < 0 || area < best_area) {
            best_index = (int)index;
            best_area = area;
        }
    }

    return best_index;
}

static int bridge_probe_text_filter(
    fz_context *ctx,
    void *opaque,
    int *ucsbuf,
    int ucslen,
    fz_matrix trm,
    fz_matrix ctm,
    fz_rect bbox,
    int tr,
    float ca,
    float CA
)
{
    bridge_text_object_probe_state *state = (bridge_text_object_probe_state *)opaque;
    int target_index;

    (void)ctx;
    (void)ucsbuf;
    (void)ucslen;
    (void)tr;
    (void)ca;
    (void)CA;

    bbox = fz_transform_rect(bbox, fz_concat(trm, ctm));
    bbox = fz_transform_rect(
        bbox,
        (fz_matrix){ 1, 0, 0, -1, -state->page_bounds.x0, state->page_bounds.y1 }
    );
    target_index = bridge_find_probe_target_index(state, bbox);
    if (target_index < 0) {
        return 0;
    }

    state->targets[target_index].current_touched = true;
    if (!state->targets[target_index].has_current_bounds) {
        state->targets[target_index].current_bounds = bbox;
        state->targets[target_index].has_current_bounds = true;
    } else {
        state->targets[target_index].current_bounds = fz_union_rect(state->targets[target_index].current_bounds, bbox);
    }

    return state->remove_matching_text ? 1 : 0;
}

static void bridge_probe_after_text_object(
    fz_context *ctx,
    void *opaque,
    pdf_document *doc,
    pdf_processor *chain,
    fz_matrix ctm
)
{
    bridge_text_object_probe_state *state = (bridge_text_object_probe_state *)opaque;
    size_t index;
    size_t touched_count = 0;

    (void)ctx;
    (void)doc;
    (void)chain;
    (void)ctm;

    for (index = 0; index < state->target_count; index++) {
        if (state->targets[index].current_touched) {
            touched_count++;
        }
    }

    for (index = 0; index < state->target_count; index++) {
        if (!state->targets[index].current_touched) {
            continue;
        }

        if (touched_count > 1) {
            state->targets[index].touched_multiple_blocks = true;
        }

        if (state->targets[index].has_current_bounds &&
            bridge_rect_approximately_matches(state->targets[index].bounds, state->targets[index].current_bounds, 3.0f)) {
            state->targets[index].matched_text_object_count++;
        }

        state->targets[index].current_touched = false;
        state->targets[index].has_current_bounds = false;
        state->targets[index].current_bounds = fz_empty_rect;
    }
}

static char *bridge_lookup_title(fz_context *ctx, fz_document *document)
{
    char buffer[512];
    int found = fz_lookup_metadata(ctx, document, FZ_META_INFO_TITLE, buffer, sizeof(buffer));
    if (found > 0 && buffer[0] != '\0') {
        return bridge_strdup(buffer);
    }
    return NULL;
}

static int bridge_collect_page_blocks(
    fz_context *ctx,
    pdf_bridge_document *document,
    int32_t page_index,
    pdf_bridge_text_block_array *out_blocks,
    pdf_bridge_page_report *out_page_report
)
{
    fz_page *page = NULL;
    fz_stext_page *stext_page = NULL;
    fz_stext_options options;
    fz_stext_block *block;
    size_t capacity = 0;
    size_t count = 0;
    pdf_bridge_text_block *blocks = NULL;
    size_t issue_capacity = 0;
    size_t issue_count = 0;
    pdf_bridge_issue *issues = NULL;
    pdf_bridge_text_block pending_block;
    bool has_pending_block = false;
    bool page_has_text = false;
    bool page_has_editable_block = false;

    bridge_zero_block_array(out_blocks);
    memset(out_page_report, 0, sizeof(*out_page_report));
    out_page_report->page_index = page_index;
    memset(&pending_block, 0, sizeof(pending_block));

    if (page_index < 0 || page_index >= fz_count_pages(ctx, document->document)) {
        return 0;
    }

    fz_init_stext_options(ctx, &options);
    options.flags = FZ_STEXT_PRESERVE_SPANS | FZ_STEXT_CLIP | FZ_STEXT_ACCURATE_BBOXES | FZ_STEXT_COLLECT_STYLES;

    page = fz_load_page(ctx, document->document, page_index);
    stext_page = fz_new_stext_page_from_page(ctx, page, &options);

    for (block = stext_page->first_block; block != NULL; block = block->next) {
        bridge_block_analysis analysis;
        pdf_bridge_text_block bridged_block;
        fz_stext_line *line;
        size_t line_index = 0;
        size_t line_capacity = 0;

        if (block->type != FZ_STEXT_BLOCK_TEXT) {
            continue;
        }

        if (count == capacity) {
            size_t new_capacity = capacity == 0 ? 4 : capacity * 2;
            pdf_bridge_text_block *grown = (pdf_bridge_text_block *)realloc(blocks, new_capacity * sizeof(*grown));
            if (grown == NULL) {
                goto fail;
            }
            memset(grown + capacity, 0, (new_capacity - capacity) * sizeof(*grown));
            blocks = grown;
            capacity = new_capacity;
        }

        analysis = bridge_analyze_text_block(ctx, document, block);
        memset(&bridged_block, 0, sizeof(bridged_block));
        bridged_block.page_index = page_index;
        bridged_block.native_block_id = block->id;
        bridged_block.bounds = bridge_make_rect(block->bbox);
        bridged_block.text = bridge_normalize_text_from_block(ctx, block);
        bridged_block.font_postscript_name = bridge_strdup(analysis.style.font_name ? analysis.style.font_name : "");
        bridged_block.font_size = analysis.style.font_size;
        bridged_block.color = analysis.style.color;
        bridged_block.character_spacing = 0.0;
        bridged_block.horizontal_scale = 1.0;
        bridged_block.rise = 0.0;
        bridged_block.is_bold = analysis.style.is_bold;
        bridged_block.is_italic = analysis.style.is_italic;
        bridged_block.is_monospaced = analysis.style.is_monospaced;
        bridged_block.is_serif = analysis.style.is_serif;
        bridged_block.is_editable = analysis.is_editable;
        bridged_block.fallback_plan = bridge_make_font_plan(&analysis);
        pending_block = bridged_block;
        has_pending_block = true;

        for (line = block->u.t.first_line; line != NULL; line = line->next) {
            pdf_bridge_line_fragment fragment;
            fz_stext_char *character;
            size_t quad_capacity = 0;
            size_t quad_count = 0;

            if (line_index == line_capacity) {
                size_t new_line_capacity = line_capacity == 0 ? 2 : line_capacity * 2;
                pdf_bridge_line_fragment *grown_lines = (pdf_bridge_line_fragment *)realloc(
                    bridged_block.lines,
                    new_line_capacity * sizeof(*grown_lines)
                );
                if (grown_lines == NULL) {
                    goto fail;
                }
                memset(grown_lines + line_capacity, 0, (new_line_capacity - line_capacity) * sizeof(*grown_lines));
                bridged_block.lines = grown_lines;
                line_capacity = new_line_capacity;
                pending_block.lines = bridged_block.lines;
            }

            memset(&fragment, 0, sizeof(fragment));
            fragment.native_line_id = (int32_t)line_index;
            fragment.bounds = bridge_make_rect(line->bbox);
            fragment.text = bridge_normalize_text_from_stext_line(ctx, line);

            for (character = line->first_char; character != NULL; character = character->next) {
                if (quad_count == quad_capacity) {
                    size_t new_quad_capacity = quad_capacity == 0 ? 8 : quad_capacity * 2;
                    pdf_bridge_quad *grown_quads = (pdf_bridge_quad *)realloc(
                        fragment.quads,
                        new_quad_capacity * sizeof(*grown_quads)
                    );
                    if (grown_quads == NULL) {
                        free(fragment.text);
                        goto fail;
                    }
                    fragment.quads = grown_quads;
                    quad_capacity = new_quad_capacity;
                }
                fragment.quads[quad_count++] = bridge_make_quad(character->quad);
            }

            fragment.quad_count = quad_count;
            bridged_block.lines[line_index++] = fragment;
        }

        if (line_index == 0 || bridged_block.text == NULL || bridged_block.text[0] == '\0') {
            bridged_block.line_count = line_index;
            bridge_clear_text_block(&bridged_block);
            memset(&pending_block, 0, sizeof(pending_block));
            has_pending_block = false;
            continue;
        }

        bridged_block.line_count = line_index;
        pending_block = bridged_block;

        if (!bridged_block.is_editable) {
            bridged_block.has_failure_reason = true;
            bridged_block.failure_reason = bridge_make_issue(
                analysis.failure_kind,
                analysis.failure_message,
                page_index,
                block->id
            );
            bridged_block.persistence_mode = PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED;
            bridged_block.persistence_message = bridge_strdup(analysis.failure_message);
            pending_block = bridged_block;

            if (issue_count == issue_capacity) {
                size_t new_issue_capacity = issue_capacity == 0 ? 4 : issue_capacity * 2;
                pdf_bridge_issue *grown_issues = (pdf_bridge_issue *)realloc(
                    issues,
                    new_issue_capacity * sizeof(*grown_issues)
                );
                if (grown_issues == NULL) {
                    goto fail;
                }
                issues = grown_issues;
                issue_capacity = new_issue_capacity;
            }

            issues[issue_count++] = bridge_make_issue(
                analysis.failure_kind,
                analysis.failure_message,
                page_index,
                block->id
            );
        } else {
            bridged_block.persistence_mode =
                (line_index == 1)
                ? PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE
                : PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK;
            bridged_block.persistence_message = bridge_strdup(
                bridged_block.persistence_mode == PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE
                    ? "This block is currently eligible for true PDF rewriting."
                    : "This block may require overlay fallback when saved."
            );
            page_has_editable_block = true;
        }

        blocks[count++] = bridged_block;
        memset(&pending_block, 0, sizeof(pending_block));
        has_pending_block = false;
        page_has_text = true;
    }

    if (!page_has_text) {
        if (issue_count == issue_capacity) {
            size_t new_issue_capacity = issue_capacity == 0 ? 1 : issue_capacity + 1;
            pdf_bridge_issue *grown_issues = (pdf_bridge_issue *)realloc(
                issues,
                new_issue_capacity * sizeof(*grown_issues)
            );
            if (grown_issues == NULL) {
                goto fail;
            }
            issues = grown_issues;
            issue_capacity = new_issue_capacity;
        }
        issues[issue_count++] = bridge_make_issue(
            PDF_BRIDGE_ISSUE_IMAGE_ONLY,
            "This page has no extractable digital text.",
            page_index,
            -1
        );
    }

    out_blocks->count = count;
    out_blocks->items = blocks;
    out_page_report->is_editable = page_has_editable_block;
    out_page_report->issue_count = issue_count;
    out_page_report->issues = issues;

    fz_drop_stext_page(ctx, stext_page);
    fz_drop_page(ctx, page);
    return 1;

fail:
    if (has_pending_block) {
        bridge_clear_text_block(&pending_block);
    }
    if (blocks != NULL) {
        size_t block_index;
        for (block_index = 0; block_index < count; block_index++) {
            bridge_clear_text_block(&blocks[block_index]);
        }
        free(blocks);
    }
    if (issues != NULL) {
        size_t index;
        for (index = 0; index < issue_count; index++) {
            bridge_free_issue(&issues[index]);
        }
        free(issues);
    }
    if (stext_page != NULL) {
        fz_drop_stext_page(ctx, stext_page);
    }
    if (page != NULL) {
        fz_drop_page(ctx, page);
    }
    return 0;
}

static int bridge_fill_document_info(fz_context *ctx, pdf_bridge_document *document, pdf_bridge_document_info *out_info)
{
    bridge_zero_document_info(out_info);
    out_info->source_path = bridge_strdup(document->source_path);
    out_info->title = bridge_lookup_title(ctx, document->document);
    out_info->page_count = fz_count_pages(ctx, document->document);
    out_info->is_encrypted = document->pdf_document->crypt != NULL;
    out_info->is_locked = fz_needs_password(ctx, document->document) != 0;
    out_info->is_signed = bridge_document_is_signed(ctx, document->pdf_document);
    out_info->can_edit = bridge_document_allows_editing(ctx, document);
    out_info->backend_kind = out_info->can_edit
        ? PDF_BRIDGE_BACKEND_MUPDF_EDITABLE
        : PDF_BRIDGE_BACKEND_MUPDF_READ_ONLY;
    return 1;
}

static int bridge_build_editability_report(
    fz_context *ctx,
    pdf_bridge_document *document,
    pdf_bridge_editability_report *out_report
)
{
    int page_count;
    int page_index;
    bool has_editable_page = false;

    bridge_zero_editability_report(out_report);

    page_count = fz_count_pages(ctx, document->document);
    out_report->page_reports = (pdf_bridge_page_report *)calloc((size_t)page_count, sizeof(*out_report->page_reports));
    if (page_count > 0 && out_report->page_reports == NULL) {
        return 0;
    }
    out_report->page_report_count = (size_t)page_count;

    {
        pdf_bridge_issue_kind document_issue_kind;
        const char *document_issue_message = bridge_document_block_message(ctx, document, &document_issue_kind);
        if (document_issue_message != NULL) {
            out_report->issues = (pdf_bridge_issue *)calloc(1, sizeof(*out_report->issues));
            if (out_report->issues == NULL) {
                return 0;
            }
            out_report->issues[0] = bridge_make_issue(document_issue_kind, document_issue_message, -1, -1);
            out_report->issue_count = 1;
        }
    }

    for (page_index = 0; page_index < page_count; page_index++) {
        pdf_bridge_text_block_array ignored_blocks;
        bridge_zero_block_array(&ignored_blocks);

        if (!bridge_collect_page_blocks(ctx, document, page_index, &ignored_blocks, &out_report->page_reports[page_index])) {
            pdf_bridge_free_text_block_array(&ignored_blocks);
            return 0;
        }

        has_editable_page = has_editable_page || out_report->page_reports[page_index].is_editable;
        pdf_bridge_free_text_block_array(&ignored_blocks);
    }

    out_report->is_editable = bridge_document_allows_editing(ctx, document) && has_editable_page;
    return 1;
}

static int bridge_create_document(
    const char *path,
    pdf_bridge_document **out_document,
    char **out_error
)
{
    pdf_bridge_document *document;

    *out_document = NULL;

    document = (pdf_bridge_document *)calloc(1, sizeof(*document));
    if (document == NULL) {
        bridge_set_error(out_error, "Out of memory while allocating MuPDF document state.");
        return 0;
    }

    document->ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (document->ctx == NULL) {
        free(document);
        bridge_set_error(out_error, "MuPDF failed to create a rendering context.");
        return 0;
    }

    fz_register_document_handlers(document->ctx);
    document->source_path = bridge_strdup(path);
    if (document->source_path == NULL) {
        fz_drop_context(document->ctx);
        free(document);
        bridge_set_error(out_error, "Out of memory while recording the source path.");
        return 0;
    }

    fz_try(document->ctx)
    {
        document->document = fz_open_document(document->ctx, path);
        document->pdf_document = pdf_document_from_fz_document(document->ctx, document->document);
        if (document->pdf_document == NULL) {
            fz_throw(document->ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF.");
        }
    }
    fz_catch(document->ctx)
    {
        bridge_set_mupdf_error(document->ctx, out_error, "Failed to open PDF");
        pdf_bridge_close_document(document);
        return 0;
    }

    *out_document = document;
    return 1;
}

static pdf_bridge_document *bridge_open_temporary_document(const char *path)
{
    pdf_bridge_document *document = NULL;
    (void)bridge_create_document(path, &document, NULL);
    return document;
}

static void bridge_shift_text(fz_text *text, float x_adjustment, float y_adjustment)
{
    fz_text_span *span;
    for (span = text->head; span != NULL; span = span->next) {
        int index;
        for (index = 0; index < span->len; index++) {
            span->items[index].x += x_adjustment;
            span->items[index].y += y_adjustment;
        }
    }
}

static bool bridge_measure_character(fz_context *ctx, fz_font *font, int unicode, float *out_advance)
{
    int glyph;
    if (unicode == '\t') {
        unicode = ' ';
    }
    glyph = fz_encode_character(ctx, font, unicode);
    if (glyph <= 0) {
        return false;
    }
    *out_advance = fz_advance_glyph(ctx, font, glyph, 0);
    return true;
}

static int bridge_break_lines(
    fz_context *ctx,
    fz_font *font,
    float font_size,
    const char *text,
    float width,
    bridge_text_layout_lines *out_lines
)
{
    bridge_text_line *lines = NULL;
    size_t line_capacity = strlen(text) + 1;
    size_t line_count = 0;
    const char *start = text;
    const char *cursor = text;
    const char *next;
    const char *space = NULL;
    float current_width = 0;
    float width_at_space = 0;

    out_lines->items = NULL;
    out_lines->count = 0;

    lines = (bridge_text_line *)calloc(line_capacity == 0 ? 1 : line_capacity, sizeof(*lines));
    if (lines == NULL) {
        return 0;
    }

    while (*cursor) {
        int unicode;
        float advance = 0;

        next = cursor + fz_chartorune(&unicode, cursor);
        if (unicode == '\r') {
            cursor = next;
            continue;
        }

        if (unicode == '\n') {
            lines[line_count].start = start;
            lines[line_count].end = cursor;
            line_count++;
            start = next;
            cursor = next;
            current_width = 0;
            space = NULL;
            width_at_space = 0;
            continue;
        }

        if (unicode == '\t') {
            unicode = ' ';
        }

        if (unicode == ' ') {
            space = cursor;
            width_at_space = current_width;
        }

        if (!bridge_measure_character(ctx, font, unicode, &advance)) {
            free(lines);
            return 0;
        }

        advance *= font_size;

        if (current_width + advance > width && current_width > 0) {
            if (space != NULL && space >= start) {
                lines[line_count].start = start;
                lines[line_count].end = space;
                line_count++;
                start = space + 1;
                cursor = start;
                current_width = 0;
                space = NULL;
                width_at_space = 0;
                continue;
            }

            if (cursor == start) {
                lines[line_count].start = start;
                lines[line_count].end = next;
                line_count++;
                start = next;
                cursor = next;
                current_width = 0;
                space = NULL;
                width_at_space = 0;
                continue;
            }

            (void)width_at_space;
            lines[line_count].start = start;
            lines[line_count].end = cursor;
            line_count++;
            start = cursor;
            current_width = 0;
            space = NULL;
            width_at_space = 0;
            continue;
        }

        current_width += advance;
        cursor = next;
    }

    if (cursor > start || line_count == 0) {
        lines[line_count].start = start;
        lines[line_count].end = cursor;
        line_count++;
    }

    out_lines->items = lines;
    out_lines->count = line_count;
    return 1;
}

static void bridge_free_layout_lines(bridge_text_layout_lines *lines)
{
    if (lines == NULL) {
        return;
    }
    free(lines->items);
    lines->items = NULL;
    lines->count = 0;
}

static fz_matrix bridge_show_string(fz_context *ctx, fz_text *text, fz_font *font, fz_matrix transform, const char *start, const char *end)
{
    const char *cursor = start;
    while (cursor < end) {
        int unicode;
        int glyph;
        float advance;

        cursor += fz_chartorune(&unicode, cursor);
        if (unicode == '\t') {
            unicode = ' ';
        }

        glyph = fz_encode_character(ctx, font, unicode);
        if (glyph <= 0) {
            continue;
        }

        fz_show_glyph(ctx, text, font, transform, glyph, unicode, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
        advance = fz_advance_glyph(ctx, font, glyph, 0);
        transform = fz_pre_translate(transform, advance, 0);
    }

    return transform;
}

static int bridge_layout_text(
    fz_context *ctx,
    fz_font *font,
    float font_size,
    const char *text,
    pdf_bridge_rect bounds,
    fz_text **out_text,
    char **out_error
)
{
    bridge_text_layout_lines lines;
    fz_text *layout = NULL;
    fz_rect text_bounds;
    fz_matrix transform;
    size_t line_index;
    float x_adjustment;
    float y_adjustment;
    float vertical_tolerance;
    fz_rect fitz_bounds = bridge_to_fz_rect(bounds);

    *out_text = NULL;

    if (text == NULL || text[0] == '\0') {
        return 1;
    }

    if (!bridge_break_lines(ctx, font, font_size, text, (float)bounds.width, &lines)) {
        bridge_set_error(out_error, "Replacement text contains characters that the selected font cannot encode.");
        return 0;
    }

    layout = fz_new_text(ctx);
    fz_try(ctx)
    {
        transform = fz_scale(font_size, -font_size);
        transform.e += fitz_bounds.x0;
        transform.f += fitz_bounds.y1;

        for (line_index = 0; line_index < lines.count; line_index++) {
            bridge_show_string(ctx, layout, font, transform, lines.items[line_index].start, lines.items[line_index].end);
            transform = fz_pre_translate(transform, 0.0f, -bridge_line_height_em);
        }

        text_bounds = fz_bound_text(ctx, layout, NULL, fz_identity);
        x_adjustment = fitz_bounds.x0 - text_bounds.x0;
        y_adjustment = fitz_bounds.y0 - text_bounds.y0;
        bridge_shift_text(layout, x_adjustment, y_adjustment);
        text_bounds = fz_bound_text(ctx, layout, NULL, fz_identity);
        vertical_tolerance = fminf(2.0f, font_size * 0.1f);

        if (text_bounds.x1 > fitz_bounds.x1 + 0.5f || text_bounds.y1 > fitz_bounds.y1 + vertical_tolerance) {
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Replacement text does not fit inside the original text block.");
        }
    }
    fz_always(ctx)
    {
        bridge_free_layout_lines(&lines);
    }
    fz_catch(ctx)
    {
        if (fz_caught(ctx) == FZ_ERROR_ARGUMENT) {
            bridge_set_error(out_error, fz_caught_message(ctx));
        } else {
            bridge_set_mupdf_error(ctx, out_error, "Failed to layout replacement text");
        }
        fz_drop_text(ctx, layout);
        return 0;
    }

    *out_text = layout;
    return 1;
}

static void bridge_append_page_transform(fz_context *ctx, fz_buffer *buffer, fz_rect fitz_page_bounds)
{
    fz_matrix page_transform = { 1, 0, 0, -1, -fitz_page_bounds.x0, fitz_page_bounds.y1 };
    fz_append_printf(ctx, buffer, "%M cm\n", &page_transform);
}

static void bridge_append_whiteout(fz_context *ctx, fz_buffer *buffer, pdf_bridge_rect bounds)
{
    fz_append_string(ctx, buffer, "q\n1 1 1 rg\n");
    fz_append_printf(ctx, buffer, "%g %g %g %g re\nf\nQ\n", bounds.x, bounds.y, bounds.width, bounds.height);
}

static void bridge_append_text_color(fz_context *ctx, fz_buffer *buffer, pdf_bridge_color color)
{
    fz_append_printf(ctx, buffer, "%g %g %g rg\n", color.red, color.green, color.blue);
}

static int bridge_encoded_value_for_item(const fz_text_item *item, pdf_bridge_text_encoding encoding)
{
    if (encoding == PDF_BRIDGE_TEXT_ENCODING_IDENTITY) {
        return item->gid;
    }

    return bridge_simple_encoding_from_unicode(encoding, item->ucs);
}

static void bridge_append_text_span(
    fz_context *ctx,
    fz_buffer *buffer,
    const char *resource_name,
    const fz_text_span *span,
    float font_size,
    pdf_bridge_text_encoding encoding,
    double character_spacing,
    double horizontal_scale,
    double rise
)
{
    fz_matrix transform;
    fz_matrix text_matrix;
    fz_matrix initial_text_matrix;
    fz_matrix inverse_font_scale;
    fz_matrix inverse_transform;
    fz_matrix inverse_text_matrix;
    fz_point delta;
    float advance;
    int index;
    int dx;
    int dy;

    if (span->len == 0) {
        return;
    }

    inverse_font_scale = fz_scale(1 / font_size, 1 / font_size);
    transform = span->trm;
    transform.e = span->items[0].x;
    transform.f = span->items[0].y;

    text_matrix = fz_concat(inverse_font_scale, transform);
    initial_text_matrix = text_matrix;
    inverse_text_matrix = fz_invert_matrix(text_matrix);
    inverse_transform = fz_invert_matrix(transform);

    fz_append_string(ctx, buffer, "BT\n");
    fz_append_printf(ctx, buffer, "/%s %g Tf\n", resource_name, font_size);
    if (character_spacing != 0.0) {
        fz_append_printf(ctx, buffer, "%g Tc\n", character_spacing);
    }
    if (horizontal_scale != 1.0) {
        fz_append_printf(ctx, buffer, "%g Tz\n", horizontal_scale * 100.0);
    }
    if (rise != 0.0) {
        fz_append_printf(ctx, buffer, "%g Ts\n", rise);
    }
    fz_append_printf(ctx, buffer, "%M Tm\n[<", &text_matrix);

    for (index = 0; index < span->len; index++) {
        const fz_text_item *item = &span->items[index];
        int encoded_value = bridge_encoded_value_for_item(item, encoding);

        if (encoded_value < 0) {
            continue;
        }

        delta.x = item->x - transform.e;
        delta.y = item->y - transform.f;
        delta = fz_transform_vector(delta, inverse_transform);
        dx = (int)(delta.x * 1000 + (delta.x < 0 ? -0.5f : 0.5f));
        dy = (int)(delta.y * 1000 + (delta.y < 0 ? -0.5f : 0.5f));

        transform.e = item->x;
        transform.f = item->y;

        if (dx != 0 || dy != 0) {
            if (dy == 0) {
                fz_append_printf(ctx, buffer, ">%d<", -dx);
            } else {
                text_matrix = fz_concat(inverse_font_scale, transform);
                delta.x = text_matrix.e - initial_text_matrix.e;
                delta.y = text_matrix.f - initial_text_matrix.f;
                delta = fz_transform_vector(delta, inverse_text_matrix);
                fz_append_printf(ctx, buffer, ">]TJ\n%g %g Td\n[<", delta.x, delta.y);
                initial_text_matrix = text_matrix;
            }
        }

        if (encoding == PDF_BRIDGE_TEXT_ENCODING_IDENTITY) {
            fz_append_printf(ctx, buffer, "%04x", encoded_value);
        } else {
            fz_append_printf(ctx, buffer, "%02x", encoded_value);
        }

        advance = fz_advance_glyph(ctx, span->font, item->gid, span->wmode);
        transform = fz_pre_translate(transform, advance, 0);
    }

    fz_append_string(ctx, buffer, ">]TJ\nET\n");
}

static void bridge_append_text(
    fz_context *ctx,
    fz_buffer *buffer,
    const char *resource_name,
    const fz_text *text,
    float font_size,
    pdf_bridge_text_encoding encoding,
    double character_spacing,
    double horizontal_scale,
    double rise
)
{
    const fz_text_span *span;
    for (span = text->head; span != NULL; span = span->next) {
        bridge_append_text_span(
            ctx,
            buffer,
            resource_name,
            span,
            font_size,
            encoding,
            character_spacing,
            horizontal_scale,
            rise
        );
    }
}

static void bridge_drop_true_rewrite_complete_state(
    fz_context *ctx,
    bridge_true_rewrite_complete_state *state
)
{
    size_t index;

    if (state == NULL) {
        return;
    }

    for (index = 0; index < state->count; index++) {
        if (state->items[index].font_reference != NULL) {
            pdf_drop_obj(ctx, state->items[index].font_reference);
        }
        if (state->items[index].layout != NULL) {
            fz_drop_text(ctx, state->items[index].layout);
        }
    }

    free(state->items);
    state->items = NULL;
    state->count = 0;
    state->page_bounds = fz_empty_rect;
}

static void bridge_complete_true_rewrite_buffer(fz_context *ctx, fz_buffer *buffer, void *opaque)
{
    bridge_true_rewrite_complete_state *state = (bridge_true_rewrite_complete_state *)opaque;
    size_t index;

    if (state == NULL || state->count == 0) {
        return;
    }

    fz_append_string(ctx, buffer, "\nq\n");
    bridge_append_page_transform(ctx, buffer, state->page_bounds);
    for (index = 0; index < state->count; index++) {
        if (state->items[index].layout == NULL || state->items[index].resource_name[0] == '\0') {
            continue;
        }
        bridge_append_text_color(ctx, buffer, state->items[index].color);
        bridge_append_text(
            ctx,
            buffer,
            state->items[index].resource_name,
            state->items[index].layout,
            state->items[index].font_size,
            state->items[index].encoding,
            0.0,
            1.0,
            0.0
        );
    }
    fz_append_string(ctx, buffer, "Q\n");
}

static int bridge_run_page_text_object_probe(
    fz_context *ctx,
    pdf_bridge_document *document,
    pdf_page *page,
    int32_t page_index,
    bridge_text_object_probe_state *probe_state,
    char **out_error
)
{
    pdf_filter_options options;
    pdf_sanitize_filter_options sanitize_options;
    pdf_filter_factory filters[2];
    pdf_processor *buffer_processor = NULL;
    pdf_processor *sanitize_processor = NULL;
    pdf_processor *top = NULL;
    fz_buffer *buffer = NULL;
    pdf_obj *resources;
    pdf_obj *contents;
    pdf_obj *new_resources = NULL;
    pdf_obj *page_object = NULL;
    int struct_parents;

    memset(&options, 0, sizeof(options));
    memset(&sanitize_options, 0, sizeof(sanitize_options));
    memset(filters, 0, sizeof(filters));

    sanitize_options.opaque = probe_state;
    sanitize_options.text_filter = bridge_probe_text_filter;
    sanitize_options.after_text_object = bridge_probe_after_text_object;

    filters[0].filter = pdf_new_sanitize_filter;
    filters[0].options = &sanitize_options;
    options.filters = filters;
    options.newlines = 0;

    contents = pdf_page_contents(ctx, page);
    resources = pdf_page_resources(ctx, page);
    page_object = pdf_lookup_page_obj(ctx, document->pdf_document, page_index);
    struct_parents = pdf_dict_get_int_default(ctx, page_object, PDF_NAME(StructParents), -1);

    fz_try(ctx)
    {
        buffer = fz_new_buffer(ctx, 1024);
        top = buffer_processor = pdf_new_buffer_processor(ctx, buffer, 0, 0);
        top = sanitize_processor = pdf_new_sanitize_filter(
            ctx,
            document->pdf_document,
            top,
            struct_parents,
            fz_identity,
            &options,
            &sanitize_options
        );

        pdf_process_contents(ctx, top, document->pdf_document, resources, contents, NULL, &new_resources);
        pdf_close_processor(ctx, top);
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, new_resources);
        fz_drop_buffer(ctx, buffer);
        if (sanitize_processor != NULL) {
            pdf_drop_processor(ctx, sanitize_processor);
        }
        if (buffer_processor != NULL) {
            pdf_drop_processor(ctx, buffer_processor);
        }
    }
    fz_catch(ctx)
    {
        bridge_set_mupdf_error(ctx, out_error, "Failed to inspect page text objects");
        return 0;
    }

    return 1;
}

static pdf_obj *bridge_ensure_font_resource_dict(fz_context *ctx, pdf_document *document, pdf_obj *resources)
{
    pdf_obj *fonts = pdf_dict_get(ctx, resources, PDF_NAME(Font));
    if (fonts == NULL) {
        fonts = pdf_new_dict(ctx, document, 4);
        pdf_dict_put_drop(ctx, resources, PDF_NAME(Font), fonts);
    }
    return fonts;
}

static void bridge_make_unique_font_resource_name(
    fz_context *ctx,
    pdf_obj *font_dict,
    char *buffer,
    size_t buffer_size,
    const char *prefix
)
{
    int index = 0;
    do {
        fz_snprintf(buffer, buffer_size, "%s%d", prefix, index++);
    } while (pdf_dict_gets(ctx, font_dict, buffer) != NULL);
}

static int bridge_apply_page_true_rewrite(
    fz_context *ctx,
    pdf_bridge_document *document,
    int32_t page_index,
    const bridge_resolved_edit *edits,
    size_t edit_count,
    char **out_error
)
{
    pdf_page *page = NULL;
    fz_stext_page *stext_page = NULL;
    fz_stext_options text_options;
    pdf_filter_options filter_options;
    pdf_sanitize_filter_options sanitize_options;
    pdf_filter_factory filters[2];
    bridge_true_rewrite_complete_state complete_state;
    bridge_text_object_probe_state probe_state;
    bridge_text_object_probe_target *probe_targets = NULL;
    pdf_obj *page_object = NULL;
    pdf_obj *page_resources = NULL;
    pdf_obj *font_dict = NULL;
    size_t index;

    memset(&complete_state, 0, sizeof(complete_state));
    memset(&probe_state, 0, sizeof(probe_state));
    memset(&filter_options, 0, sizeof(filter_options));
    memset(&sanitize_options, 0, sizeof(sanitize_options));
    memset(filters, 0, sizeof(filters));

    if (edit_count == 0) {
        return 1;
    }

    fz_init_stext_options(ctx, &text_options);
    text_options.flags = FZ_STEXT_PRESERVE_SPANS | FZ_STEXT_CLIP | FZ_STEXT_ACCURATE_BBOXES | FZ_STEXT_COLLECT_STYLES;

    complete_state.items = (bridge_true_rewrite_append_spec *)calloc(edit_count, sizeof(*complete_state.items));
    probe_targets = (bridge_text_object_probe_target *)calloc(edit_count, sizeof(*probe_targets));
    if (complete_state.items == NULL || probe_targets == NULL) {
        bridge_set_error(out_error, "Out of memory while preparing true PDF rewrite content.");
        goto fail;
    }

    page = pdf_load_page(ctx, document->pdf_document, page_index);
    stext_page = fz_new_stext_page_from_page(ctx, (fz_page *)page, &text_options);
    complete_state.page_bounds = fz_bound_page(ctx, (fz_page *)page);

    page_object = pdf_lookup_page_obj(ctx, document->pdf_document, page_index);
    pdf_flatten_inheritable_page_items(ctx, page_object);
    page_resources = pdf_dict_get(ctx, page_object, PDF_NAME(Resources));
    if (page_resources == NULL) {
        page_resources = pdf_new_dict(ctx, document->pdf_document, 4);
        pdf_dict_put_drop(ctx, page_object, PDF_NAME(Resources), page_resources);
    }
    font_dict = bridge_ensure_font_resource_dict(ctx, document->pdf_document, page_resources);

    for (index = 0; index < edit_count; index++) {
        fz_stext_block *block = bridge_find_text_block_by_native_id(stext_page, edits[index].native_block_id);
        bridge_block_analysis analysis;
        bridge_selected_font selected_font;

        if (block == NULL) {
            bridge_set_error(out_error, "The edited text block could not be found during true rewrite.");
            goto fail;
        }

        analysis = bridge_analyze_text_block(ctx, document, block);
        if (!analysis.is_editable) {
            bridge_set_error(out_error, analysis.failure_message);
            goto fail;
        }

        memset(&selected_font, 0, sizeof(selected_font));
        if (!bridge_select_font(ctx, &analysis, edits[index].replacement_text, &selected_font)) {
            bridge_set_error(out_error, "True rewrite could not encode the replacement text with the original font or Base14 fallback.");
            goto fail;
        }

        if (!bridge_layout_text(
                ctx,
                selected_font.font ? selected_font.font : analysis.style.font,
                analysis.style.font_size,
                edits[index].replacement_text,
                bridge_make_rect(block->bbox),
                &complete_state.items[complete_state.count].layout,
                out_error
            )) {
            bridge_drop_selected_font(ctx, &selected_font);
            goto fail;
        }

        complete_state.items[complete_state.count].color = analysis.style.color;
        complete_state.items[complete_state.count].font_size = analysis.style.font_size;
        complete_state.items[complete_state.count].encoding = selected_font.encoding;
        if (edits[index].replacement_text != NULL && edits[index].replacement_text[0] != '\0') {
            bridge_make_unique_font_resource_name(
                ctx,
                font_dict,
                complete_state.items[complete_state.count].resource_name,
                sizeof(complete_state.items[complete_state.count].resource_name),
                "TRW"
            );
            if (selected_font.mode == PDF_BRIDGE_FONT_MODE_ORIGINAL) {
                complete_state.items[complete_state.count].font_reference = pdf_add_cid_font(
                    ctx,
                    document->pdf_document,
                    analysis.style.font
                );
            } else {
                int simple_encoding = PDF_SIMPLE_ENCODING_LATIN;
                if (selected_font.encoding == PDF_BRIDGE_TEXT_ENCODING_GREEK) {
                    simple_encoding = PDF_SIMPLE_ENCODING_GREEK;
                } else if (selected_font.encoding == PDF_BRIDGE_TEXT_ENCODING_CYRILLIC) {
                    simple_encoding = PDF_SIMPLE_ENCODING_CYRILLIC;
                }
                complete_state.items[complete_state.count].font_reference = pdf_add_simple_font(
                    ctx,
                    document->pdf_document,
                    selected_font.font,
                    simple_encoding
                );
            }
        }
        complete_state.count++;
        bridge_drop_selected_font(ctx, &selected_font);

        probe_targets[index].native_block_id = edits[index].native_block_id;
        probe_targets[index].bounds = bridge_make_rect(block->bbox);
    }

    probe_state.targets = probe_targets;
    probe_state.target_count = edit_count;
    probe_state.remove_matching_text = true;
    probe_state.page_bounds = complete_state.page_bounds;

    sanitize_options.opaque = &probe_state;
    sanitize_options.text_filter = bridge_probe_text_filter;
    sanitize_options.after_text_object = bridge_probe_after_text_object;
    filters[0].filter = pdf_new_sanitize_filter;
    filters[0].options = &sanitize_options;
    filter_options.filters = filters;
    filter_options.opaque = &complete_state;
    filter_options.complete = bridge_complete_true_rewrite_buffer;
    filter_options.newlines = 0;

    pdf_filter_page_contents(ctx, document->pdf_document, page, &filter_options);

    page_object = pdf_lookup_page_obj(ctx, document->pdf_document, page_index);
    page_resources = pdf_dict_get(ctx, page_object, PDF_NAME(Resources));
    if (page_resources == NULL) {
        page_resources = pdf_new_dict(ctx, document->pdf_document, 4);
        pdf_dict_put_drop(ctx, page_object, PDF_NAME(Resources), page_resources);
    }
    font_dict = bridge_ensure_font_resource_dict(ctx, document->pdf_document, page_resources);

    for (index = 0; index < complete_state.count; index++) {
        if (complete_state.items[index].font_reference != NULL && complete_state.items[index].resource_name[0] != '\0') {
            pdf_dict_puts(ctx, font_dict, complete_state.items[index].resource_name, complete_state.items[index].font_reference);
        }
    }

    free(probe_targets);
    bridge_drop_true_rewrite_complete_state(ctx, &complete_state);
    if (stext_page != NULL) {
        fz_drop_stext_page(ctx, stext_page);
    }
    if (page != NULL) {
        pdf_drop_page(ctx, page);
    }
    return 1;

fail:
    free(probe_targets);
    bridge_drop_true_rewrite_complete_state(ctx, &complete_state);
    if (stext_page != NULL) {
        fz_drop_stext_page(ctx, stext_page);
    }
    if (page != NULL) {
        pdf_drop_page(ctx, page);
    }
    return 0;
}

static int bridge_select_font(
    fz_context *ctx,
    const bridge_block_analysis *analysis,
    const char *replacement_text,
    bridge_selected_font *out_font
)
{
    memset(out_font, 0, sizeof(*out_font));

    if (replacement_text == NULL || replacement_text[0] == '\0') {
        out_font->mode = analysis->style.can_write_original_font
            ? PDF_BRIDGE_FONT_MODE_ORIGINAL
            : PDF_BRIDGE_FONT_MODE_BASE14;
        out_font->encoding = analysis->style.can_write_original_font
            ? PDF_BRIDGE_TEXT_ENCODING_IDENTITY
            : analysis->style.base14_encoding;
        out_font->font_name = analysis->style.can_write_original_font
            ? analysis->style.font_name
            : analysis->style.base14_font_name;
        return 1;
    }

    if (analysis->style.can_write_original_font &&
        bridge_can_encode_with_font(ctx, analysis->style.font, replacement_text)) {
        out_font->font = analysis->style.font;
        out_font->mode = PDF_BRIDGE_FONT_MODE_ORIGINAL;
        out_font->encoding = PDF_BRIDGE_TEXT_ENCODING_IDENTITY;
        out_font->font_name = analysis->style.font_name;
        return 1;
    }

    if (!bridge_pick_base14_encoding(replacement_text, &out_font->encoding)) {
        return 0;
    }

    out_font->font = fz_new_base14_font(ctx, analysis->style.base14_font_name);
    out_font->drop_font_when_done = true;
    out_font->mode = PDF_BRIDGE_FONT_MODE_BASE14;
    out_font->font_name = analysis->style.base14_font_name;
    return out_font->font != NULL;
}

static void bridge_drop_selected_font(fz_context *ctx, bridge_selected_font *font)
{
    if (font->drop_font_when_done && font->font != NULL) {
        fz_drop_font(ctx, font->font);
    }
    memset(font, 0, sizeof(*font));
}

static void bridge_set_resolved_edit_message(bridge_resolved_edit *edit, const char *message)
{
    free(edit->message);
    edit->message = bridge_strdup(message != NULL ? message : "");
}

static void bridge_clear_resolved_edits(bridge_resolved_edit *edits, size_t edit_count)
{
    size_t index;
    if (edits == NULL) {
        return;
    }
    for (index = 0; index < edit_count; index++) {
        free(edits[index].original_text);
        edits[index].original_text = NULL;
        free(edits[index].message);
        edits[index].message = NULL;
    }
}

static fz_stext_block *bridge_find_text_block_by_native_id(fz_stext_page *stext_page, int32_t native_block_id)
{
    fz_stext_block *block;
    for (block = stext_page->first_block; block != NULL; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_TEXT && block->id == native_block_id) {
            return block;
        }
    }
    return NULL;
}

static int bridge_classify_page_edits(
    fz_context *ctx,
    pdf_bridge_document *document,
    int32_t page_index,
    bridge_resolved_edit *edits,
    size_t edit_count,
    char **out_error
)
{
    pdf_page *page = NULL;
    fz_stext_page *stext_page = NULL;
    fz_stext_options options;
    fz_stext_block **matched_blocks = NULL;
    bridge_block_analysis *analyses = NULL;
    bridge_text_object_probe_target *probe_targets = NULL;
    int *probe_indices = NULL;
    bridge_text_object_probe_state probe_state;
    size_t probe_count = 0;
    size_t index;

    memset(&probe_state, 0, sizeof(probe_state));
    fz_init_stext_options(ctx, &options);
    options.flags = FZ_STEXT_PRESERVE_SPANS | FZ_STEXT_CLIP | FZ_STEXT_ACCURATE_BBOXES | FZ_STEXT_COLLECT_STYLES;

    matched_blocks = (fz_stext_block **)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*matched_blocks));
    analyses = (bridge_block_analysis *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*analyses));
    probe_targets = (bridge_text_object_probe_target *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*probe_targets));
    probe_indices = (int *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*probe_indices));
    if (matched_blocks == NULL || analyses == NULL || probe_targets == NULL || probe_indices == NULL) {
        bridge_set_error(out_error, "Out of memory while classifying page edits.");
        goto fail;
    }

    for (index = 0; index < edit_count; index++) {
        probe_indices[index] = -1;
        edits[index].mode = PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED;
        bridge_set_resolved_edit_message(&edits[index], "This block is not safe to save.");
    }

    page = pdf_load_page(ctx, document->pdf_document, page_index);
    stext_page = fz_new_stext_page_from_page(ctx, (fz_page *)page, &options);

    for (index = 0; index < edit_count; index++) {
        fz_stext_block *block = bridge_find_text_block_by_native_id(stext_page, edits[index].native_block_id);
        if (block == NULL) {
            bridge_set_resolved_edit_message(&edits[index], "The edited text block could not be found during save preflight.");
            continue;
        }

        matched_blocks[index] = block;
        analyses[index] = bridge_analyze_text_block(ctx, document, block);
        free(edits[index].original_text);
        edits[index].original_text = bridge_normalize_text_from_block(ctx, block);
        if (!analyses[index].is_editable) {
            bridge_set_resolved_edit_message(&edits[index], analyses[index].failure_message);
            continue;
        }

        probe_targets[probe_count].native_block_id = edits[index].native_block_id;
        probe_targets[probe_count].bounds = bridge_make_rect(block->bbox);
        probe_indices[index] = (int)probe_count;
        probe_count++;
    }

    if (probe_count > 0) {
        probe_state.targets = probe_targets;
        probe_state.target_count = probe_count;
        probe_state.remove_matching_text = false;
        probe_state.page_bounds = fz_bound_page(ctx, (fz_page *)page);
        if (!bridge_run_page_text_object_probe(ctx, document, page, page_index, &probe_state, out_error)) {
            goto fail;
        }
    }

    for (index = 0; index < edit_count; index++) {
        bridge_selected_font selected_font;
        fz_text *layout = NULL;
        char *layout_error = NULL;
        bool overlay_possible;
        bool true_rewrite_possible = false;
        int probe_index = probe_indices[index];

        if (matched_blocks[index] == NULL || !analyses[index].is_editable) {
            continue;
        }

        memset(&selected_font, 0, sizeof(selected_font));
        overlay_possible =
            bridge_select_font(ctx, &analyses[index], edits[index].replacement_text, &selected_font) &&
            bridge_layout_text(
                ctx,
                selected_font.font ? selected_font.font : analyses[index].style.font,
                analyses[index].style.font_size,
                edits[index].replacement_text,
                bridge_make_rect(matched_blocks[index]->bbox),
                &layout,
                &layout_error
            );

        if (overlay_possible &&
            edits[index].original_text != NULL &&
            strchr(edits[index].original_text, '\n') == NULL &&
            (probe_index < 0 ||
                (probe_targets[probe_index].matched_text_object_count <= 1 &&
                 !probe_targets[probe_index].touched_multiple_blocks))) {
            true_rewrite_possible = true;
        }

        if (layout != NULL) {
            fz_drop_text(ctx, layout);
        }
        bridge_drop_selected_font(ctx, &selected_font);

        if (true_rewrite_possible) {
            edits[index].mode = PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE;
            bridge_set_resolved_edit_message(&edits[index], "This block will be saved as a true PDF edit.");
        } else if (overlay_possible) {
            edits[index].mode = PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK;
            bridge_set_resolved_edit_message(
                &edits[index],
                "True rewrite is unavailable because the original text program could not be matched safely. Saving will use content overlay."
            );
        } else {
            edits[index].mode = PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED;
            bridge_set_resolved_edit_message(
                &edits[index],
                layout_error != NULL ? layout_error : "Replacement text does not fit inside the original text block."
            );
        }

        pdf_bridge_free_error(layout_error);
    }

    free(probe_indices);
    free(probe_targets);
    free(analyses);
    free(matched_blocks);
    fz_drop_stext_page(ctx, stext_page);
    pdf_drop_page(ctx, page);
    return 1;

fail:
    free(probe_indices);
    free(probe_targets);
    free(analyses);
    free(matched_blocks);
    if (stext_page != NULL) {
        fz_drop_stext_page(ctx, stext_page);
    }
    if (page != NULL) {
        pdf_drop_page(ctx, page);
    }
    return 0;
}

static int bridge_classify_edits(
    fz_context *ctx,
    pdf_bridge_document *document,
    bridge_resolved_edit *resolved_edits,
    size_t edit_count,
    char **out_error
)
{
    size_t page_start = 0;

    qsort(resolved_edits, edit_count, sizeof(*resolved_edits), bridge_compare_edits);

    while (page_start < edit_count) {
        size_t page_end = page_start + 1;
        while (page_end < edit_count && resolved_edits[page_end].page_index == resolved_edits[page_start].page_index) {
            page_end++;
        }

        if (!bridge_classify_page_edits(
                ctx,
                document,
                resolved_edits[page_start].page_index,
                resolved_edits + page_start,
                page_end - page_start,
                out_error
            )) {
            return 0;
        }

        page_start = page_end;
    }

    return 1;
}

static int bridge_apply_page_overlay(
    fz_context *ctx,
    pdf_bridge_document *document,
    int32_t page_index,
    const bridge_resolved_edit *edits,
    size_t edit_count,
    char **out_error
)
{
    pdf_obj *page_object = NULL;
    pdf_obj *page_resources = NULL;
    pdf_obj *xobject_resources = NULL;
    pdf_obj *overlay_resources = NULL;
    pdf_obj *overlay_form = NULL;
    pdf_obj *overlay_invocation = NULL;
    pdf_obj *page_contents = NULL;
    pdf_obj *content_array = NULL;
    fz_page *page = NULL;
    fz_stext_page *stext_page = NULL;
    fz_stext_options options;
    fz_buffer *overlay_buffer = NULL;
    fz_buffer *invocation_buffer = NULL;
    fz_rect fitz_page_bounds;
    fz_matrix page_transform;
    fz_rect pdf_page_bounds;
    size_t edit_index;
    int font_resource_index = 0;

    fz_init_stext_options(ctx, &options);
    options.flags = FZ_STEXT_PRESERVE_SPANS | FZ_STEXT_CLIP | FZ_STEXT_ACCURATE_BBOXES | FZ_STEXT_COLLECT_STYLES;

    page = fz_load_page(ctx, document->document, page_index);
    stext_page = fz_new_stext_page_from_page(ctx, page, &options);
    fitz_page_bounds = fz_bound_page(ctx, page);
    page_transform = (fz_matrix){ 1, 0, 0, -1, -fitz_page_bounds.x0, fitz_page_bounds.y1 };
    pdf_page_bounds = fz_transform_rect(fitz_page_bounds, page_transform);

    overlay_resources = pdf_new_dict(ctx, document->pdf_document, 2);
    overlay_buffer = fz_new_buffer(ctx, 256);
    bridge_append_page_transform(ctx, overlay_buffer, fitz_page_bounds);

    for (edit_index = 0; edit_index < edit_count; edit_index++) {
        fz_stext_block *block;
        bridge_block_analysis analysis;
        bridge_selected_font selected_font;
        fz_text *layout = NULL;
        pdf_obj *font_reference = NULL;
        pdf_obj *font_dict;
        char resource_name[16];

        block = stext_page->first_block;
        while (block != NULL && block->id != edits[edit_index].native_block_id) {
            block = block->next;
        }

        if (block == NULL) {
            bridge_set_error(out_error, "The edited text block could not be found during save.");
            goto fail;
        }

        analysis = bridge_analyze_text_block(ctx, document, block);
        if (!analysis.is_editable) {
            bridge_set_error(out_error, analysis.failure_message);
            goto fail;
        }

        if (!bridge_select_font(ctx, &analysis, edits[edit_index].replacement_text, &selected_font)) {
            bridge_set_error(out_error, "Replacement text cannot be encoded by the original font or the family-matched Base14 fallback.");
            goto fail;
        }

        if (!bridge_layout_text(
                ctx,
                selected_font.font ? selected_font.font : analysis.style.font,
                analysis.style.font_size,
                edits[edit_index].replacement_text,
                bridge_make_rect(block->bbox),
                &layout,
                out_error
            )) {
            bridge_drop_selected_font(ctx, &selected_font);
            goto fail;
        }

        bridge_append_whiteout(ctx, overlay_buffer, bridge_make_rect(block->bbox));

        if (edits[edit_index].replacement_text != NULL && edits[edit_index].replacement_text[0] != '\0') {
            font_dict = bridge_ensure_font_resource_dict(ctx, document->pdf_document, overlay_resources);
            fz_snprintf(resource_name, sizeof(resource_name), "F%d", font_resource_index++);

            if (selected_font.mode == PDF_BRIDGE_FONT_MODE_ORIGINAL) {
                font_reference = pdf_add_cid_font(ctx, document->pdf_document, analysis.style.font);
            } else {
                int simple_encoding = PDF_SIMPLE_ENCODING_LATIN;
                if (selected_font.encoding == PDF_BRIDGE_TEXT_ENCODING_GREEK) {
                    simple_encoding = PDF_SIMPLE_ENCODING_GREEK;
                } else if (selected_font.encoding == PDF_BRIDGE_TEXT_ENCODING_CYRILLIC) {
                    simple_encoding = PDF_SIMPLE_ENCODING_CYRILLIC;
                }
                font_reference = pdf_add_simple_font(ctx, document->pdf_document, selected_font.font, simple_encoding);
            }

            pdf_dict_puts(ctx, font_dict, resource_name, font_reference);
            bridge_append_text_color(ctx, overlay_buffer, analysis.style.color);
            bridge_append_text(
                ctx,
                overlay_buffer,
                resource_name,
                layout,
                analysis.style.font_size,
                selected_font.encoding,
                0.0,
                1.0,
                0.0
            );
            pdf_drop_obj(ctx, font_reference);
        }

        fz_drop_text(ctx, layout);
        bridge_drop_selected_font(ctx, &selected_font);
    }

    overlay_form = pdf_new_xobject(ctx, document->pdf_document, pdf_page_bounds, fz_identity, overlay_resources, overlay_buffer);

    page_object = pdf_lookup_page_obj(ctx, document->pdf_document, page_index);
    pdf_flatten_inheritable_page_items(ctx, page_object);

    page_resources = pdf_dict_get(ctx, page_object, PDF_NAME(Resources));
    if (page_resources == NULL) {
        page_resources = pdf_new_dict(ctx, document->pdf_document, 2);
        pdf_dict_put_drop(ctx, page_object, PDF_NAME(Resources), page_resources);
    }

    xobject_resources = pdf_dict_get(ctx, page_resources, PDF_NAME(XObject));
    if (xobject_resources == NULL) {
        xobject_resources = pdf_new_dict(ctx, document->pdf_document, 2);
        pdf_dict_put_drop(ctx, page_resources, PDF_NAME(XObject), xobject_resources);
    }

    invocation_buffer = fz_new_buffer(ctx, 64);
    {
        int xobject_index = 0;
        char xobject_name[16];

        do {
            fz_snprintf(xobject_name, sizeof(xobject_name), "PEO%d", xobject_index++);
        } while (pdf_dict_gets(ctx, xobject_resources, xobject_name) != NULL);

        pdf_dict_puts(ctx, xobject_resources, xobject_name, overlay_form);
        fz_append_printf(ctx, invocation_buffer, "q /%s Do Q\n", xobject_name);
    }

    overlay_invocation = pdf_add_stream(ctx, document->pdf_document, invocation_buffer, NULL, 0);
    page_contents = pdf_dict_get(ctx, page_object, PDF_NAME(Contents));
    if (page_contents == NULL) {
        pdf_dict_put(ctx, page_object, PDF_NAME(Contents), overlay_invocation);
    } else if (pdf_is_array(ctx, page_contents)) {
        pdf_array_push(ctx, page_contents, overlay_invocation);
    } else {
        content_array = pdf_new_array(ctx, document->pdf_document, 2);
        pdf_array_push(ctx, content_array, page_contents);
        pdf_array_push(ctx, content_array, overlay_invocation);
        pdf_dict_put_drop(ctx, page_object, PDF_NAME(Contents), content_array);
        content_array = NULL;
    }

    pdf_drop_obj(ctx, overlay_invocation);
    pdf_drop_obj(ctx, overlay_form);
    fz_drop_buffer(ctx, invocation_buffer);
    fz_drop_buffer(ctx, overlay_buffer);
    pdf_drop_obj(ctx, overlay_resources);
    fz_drop_stext_page(ctx, stext_page);
    fz_drop_page(ctx, page);
    return 1;

fail:
    if (content_array != NULL) {
        pdf_drop_obj(ctx, content_array);
    }
    if (overlay_invocation != NULL) {
        pdf_drop_obj(ctx, overlay_invocation);
    }
    if (overlay_form != NULL) {
        pdf_drop_obj(ctx, overlay_form);
    }
    if (invocation_buffer != NULL) {
        fz_drop_buffer(ctx, invocation_buffer);
    }
    if (overlay_buffer != NULL) {
        fz_drop_buffer(ctx, overlay_buffer);
    }
    if (overlay_resources != NULL) {
        pdf_drop_obj(ctx, overlay_resources);
    }
    if (stext_page != NULL) {
        fz_drop_stext_page(ctx, stext_page);
    }
    if (page != NULL) {
        fz_drop_page(ctx, page);
    }
    return 0;
}

static int bridge_compare_edits(const void *left, const void *right)
{
    const bridge_resolved_edit *lhs = (const bridge_resolved_edit *)left;
    const bridge_resolved_edit *rhs = (const bridge_resolved_edit *)right;
    if (lhs->page_index != rhs->page_index) {
        return lhs->page_index < rhs->page_index ? -1 : 1;
    }
    if (lhs->native_block_id != rhs->native_block_id) {
        return lhs->native_block_id < rhs->native_block_id ? -1 : 1;
    }
    return 0;
}

static int bridge_fill_block_outcomes(
    const bridge_resolved_edit *resolved_edits,
    size_t edit_count,
    pdf_bridge_block_outcome **out_outcomes,
    int32_t *out_true_rewrite_count,
    int32_t *out_overlay_fallback_count,
    int32_t *out_blocked_count
)
{
    pdf_bridge_block_outcome *outcomes = NULL;
    size_t index;
    int32_t true_rewrite_count = 0;
    int32_t overlay_fallback_count = 0;
    int32_t blocked_count = 0;

    outcomes = (pdf_bridge_block_outcome *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*outcomes));
    if (outcomes == NULL) {
        return 0;
    }

    for (index = 0; index < edit_count; index++) {
        outcomes[index].page_index = resolved_edits[index].page_index;
        outcomes[index].native_block_id = resolved_edits[index].native_block_id;
        outcomes[index].mode = resolved_edits[index].mode;
        outcomes[index].message = bridge_strdup(resolved_edits[index].message != NULL ? resolved_edits[index].message : "");

        switch (resolved_edits[index].mode) {
        case PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE:
            true_rewrite_count++;
            break;
        case PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK:
            overlay_fallback_count++;
            break;
        case PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED:
            blocked_count++;
            break;
        }
    }

    *out_outcomes = outcomes;
    *out_true_rewrite_count = true_rewrite_count;
    *out_overlay_fallback_count = overlay_fallback_count;
    *out_blocked_count = blocked_count;
    return 1;
}

static char *bridge_make_temporary_path(const char *destination_path)
{
    const char *separator = strrchr(destination_path, '/');
    const char *basename = separator == NULL ? destination_path : separator + 1;
    size_t directory_length = separator == NULL ? 1 : (size_t)(separator - destination_path + 1);
    size_t suffix_length = strlen(".bridge-save-XXXXXX.pdf");
    char *path = (char *)malloc(directory_length + strlen(basename) + suffix_length + 1);

    if (path == NULL) {
        return NULL;
    }

    if (separator == NULL) {
        path[0] = '.';
        path[1] = '/';
        memcpy(path + 2, basename, strlen(basename));
        strcpy(path + 2 + strlen(basename), ".bridge-save-XXXXXX.pdf");
    } else {
        memcpy(path, destination_path, directory_length);
        memcpy(path + directory_length, basename, strlen(basename));
        strcpy(path + directory_length + strlen(basename), ".bridge-save-XXXXXX.pdf");
    }

    return path;
}

static int bridge_create_temporary_file(char *path_template)
{
    int descriptor = mkstemps(path_template, 4);
    if (descriptor >= 0) {
        close(descriptor);
    }
    return descriptor;
}

static int bridge_validate_saved_edits(
    const char *path,
    const bridge_resolved_edit *edits,
    size_t edit_count,
    int expected_page_count,
    pdf_bridge_validation_report *out_report
)
{
    pdf_bridge_document *document = NULL;
    fz_context *ctx;
    size_t edit_index;
    fz_stext_options options;

    bridge_zero_validation_report(out_report);

    document = bridge_open_temporary_document(path);
    if (document == NULL) {
        out_report->is_valid = false;
        out_report->validator = bridge_strdup("MuPDF reopen");
        out_report->message_count = 1;
        out_report->messages = (char **)calloc(1, sizeof(char *));
        if (out_report->messages != NULL) {
            out_report->messages[0] = bridge_strdup("Saved file could not be reopened for validation.");
        }
        return 1;
    }

    ctx = document->ctx;
    out_report->validator = bridge_strdup("MuPDF reopen");

    if (fz_count_pages(ctx, document->document) != expected_page_count) {
        out_report->is_valid = false;
        out_report->message_count = 1;
        out_report->messages = (char **)calloc(1, sizeof(char *));
        if (out_report->messages != NULL) {
            out_report->messages[0] = bridge_strdup("Saved file reopened with a different page count.");
        }
        pdf_bridge_close_document(document);
        return 1;
    }

    fz_init_stext_options(ctx, &options);
    options.flags = FZ_STEXT_PRESERVE_SPANS | FZ_STEXT_CLIP | FZ_STEXT_ACCURATE_BBOXES;

    out_report->messages = (char **)calloc((edit_count * 2) + 2, sizeof(char *));
    if (out_report->messages == NULL) {
        pdf_bridge_close_document(document);
        return 0;
    }

    out_report->messages[0] = bridge_strdup("Saved file reopened successfully through MuPDF.");
    out_report->message_count = 1;
    out_report->is_valid = true;

    for (edit_index = 0; edit_index < edit_count; edit_index++) {
        fz_buffer *page_text = NULL;
        const char *haystack;
        fz_try(ctx)
        {
            page_text = fz_new_buffer_from_page_number(ctx, document->document, edits[edit_index].page_index, &options);
            haystack = fz_string_from_buffer(ctx, page_text);
            if (edits[edit_index].mode == PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE) {
                if (edits[edit_index].replacement_text != NULL &&
                    edits[edit_index].replacement_text[0] != '\0' &&
                    strstr(haystack, edits[edit_index].replacement_text) == NULL) {
                    out_report->is_valid = false;
                    out_report->messages[out_report->message_count++] = bridge_strdup("A true-rewrite block did not reopen with its replacement text present.");
                    break;
                }
                if (edits[edit_index].original_text != NULL &&
                    edits[edit_index].original_text[0] != '\0' &&
                    edits[edit_index].replacement_text != NULL &&
                    strcmp(edits[edit_index].original_text, edits[edit_index].replacement_text) != 0 &&
                    strstr(haystack, edits[edit_index].original_text) != NULL) {
                    out_report->messages[out_report->message_count++] = bridge_strdup("Warning: a true-rewrite block still exposed its original text after save.");
                }
            } else if (edits[edit_index].mode == PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK) {
                out_report->messages[out_report->message_count++] = bridge_strdup("One or more blocks were saved through visual overlay fallback and may not behave like true edits in other viewers.");
            }
        }
        fz_always(ctx)
        {
            fz_drop_buffer(ctx, page_text);
        }
        fz_catch(ctx)
        {
            out_report->is_valid = false;
            out_report->messages[out_report->message_count++] = bridge_strdup("Saved file reopened, but post-save text validation failed.");
            break;
        }
    }

    if (out_report->is_valid) {
        out_report->messages[out_report->message_count++] = bridge_strdup("Edited pages reopened successfully after save.");
    }

    pdf_bridge_close_document(document);
    return 1;
}

bool pdf_engine_bridge_is_available(void)
{
    return true;
}

int pdf_bridge_open_document(
    const char *path,
    pdf_bridge_document **out_document,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
)
{
    pdf_bridge_document *document = NULL;

    bridge_zero_document_info(out_info);
    bridge_zero_editability_report(out_report);
    *out_document = NULL;

    if (!bridge_create_document(path, &document, out_error)) {
        return 0;
    }

    fz_try(document->ctx)
    {
        if (!bridge_fill_document_info(document->ctx, document, out_info) ||
            !bridge_build_editability_report(document->ctx, document, out_report)) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to build MuPDF document metadata.");
        }
    }
    fz_catch(document->ctx)
    {
        bridge_set_mupdf_error(document->ctx, out_error, "Failed to inspect PDF");
        pdf_bridge_close_document(document);
        pdf_bridge_free_document_info(out_info);
        pdf_bridge_free_editability_report(out_report);
        return 0;
    }

    *out_document = document;
    return 1;
}

int pdf_bridge_unlock_document(
    pdf_bridge_document *document,
    const char *password,
    pdf_bridge_document_info *out_info,
    pdf_bridge_editability_report *out_report,
    char **out_error
)
{
    bridge_zero_document_info(out_info);
    bridge_zero_editability_report(out_report);

    fz_try(document->ctx)
    {
        if (!fz_authenticate_password(document->ctx, document->document, password != NULL ? password : "")) {
            fz_throw(document->ctx, FZ_ERROR_ARGUMENT, "The provided password did not unlock this PDF.");
        }

        if (!bridge_fill_document_info(document->ctx, document, out_info) ||
            !bridge_build_editability_report(document->ctx, document, out_report)) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to rebuild editability after unlocking.");
        }
    }
    fz_catch(document->ctx)
    {
        bridge_set_mupdf_error(document->ctx, out_error, "Failed to unlock PDF");
        pdf_bridge_free_document_info(out_info);
        pdf_bridge_free_editability_report(out_report);
        return 0;
    }

    return 1;
}

void pdf_bridge_close_document(pdf_bridge_document *document)
{
    if (document == NULL) {
        return;
    }

    if (document->document != NULL && document->ctx != NULL) {
        fz_drop_document(document->ctx, document->document);
    }
    if (document->ctx != NULL) {
        fz_drop_context(document->ctx);
    }

    free(document->source_path);
    free(document);
}

int pdf_bridge_render_page(
    pdf_bridge_document *document,
    int32_t page_index,
    double scale,
    pdf_bridge_rendered_page *out_page,
    char **out_error
)
{
    fz_page *page = NULL;
    fz_device *device = NULL;
    fz_pixmap *pixmap = NULL;
    fz_rect bounds;
    fz_matrix transform;
    fz_rect transformed_bounds;
    fz_irect bbox;
    size_t sample_size;
    unsigned char *samples;

    bridge_zero_rendered_page(out_page);

    fz_try(document->ctx)
    {
        page = fz_load_page(document->ctx, document->document, page_index);
        bounds = fz_bound_page(document->ctx, page);
        transform = fz_post_scale(fz_translate(-bounds.x0, -bounds.y0), (float)scale, (float)scale);
        transformed_bounds = fz_transform_rect(bounds, transform);
        bbox = fz_round_rect(transformed_bounds);

        pixmap = fz_new_pixmap_with_bbox(document->ctx, fz_device_rgb(document->ctx), bbox, NULL, 1);
        fz_clear_pixmap_with_value(document->ctx, pixmap, 0xFF);
        device = fz_new_draw_device(document->ctx, transform, pixmap);
        fz_run_page(document->ctx, page, device, fz_identity, NULL);
        fz_close_device(document->ctx, device);

        out_page->width = fz_pixmap_width(document->ctx, pixmap);
        out_page->height = fz_pixmap_height(document->ctx, pixmap);
        out_page->stride = fz_pixmap_stride(document->ctx, pixmap);
        sample_size = (size_t)(out_page->stride * out_page->height);
        samples = fz_pixmap_samples(document->ctx, pixmap);
        out_page->pixels = (unsigned char *)malloc(sample_size);
        if (out_page->pixels == NULL) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Out of memory while copying rendered page pixels.");
        }
        memcpy(out_page->pixels, samples, sample_size);
    }
    fz_always(document->ctx)
    {
        if (device != NULL) {
            fz_drop_device(document->ctx, device);
        }
        if (pixmap != NULL) {
            fz_drop_pixmap(document->ctx, pixmap);
        }
        if (page != NULL) {
            fz_drop_page(document->ctx, page);
        }
    }
    fz_catch(document->ctx)
    {
        bridge_set_mupdf_error(document->ctx, out_error, "Failed to render page");
        pdf_bridge_free_rendered_page(out_page);
        return 0;
    }

    return 1;
}

int pdf_bridge_extract_blocks(
    pdf_bridge_document *document,
    int32_t page_index,
    pdf_bridge_text_block_array *out_blocks,
    char **out_error
)
{
    pdf_bridge_page_report ignored_page_report;
    memset(&ignored_page_report, 0, sizeof(ignored_page_report));
    bridge_zero_block_array(out_blocks);

    if (fz_needs_password(document->ctx, document->document)) {
        bridge_set_error(out_error, "This PDF requires a password before text blocks can be extracted.");
        return 0;
    }

    fz_try(document->ctx)
    {
        if (!bridge_collect_page_blocks(document->ctx, document, page_index, out_blocks, &ignored_page_report)) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to extract MuPDF text blocks.");
        }
    }
    fz_always(document->ctx)
    {
        size_t issue_index;
        for (issue_index = 0; issue_index < ignored_page_report.issue_count; issue_index++) {
            bridge_free_issue(&ignored_page_report.issues[issue_index]);
        }
        free(ignored_page_report.issues);
    }
    fz_catch(document->ctx)
    {
        bridge_set_mupdf_error(document->ctx, out_error, "Failed to extract page blocks");
        pdf_bridge_free_text_block_array(out_blocks);
        return 0;
    }

    return 1;
}

int pdf_bridge_preflight_save(
    pdf_bridge_document *document,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_preflight_report *out_report,
    char **out_error
)
{
    bridge_resolved_edit *resolved_edits = NULL;
    int32_t true_rewrite_count = 0;
    int32_t overlay_fallback_count = 0;
    int32_t blocked_count = 0;

    bridge_zero_save_preflight_report(out_report);

    if (!bridge_document_allows_editing(document->ctx, document)) {
        bridge_set_error(out_error, "This PDF is currently read-only and cannot be saved through the MuPDF bridge.");
        return 0;
    }

    resolved_edits = (bridge_resolved_edit *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*resolved_edits));
    if (resolved_edits == NULL) {
        bridge_set_error(out_error, "Out of memory while preparing save preflight.");
        return 0;
    }

    for (size_t edit_index = 0; edit_index < edit_count; edit_index++) {
        resolved_edits[edit_index].page_index = edits[edit_index].page_index;
        resolved_edits[edit_index].native_block_id = edits[edit_index].native_block_id;
        resolved_edits[edit_index].replacement_text = edits[edit_index].replacement_text;
        resolved_edits[edit_index].original_text = NULL;
        resolved_edits[edit_index].message = NULL;
        resolved_edits[edit_index].mode = PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED;
    }

    fz_try(document->ctx)
    {
        if (!bridge_classify_edits(document->ctx, document, resolved_edits, edit_count, out_error)) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to classify save preflight edits.");
        }
    }
    fz_catch(document->ctx)
    {
        if (out_error != NULL && *out_error == NULL) {
            bridge_set_mupdf_error(document->ctx, out_error, "Failed to prepare save preflight");
        }
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        return 0;
    }

    if (!bridge_fill_block_outcomes(
            resolved_edits,
            edit_count,
            &out_report->outcomes,
            &true_rewrite_count,
            &overlay_fallback_count,
            &blocked_count
        )) {
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        bridge_set_error(out_error, "Out of memory while building the save preflight report.");
        return 0;
    }

    out_report->outcome_count = edit_count;
    out_report->true_rewrite_count = true_rewrite_count;
    out_report->overlay_fallback_count = overlay_fallback_count;
    out_report->blocked_count = blocked_count;

    if (overlay_fallback_count > 0) {
        out_report->warnings = (char **)calloc(1, sizeof(char *));
        if (out_report->warnings == NULL) {
            pdf_bridge_free_save_preflight_report(out_report);
            bridge_clear_resolved_edits(resolved_edits, edit_count);
            free(resolved_edits);
            bridge_set_error(out_error, "Out of memory while recording save warnings.");
            return 0;
        }
        out_report->warning_count = 1;
        out_report->warnings[0] = bridge_strdup("Some edits require content overlay fallback. Explicit approval is required before save.");
    }

    bridge_clear_resolved_edits(resolved_edits, edit_count);
    free(resolved_edits);
    return 1;
}

int pdf_bridge_save_document(
    pdf_bridge_document *document,
    const char *destination_path,
    const pdf_bridge_text_edit *edits,
    size_t edit_count,
    pdf_bridge_save_mode requested_mode,
    bool allow_overlay_fallback,
    pdf_bridge_save_result *out_result,
    char **out_error
)
{
    bridge_resolved_edit *resolved_edits = NULL;
    size_t edit_index;
    char *temporary_path = NULL;
    pdf_write_options write_options;
    size_t page_start = 0;
    int32_t true_rewrite_count = 0;
    int32_t overlay_fallback_count = 0;
    int32_t blocked_count = 0;

    bridge_zero_save_result(out_result);

    if (requested_mode == PDF_BRIDGE_SAVE_MODE_INCREMENTAL) {
        bridge_set_error(out_error, "Incremental save is intentionally unsupported for the MuPDF bridge in this milestone.");
        return 0;
    }

    if (!bridge_document_allows_editing(document->ctx, document)) {
        bridge_set_error(out_error, "This PDF is currently read-only and cannot be saved through the MuPDF bridge.");
        return 0;
    }

    resolved_edits = (bridge_resolved_edit *)calloc(edit_count == 0 ? 1 : edit_count, sizeof(*resolved_edits));
    if (resolved_edits == NULL) {
        bridge_set_error(out_error, "Out of memory while preparing pending edits for save.");
        return 0;
    }

    for (edit_index = 0; edit_index < edit_count; edit_index++) {
        resolved_edits[edit_index].page_index = edits[edit_index].page_index;
        resolved_edits[edit_index].native_block_id = edits[edit_index].native_block_id;
        resolved_edits[edit_index].replacement_text = edits[edit_index].replacement_text;
        resolved_edits[edit_index].original_text = NULL;
        resolved_edits[edit_index].message = NULL;
        resolved_edits[edit_index].mode = PDF_BRIDGE_PERSISTENCE_MODE_BLOCKED;
    }

    fz_try(document->ctx)
    {
        if (!bridge_classify_edits(document->ctx, document, resolved_edits, edit_count, out_error)) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to classify edits for save.");
        }
    }
    fz_catch(document->ctx)
    {
        if (out_error != NULL && *out_error == NULL) {
            bridge_set_mupdf_error(document->ctx, out_error, "Failed to classify edits for save");
        }
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        return 0;
    }

    if (!bridge_fill_block_outcomes(
            resolved_edits,
            edit_count,
            &out_result->outcomes,
            &true_rewrite_count,
            &overlay_fallback_count,
            &blocked_count
        )) {
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        bridge_set_error(out_error, "Out of memory while recording save outcomes.");
        return 0;
    }
    out_result->outcome_count = edit_count;
    out_result->true_rewrite_count = true_rewrite_count;
    out_result->overlay_fallback_count = overlay_fallback_count;

    if (blocked_count > 0) {
        bridge_set_error(out_error, "One or more edits are blocked and cannot be saved.");
        pdf_bridge_free_save_result(out_result);
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        return 0;
    }

    if (overlay_fallback_count > 0 && !allow_overlay_fallback) {
        bridge_set_error(out_error, "One or more edits require overlay fallback confirmation before save.");
        pdf_bridge_free_save_result(out_result);
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        return 0;
    }

    fz_try(document->ctx)
    {
        while (page_start < edit_count) {
            size_t page_end = page_start + 1;
            size_t page_index_count;
            size_t true_count = 0;
            size_t overlay_count = 0;
            bridge_resolved_edit *true_edits = NULL;
            bridge_resolved_edit *overlay_edits = NULL;
            size_t page_offset = 0;

            while (page_end < edit_count && resolved_edits[page_end].page_index == resolved_edits[page_start].page_index) {
                page_end++;
            }

            page_index_count = page_end - page_start;
            true_edits = (bridge_resolved_edit *)calloc(page_index_count == 0 ? 1 : page_index_count, sizeof(*true_edits));
            overlay_edits = (bridge_resolved_edit *)calloc(page_index_count == 0 ? 1 : page_index_count, sizeof(*overlay_edits));
            if (true_edits == NULL || overlay_edits == NULL) {
                free(true_edits);
                free(overlay_edits);
                fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Out of memory while grouping per-page edits.");
            }

            for (page_offset = page_start; page_offset < page_end; page_offset++) {
                if (resolved_edits[page_offset].mode == PDF_BRIDGE_PERSISTENCE_MODE_TRUE_REWRITE) {
                    true_edits[true_count++] = resolved_edits[page_offset];
                } else if (resolved_edits[page_offset].mode == PDF_BRIDGE_PERSISTENCE_MODE_OVERLAY_FALLBACK) {
                    overlay_edits[overlay_count++] = resolved_edits[page_offset];
                }
            }

            if (true_count > 0 &&
                !bridge_apply_page_true_rewrite(
                    document->ctx,
                    document,
                    resolved_edits[page_start].page_index,
                    true_edits,
                    true_count,
                    out_error
                )) {
                free(true_edits);
                free(overlay_edits);
                fz_throw(document->ctx, FZ_ERROR_ARGUMENT, "Failed to apply true PDF rewrite content.");
            }

            if (overlay_count > 0 &&
                !bridge_apply_page_overlay(
                    document->ctx,
                    document,
                    resolved_edits[page_start].page_index,
                    overlay_edits,
                    overlay_count,
                    out_error
                )) {
                free(true_edits);
                free(overlay_edits);
                fz_throw(document->ctx, FZ_ERROR_ARGUMENT, "Failed to build one or more edited page overlays.");
            }

            free(true_edits);
            free(overlay_edits);
            page_start = page_end;
        }

        temporary_path = bridge_make_temporary_path(destination_path);
        if (temporary_path == NULL) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Out of memory while creating a temporary save path.");
        }
        if (bridge_create_temporary_file(temporary_path) < 0) {
            fz_throw(document->ctx, FZ_ERROR_SYSTEM, "Failed to create a temporary save file.");
        }

        pdf_init_write_options(document->ctx, &write_options);
        write_options.do_incremental = 0;
        write_options.do_compress = 1;
        write_options.do_compress_fonts = 1;
        write_options.do_compress_images = 1;
        write_options.do_use_objstms = 1;
        pdf_save_document(document->ctx, document->pdf_document, temporary_path, &write_options);
    }
    fz_catch(document->ctx)
    {
        if (out_error != NULL && *out_error == NULL) {
            bridge_set_mupdf_error(document->ctx, out_error, "Failed to save edited PDF");
        }
        if (temporary_path != NULL) {
            unlink(temporary_path);
        }
        free(temporary_path);
        pdf_bridge_free_save_result(out_result);
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        return 0;
    }

    if (!bridge_validate_saved_edits(
            temporary_path,
            resolved_edits,
            edit_count,
            fz_count_pages(document->ctx, document->document),
            &out_result->validation
        )) {
        unlink(temporary_path);
        free(temporary_path);
        pdf_bridge_free_save_result(out_result);
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        bridge_set_error(out_error, "Saved file could not be validated after MuPDF wrote it.");
        return 0;
    }

    if (rename(temporary_path, destination_path) != 0) {
        bridge_set_error(out_error, "Saved PDF validated successfully, but the temporary file could not replace the destination.");
        unlink(temporary_path);
        free(temporary_path);
        pdf_bridge_free_save_result(out_result);
        bridge_clear_resolved_edits(resolved_edits, edit_count);
        free(resolved_edits);
        pdf_bridge_free_validation_report(&out_result->validation);
        return 0;
    }

    out_result->applied_edit_count = (int32_t)edit_count;
    out_result->used_save_mode = PDF_BRIDGE_SAVE_MODE_FULL_REWRITE;

    free(temporary_path);
    bridge_clear_resolved_edits(resolved_edits, edit_count);
    free(resolved_edits);
    return 1;
}

int pdf_bridge_validate_file(
    const char *path,
    pdf_bridge_validation_report *out_report,
    char **out_error
)
{
    pdf_bridge_document *document = NULL;
    bridge_zero_validation_report(out_report);

    document = bridge_open_temporary_document(path);
    if (document == NULL) {
        bridge_set_error(out_error, "MuPDF could not reopen the file for validation.");
        return 0;
    }

    out_report->validator = bridge_strdup("MuPDF reopen");
    out_report->message_count = 1;
    out_report->messages = (char **)calloc(1, sizeof(char *));
    if (out_report->messages == NULL) {
        pdf_bridge_close_document(document);
        bridge_set_error(out_error, "Out of memory while building the validation report.");
        return 0;
    }

    out_report->is_valid = true;
    out_report->messages[0] = bridge_strdup("File reopened successfully through MuPDF.");
    pdf_bridge_close_document(document);
    return 1;
}

#endif

void pdf_bridge_free_document_info(pdf_bridge_document_info *info)
{
    if (info == NULL) {
        return;
    }

    free(info->source_path);
    free(info->title);
    memset(info, 0, sizeof(*info));
}

void pdf_bridge_free_editability_report(pdf_bridge_editability_report *report)
{
    size_t page_index;
    size_t issue_index;

    if (report == NULL) {
        return;
    }

    for (issue_index = 0; issue_index < report->issue_count; issue_index++) {
        bridge_free_issue(&report->issues[issue_index]);
    }
    free(report->issues);

    for (page_index = 0; page_index < report->page_report_count; page_index++) {
        pdf_bridge_page_report *page_report = &report->page_reports[page_index];
        for (issue_index = 0; issue_index < page_report->issue_count; issue_index++) {
            bridge_free_issue(&page_report->issues[issue_index]);
        }
        free(page_report->issues);
    }
    free(report->page_reports);
    memset(report, 0, sizeof(*report));
}

void pdf_bridge_free_text_block_array(pdf_bridge_text_block_array *blocks)
{
    size_t block_index;

    if (blocks == NULL || blocks->items == NULL) {
        if (blocks != NULL) {
            memset(blocks, 0, sizeof(*blocks));
        }
        return;
    }

    for (block_index = 0; block_index < blocks->count; block_index++) {
        bridge_clear_text_block(&blocks->items[block_index]);
    }

    free(blocks->items);
    memset(blocks, 0, sizeof(*blocks));
}

void pdf_bridge_free_rendered_page(pdf_bridge_rendered_page *page)
{
    if (page == NULL) {
        return;
    }

    free(page->pixels);
    memset(page, 0, sizeof(*page));
}

static void bridge_free_block_outcomes(pdf_bridge_block_outcome *outcomes, size_t count)
{
    size_t index;

    if (outcomes == NULL) {
        return;
    }

    for (index = 0; index < count; index++) {
        free(outcomes[index].message);
    }
    free(outcomes);
}

void pdf_bridge_free_save_preflight_report(pdf_bridge_save_preflight_report *report)
{
    size_t warning_index;

    if (report == NULL) {
        return;
    }

    bridge_free_block_outcomes(report->outcomes, report->outcome_count);
    for (warning_index = 0; warning_index < report->warning_count; warning_index++) {
        free(report->warnings[warning_index]);
    }
    free(report->warnings);
    memset(report, 0, sizeof(*report));
}

void pdf_bridge_free_validation_report(pdf_bridge_validation_report *report)
{
    size_t message_index;

    if (report == NULL) {
        return;
    }

    free(report->validator);
    for (message_index = 0; message_index < report->message_count; message_index++) {
        free(report->messages[message_index]);
    }
    free(report->messages);
    memset(report, 0, sizeof(*report));
}

void pdf_bridge_free_save_result(pdf_bridge_save_result *result)
{
    if (result == NULL) {
        return;
    }

    bridge_free_block_outcomes(result->outcomes, result->outcome_count);
    pdf_bridge_free_validation_report(&result->validation);
    memset(result, 0, sizeof(*result));
}
