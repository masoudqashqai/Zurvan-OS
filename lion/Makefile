# Build zurvan-lion, the /data snapshot daemon.
#
# Same rules as the PID 1 and zurvan-svc: static (no dynamic loader in the
# image), small, warnings on. See zurvan-lion.c — it is meant to be read whole.

CC      ?= cc
CFLAGS  ?= -static -Os -Wall -Wextra -std=c11
TARGET  := zurvan-lion
SRC     := zurvan-lion.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)
	@echo ">> built $(TARGET)"
	@file $(TARGET) 2>/dev/null || true

clean:
	rm -f $(TARGET) *.o
