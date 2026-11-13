/* Test libc against the generated launcher, with no Titan module linked. */
#define CHECK_STDIO(condition) \
    do { if (!(condition)) return luaL_error(L, "stdio fixture: %s", #condition); } while (0)

static int titan_browser_worker(lua_State *L) {
    unsigned char out[] = {0x41, 0, 0xff, 0x80, 0x42};
    unsigned char large[5000];
    static char out_buffer[BUFSIZ];
    CHECK_STDIO(setvbuf(stdout, out_buffer, _IOFBF, sizeof out_buffer) == 0);
    CHECK_STDIO(fwrite(out, 1, sizeof out, stdout) == sizeof out);
    CHECK_STDIO(fflush(stdout) == 0);
    memset(out, 0, sizeof out);
    CHECK_STDIO(fputs("err-tail", stderr) >= 0);
    memset(large, 'x', sizeof large);
    CHECK_STDIO(fwrite(large, 1, sizeof large, stdout) == sizeof large);
    CHECK_STDIO(fflush(stdout) == 0);
    memset(large, 0, sizeof large);

    const __wasi_ciovec_t iovs[] = {{"left", 4}, {NULL, 0}, {"right", 5}};
    __wasi_size_t count = 99;
    CHECK_STDIO(__wasi_fd_write(1, iovs, 3, &count) == __WASI_ERRNO_SUCCESS && count == 9);
    CHECK_STDIO(__wasi_fd_write(2, NULL, 0, &count) == __WASI_ERRNO_SUCCESS && count == 0);
    CHECK_STDIO(__wasi_fd_write(3, NULL, 0, &count) == __WASI_ERRNO_BADF);
    CHECK_STDIO(__wasi_fd_close(0) == __WASI_ERRNO_SUCCESS);
    CHECK_STDIO(__wasi_fd_close(1) == __WASI_ERRNO_SUCCESS);
    CHECK_STDIO(__wasi_fd_close(2) == __WASI_ERRNO_SUCCESS);
    CHECK_STDIO(__wasi_fd_close(3) == __WASI_ERRNO_BADF);
    CHECK_STDIO(__wasi_fd_seek(1, 0, __WASI_WHENCE_SET, NULL) == __WASI_ERRNO_SPIPE);

    CHECK_STDIO(fopen("missing.txt", "r") == NULL && errno == ENOSYS);
    CHECK_STDIO(fopen("new.txt", "w") == NULL && errno == ENOSYS);
    CHECK_STDIO(remove("missing.txt") == -1 && errno == ENOSYS);
    CHECK_STDIO(rename("old.txt", "new.txt") == -1 && errno == ENOSYS);
    CHECK_STDIO(tmpfile() == NULL && errno == ENOSYS);
    CHECK_STDIO(tmpnam(NULL) == NULL && errno == ENOSYS);
    unsigned char input;
    CHECK_STDIO(fread(&input, 1, 1, stdin) == 0 && ferror(stdin) && !feof(stdin) && errno == ENOSYS);
    CHECK_STDIO(system(NULL) == 0);
    CHECK_STDIO(system("echo TITAN_UNEXPECTED_HOST_SHELL") == -1 && errno == ENOSYS);
    lua_pushinteger(L, 0);
    return 1;
}
