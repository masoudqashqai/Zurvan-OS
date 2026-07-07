/*
 * zurvan-certgen — generate the panel's per-box TLS identity (v2 M6).
 *
 * A self-signed P-256 certificate and its key, made ON THE BOX at first boot
 * so no two Zurvan installs share a private key (the same reasoning that put
 * the SSH host keys on /data). The panel is HTTPS-only; the cert is
 * self-signed on purpose — there is no CA to trust on a headless box, so the
 * admin accepts it once, exactly like an SSH host-key fingerprint.
 *
 * It writes two DER files that zurvan-face loads at startup:
 *   <dir>/key.der    the EC private key (SEC1 ECPrivateKey)
 *   <dir>/cert.der   the self-signed certificate
 *
 * Everything is built from BearSSL primitives — EC keygen, SHA-256, ECDSA —
 * plus a few hundred bytes of hand-written DER. No OpenSSL in the image.
 * Idempotent-ish: run it only when the files are missing (rc.init does that).
 *
 * Usage: zurvan-certgen <dir>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/random.h>
#include "bearssl.h"

/* --- a tiny DER writer: append primitives, wrap with tag+length ------------- */

struct buf { unsigned char *p; size_t n, cap; };

static void put(struct buf *b, const void *data, size_t len)
{
	if (b->n + len > b->cap) {
		b->cap = (b->n + len) * 2 + 64;
		b->p = realloc(b->p, b->cap);
	}
	memcpy(b->p + b->n, data, len);
	b->n += len;
}
static void put1(struct buf *b, unsigned char c) { put(b, &c, 1); }

/* Emit a DER length. Short form < 128, else long form. */
static void put_len(struct buf *b, size_t len)
{
	if (len < 0x80) {
		put1(b, (unsigned char)len);
	} else if (len < 0x100) {
		put1(b, 0x81); put1(b, (unsigned char)len);
	} else {
		put1(b, 0x82);
		put1(b, (unsigned char)(len >> 8));
		put1(b, (unsigned char)(len & 0xff));
	}
}
/* Emit a full TLV: tag, length, content. */
static void tlv(struct buf *b, unsigned char tag, const void *v, size_t len)
{
	put1(b, tag);
	put_len(b, len);
	put(b, v, len);
}

/* --- fixed DER blobs -------------------------------------------------------- */

/* AlgorithmIdentifier: ecdsa-with-SHA256 (1.2.840.10045.4.3.2) */
static const unsigned char ALG_ECDSA_SHA256[] = {
	0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02
};
/* SPKI AlgorithmIdentifier: id-ecPublicKey + prime256v1 */
static const unsigned char ALG_EC_P256[] = {
	0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
	0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
};
/* OID prime256v1 (for the SEC1 key's [0] parameters) */
static const unsigned char OID_P256[] = {
	0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
};

/* Name = SEQ { SET { SEQ { OID commonName, PrintableString "zurvan" } } } */
static void name_zurvan(struct buf *out)
{
	struct buf atv = {0}, rdn = {0}, name = {0};
	static const unsigned char OID_CN[] = { 0x06, 0x03, 0x55, 0x04, 0x03 };
	put(&atv, OID_CN, sizeof OID_CN);
	tlv(&atv, 0x13, "zurvan", 6);              /* PrintableString */
	tlv(&rdn, 0x30, atv.p, atv.n);             /* AttributeTypeAndValue SEQ */
	tlv(&name, 0x31, rdn.p, rdn.n);            /* RDN SET */
	tlv(out, 0x30, name.p, name.n);            /* RDNSequence SEQ */
	free(atv.p); free(rdn.p); free(name.p);
}

/* UTCTime "YYMMDDHHMMSSZ" from a struct tm */
static void utctime(struct buf *out, const struct tm *t)
{
	char s[24];
	snprintf(s, sizeof s, "%02d%02d%02d%02d%02d%02dZ",
	         (t->tm_year + 1900) % 100, t->tm_mon + 1, t->tm_mday,
	         t->tm_hour, t->tm_min, t->tm_sec);
	tlv(out, 0x17, s, 13);
}

