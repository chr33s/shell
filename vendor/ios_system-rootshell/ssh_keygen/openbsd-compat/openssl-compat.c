/*
 * Copyright (c) 2005 Darren Tucker <dtucker@zip.com.au>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#define SSH_DONT_OVERLOAD_OPENSSL_FUNCS
#include "includes.h"

#ifdef WITH_OPENSSL

#include <stdarg.h>
#include <string.h>
#include <TargetConditionals.h>

#ifdef USE_OPENSSL_ENGINE
# include <openssl/engine.h>
# include <openssl/conf.h>
#endif

#include "log.h"

#include "openssl-compat.h"

/*
 * OpenSSL version numbers: MNNFFPPS: major minor fix patch status
 * We match major, minor, fix and status (not patch) for <1.0.0.
 * After that, we acceptable compatible fix versions (so we
 * allow 1.0.1 to work with 1.0.0). Going backwards is only allowed
 * within a patch series.
 */

int
ssh_compatible_openssl(long headerver, long libver)
{
	long mask, hfix, lfix;

	/* exact match is always OK */
	if (headerver == libver)
		return 1;

	/* for versions < 1.0.0, major,minor,fix,status must match */
	if (headerver < 0x1000000f) {
		mask = 0xfffff00fL; /* major,minor,fix,status */
		return (headerver & mask) == (libver & mask);
	}

	/*
	 * For versions >= 1.0.0, major,minor,status must match and library
	 * fix version must be equal to or newer than the header.
	 */
	mask = 0xfff0000fL; /* major,minor,status */
	hfix = (headerver & 0x000ff000) >> 12;
	lfix = (libver & 0x000ff000) >> 12;
	if ( (headerver & mask) == (libver & mask) && lfix >= hfix)
		return 1;
	return 0;
}

void
ssh_libcrypto_init(void)
{
#if defined(HAVE_OPENSSL_INIT_CRYPTO) && \
      defined(OPENSSL_INIT_ADD_ALL_CIPHERS) && \
      defined(OPENSSL_INIT_ADD_ALL_DIGESTS)
	OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS |
	    OPENSSL_INIT_ADD_ALL_DIGESTS, NULL);
#elif defined(HAVE_OPENSSL_ADD_ALL_ALGORITHMS)
	OpenSSL_add_all_algorithms();
#endif

#ifdef	USE_OPENSSL_ENGINE
	/* Enable use of crypto hardware */
	ENGINE_load_builtin_engines();
	ENGINE_register_all_complete();

	/* Load the libcrypto config file to pick up engines defined there */
# if defined(HAVE_OPENSSL_INIT_CRYPTO) && defined(OPENSSL_INIT_LOAD_CONFIG)
	OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS |
	    OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CONFIG, NULL);
# else
	OPENSSL_config(NULL);
# endif
#endif /* USE_OPENSSL_ENGINE */
}

/* OpenSSL 3.x compatibility wrappers for deprecated low-level APIs */
#if OPENSSL_VERSION_NUMBER >= 0x30000000L

/* RSA functions: only compile when deprecated API is NOT available in OpenSSL.
 * If OPENSSL_NO_DEPRECATED_3_0 is defined, the deprecated low-level APIs
 * (RSA_sign, RSA_verify, RSA_size, BN_is_prime_ex) are removed from libcrypto
 * and we need to provide our own implementations.
 * If deprecated API IS available, these symbols exist in libcrypto and we
 * should not redefine them to avoid duplicate symbol errors. */
#ifdef OPENSSL_NO_DEPRECATED_3_0

#ifndef HAVE_RSA_SIZE
#include <openssl/evp.h>
#include <openssl/rsa.h>

int
RSA_size(const RSA *rsa)
{
	EVP_PKEY *pkey = NULL;
	int ret = 0;

	if (rsa == NULL)
		return 0;

	/* Create an EVP_PKEY from the RSA key */
	pkey = EVP_PKEY_new();
	if (pkey == NULL)
		return 0;

	/* This increases the reference count, so we need to free both */
	if (EVP_PKEY_set1_RSA(pkey, (RSA *)rsa) != 1) {
		EVP_PKEY_free(pkey);
		return 0;
	}

	ret = EVP_PKEY_size(pkey);
	EVP_PKEY_free(pkey);
	return ret;
}
#endif /* HAVE_RSA_SIZE */

