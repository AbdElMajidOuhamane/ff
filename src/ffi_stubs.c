// libffi symbol stubs for -Dffi=false builds (e.g. the Docker/musl image).
// The ffi global is gated behind ffcfg.ffi — dlopen/callback throw before
// any of these are ever called. Only symbol names matter for linking.
int ffi_prep_cif(void) { return -1; }
void ffi_call(void) {}
void *ffi_closure_alloc(void) { return 0; }
void ffi_closure_free(void) {}
int ffi_prep_closure_loc(void) { return -1; }
char ffi_type_void, ffi_type_sint8, ffi_type_uint8;
char ffi_type_sint16, ffi_type_uint16, ffi_type_sint32, ffi_type_uint32;
char ffi_type_sint64, ffi_type_uint64, ffi_type_float, ffi_type_double;
char ffi_type_pointer;