static int write_file(const char *path, const void *data, size_t len)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return -1;
	int ok = write(fd, data, len) == (ssize_t)len;
	fsync(fd);
	close(fd);
	return ok ? 0 : -1;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: zurvan-certgen <dir>\n"); return 2; }
	const char *dir = argv[1];

	/* seed a DRBG from the kernel RNG */
	unsigned char seed[32];
	if (getrandom(seed, sizeof seed, 0) != (ssize_t)sizeof seed) {
		fprintf(stderr, "certgen: getrandom failed\n"); return 1;
	}
	br_hmac_drbg_context rng;
	br_hmac_drbg_init(&rng, &br_sha256_vtable, seed, sizeof seed);

	/* EC P-256 keypair */
	br_ec_private_key sk;
	unsigned char kbuf[BR_EC_KBUF_PRIV_MAX_SIZE];
	if (br_ec_keygen(&rng.vtable, &br_ec_prime_i31, &sk, kbuf,
	                 BR_EC_secp256r1) == 0) {
		fprintf(stderr, "certgen: keygen failed\n"); return 1;
	}
	br_ec_public_key pk;
	unsigned char pkbuf[BR_EC_KBUF_PUB_MAX_SIZE];
	br_ec_compute_pub(&br_ec_prime_i31, &pk, pkbuf, &sk);

	/* pad the private scalar to 32 bytes for the SEC1 OCTET STRING */
	unsigned char priv32[32] = {0};
	memcpy(priv32 + (32 - sk.xlen), sk.x, sk.xlen);

	/* --- SubjectPublicKeyInfo --- */
	struct buf spki = {0}, spk_bits = {0};
	put1(&spk_bits, 0x00);                        /* BIT STRING unused-bits */
	put(&spk_bits, pk.q, pk.qlen);                /* 04 || X || Y */
	{
		struct buf tmp = {0};
		put(&tmp, ALG_EC_P256, sizeof ALG_EC_P256);
		tlv(&tmp, 0x03, spk_bits.p, spk_bits.n);  /* subjectPublicKey */
		tlv(&spki, 0x30, tmp.p, tmp.n);
		free(tmp.p);
	}
	free(spk_bits.p);

	/* --- TBSCertificate --- */
	time_t now = time(NULL);
	struct tm nb, na;
	gmtime_r(&now, &nb);
	time_t later = now + (time_t)10 * 365 * 24 * 3600;   /* ~10 years */
	gmtime_r(&later, &na);

	struct buf tbs = {0};
	{
		struct buf body = {0}, validity = {0}, serial = {0};
		/* version [0] EXPLICIT INTEGER 2 (v3) */
		static const unsigned char VER[] = { 0xA0, 0x03, 0x02, 0x01, 0x02 };
		put(&body, VER, sizeof VER);
		/* serialNumber: 8 random bytes, high bit cleared -> positive */
		unsigned char sn[8];
		br_hmac_drbg_generate(&rng, sn, sizeof sn);
		sn[0] &= 0x7F; if (sn[0] == 0) sn[0] = 1;
		tlv(&serial, 0x02, sn, sizeof sn);
		put(&body, serial.p, serial.n);
		/* signature alg */
		put(&body, ALG_ECDSA_SHA256, sizeof ALG_ECDSA_SHA256);
		/* issuer == subject (self-signed) */
		name_zurvan(&body);
		/* validity */
		utctime(&validity, &nb);
		utctime(&validity, &na);
		tlv(&body, 0x30, validity.p, validity.n);
		/* subject */
		name_zurvan(&body);
		/* SPKI */
		put(&body, spki.p, spki.n);

		tlv(&tbs, 0x30, body.p, body.n);
		free(body.p); free(validity.p); free(serial.p);
	}

	/* --- sign the TBS --- */
	unsigned char hash[32];
	br_sha256_context sh;
	br_sha256_init(&sh);
	br_sha256_update(&sh, tbs.p, tbs.n);
	br_sha256_out(&sh, hash);

	unsigned char sig[80];
	size_t siglen = br_ecdsa_i31_sign_asn1(&br_ec_prime_i31, &br_sha256_vtable,
	                                       hash, &sk, sig);
	if (siglen == 0) { fprintf(stderr, "certgen: sign failed\n"); return 1; }

	/* --- Certificate = SEQ { tbs, sigAlg, BIT STRING sig } --- */
	struct buf cert = {0};
	{
		struct buf body = {0}, sigbits = {0};
		put(&body, tbs.p, tbs.n);
		put(&body, ALG_ECDSA_SHA256, sizeof ALG_ECDSA_SHA256);
		put1(&sigbits, 0x00);
		put(&sigbits, sig, siglen);
		tlv(&body, 0x03, sigbits.p, sigbits.n);
		tlv(&cert, 0x30, body.p, body.n);
		free(body.p); free(sigbits.p);
	}

	/* --- SEC1 ECPrivateKey = SEQ { INTEGER 1, OCTET priv, [0] params } --- */
	struct buf key = {0};
	{
		struct buf body = {0}, params = {0};
		static const unsigned char V1[] = { 0x02, 0x01, 0x01 };
		put(&body, V1, sizeof V1);
		tlv(&body, 0x04, priv32, sizeof priv32);
		put(&params, OID_P256, sizeof OID_P256);
		tlv(&body, 0xA0, params.p, params.n);     /* [0] parameters */
		tlv(&key, 0x30, body.p, body.n);
		free(body.p); free(params.p);
	}

	char path[512];
	snprintf(path, sizeof path, "%s/key.der", dir);
	if (write_file(path, key.p, key.n) != 0) {
		fprintf(stderr, "certgen: cannot write %s\n", path); return 1;
	}
	snprintf(path, sizeof path, "%s/cert.der", dir);
	if (write_file(path, cert.p, cert.n) != 0) {
		fprintf(stderr, "certgen: cannot write %s\n", path); return 1;
	}

	fprintf(stderr, "certgen: wrote %s/{key,cert}.der (%zu-byte cert)\n",
	        dir, cert.n);
	free(spki.p); free(tbs.p); free(cert.p); free(key.p);
	return 0;
}
