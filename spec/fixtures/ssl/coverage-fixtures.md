These PEM files exercise TLS input validation without replacing OpenSSL calls
or changing production state. They contain only test credentials.

- `coverage-trusted-ca.pem` is the existing `ca.pem` certificate emitted with
  OpenSSL's `x509 -addtrust serverAuth -trustout` auxiliary trust encoding.
- `coverage-certificate-trailing-der.pem` and `coverage-key-trailing-der.pem`
  decode the existing server certificate/key, append one zero byte, then encode
  the result back into the original PEM label. Each contains valid DER followed
  by a byte that strict single-object decoding must reject.
- `coverage-encrypted-rsa-key.pem` is the existing server key emitted with
  `openssl pkey -traditional -aes256 -passout pass:titan-coverage-only`. The
  password is a public test fixture value. TLS must reject encrypted keys
  without attempting an interactive password prompt.
- `coverage-mismatched-key.pem` is a separate P-256 EC key produced by
  `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256`; it cannot
  match the RSA server certificate.
- `coverage-unsupported-certificate.pem` has a well-formed X25519 subject public
  key and an RSA signature from the existing test key. It was produced with
  `openssl x509 -new -force_pubkey <X25519-public-key> -signkey server-key.pem`.
  X25519 cannot authenticate a TLS server, so loading it must reject the
  certificate and release the decoded X509 object.

- `coverage-unsupported-key.pem` is the X25519 private key used for the
  unsupported-authentication certificate. It is structurally valid
  key-exchange material, but OpenSSL cannot install it as a TLS server
  authentication key.

Fixtures were generated with OpenSSL 3.5.9. Tests assert stable Titan error
identities/operations and only Titan-owned diagnostic text; they do not depend
on OpenSSL's version-specific ASN.1 or key-mismatch wording.
