/*
 * sntrup761.h - Streamlined NTRU Prime 761 KEM
 *
 * Public domain. Based on the reference implementation by
 * Daniel J. Bernstein, Chitchanok Chuengsatiansup,
 * Tanja Lange, and Christine van Vredendaal.
 */

#ifndef SNTRUP761_H
#define SNTRUP761_H

#define SNTRUP761_PUBLICKEYBYTES  1158
#define SNTRUP761_SECRETKEYBYTES  1763
#define SNTRUP761_CIPHERTEXTBYTES 1039
#define SNTRUP761_BYTES           32

/*
 * Generate a sntrup761 key pair.
 * pk: output public key (SNTRUP761_PUBLICKEYBYTES bytes)
 * sk: output secret key (SNTRUP761_SECRETKEYBYTES bytes)
 * Returns 0 on success.
 */
int sntrup761_keypair(unsigned char *pk, unsigned char *sk);

/*
 * Encapsulate: generate ciphertext and shared secret from public key.
 * ct: output ciphertext (SNTRUP761_CIPHERTEXTBYTES bytes)
 * ss: output shared secret (SNTRUP761_BYTES bytes)
 * pk: input public key (SNTRUP761_PUBLICKEYBYTES bytes)
 * Returns 0 on success.
 */
int sntrup761_enc(unsigned char *ct, unsigned char *ss, const unsigned char *pk);

/*
 * Decapsulate: recover shared secret from ciphertext and secret key.
 * ss: output shared secret (SNTRUP761_BYTES bytes)
 * ct: input ciphertext (SNTRUP761_CIPHERTEXTBYTES bytes)
 * sk: input secret key (SNTRUP761_SECRETKEYBYTES bytes)
 * Returns 0 on success.
 */
int sntrup761_dec(unsigned char *ss, const unsigned char *ct, const unsigned char *sk);

#endif /* SNTRUP761_H */
