# Makefile for EtherCAT port driver
#
# Prerequisites:
#   - Erlang/OTP installed
#   - IgH EtherCAT Master installed (typically in /opt/etherlab)
#   - gcc
#
# Environment variables (optional):
#   ETHERCAT_LIB_PATH - Path to EtherCAT master installation (default: /opt/etherlab)
#   ETHERCAT_INCLUDE_PATH - Path to EtherCAT master installation (default: /opt/etherlab)
#   ERL_INCLUDE   - Path to Erlang include files (auto-detected)

# Project configuration
DRIVER_NAME = ethercat_driver
PRIV_DIR = priv
C_SRC_DIR = c_src

# Detect OS
UNAME_S := $(shell uname -s)

# EtherCAT master path
ETHERCAT_LIB_PATH ?= /usr/local/lib64
ETHERCAT_INCLUDE_PATH ?= /usr/local/include

# Auto-detect Erlang paths
ERL_INCLUDE ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)
EI_INCLUDE ?= $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erl_interface, include)])' -s init stop)

# Compiler settings
CC = gcc
CFLAGS = -O2 -Wall -Wextra -Werror -fPIC -pedantic -std=c11
CFLAGS += -D_GNU_SOURCE
CFLAGS += -I$(ERL_INCLUDE)
CFLAGS += -I$(ETHERCAT_INCLUDE_PATH)

# Debug build (make DEBUG=1)
ifdef DEBUG
	CFLAGS += -g -DDEBUG -O0
endif

# Linker settings
LDFLAGS = -shared
LDFLAGS += -L$(ETHERCAT_LIB_PATH)
LDLIBS = -lethercat -lpthread -lrt

# Platform-specific settings
ifeq ($(UNAME_S),Linux)
	SO_EXT = so
	LDFLAGS += -Wl,-rpath,$(ETHERCAT_LIB_PATH)
endif

ifeq ($(UNAME_S),Darwin)
	$(error macOS is not supported - EtherCAT requires Linux)
endif

# Source files
SOURCES = $(wildcard $(C_SRC_DIR)/*.c)
HEADERS = $(wildcard $(C_SRC_DIR)/*.h)
TARGET = $(PRIV_DIR)/$(DRIVER_NAME).$(SO_EXT)

# Default target
.PHONY: all
all: $(TARGET)

# Create priv directory
$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Build the shared library
$(TARGET): $(SOURCES) $(HEADERS) | $(PRIV_DIR)
	@echo "Building $(DRIVER_NAME)..."
	@echo "  ERL_INCLUDE: $(ERL_INCLUDE)"
	@echo "  ETHERCAT_LIB_PATH: $(ETHERCAT_LIB_PATH)"
	@echo "  ETHERCAT_INCLUDE_PATH: $(ETHERCAT_INCLUDE_PATH)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) $(LDLIBS)
	@echo "Built $@"

# Clean build artifacts
.PHONY: clean
clean:
	rm -rf $(PRIV_DIR)/$(DRIVER_NAME).$(SO_EXT)
	rm -rf _build
	rm -rf deps

# Deep clean including dependencies
.PHONY: distclean
distclean: clean
	rm -rf $(PRIV_DIR)
	rm -rf doc

# Check prerequisites
.PHONY: check
check:
	@echo "Checking prerequisites..."
	@which erl > /dev/null || (echo "ERROR: Erlang not found" && exit 1)
	@echo "  Erlang: OK ($(shell erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)])' -s init stop))"
	@test -d "$(ERL_INCLUDE)" || (echo "ERROR: Erlang include dir not found: $(ERL_INCLUDE)" && exit 1)
	@echo "  Erlang includes: OK"
	@test -f "$(ETHERCAT_INCLUDE_PATH)/ecrt.h" || (echo "ERROR: ecrt.h not found" && exit 1)
	@echo "  EtherCAT headers: OK"
	@test -f "$(ETHERCAT_LIB_PATH)/libethercat.so" || (echo "ERROR: libethercat.so not found" && exit 1)
	@echo "  EtherCAT library: OK"
	@echo "All prerequisites OK!"

# Install EtherCAT kernel module (requires root)
.PHONY: load-module
load-module:
	@echo "Loading EtherCAT kernel module..."
	sudo modprobe ec_master main_devices=eth0
	@echo "Done. Check 'dmesg | tail' for status."

# Unload EtherCAT kernel module (requires root)
.PHONY: unload-module
unload-module:
	@echo "Unloading EtherCAT kernel module..."
	sudo rmmod ec_master || true
	@echo "Done."

# Show EtherCAT status
.PHONY: status
status:
	@echo "=== EtherCAT Master Status ==="
	@cat /sys/module/ec_master/parameters/main_devices 2>/dev/null || echo "Module not loaded"
	@echo ""
	@ls -la /dev/EtherCAT* 2>/dev/null || echo "No EtherCAT devices"
	@echo ""
	@ethercat master 2>/dev/null || echo "ethercat tool not available or master not running"

# Run tests
.PHONY: test
test: all
	mix test

# Generate documentation
.PHONY: docs
docs:
	mix docs

# Format code
.PHONY: format
format:
	mix format
	find $(C_SRC_DIR) -name '*.c' -o -name '*.h' | xargs clang-format -i 2>/dev/null || true

# Static analysis
.PHONY: analyze
analyze:
	mix dialyzer
	cppcheck --enable=all --suppress=missingIncludeSystem $(C_SRC_DIR) 2>/dev/null || true

# Help
.PHONY: help
help:
	@echo "EtherCAT Driver Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all          - Build the driver (default)"
	@echo "  clean        - Remove build artifacts"
	@echo "  distclean    - Remove all generated files"
	@echo "  check        - Check build prerequisites"
	@echo "  test         - Run tests"
	@echo "  docs         - Generate documentation"
	@echo "  format       - Format source code"
	@echo "  analyze      - Run static analysis"
	@echo "  load-module  - Load EtherCAT kernel module (requires root)"
	@echo "  unload-module- Unload EtherCAT kernel module (requires root)"
	@echo "  status       - Show EtherCAT status"
	@echo ""
	@echo "Variables:"
	@echo "  ETHERCAT_PATH - EtherCAT master installation path (default: /opt/etherlab)"
	@echo "  DEBUG=1       - Enable debug build"
	@echo ""
	@echo "Example:"
	@echo "  make check"
	@echo "  make"
	@echo "  make test"
