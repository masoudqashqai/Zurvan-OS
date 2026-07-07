# Build zurvan-snake, the disposable job runner.
#
# Same rules as the PID 1, zurvan-svc, and the lion: static (no dynamic
# loader in the image), small, warnings on. See zurvan-snake.c — read whole.

CC      ?= cc
CFLAGS  ?= -static -Os -Wall -Wextra -std=c11
TARGET  := zurvan-snake
SRC     := zurvan-snake.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)
	@echo ">> built $(TARGET)"
	@file $(TARGET) 2>/dev/null || true

clean:
	rm -f $(TARGET) *.o
