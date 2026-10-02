__declspec(dllimport) int titan_loader_dependency(void);
__declspec(dllexport) int titan_loader_native_value(void) {
    return titan_loader_dependency();
}
