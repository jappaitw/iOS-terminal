#ifndef TREE_SITTER_WASM_H_
#define TREE_SITTER_WASM_H_

#ifdef __cplusplus
extern "C" {
#endif

#include "tree_sitter/api.h"
#include "./parser.h"

bool pcts_wasm_store_start(TSWasmStore *self, TSLexer *lexer, const TSLanguage *language);
void pcts_wasm_store_reset(TSWasmStore *self);
bool pcts_wasm_store_has_error(const TSWasmStore *self);

bool pcts_wasm_store_call_lex_main(TSWasmStore *self, TSStateId state);
bool pcts_wasm_store_call_lex_keyword(TSWasmStore *self, TSStateId state);

uint32_t pcts_wasm_store_call_scanner_create(TSWasmStore *self);
void pcts_wasm_store_call_scanner_destroy(TSWasmStore *self, uint32_t scanner_address);
bool pcts_wasm_store_call_scanner_scan(TSWasmStore *self, uint32_t scanner_address, uint32_t valid_tokens_ix);
uint32_t pcts_wasm_store_call_scanner_serialize(TSWasmStore *self, uint32_t scanner_address, char *buffer);
void pcts_wasm_store_call_scanner_deserialize(TSWasmStore *self, uint32_t scanner, const char *buffer, unsigned length);

void pcts_wasm_language_retain(const TSLanguage *self);
void pcts_wasm_language_release(const TSLanguage *self);

#ifdef __cplusplus
}
#endif

#endif  // TREE_SITTER_WASM_H_
