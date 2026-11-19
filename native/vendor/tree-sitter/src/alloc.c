#include "alloc.h"
#include "tree_sitter/api.h"
#include <stdlib.h>

static void *pcts_malloc_default(size_t size) {
  void *result = malloc(size);
  if (size > 0 && !result) {
    fprintf(stderr, "tree-sitter failed to allocate %zu bytes", size);
    abort();
  }
  return result;
}

static void *pcts_calloc_default(size_t count, size_t size) {
  void *result = calloc(count, size);
  if (count > 0 && !result) {
    fprintf(stderr, "tree-sitter failed to allocate %zu bytes", count * size);
    abort();
  }
  return result;
}

static void *pcts_realloc_default(void *buffer, size_t size) {
  void *result = realloc(buffer, size);
  if (size > 0 && !result) {
    fprintf(stderr, "tree-sitter failed to reallocate %zu bytes", size);
    abort();
  }
  return result;
}

// Allow clients to override allocation functions dynamically
TS_PUBLIC void *(*pcts_current_malloc)(size_t) = pcts_malloc_default;
TS_PUBLIC void *(*pcts_current_calloc)(size_t, size_t) = pcts_calloc_default;
TS_PUBLIC void *(*pcts_current_realloc)(void *, size_t) = pcts_realloc_default;
TS_PUBLIC void (*pcts_current_free)(void *) = free;

void pcts_set_allocator(
  void *(*new_malloc)(size_t size),
  void *(*new_calloc)(size_t count, size_t size),
  void *(*new_realloc)(void *ptr, size_t size),
  void (*new_free)(void *ptr)
) {
  pcts_current_malloc = new_malloc ? new_malloc : pcts_malloc_default;
  pcts_current_calloc = new_calloc ? new_calloc : pcts_calloc_default;
  pcts_current_realloc = new_realloc ? new_realloc : pcts_realloc_default;
  pcts_current_free = new_free ? new_free : free;
}
