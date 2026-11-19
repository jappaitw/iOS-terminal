#include "tree_sitter/api.h"
#include "./array.h"
#include "./get_changed_ranges.h"
#include "./length.h"
#include "./subtree.h"
#include "./tree_cursor.h"
#include "./tree.h"

TSTree *pcts_tree_new(
  Subtree root, const TSLanguage *language,
  const TSRange *included_ranges, unsigned included_range_count
) {
  TSTree *result = pcts_malloc(sizeof(TSTree));
  result->root = root;
  result->language = pcts_language_copy(language);
  result->included_ranges = pcts_calloc(included_range_count, sizeof(TSRange));
  memcpy(result->included_ranges, included_ranges, included_range_count * sizeof(TSRange));
  result->included_range_count = included_range_count;
  return result;
}

TSTree *pcts_tree_copy(const TSTree *self) {
  pcts_subtree_retain(self->root);
  return pcts_tree_new(self->root, self->language, self->included_ranges, self->included_range_count);
}

void pcts_tree_delete(TSTree *self) {
  if (!self) return;

  SubtreePool pool = pcts_subtree_pool_new(0);
  pcts_subtree_release(&pool, self->root);
  pcts_subtree_pool_delete(&pool);
  pcts_language_delete(self->language);
  pcts_free(self->included_ranges);
  pcts_free(self);
}

TSNode pcts_tree_root_node(const TSTree *self) {
  return pcts_node_new(self, &self->root, pcts_subtree_padding(self->root), 0);
}

TSNode pcts_tree_root_node_with_offset(
  const TSTree *self,
  uint32_t offset_bytes,
  TSPoint offset_extent
) {
  Length offset = {offset_bytes, offset_extent};
  return pcts_node_new(self, &self->root, length_add(offset, pcts_subtree_padding(self->root)), 0);
}

const TSLanguage *pcts_tree_language(const TSTree *self) {
  return self->language;
}

void pcts_tree_edit(TSTree *self, const TSInputEdit *edit) {
  for (unsigned i = 0; i < self->included_range_count; i++) {
    TSRange *range = &self->included_ranges[i];
    if (range->end_byte >= edit->old_end_byte) {
      if (range->end_byte != UINT32_MAX) {
        range->end_byte = edit->new_end_byte + (range->end_byte - edit->old_end_byte);
        range->end_point = point_add(
          edit->new_end_point,
          point_sub(range->end_point, edit->old_end_point)
        );
        if (range->end_byte < edit->new_end_byte) {
          range->end_byte = UINT32_MAX;
          range->end_point = POINT_MAX;
        }
      }
    } else if (range->end_byte > edit->start_byte) {
      range->end_byte = edit->start_byte;
      range->end_point = edit->start_point;
    }
    if (range->start_byte >= edit->old_end_byte) {
      range->start_byte = edit->new_end_byte + (range->start_byte - edit->old_end_byte);
      range->start_point = point_add(
        edit->new_end_point,
        point_sub(range->start_point, edit->old_end_point)
      );
      if (range->start_byte < edit->new_end_byte) {
        range->start_byte = UINT32_MAX;
        range->start_point = POINT_MAX;
      }
    } else if (range->start_byte > edit->start_byte) {
      range->start_byte = edit->start_byte;
      range->start_point = edit->start_point;
    }
  }

  SubtreePool pool = pcts_subtree_pool_new(0);
  self->root = pcts_subtree_edit(self->root, edit, &pool);
  pcts_subtree_pool_delete(&pool);
}

TSRange *pcts_tree_included_ranges(const TSTree *self, uint32_t *length) {
  *length = self->included_range_count;
  TSRange *ranges = pcts_calloc(self->included_range_count, sizeof(TSRange));
  memcpy(ranges, self->included_ranges, self->included_range_count * sizeof(TSRange));
  return ranges;
}

TSRange *pcts_tree_get_changed_ranges(const TSTree *old_tree, const TSTree *new_tree, uint32_t *length) {
  TreeCursor cursor1 = {NULL, array_new(), 0};
  TreeCursor cursor2 = {NULL, array_new(), 0};
  pcts_tree_cursor_init(&cursor1, pcts_tree_root_node(old_tree));
  pcts_tree_cursor_init(&cursor2, pcts_tree_root_node(new_tree));

  TSRangeArray included_range_differences = array_new();
  pcts_range_array_get_changed_ranges(
    old_tree->included_ranges, old_tree->included_range_count,
    new_tree->included_ranges, new_tree->included_range_count,
    &included_range_differences
  );

  TSRange *result;
  *length = pcts_subtree_get_changed_ranges(
    &old_tree->root, &new_tree->root, &cursor1, &cursor2,
    old_tree->language, &included_range_differences, &result
  );

  array_delete(&included_range_differences);
  array_delete(&cursor1.stack);
  array_delete(&cursor2.stack);
  return result;
}

#ifdef _WIN32

#include <io.h>
#include <windows.h>

int _ts_dup(HANDLE handle) {
  HANDLE dup_handle;
  if (!DuplicateHandle(
    GetCurrentProcess(), handle,
    GetCurrentProcess(), &dup_handle,
    0, FALSE, DUPLICATE_SAME_ACCESS
  )) return -1;

  return _open_osfhandle((intptr_t)dup_handle, 0);
}

void pcts_tree_print_dot_graph(const TSTree *self, int fd) {
  FILE *file = _fdopen(_ts_dup((HANDLE)_get_osfhandle(fd)), "a");
  pcts_subtree_print_dot_graph(self->root, self->language, file);
  fclose(file);
}

#elif !defined(__wasi__) // WASI doesn't support dup

#include <unistd.h>

int _ts_dup(int file_descriptor) {
  return dup(file_descriptor);
}

void pcts_tree_print_dot_graph(const TSTree *self, int file_descriptor) {
  FILE *file = fdopen(_ts_dup(file_descriptor), "a");
  pcts_subtree_print_dot_graph(self->root, self->language, file);
  fclose(file);
}

#else

void pcts_tree_print_dot_graph(const TSTree *self, int file_descriptor) {
  (void)self;
  (void)file_descriptor;
}

#endif
