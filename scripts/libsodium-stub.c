// Stub libsodium for the Mac Catalyst slice of vim.framework.
//
// The arm64 Mac Catalyst slice of upstream vim-rootshell v0.1.0 was built on a
// Mac that had Homebrew's libsodium installed, so Vim's configure auto-enabled
// the xchacha20 crypt method and the binary hard-links
// /opt/homebrew/opt/libsodium/lib/libsodium.26.dylib. That path exists on no
// user's Mac, and dyld refuses to launch the app without it. No other slice or
// command framework has this problem.
//
// scripts/patch-vim-framework.sh compiles this file into a libsodium.26.dylib
// that ships in Shell.app/Contents/Frameworks and repoints vim's load command
// at it. Every entry point Vim imports is defined here. sodium_init() reports
// failure, so Vim takes the same fallbacks it uses when built without libsodium:
// SHA-256 seeding, plain memset for key wiping, and an error instead of the
// xchacha20 crypt method. The randombytes functions delegate to arc4random so
// the few unguarded callers (swap-file seed, rand()) still get real entropy.
//
// Nothing here implements cryptography; the crypto_* functions only fail.

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define SODIUM_EXPORT __attribute__((visibility("default")))

SODIUM_EXPORT int sodium_init(void) {
    return -1;
}

SODIUM_EXPORT void *sodium_malloc(size_t size) {
    (void)size;
    return NULL;
}

SODIUM_EXPORT void sodium_free(void *ptr) {
    (void)ptr;
}

SODIUM_EXPORT void sodium_memzero(void *const pnt, const size_t len) {
    if (pnt != NULL && len > 0) {
        memset_s(pnt, len, 0, len);
    }
}

SODIUM_EXPORT int sodium_mlock(void *const addr, const size_t len) {
    (void)addr;
    (void)len;
    return -1;
}

SODIUM_EXPORT int sodium_munlock(void *const addr, const size_t len) {
    (void)addr;
    (void)len;
    return 0;
}

SODIUM_EXPORT void randombytes_buf(void *const buf, const size_t size) {
    if (buf != NULL && size > 0) {
        arc4random_buf(buf, size);
    }
}

SODIUM_EXPORT uint32_t randombytes_random(void) {
    return arc4random();
}

SODIUM_EXPORT int crypto_pwhash(unsigned char *const out, unsigned long long outlen,
                                const char *const passwd, unsigned long long passwdlen,
                                const unsigned char *const salt,
                                unsigned long long opslimit, size_t memlimit, int alg) {
    (void)out; (void)outlen; (void)passwd; (void)passwdlen;
    (void)salt; (void)opslimit; (void)memlimit; (void)alg;
    return -1;
}

SODIUM_EXPORT int crypto_secretstream_xchacha20poly1305_init_push(
    void *state, unsigned char *header, const unsigned char *k) {
    (void)state; (void)header; (void)k;
    return -1;
}

SODIUM_EXPORT int crypto_secretstream_xchacha20poly1305_init_pull(
    void *state, const unsigned char *header, const unsigned char *k) {
    (void)state; (void)header; (void)k;
    return -1;
}

SODIUM_EXPORT int crypto_secretstream_xchacha20poly1305_push(
    void *state, unsigned char *c, unsigned long long *clen_p,
    const unsigned char *m, unsigned long long mlen,
    const unsigned char *ad, unsigned long long adlen, unsigned char tag) {
    (void)state; (void)c; (void)clen_p; (void)m; (void)mlen;
    (void)ad; (void)adlen; (void)tag;
    return -1;
}

SODIUM_EXPORT int crypto_secretstream_xchacha20poly1305_pull(
    void *state, unsigned char *m, unsigned long long *mlen_p, unsigned char *tag_p,
    const unsigned char *c, unsigned long long clen,
    const unsigned char *ad, unsigned long long adlen) {
    (void)state; (void)m; (void)mlen_p; (void)tag_p; (void)c; (void)clen;
    (void)ad; (void)adlen;
    return -1;
}
