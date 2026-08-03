# SSL and HTTP(S)

The example code in this draft is in C, but it has a straightforward translation to Titan with the FFI. All of the
new modules should be part of the Titan stdlib (so bundled into the stdlib titan.so/titan.a).

The outcome of the `ssl` module is to provide SSL TCP connections that will be useful not just for
the `http` module in this same draft, but also for other network clients that need SSL (Redis, PostgresSQL, etc.).

For the `http` module, the client part should be barebones (following redirects and handling compressed body data
up to the caller) but work with any HTTP(S) server that supports HTTP/1.1.

The HTTP(S) server part also only supports `HTTP/1.1` and is also barebones, with a single "request handler" function
per server instance. Users can use hostname and path information to multiplex this into multiple logical
handlers and build more elaborate server frameworks.

Websockets are explicitly out of scope of this iteration.

## SSL sockets using OpenSSL, built on top of the libuv-based async IO.

The most common way to integrate OpenSSL with libuv is through Memory BIOs (Basic Input/Output).
Instead of allowing OpenSSL to handle network sockets directly, you use memory buffers to pass data back and forth.

* **Network Read**: When libuv fires uv_read_cb, you take the raw encrypted network bytes and write
them into OpenSSL’s input BIO.
* **Decryption**: You call OpenSSL’s SSL_read() to extract the unencrypted plaintext bytes from that input BIO.
* **Encryption**: When your app wants to send data, you write plaintext to OpenSSL via SSL_write().
* **Network Write**: You then extract the newly encrypted bytes from OpenSSL's output BIO and send them
over the wire using uv_write().

### Client connections

When using OpenSSL memory BIOs with uv_tcp_connect, libuv handles the underlying TCP connection, while OpenSSL drives
the TLS state machine in memory. Here is how the initial handshake and key exchange flow step-by-step on pure
libuv:

#### 1. Initiation (uv_tcp_connect)

1. You call uv_tcp_connect to initiate the raw TCP connection to the server.
2. In tandem, you initialize your OpenSSL context (SSL_CTX_new) and create an SSL structure (SSL_new), setting up the connection for certificate validation (see the validation section below).
3. You create two memory BIOs: an input BIO (for data received from the network) and an output BIO (for data to be sent to the network).
4. You bind these BIOs to your SSL object using SSL_set_bio(ssl, input_bio, output_bio).
5. You place the SSL object into client mode by calling SSL_set_connect_state(ssl).

#### 2. Generating the Client Hello

1. Once your uv_connect_cb callback fires, the raw TCP socket is officially connected.
2. You immediately trigger the TLS handshake by calling SSL_do_handshake(ssl).
3. Because the connection is new, SSL_do_handshake will return an error code SSL_ERROR_WANT_READ. This is expected behavior.
4. Internally, OpenSSL has now generated the Client Hello message and written it into your output BIO.
5. You check the output BIO for pending data using BIO_ctrl_pending(output_bio).
6. You read those encrypted Client Hello bytes out of the output BIO into a regular buffer and transmit them to the server using uv_write.
7. Finally, you call uv_read_start on the TCP stream to begin listening for the server's response.

#### 3. Processing the Server Hello & Key Exchange

1. The server receives your Client Hello, processes it, and responds with its Server Hello, Certificate, and Key Exchange data.
2. Libuv intercepts these raw bytes via your uv_read_cb callback.
3. Inside uv_read_cb, you take the incoming buffer and write it directly into OpenSSL's input BIO using BIO_write.
4. You call SSL_do_handshake(ssl) again. OpenSSL will consume the Server Hello from the input BIO and process the server's cryptographic keys.

#### 4. Completing the Handshake Loop

1. Depending on the TLS version and cipher suite, OpenSSL may need to send more handshake data (like client key exchange tokens).
2. If SSL_do_handshake returns SSL_ERROR_WANT_WRITE or SSL_ERROR_WANT_READ, you check the output BIO again. If data exists, you pass it to uv_write.
3. You loop this read/write state machine until SSL_do_handshake returns exactly 1.
4. A return value of 1 indicates that the cryptographic key exchange is complete, certificates are verified, and the secure TLS channel is open for application data.

#### Certificate Validation

For the SSL client, you must verify the identity of the server to prevent Man-in-the-Middle (MitM) attacks.

Before starting the connection, you must tell OpenSSL where to find your operating system's trusted Root Certificate Authorities (CAs)
with `SSL_CTX_set_default_verify_path` on the new OpenSSL context.

Then you onfigure the SSL context to require verification and reject the connection if the certificate chain is invalid.

```c
SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
```

A certificate can be cryptographically valid but belong to a completely different website. You must explicitly tell OpenSSL the target domain name (example.com) so it can match it against the certificate's Subject Alternative Name (SAN) fields.

```c
// Enable automatic hostname validation during the handshake
SSL_set_hostflags(ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
if (SSL_set1_host(ssl, "example.com") != 1) {
    // Handle error: failed to set hostname target
}
// Also set Server Name Indication (SNI) so the server knows which cert to send
SSL_set_tlsext_host_name(ssl, "example.com");
```

Once your SSL_do_handshake loop successfully returns 1, you must perform a final check to confirm that the verification succeeded.

```c
long verify_result = SSL_get_verify_result(ssl);
if (verify_result != X509_V_OK) {
    // Handshake finished, but the certificate validation FAILED!
    // Log the error using X509_verify_cert_error_string(verify_result)
    // Abort connection and close the libuv socket immediately.
}
// Safe to proceed with HTTP/1.1 plaintext transmission
```

### Server connections

For the server connections it is a similar handshake flow, except that the server waits for a Client Hello, processes it, and generates a Server Hello.
Certificate validation for servers is typically handled entirely by the client. The server simply loads its own certificate and private key:

