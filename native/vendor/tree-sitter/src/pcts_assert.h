#ifndef TREE_SITTER_ASSERT_H_
#define TREE_SITTER_ASSERT_H_

#ifdef NDEBUG
#define pcts_assert(e) ((void)(e))
#else
#include <assert.h>
#define pcts_assert(e) assert(e)
#endif

#endif // TREE_SITTER_ASSERT_H_
