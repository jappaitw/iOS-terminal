// Stubs for v8::WasmModuleCompilation, referenced by the rusty_v8 binding's
// WasmStreaming glue but absent from our V8 (built with
// v8_enable_webassembly=false). As a plain archive the referencing members were
// never pulled in; the sealed prelink (-force_load, pc_* exports only) pulls
// everything, so the final app link needs these defined. Wasm is off at
// runtime, so they can never be called — abort() guards the impossible.
//
// C functions named with the C++ mangled spelling produce the exact Mach-O
// symbols (`_` prefix added by the toolchain), without needing Chromium's
// libc++ (std::__Cr) headers to spell the real signatures.
#include <stdlib.h>

#define PC_WASM_STUB(name) void name(void) { abort(); }

PC_WASM_STUB(_ZN2v821WasmModuleCompilation15OnBytesReceivedEPKhm)
PC_WASM_STUB(_ZN2v821WasmModuleCompilation25SetHasCompiledModuleBytesEv)
PC_WASM_STUB(_ZN2v821WasmModuleCompilation39SetMoreFunctionsCanBeSerializedCallbackENSt4__Cr8functionIFvNS_18CompiledWasmModuleEEEE)
PC_WASM_STUB(_ZN2v821WasmModuleCompilation5AbortEv)
PC_WASM_STUB(_ZN2v821WasmModuleCompilation6FinishEPNS_7IsolateERKNSt4__Cr8functionIFvRNS_13WasmStreaming22ModuleCachingInterfaceEEEERKNS4_IFvNS3_7variantIJNS_5LocalINS_16WasmModuleObjectEEENSD_INS_5ValueEEEEEEEEE)
PC_WASM_STUB(_ZN2v821WasmModuleCompilation6SetUrlEPKcm)
PC_WASM_STUB(_ZN2v821WasmModuleCompilationC1Ev)
PC_WASM_STUB(_ZN2v821WasmModuleCompilationD1Ev)
