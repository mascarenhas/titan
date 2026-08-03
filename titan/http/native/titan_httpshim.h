#ifndef TITAN_HTTPSHIM_H
#define TITAN_HTTPSHIM_H

#include <llhttp.h>

/*
 * Exact llhttp-shaped callback trampolines for titan.http.  Each callback
 * synchronously invokes the corresponding Titan closure stored in the parser
 * owner; parser policy, event construction, span copying, and errors all stay
 * in Titan.
 */
int titan_httpshim_url_cb(llhttp_t *parser, const char *data, size_t length);
int titan_httpshim_status_cb(llhttp_t *parser, const char *data,
                             size_t length);
int titan_httpshim_header_field_cb(llhttp_t *parser, const char *data,
                                   size_t length);
int titan_httpshim_header_value_cb(llhttp_t *parser, const char *data,
                                   size_t length);
int titan_httpshim_header_value_complete_cb(llhttp_t *parser);
int titan_httpshim_headers_complete_cb(llhttp_t *parser);
int titan_httpshim_body_cb(llhttp_t *parser, const char *data, size_t length);
int titan_httpshim_message_complete_cb(llhttp_t *parser);

#endif
