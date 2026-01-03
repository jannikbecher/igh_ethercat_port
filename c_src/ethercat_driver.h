/*
 * EtherCAT Port Driver for Erlang/Elixir
 *
 * Copyright 2024 Jannik Becher
 * Licensed under the Apache License, Version 2.0
 */

#ifndef ETHERCAT_DRIVER_H
#define ETHERCAT_DRIVER_H

#include <erl_driver.h>
#include <ecrt.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/timerfd.h>

/* Version */
#define DRIVER_VERSION_MAJOR 0
#define DRIVER_VERSION_MINOR 1
#define DRIVER_VERSION_PATCH 0

/* Limits */
#define MAX_SLAVES          64
#define MAX_PDO_ENTRIES     512
#define MAX_PENDING_WRITES  64
#define STATS_REPORT_CYCLES 1000

/* Commands - Synchronous (port_control) */
#define CMD_REQUEST_MASTER      1
#define CMD_RELEASE_MASTER      2
#define CMD_GET_LINK_STATE      3
#define CMD_SCAN_SLAVES         4
#define CMD_ACTIVATE            5
#define CMD_DEACTIVATE          6
#define CMD_START_CYCLIC        7
#define CMD_STOP_CYCLIC         8
#define CMD_SET_CYCLE_TIME      9
#define CMD_GET_MASTER_STATE    10
#define CMD_GET_SLAVE_INFO      11
#define CMD_REGISTER_PDO        12
#define CMD_ADD_SLAVE           13
#define CMD_CONFIGURE_DC        14

/* Commands - Asynchronous (port_command/output) */
#define OUT_SET_OUTPUT          4

/* Events to Erlang */
#define EVT_LINK_STATE          1
#define EVT_SLAVE_COUNT         2
#define EVT_MASTER_STATE        3
#define EVT_PDO_CHANGED         4
#define EVT_OUTPUT_CONFIRMED    5
#define EVT_CYCLE_STATS         6
#define EVT_ERROR               7
#define EVT_SLAVE_STATE         8

/* PDO Entry */
typedef struct {
    uint16_t slave_index;
    uint16_t index;
    uint8_t subindex;
    unsigned int byte_offset;
    unsigned int bit_offset;
    unsigned int bit_length;
    uint8_t is_output;
    uint64_t deadband;
    uint64_t min_interval_ns;
    uint64_t last_change_time;
    uint8_t shadow[8];
    uint8_t initialized;
} pdo_entry_t;

/* Pending Write */
typedef struct {
    uint32_t request_id;
    uint16_t pdo_index;
    uint8_t data[8];
    uint8_t bit_length;
    ErlDrvTermData caller;
    atomic_int state;
} pending_write_t;

/* Message Queue Entry Types */
#define MSG_TYPE_PDO_CHANGED    1
#define MSG_TYPE_LINK_STATE     2
#define MSG_TYPE_MASTER_STATE   3
#define MSG_TYPE_CYCLE_STATS    4
#define MSG_TYPE_OUTPUT_CONFIRMED 5

/* Message Queue Entry */
typedef struct {
    uint8_t type;
    union {
        struct {
            uint16_t slave_index;
            uint16_t entry_index;
            uint64_t value;
        } pdo_changed;
        struct {
            uint8_t link_up;
        } link_state;
        struct {
            uint8_t slaves_responding;
            uint8_t al_states;
            uint8_t link_up;
        } master_state;
        struct {
            uint64_t cycle_count;
            int64_t min_latency_ns;
            int64_t max_latency_ns;
            int64_t avg_latency_ns;
            uint64_t overrun_count;
        } cycle_stats;
        struct {
            uint32_t request_id;
        } output_confirmed;
    } data;
} message_queue_entry_t;

#define MESSAGE_QUEUE_SIZE 256

/* Slave Configuration */
typedef struct {
    uint16_t alias;
    uint16_t position;
    uint32_t vendor_id;
    uint32_t product_code;
    ec_slave_config_t *config;
    ec_slave_config_state_t last_state;
} slave_config_t;

/* Driver State */
typedef struct {
    ErlDrvPort port;
    ErlDrvTermData port_term;  // Thread-safe port identifier for messages
    
    /* Pipe for thread-safe signaling */
    int pipe_fd[2];  // [0] = read end, [1] = write end
    atomic_int pending_messages;  // Count of pending messages
    
    /* Message queue for thread-safe communication */
    message_queue_entry_t message_queue[MESSAGE_QUEUE_SIZE];
    atomic_uint msg_head;
    atomic_uint msg_tail;
    
    /* Pre-created atoms (driver_mk_atom is not thread-safe) */
    ErlDrvTermData atom_ecat_pdo;
    ErlDrvTermData atom_ecat_link;
    ErlDrvTermData atom_ecat_master_state;
    ErlDrvTermData atom_ecat_stats;
    ErlDrvTermData atom_up;
    ErlDrvTermData atom_down;
    ErlDrvTermData atom_true;
    ErlDrvTermData atom_false;

    /* EtherCAT Master */
    ec_master_t *master;
    ec_master_state_t master_state;
    ec_domain_t *domain;
    ec_domain_state_t domain_state;
    uint8_t *domain_pd;
    size_t domain_size;

    /* Slaves */
    slave_config_t slaves[MAX_SLAVES];
    int num_slaves;

    /* PDO Entries */
    pdo_entry_t pdo_entries[MAX_PDO_ENTRIES];
    int num_pdo_entries;

    /* Pending Writes */
    pending_write_t pending_writes[MAX_PENDING_WRITES];
    atomic_uint write_head;
    atomic_uint write_tail;
    uint32_t next_request_id;

    /* Cyclic Task */
    pthread_t cyclic_thread;
    atomic_int running;
    atomic_int activated;

    /* Configuration */
    uint64_t cycle_time_ns;
    int dc_enabled;

    /* Statistics */
    int64_t min_latency_ns;
    int64_t max_latency_ns;
    int64_t sum_latency_ns;
    uint64_t cycle_count;
    uint64_t overrun_count;

} driver_state_t;

/* Function Prototypes */
static uint64_t read_bits(const uint8_t *data, unsigned int byte_offset,
                   unsigned int bit_offset, unsigned int bit_length);

static void write_bits(uint8_t *data, unsigned int byte_offset,
                unsigned int bit_offset, unsigned int bit_length,
                uint64_t value);

#endif /* ETHERCAT_DRIVER_H */
