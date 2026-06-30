# Build the Zurvan PID 1.
#
# Static so the rootfs needs no dynamic loader (matches the static userland).
# -Os keeps it tiny; the warnings are on because a wrong init just panics with
# no message, so let the compiler catch what it can.

CC      ?= cc
CFLAGS  ?= -static -Os -Wall -Wextra -std=c11
TARGET  := init
SRC     := init.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)
	@echo ">> built $(TARGET)"
	@file $(TARGET) 2>/dev/null || true

clean:
	rm -f $(TARGET) *.o
