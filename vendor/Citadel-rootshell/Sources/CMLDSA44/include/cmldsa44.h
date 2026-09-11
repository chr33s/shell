#ifndef CMLDSA44_H
#define CMLDSA44_H

#include <stddef.h>
#include <stdint.h>

// Byte-oriented bridge to the ML-DSA-44 (FIPS 204) implementation compiled
// inside swift-crypto's vendored BoringSSL. CCryptoBoringSSL's umbrella
// header does not expose <mldsa.h>, so the prefixed symbols are declared in
// cmldsa44.c and resolved at link time against the module that is already in
// the dependency graph.

#define CMLDSA44_PUBLIC_KEY_BYTES 1312
#define CMLDSA44_SIGNATURE_BYTES 2420
#define CMLDSA44_SEED_BYTES 32

// All functions return 1 on success, 0 on failure (BoringSSL convention).

// Generates a fresh key pair, writing the encoded public key and the 32-byte
// seed the private key can be re-derived from.
int cmldsa44_generate_key(uint8_t out_public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                          uint8_t out_seed[CMLDSA44_SEED_BYTES]);

// Re-derives the encoded public key from a seed.
int cmldsa44_public_from_seed(uint8_t out_public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                              const uint8_t seed[CMLDSA44_SEED_BYTES]);

// Pure ML-DSA.Sign (hedged/randomized) over |msg| with |context|; the private
// key is expanded from |seed| for the duration of the call only.
int cmldsa44_sign(uint8_t out_signature[CMLDSA44_SIGNATURE_BYTES],
                  const uint8_t seed[CMLDSA44_SEED_BYTES],
                  const uint8_t *msg, size_t msg_len,
                  const uint8_t *context, size_t context_len);

// Pure ML-DSA.Verify over |msg| with |context|.
int cmldsa44_verify(const uint8_t public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                    const uint8_t *signature, size_t signature_len,
                    const uint8_t *msg, size_t msg_len,
                    const uint8_t *context, size_t context_len);

#endif