```c
SSL_CTX_use_certificate_chain_file(ctx, "server.crt");
SSL_CTX_use_PrivateKey_file(ctx, "server.key", SSL_FILETYPE_PEM);
```

This version is not going to support mTLS.

#### 1. Connection Initialization (uv_accept)

1. When a new connection arrives, your uv_connection_cb (listen callback) fires.
2. You initialize a new client stream using uv_tcp_init and accept the raw connection by calling uv_accept.
3. Just like the client, you create your SSL object and attach two memory BIOs (Input and Output).
4. The Reverse Step: Instead of setting connect state, you put OpenSSL into server mode by calling SSL_set_accept_state(ssl).
5. You immediately call uv_read_start on the newly accepted client stream. The server cannot call SSL_do_handshake effectively yet because it has no data to process.

#### 2. Receiving the Client Hello

1. The client sends its Client Hello over the wire.
2. Your libuv client stream fires its uv_read_cb callback.
3. You take the raw encrypted network bytes from the libuv buffer and write them into OpenSSL's input BIO via BIO_write.
4. Now, you call SSL_do_handshake(ssl) for the first time.

#### 3. Generating the Server Response

1. OpenSSL consumes the Client Hello from the input BIO.
2. It processes the cipher suites, selects the parameters, and generates the Server Hello, Certificate, and Key Exchange messages.
3. SSL_do_handshake will return -1, and SSL_get_error will yield SSL_ERROR_WANT_READ (meaning it needs more data from the client to finish).
4. Even though it wants more data, OpenSSL has successfully queued its response inside your output BIO.
5. You check BIO_ctrl_pending(output_bio), read the generated server handshake bytes, and send them back to the client using uv_write.

#### 4. Driving the Loop to Completion

1. The client processes your server response and sends back its final key exchange/finished tokens.
2. Your uv_read_cb fires again. You push those bytes into the input BIO and call SSL_do_handshake.
3. You continue this ping-pong loop (Read network → Write to Input BIO → Handshake → Read from Output BIO → Write to network) until SSL_do_handshake returns 1.

### Implementation notes

None of the above is something that needs to be baked into the `uv` module itself, it can be a high-level
`ssl` stdlib module that wraps the `Connection` and `Server` from the `net` module into its own `Connection`
and `Server` records (so `net.Connection` is the plain TCP connection and `ssl.Connection` is an SSL connection,
the same for the `Server`).

Like with libuv, the build system should have the option of pulling OpenSSL sources and linking it statically
to titan.so and titan.a, but also be able to use a system-installed OpenSSL.

Both `net.Connection` and `ssl.Connection` should implement the same interfaces from the `io` module.

Watch out for `SSL_ERROR_WANT_WRITE` during writes. When calling `SSL_write`,
OpenSSL might occasionally return `SSL_ERROR_WANT_WRITE` if a TLS re-negotiation or session ticket update
triggers mid-stream. The code must check for this, drain the output BIO via a connection write,
and retry the write.

## Basic HTTP client and server libraries

The `http` module then uses the `net` or `ssl` modules, depending on whether HTTPS is in use or not.
For the client, this is part of the URL parsing, but for the server it is a server startup option.

### HTTP client

For a client, the handshake and the initial HTTP request happen sequentially.

1. Parse the URL
2. Connect & Handshake: Initiate the connection (via regular `net` or `ssl` `connect`).
3. Send the Request: immediately construct your HTTP plaintext request headers (e.g., GET /path HTTP/1.1\r\nHost: example.com\r\n\r\n),
write this to the connection
4. Parse the headers: The server will respond with HTTP data, read from the connection, feeding the headers into the protocol parser.
5. Handling Chunked Transfer Encoding: HTTP/1.1 servers often stream content using `Transfer-Encoding: chunked`. Your parser must decode
these chunks sequentially as `read`` returns them, assembly-lining the data until the parser signals that the body is complete.

The client library should not try to keep connections open with `keep-alive` and reuse them, just close
the connection after the request is done.

### HTTP server

The server flow is similar, but complicated by `keep-alive` management and the fact that each connection is serviced in its own separate `async.Task`:

1. Get a connection from `:accept()`, pass the connection to a new `async.Task`, the rest of the flow is in this task separate from the main `listen/accept` loop
2. Read and parse the request preamble (initial line and headers)
3. Call the request handler function
4. Start sending a response as soon as the request handler has the status code and response haders, continue streaming
the body until the request handler signals it is done
5. Keep-Alive Management: HTTP/1.1 relies heavily on persistent connections (Connection: keep-alive).
Do not close the raw TCP socket or free the SSL context after sending a response unless the client explicitly requests `Connection: close` or a timeout occurs.
Continue from 2 as if this was a new connection.

Have the usual `Request` and `Response` objects (records in Titan) representing the HTTP request and response, with
the request handler receiving both. The `Request` object should hide the details of chunked transfer encoding, exposing
a similar interface for reading the body as `io.Reader`, besides methods to get request headers and the URL details.

The `Response` object has methods to set the status code and response headers, a method to send the response headers and status,
a `write` method to stream the response body (so `Response` implements `io.Writer`), and `close` method that signals it is
finished with the response.

### HTTP parsing

Use https://github.com/nodejs/llhttp for the parser, make it always bundled, with no system version (unlike libuv/OpenSSL).
This parser is callback-based, but the `llhttp_execute` function that parses a piece of the HTTP message (which should be called
after every call to `:read()` on the connection) only returns after the entire piece been consumed and parsed, so there is no
need for coroutine-based callbacks here: the callbacks set fields on the objects that represent the server response (in the case
of the HTTP client) client request (in the case of the HTTP server).

Do not expose the llhttp bindings, keep them private to the `http` module.
