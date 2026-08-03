#include "titan_httpshim.h"

#include <stddef.h>

#include "lobject.h"
#include "lua.h"

#include "titan.h"

/*
 * Parser is a Titan record.  Its first fields are the native parser/settings,
 * the Lua state active for the synchronous execute, and one exact closure per
 * registered llhttp callback.  Titan record fields occupy matching zero-based
 * Udata.uv slots, as in the titan.uv callback-owner protocol.
 */
enum titan_httpshim_parser_c_index {
    TITAN_HTTPSHIM_STATE_C_INDEX = 2,
    TITAN_HTTPSHIM_URL_CALLBACK_C_INDEX = 3,
    TITAN_HTTPSHIM_STATUS_CALLBACK_C_INDEX = 4,
    TITAN_HTTPSHIM_HEADER_FIELD_CALLBACK_C_INDEX = 5,
    TITAN_HTTPSHIM_HEADER_VALUE_CALLBACK_C_INDEX = 6,
    TITAN_HTTPSHIM_HEADER_VALUE_COMPLETE_CALLBACK_C_INDEX = 7,
    TITAN_HTTPSHIM_HEADERS_COMPLETE_CALLBACK_C_INDEX = 8,
    TITAN_HTTPSHIM_BODY_CALLBACK_C_INDEX = 9,
    TITAN_HTTPSHIM_MESSAGE_COMPLETE_CALLBACK_C_INDEX = 10
};

typedef int (*titan_httpshim_data_callback_func)(
    lua_State *L, Udata *module, CClosure *closure, Udata *owner,
    const char *data, size_t length);
typedef int (*titan_httpshim_callback_func)(
    lua_State *L, Udata *module, CClosure *closure, Udata *owner);

typedef struct titan_httpshim_callback_context {
    lua_State *L;
    Udata *module;
    CClosure *closure;
    void *entry;
    int stack_top;
} titan_httpshim_callback_context;

/*
 * This is callback-only extraction, not a Titan-callable trampoline.  It must
 * inspect the raw Udata/CClosure slots supplied by Titan's generated native
 * entry ABI, which Titan code cannot express.  Keeping it here makes each
 * llhttp callback do only that extraction plus the exact native-entry call.
 */
static titan_httpshim_callback_context titan_httpshim_callback_context_for(
    llhttp_t *parser, size_t callback_index)
{
    Udata *owner = (Udata *)parser->data;
    CClosure *callback = clCvalue(&owner->uv[callback_index].uv);
    titan_httpshim_callback_context context;

    context.L = (lua_State *)pvalue(
        &owner->uv[TITAN_HTTPSHIM_STATE_C_INDEX].uv);
    context.module = uvalue(&callback->upvalue[0]);
    context.closure = callback;
    context.entry = pvalue(&callback->upvalue[2]);
    context.stack_top = lua_gettop(context.L);
    /* A callback may append to a GC-owned Array and thereby collect. */
    titan_pushmodule(context.L, owner);
    return context;
}

/*
 * This is callback-only stack cleanup, not a Titan-callable trampoline.  The
 * C callback temporarily roots its Titan owner on the raw Lua stack so an
 * Array append may collect safely; only the C callback boundary can restore
 * the exact pre-callback stack top.
 */
static void titan_httpshim_callback_context_release(
    titan_httpshim_callback_context *context)
{
    lua_settop(context->L, context->stack_top);
}

int titan_httpshim_url_cb(llhttp_t *parser, const char *data, size_t length)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_URL_CALLBACK_C_INDEX);
    titan_httpshim_data_callback_func callback = titan_cast_func(
        titan_httpshim_data_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data, data, length);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_status_cb(llhttp_t *parser, const char *data, size_t length)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_STATUS_CALLBACK_C_INDEX);
    titan_httpshim_data_callback_func callback = titan_cast_func(
        titan_httpshim_data_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data, data, length);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_header_field_cb(llhttp_t *parser, const char *data,
                                   size_t length)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_HEADER_FIELD_CALLBACK_C_INDEX);
    titan_httpshim_data_callback_func callback = titan_cast_func(
        titan_httpshim_data_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data, data, length);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_header_value_cb(llhttp_t *parser, const char *data,
                                   size_t length)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_HEADER_VALUE_CALLBACK_C_INDEX);
    titan_httpshim_data_callback_func callback = titan_cast_func(
        titan_httpshim_data_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data, data, length);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_header_value_complete_cb(llhttp_t *parser)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser,
            TITAN_HTTPSHIM_HEADER_VALUE_COMPLETE_CALLBACK_C_INDEX);
    titan_httpshim_callback_func callback = titan_cast_func(
        titan_httpshim_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_headers_complete_cb(llhttp_t *parser)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_HEADERS_COMPLETE_CALLBACK_C_INDEX);
    titan_httpshim_callback_func callback = titan_cast_func(
        titan_httpshim_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_body_cb(llhttp_t *parser, const char *data, size_t length)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_BODY_CALLBACK_C_INDEX);
    titan_httpshim_data_callback_func callback = titan_cast_func(
        titan_httpshim_data_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data, data, length);
    titan_httpshim_callback_context_release(&context);
    return result;
}

int titan_httpshim_message_complete_cb(llhttp_t *parser)
{
    titan_httpshim_callback_context context =
        titan_httpshim_callback_context_for(
            parser, TITAN_HTTPSHIM_MESSAGE_COMPLETE_CALLBACK_C_INDEX);
    titan_httpshim_callback_func callback = titan_cast_func(
        titan_httpshim_callback_func, context.entry);
    int result = callback(context.L, context.module, context.closure,
                          (Udata *)parser->data);
    titan_httpshim_callback_context_release(&context);
    return result;
}
