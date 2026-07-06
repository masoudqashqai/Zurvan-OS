# Build zurvan-svc, the service supervisor.
#
# Same rules as the PID 1: static (no dynamic loader in the image), small,
# warnings on. See zurvan-svc.c for the design — it is meant to be read whole.

CC      ?= cc
CFLAGS  ?= -static -Os -Wall -Wextra -std=c11
TARGET  := zurvan-svc
SRC     := zurvan-svc.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)
	@echo ">> built $(TARGET)"
	@file $(TARGET) 2>/dev/null || true

clean:
	rm -f $(TARGET) *.o
