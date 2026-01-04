# Makefile for EtherCAT port driver
# Called by elixir_make from mix.exs

PRIV_DIR = priv
C_SRC_DIR = c_src

# Detect OS
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	$(error macOS is not supported - EtherCAT requires Linux)
endif

# Compiler (auto-detect cross-compiler for Nerves)
ifdef CROSSCOMPILE
	CC = $(CROSSCOMPILE)gcc
else
	CC ?= gcc
endif

# Auto-detect Erlang paths
ERL_INCLUDE ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)

# Use pkg-config for EtherCAT libraries
PKG_CONFIG ?= pkg-config
ETHERCAT_CFLAGS := $(shell $(PKG_CONFIG) --cflags libethercat 2>/dev/null)
ETHERCAT_LIBS := $(shell $(PKG_CONFIG) --libs libethercat 2>/dev/null)

# Check if libfakeethercat is available (direct lib check, not pkg-config)
FAKE_LIB_PATH ?= /usr/local/lib64
HAS_FAKE := $(shell test -f $(FAKE_LIB_PATH)/libfakeethercat.so && echo yes)
ifeq ($(HAS_FAKE),yes)
	FAKEETHERCAT_CFLAGS := -I/usr/local/include
	FAKEETHERCAT_LIBS := -L$(FAKE_LIB_PATH) -lfakeethercat
endif

# Compiler flags
CFLAGS = -O2 -Wall -Wextra -Werror -fPIC -std=c11
CFLAGS += -D_GNU_SOURCE
CFLAGS += -I$(ERL_INCLUDE)

ifdef DEBUG
	CFLAGS += -g -DDEBUG -O0
endif

# Linker flags
LDFLAGS = -shared

# Source files
SOURCES = $(wildcard $(C_SRC_DIR)/*.c)
HEADERS = $(wildcard $(C_SRC_DIR)/*.h)

# Targets
REAL_TARGET = $(PRIV_DIR)/ethercat_driver.so
FAKE_TARGET = $(PRIV_DIR)/fakeethercat_driver.so

.PHONY: all clean real fake

ifeq ($(HAS_FAKE),yes)
all: real fake
else
all: real
	@echo "Note: libfakeethercat not found, skipping fake driver build"
endif

real: $(REAL_TARGET)

ifeq ($(HAS_FAKE),yes)
fake: $(FAKE_TARGET)
else
fake:
	@echo "libfakeethercat not available - install with: ./configure --enable-fakeuserlib"
	@exit 1
endif

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(REAL_TARGET): $(SOURCES) $(HEADERS) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(ETHERCAT_CFLAGS) -DDRIVER_NAME='"ethercat_driver"' $(LDFLAGS) -o $@ $(SOURCES) $(ETHERCAT_LIBS) -lpthread -lrt

$(FAKE_TARGET): $(SOURCES) $(HEADERS) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(FAKEETHERCAT_CFLAGS) -DDRIVER_NAME='"fakeethercat_driver"' $(LDFLAGS) -o $@ $(SOURCES) $(FAKEETHERCAT_LIBS) -lpthread -lrt

clean:
	rm -f $(REAL_TARGET) $(FAKE_TARGET)
