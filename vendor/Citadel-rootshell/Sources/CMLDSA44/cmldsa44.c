// Bridge to the ML-DSA-44 implementation compiled inside swift-crypto's
// vendored BoringSSL (CCryptoBoringSSL). Prototypes below mirror the
// swift-crypto 3.15.1 vendored mldsa.h/bytestring.h with the symbol prefix
// applied. The key/CBB structs are treated as opaque: storage is allocated
// here with generous headroom over the actual sizes (12,416 / 4,192 / ~64
// bytes in 3.15.1) so a moderate upstream size change cannot overflow.

#include "include/cmldsa44.h"

#include <string.h>

struct MLDSA44_private_key;
struct MLDSA44_public_key;

typedef struct cbs_st {
  const uint8_t *data;
  size_t len;
} CBS;

// CBB is only ever passed by pointer and initialised via CBB_init_fixed, so
// opaque over-allocated storage stands in for the real struct.
typedef struct cmldsa44_opaque_cbb {
  uint8_t opaque[512] __attribute__((aligned(16)));
} OPAQUE_CBB;

#define CMLDSA44_PRIVATE_KEY_STORAGE 16384
#define CMLDSA44_PUBLIC_KEY_STORAGE 8192

extern int CCryptoBoringSSL_MLDSA44_generate_key(
    uint8_t out_encoded_public_key[CMLDSA44_PUBLIC_KEY_BYTES],
    uint8_t out_seed[CMLDSA44_SEED_BYTES],
    struct MLDSA44_private_key *out_private_key);
extern int CCryptoBoringSSL_MLDSA44_private_key_from_seed(
    struct MLDSA44_private_key *out_private_key, const uint8_t *seed,
    size_t seed_len);
extern int CCryptoBoringSSL_MLDSA44_public_from_private(
    struct MLDSA44_public_key *out_public_key,
    const struct MLDSA44_private_key *private_key);
extern int CCryptoBoringSSL_MLDSA44_sign(
    uint8_t out_encoded_signature[CMLDSA44_SIGNATURE_BYTES],
    const struct MLDSA44_private_key *private_key, const uint8_t *msg,
    size_t msg_len, const uint8_t *context, size_t context_len);
extern int CCryptoBoringSSL_MLDSA44_verify(
    const struct MLDSA44_public_key *public_key, const uint8_t *signature,
    size_t signature_len, const uint8_t *msg, size_t msg_len,
    const uint8_t *context, size_t context_len);
extern int CCryptoBoringSSL_MLDSA44_marshal_public_key(
    void *out_cbb, const struct MLDSA44_public_key *public_key);
extern int CCryptoBoringSSL_MLDSA44_parse_public_key(
    struct MLDSA44_public_key *out_public_key, CBS *in);
extern int CCryptoBoringSSL_CBB_init_fixed(void *cbb, uint8_t *buf, size_t len);
extern size_t CCryptoBoringSSL_CBB_len(const void *cbb);
extern void CCryptoBoringSSL_OPENSSL_cleanse(void *ptr, size_t len);

int cmldsa44_generate_key(uint8_t out_public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                          uint8_t out_seed[CMLDSA44_SEED_BYTES]) {
  uint8_t priv_storage[CMLDSA44_PRIVATE_KEY_STORAGE]
      __attribute__((aligned(16)));
  struct MLDSA44_private_key *priv =
      (struct MLDSA44_private_key *)priv_storage;

  int ok = CCryptoBoringSSL_MLDSA44_generate_key(out_public_key, out_seed, priv);
  CCryptoBoringSSL_OPENSSL_cleanse(priv_storage, sizeof(priv_storage));
  return ok;
}

int cmldsa44_public_from_seed(uint8_t out_public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                              const uint8_t seed[CMLDSA44_SEED_BYTES]) {
  uint8_t priv_storage[CMLDSA44_PRIVATE_KEY_STORAGE]
      __attribute__((aligned(16)));
  uint8_t pub_storage[CMLDSA44_PUBLIC_KEY_STORAGE] __attribute__((aligned(16)));
  struct MLDSA44_private_key *priv =
      (struct MLDSA44_private_key *)priv_storage;
  struct MLDSA44_public_key *pub = (struct MLDSA44_public_key *)pub_storage;
  OPAQUE_CBB cbb;
  int ok = 0;

  if (!CCryptoBoringSSL_MLDSA44_private_key_from_seed(priv, seed,
                                                      CMLDSA44_SEED_BYTES)) {
    goto out;
  }
  if (!CCryptoBoringSSL_MLDSA44_public_from_private(pub, priv)) {
    goto out;
  }
  if (!CCryptoBoringSSL_CBB_init_fixed(&cbb, out_public_key,
                                       CMLDSA44_PUBLIC_KEY_BYTES)) {
    goto out;
  }
  if (!CCryptoBoringSSL_MLDSA44_marshal_public_key(&cbb, pub) ||
      CCryptoBoringSSL_CBB_len(&cbb) != CMLDSA44_PUBLIC_KEY_BYTES) {
    goto out;
  }
  ok = 1;

out:
  CCryptoBoringSSL_OPENSSL_cleanse(priv_storage, sizeof(priv_storage));
  return ok;
}

int cmldsa44_sign(uint8_t out_signature[CMLDSA44_SIGNATURE_BYTES],
                  const uint8_t seed[CMLDSA44_SEED_BYTES],
                  const uint8_t *msg, size_t msg_len,
                  const uint8_t *context, size_t context_len) {
  uint8_t priv_storage[CMLDSA44_PRIVATE_KEY_STORAGE]
      __attribute__((aligned(16)));
  struct MLDSA44_private_key *priv =
      (struct MLDSA44_private_key *)priv_storage;
  int ok = 0;

  if (!CCryptoBoringSSL_MLDSA44_private_key_from_seed(priv, seed,
                                                      CMLDSA44_SEED_BYTES)) {
    goto out;
  }
  ok = CCryptoBoringSSL_MLDSA44_sign(out_signature, priv, msg, msg_len,
                                     context, context_len);

out:
  CCryptoBoringSSL_OPENSSL_cleanse(priv_storage, sizeof(priv_storage));
  return ok;
}

int cmldsa44_verify(const uint8_t public_key[CMLDSA44_PUBLIC_KEY_BYTES],
                    const uint8_t *signature, size_t signature_len,
                    const uint8_t *msg, size_t msg_len,
                    const uint8_t *context, size_t context_len) {
  uint8_t pub_storage[CMLDSA44_PUBLIC_KEY_STORAGE] __attribute__((aligned(16)));
  struct MLDSA44_public_key *pub = (struct MLDSA44_public_key *)pub_storage;
  CBS cbs = {public_key, CMLDSA44_PUBLIC_KEY_BYTES};

  if (!CCryptoBoringSSL_MLDSA44_parse_public_key(pub, &cbs)) {
    return 0;
  }
  return CCryptoBoringSSL_MLDSA44_verify(pub, signature, signature_len, msg,
                                         msg_len, context, context_len);
}
