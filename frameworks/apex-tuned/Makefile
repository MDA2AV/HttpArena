CC ?= gcc

# Base warning flags
WARN_FLAGS = -Wall -Wextra -Wshadow -Wpointer-arith -Wcast-qual \
             -Wstrict-prototypes -Wmissing-prototypes

# High-performance optimization flags
OPT_FLAGS = -O3 -march=native -mtune=native -flto=auto \
            -fno-semantic-interposition \
            -falign-functions=32 -falign-loops=32 -falign-jumps=32 -falign-labels=32 \
            -ffunction-sections -fdata-sections \
            -fomit-frame-pointer \
            -fno-math-errno -fno-trapping-math \
            -D_GNU_SOURCE -DNDEBUG

CFLAGS ?= $(OPT_FLAGS) $(WARN_FLAGS) -std=gnu2x -MMD -MP
LDFLAGS ?= -flto=auto -Wl,--gc-sections -Wl,-O3 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -s
LIBS = -lssl -lcrypto -lbrotlienc -lbrotlicommon -lisal -ldeflate -lz -lcjson -lpthread -lnghttp2

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
DEPS = $(SRCS:.c=.d)
TARGET = server

ifeq ($(V),1)
  Q :=
else
  Q := @
endif

all: $(TARGET)

$(TARGET): $(OBJS)
	@printf "  LINK    $@\n"
	$(Q)$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

%.o: %.c
	@printf "  CC      $<\n"
	$(Q)$(CC) $(CFLAGS) -c $< -o $@

-include $(DEPS)

debug: CFLAGS = -g3 -O0 -fsanitize=address,undefined $(WARN_FLAGS) -std=gnu2x -D_GNU_SOURCE -MMD -MP
debug: LDFLAGS = -fsanitize=address,undefined
debug: clean $(TARGET)

clean:
	@printf "  CLEAN\n"
	$(Q)rm -f $(OBJS) $(DEPS) $(TARGET)

.PHONY: all debug clean
