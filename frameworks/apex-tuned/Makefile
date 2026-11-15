CC ?= gcc
CFLAGS ?= -O3 -march=native -flto -Wall -Wextra -std=gnu2x -D_GNU_SOURCE
LDFLAGS ?= -flto
LIBS = -lssl -lcrypto -lbrotlienc -lbrotlicommon -lz -lcjson -lpthread -lnghttp2

SRCS = src/main.c src/http.c src/router.c src/dataset.c src/timer.c src/tls.c src/static_files.c src/h2.c
OBJS = $(SRCS:.c=.o)
TARGET = server

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
