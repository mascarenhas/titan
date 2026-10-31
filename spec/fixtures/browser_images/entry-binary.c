static int titan_browser_worker(lua_State *L) {
    static const unsigned char message[] = {69, 0, 255, 195, 40};
    lua_pushlstring(L, (const char *)message, sizeof message);
    return lua_error(L);
}
