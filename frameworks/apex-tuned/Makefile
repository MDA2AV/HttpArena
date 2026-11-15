CC ?= gcc
CFLAGS ?= -O3 -march=native -flto -Wall -Wextra -std=gnu2x -D_GNU_SOURCE
LDFLAGS ?= -flto
LIBS = -lssl -lcrypto -lbrotlienc -lbrotlicommon -lz -lcjson -lpthread -lnghttp2

SRCS = src/main.c \
       src/buffer_pool.c \
       src/connection.c \
       src/dataset.c \
       src/h2.c \
       src/handlers.c \
       src/http.c \
       src/listener.c \
       src/response_builder.c \
       src/router.c \
       src/static_files.c \
       src/timer.c \
       src/tls.c \
       src/worker.c

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
