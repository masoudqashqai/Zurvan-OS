# Build zurvan-face (the web panel) and zurvan-certgen (its first-boot TLS
# identity). Both are static and link BearSSL's archive — no dynamic loader in
# the image. See zurvan-face.c and zurvan-certgen.c; each is meant to read whole.

CC      ?= cc
BEARSSL := ../userland/build
CFLAGS  ?= -static -Os -Wall -Wextra -std=c11 -I$(BEARSSL)/bearssl-inc
LIB     := $(BEARSSL)/libbearssl.a

.PHONY: all clean
all: zurvan-face zurvan-certgen

zurvan-face: zurvan-face.c $(LIB)
	$(CC) $(CFLAGS) -o $@ zurvan-face.c $(LIB)
	@echo ">> built zurvan-face"
	@file zurvan-face 2>/dev/null || true

zurvan-certgen: zurvan-certgen.c $(LIB)
	$(CC) $(CFLAGS) -o $@ zurvan-certgen.c $(LIB)
	@echo ">> built zurvan-certgen"

$(LIB):
	@echo "!! missing $(LIB) — run userland/build-bearssl.sh first" >&2
	@exit 1

clean:
	rm -f zurvan-face zurvan-certgen *.o
