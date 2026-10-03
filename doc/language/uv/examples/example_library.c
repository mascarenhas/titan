/* A tiny application-owned DLL fixture; it has no libuv dependency. */
#if defined(_WIN32)
__declspec(dllexport)
#endif
int example_value(void) { return 42; }
