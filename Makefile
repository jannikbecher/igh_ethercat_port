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

# Real EtherCAT driver
ETHERCAT_CFLAGS := $(shell $(PKG_CONFIG) --cflags libethercat 2>/dev/null)
ETHERCAT_LIBS := $(shell $(PKG_CONFIG) --libs libethercat 2>/dev/null)

# Fake EtherCAT driver (for testing)
FAKEETHERCAT_CFLAGS := $(shell $(PKG_CONFIG) --cflags libfakeethercat 2>/dev/null)
FAKEETHERCAT_LIBS := $(shell $(PKG_CONFIG) --libs libfakeethercat 2>/dev/null)

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

all: real fake

real: $(REAL_TARGET)

fake: $(FAKE_TARGET)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(REAL_TARGET): $(SOURCES) $(HEADERS) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(ETHERCAT_CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) $(ETHERCAT_LIBS) -lpthread -lrt

$(FAKE_TARGET): $(SOURCES) $(HEADERS) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(FAKEETHERCAT_CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) $(FAKEETHERCAT_LIBS) -lpthread -lrt

clean:
	rm -f $(REAL_TARGET) $(FAKE_TARGET)
