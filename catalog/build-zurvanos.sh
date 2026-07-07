#!/bin/sh
# catalog/build-zurvanos.sh — a tiny, cheerful demo package.
#
# `zurvanos` prints an animated block-letter ZURVAN-OS banner with a moving
# rainbow, then exits. It carries no service and no state — just a static
# binary and a manifest that links it into /usr/bin. Perfect for exercising
# the web panel's upload + install flow (Packages page).
#
# Output: build/catalog/zurvanos-1.0.tar.gz
set -eu

VERSION=1.0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/build/catalog}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR" "$STAGE/bin"

# --- the program ---------------------------------------------------------------
cat > "$STAGE/zurvanos.c" <<'EOF'
/* zurvanos — an animated ZURVAN-OS banner. A finite ~3s rainbow sweep over
 * a 5-row block font, then a tagline. Pure ANSI; runs over SSH or console. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <time.h>

/* 5x5 block glyphs: '#' = filled cell, ' ' = empty. */
static const char *glyph(char c, int row)
{
    static const char *Z[5]  = {"#####","   # ","  #  "," #   ","#####"};
    static const char *U[5]  = {"#   #","#   #","#   #","#   #","#####"};
    static const char *R[5]  = {"#### ","#   #","#### ","#  # ","#   #"};
    static const char *V[5]  = {"#   #","#   #","#   #"," # # ","  #  "};
    static const char *A[5]  = {" ### ","#   #","#####","#   #","#   #"};
    static const char *N[5]  = {"#   #","##  #","# # #","#  ##","#   #"};
    static const char *D[5]  = {"     ","     "," ### ","     ","     "};
    static const char *O[5]  = {" ### ","#   #","#   #","#   #"," ### "};
    static const char *S[5]  = {" ####","#    "," ### ","    #","#### "};
    switch (c) {
        case 'Z': return Z[row]; case 'U': return U[row];
        case 'R': return R[row]; case 'V': return V[row];
        case 'A': return A[row]; case 'N': return N[row];
        case '-': return D[row]; case 'O': return O[row];
        case 'S': return S[row]; default:  return "     ";
    }
}

/* HSV(h,1,1) -> RGB, for the moving rainbow. */
static void hue_rgb(int h, int *r, int *g, int *b)
{
    h %= 360; if (h < 0) h += 360;
    int seg = h / 60, f = h % 60, q = 255 - 255 * f / 60, t = 255 * f / 60;
    switch (seg) {
        case 0: *r=255; *g=t;   *b=0;   break;
        case 1: *r=q;   *g=255; *b=0;   break;
        case 2: *r=0;   *g=255; *b=t;   break;
        case 3: *r=0;   *g=q;   *b=255; break;
        case 4: *r=t;   *g=0;   *b=255; break;
        default:*r=255; *g=0;   *b=q;   break;
    }
}

int main(void)
{
    const char *word = "ZURVAN-OS";
    int wlen = (int)strlen(word);

    printf("\033[2J\033[H\033[?25l");            /* clear, home, hide cursor */
    for (int fr = 0; fr < 50; fr++) {
        printf("\033[H\n");
        for (int row = 0; row < 5; row++) {
            printf("   ");
            int gcol = 0;
            for (int i = 0; i < wlen; i++) {
                const char *g = glyph(word[i], row);
                for (int k = 0; g[k]; k++, gcol++) {
                    if (g[k] == '#') {
                        int r, gg, b;
                        hue_rgb(gcol * 7 + fr * 9, &r, &gg, &b);
                        printf("\033[38;2;%d;%d;%dm\xE2\x96\x88", r, gg, b);
                    } else {
                        printf(" ");
                    }
                }
                printf("\033[0m ");
            }
            printf("\033[0m\n");
        }
        fflush(stdout);
        nanosleep(&(struct timespec){0, 55L * 1000000L}, 0);
    }
    printf("\033[0m\n     \033[1;36mthe snake sheds  \xC2\xB7  the lion remembers\033[0m\n\n");
    printf("\033[?25h");                          /* show cursor */
    fflush(stdout);
    return 0;
}
EOF
cc -static -O2 -o "$STAGE/bin/zurvanos" "$STAGE/zurvanos.c"
rm "$STAGE/zurvanos.c"

# --- the manifest ----------------------------------------------------------------
cat > "$STAGE/manifest.yaml" <<EOF
name: zurvanos
version: "$VERSION"
links:
  - /usr/bin/zurvanos -> bin/zurvanos
EOF

# --- pack --------------------------------------------------------------------------
TARBALL="$OUT_DIR/zurvanos-$VERSION.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" manifest.yaml bin
echo ">> done: $TARBALL"
tar -tzf "$TARBALL"