#ifndef HAVE_RSA_SIGN
int
RSA_sign(int type, const unsigned char *m, unsigned int m_len,
    unsigned char *sigret, unsigned int *siglen, RSA *rsa)
{
	EVP_PKEY *pkey = NULL;
	EVP_MD_CTX *ctx = NULL;
	const EVP_MD *md = NULL;
	size_t sltmp;
	int ret = 0;

	if (rsa == NULL || m == NULL || sigret == NULL || siglen == NULL)
		return 0;

	/* Get the digest type */
	md = EVP_get_digestbynid(type);
	if (md == NULL)
		return 0;

	/* Create EVP_PKEY from RSA */
	pkey = EVP_PKEY_new();
	if (pkey == NULL)
		return 0;

	if (EVP_PKEY_set1_RSA(pkey, rsa) != 1)
		goto cleanup;

	/* Create signing context */
	ctx = EVP_MD_CTX_new();
	if (ctx == NULL)
		goto cleanup;

	/* Perform the signature */
	if (EVP_DigestSignInit(ctx, NULL, md, NULL, pkey) != 1)
		goto cleanup;

	if (EVP_DigestSign(ctx, sigret, &sltmp, m, m_len) != 1)
		goto cleanup;

	*siglen = (unsigned int)sltmp;
	ret = 1;

cleanup:
	EVP_MD_CTX_free(ctx);
	EVP_PKEY_free(pkey);
	return ret;
}
#endif /* HAVE_RSA_SIGN */

#ifndef HAVE_RSA_VERIFY
int
RSA_verify(int type, const unsigned char *m, unsigned int m_len,
    const unsigned char *sigbuf, unsigned int siglen, RSA *rsa)
{
	EVP_PKEY *pkey = NULL;
	EVP_MD_CTX *ctx = NULL;
	const EVP_MD *md = NULL;
	int ret = 0;

	if (rsa == NULL || m == NULL || sigbuf == NULL)
		return 0;

	/* Get the digest type */
	md = EVP_get_digestbynid(type);
	if (md == NULL)
		return 0;

	/* Create EVP_PKEY from RSA */
	pkey = EVP_PKEY_new();
	if (pkey == NULL)
		return 0;

	if (EVP_PKEY_set1_RSA(pkey, rsa) != 1)
		goto cleanup;

	/* Create verification context */
	ctx = EVP_MD_CTX_new();
	if (ctx == NULL)
		goto cleanup;

	/* Perform the verification */
	if (EVP_DigestVerifyInit(ctx, NULL, md, NULL, pkey) != 1)
		goto cleanup;

	if (EVP_DigestVerify(ctx, sigbuf, siglen, m, m_len) == 1)
		ret = 1;

cleanup:
	EVP_MD_CTX_free(ctx);
	EVP_PKEY_free(pkey);
	return ret;
}
#endif /* HAVE_RSA_VERIFY */

/* BN_is_prime_ex was removed in OpenSSL 3.0 - only needed when deprecated API unavailable */
#include <openssl/bn.h>

int
BN_is_prime_ex(const BIGNUM *p, int nchecks, BN_CTX *ctx, BN_GENCB *cb)
{
	int ret;

	/* BN_check_prime replaces BN_is_prime_ex in OpenSSL 3.x */
	ret = BN_check_prime(p, ctx, cb);

	/* BN_check_prime returns 1 for prime, 0 for composite, -1 for error */
	/* BN_is_prime_ex returned 1 for prime, 0 for composite or error */
	/* So we need to convert -1 to 0 for compatibility */
	return (ret == 1) ? 1 : 0;
}

#endif /* OPENSSL_NO_DEPRECATED_3_0 */

#endif /* OPENSSL_VERSION_NUMBER >= 0x30000000L */

#endif /* WITH_OPENSSL */
