// ethercat_driver.c

#include "ethercat_driver.h"

// Forward declarations
static int handle_register_pdo(driver_state_t *state, char *buf, size_t len);
static int handle_add_slave(driver_state_t *state, char *buf, size_t len);
static int handle_configure_dc(driver_state_t *state, char *buf, size_t len);

// ============================================================================
// Bit-Precise Operations
// ============================================================================

static uint64_t read_bits(const uint8_t *data, unsigned int byte_offset,
                          unsigned int bit_offset, unsigned int bit_length) {
    if (bit_length == 0 || bit_length > 64) return 0;

    uint64_t result = 0;
    unsigned int bits_read = 0;
    unsigned int curr_byte = byte_offset;
    unsigned int curr_bit = bit_offset;

    while (bits_read < bit_length) {
        unsigned int bits_avail = 8 - curr_bit;
        unsigned int bits_needed = bit_length - bits_read;
        unsigned int bits_take = (bits_needed < bits_avail) ? bits_needed : bits_avail;

        uint8_t mask = ((1 << bits_take) - 1) << curr_bit;
        uint8_t val = (data[curr_byte] & mask) >> curr_bit;

        result |= ((uint64_t)val << bits_read);

        bits_read += bits_take;
        curr_byte++;
        curr_bit = 0;
    }

    return result;
}

static void write_bits(uint8_t *data, unsigned int byte_offset,
                       unsigned int bit_offset, unsigned int bit_length,
                       uint64_t value) {
    if (bit_length == 0 || bit_length > 64) return;

    unsigned int bits_written = 0;
    unsigned int curr_byte = byte_offset;
    unsigned int curr_bit = bit_offset;

    while (bits_written < bit_length) {
        unsigned int bits_avail = 8 - curr_bit;
        unsigned int bits_needed = bit_length - bits_written;
        unsigned int bits_take = (bits_needed < bits_avail) ? bits_needed : bits_avail;

        uint8_t mask = ((1 << bits_take) - 1) << curr_bit;
        uint8_t val = ((value >> bits_written) & ((1 << bits_take) - 1)) << curr_bit;

        data[curr_byte] = (data[curr_byte] & ~mask) | val;

        bits_written += bits_take;
        curr_byte++;
        curr_bit = 0;
    }
}

static int value_exceeds_deadband(uint64_t old_val, uint64_t new_val,
                                   uint64_t deadband, unsigned int bit_length) {
    if (deadband == 0) return old_val != new_val;

    int64_t diff;

    // Sign-extend for common sizes
    switch (bit_length) {
        case 8: {
            int8_t o = (int8_t)old_val, n = (int8_t)new_val;
            diff = (int64_t)n - (int64_t)o;
            break;
        }
        case 16: {
            int16_t o = (int16_t)old_val, n = (int16_t)new_val;
            diff = (int64_t)n - (int64_t)o;
            break;
        }
        case 32: {
            int32_t o = (int32_t)old_val, n = (int32_t)new_val;
            diff = (int64_t)n - (int64_t)o;
            break;
        }
        default: {
            // Unsigned comparison
            diff = (new_val > old_val) ?
                   (int64_t)(new_val - old_val) :
                   (int64_t)(old_val - new_val);
        }
    }

    if (diff < 0) diff = -diff;
    return (uint64_t)diff > deadband;
}

// ============================================================================
// Timing
// ============================================================================

static inline uint64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static inline uint64_t get_realtime_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ((uint64_t)ts.tv_sec - 946684800ULL) * 1000000000ULL + ts.tv_nsec;
}

// ============================================================================
// Thread-Safe Signaling
// ============================================================================

static int enqueue_message(driver_state_t *state, message_queue_entry_t *msg) {
    unsigned int head = atomic_load(&state->msg_head);
    unsigned int tail = atomic_load(&state->msg_tail);
    unsigned int next_head = (head + 1) % MESSAGE_QUEUE_SIZE;

    // Check if queue is full
    if (next_head == tail) {
        return -1;  // Queue full, drop message
    }

    // Copy message to queue
    memcpy(&state->message_queue[head], msg, sizeof(message_queue_entry_t));

    // Update head
    atomic_store(&state->msg_head, next_head);

    return 0;
}

static void signal_driver_thread(driver_state_t *state) {
    // Increment pending message counter
    atomic_fetch_add(&state->pending_messages, 1);

    // Write a byte to the pipe to wake up the driver thread
    char byte = 1;
    ssize_t written = write(state->pipe_fd[1], &byte, 1);
    (void)written;  // Ignore errors - if pipe is full, driver will still be notified
}

// ============================================================================
// Erlang Communication
// ============================================================================

static void send_link_state(driver_state_t *state, int link_up) {
    message_queue_entry_t msg = {
        .type = MSG_TYPE_LINK_STATE,
        .data.link_state.link_up = link_up
    };
    if (enqueue_message(state, &msg) == 0) {
        signal_driver_thread(state);
    }
}

static void send_slave_count(driver_state_t *state, unsigned int count) {
    (void)state;
    (void)count;
    // Not using message queue - could be added if needed
}

static void send_master_state(driver_state_t *state, ec_master_state_t *ms) {
    message_queue_entry_t msg = {
        .type = MSG_TYPE_MASTER_STATE,
        .data.master_state.slaves_responding = ms->slaves_responding,
        .data.master_state.al_states = ms->al_states,
        .data.master_state.link_up = ms->link_up
    };
    if (enqueue_message(state, &msg) == 0) {
        signal_driver_thread(state);
    }
}

static void send_pdo_changed(driver_state_t *state, pdo_entry_t *pdo,
                             int entry_index, uint64_t value) {
    message_queue_entry_t msg = {
        .type = MSG_TYPE_PDO_CHANGED,
        .data.pdo_changed.slave_index = pdo->slave_index,
        .data.pdo_changed.entry_index = entry_index,
        .data.pdo_changed.value = value
    };
    if (enqueue_message(state, &msg) == 0) {
        signal_driver_thread(state);
    }
}

static void send_output_confirmed(driver_state_t *state, pending_write_t *write) {
    message_queue_entry_t msg = {
        .type = MSG_TYPE_OUTPUT_CONFIRMED,
        .data.output_confirmed.request_id = write->request_id
    };
    if (enqueue_message(state, &msg) == 0) {
        signal_driver_thread(state);
    }
}

static void send_cycle_stats(driver_state_t *state) {
    int64_t avg = state->cycle_count > 0 ?
                  state->sum_latency_ns / (int64_t)state->cycle_count : 0;

    message_queue_entry_t msg = {
        .type = MSG_TYPE_CYCLE_STATS,
        .data.cycle_stats.cycle_count = state->cycle_count,
        .data.cycle_stats.min_latency_ns = state->min_latency_ns,
        .data.cycle_stats.max_latency_ns = state->max_latency_ns,
        .data.cycle_stats.avg_latency_ns = avg,
        .data.cycle_stats.overrun_count = state->overrun_count
    };
    if (enqueue_message(state, &msg) == 0) {
        signal_driver_thread(state);
    }
}

static void send_error(driver_state_t *state, const char *msg) {
    (void)state;
    (void)msg;
    // Not using message queue - could be added if needed
}

static void send_response(driver_state_t *state, ErlDrvTermData caller,
                          uint8_t cmd, int32_t result) {
    ErlDrvTermData spec[] = {
        ERL_DRV_ATOM, driver_mk_atom("ecat_response"),
        ERL_DRV_UINT, cmd,
        ERL_DRV_INT, result,
        ERL_DRV_TUPLE, 3
    };
    erl_drv_send_term(state->port_term, caller,
                      spec, sizeof(spec)/sizeof(spec[0]));
}

// ============================================================================
// Cyclic Task
// ============================================================================

static void check_pdo_changes(driver_state_t *state, uint64_t now) {
    // Safety check: domain_pd must be valid
    if (!state->domain_pd) return;

    for (int i = 0; i < state->num_pdo_entries; i++) {
        pdo_entry_t *pdo = &state->pdo_entries[i];

        // Only check inputs (data from slaves)
        if (pdo->is_output) continue;

        // Rate limit
        if (now - pdo->last_change_time < pdo->min_interval_ns) continue;

        uint64_t current = read_bits(state->domain_pd, pdo->byte_offset,
                                     pdo->bit_offset, pdo->bit_length);

        uint64_t shadow = 0;
        memcpy(&shadow, pdo->shadow, (pdo->bit_length + 7) / 8);

        // Initialize shadow on first read
        if (!pdo->initialized) {
            memcpy(pdo->shadow, &current, (pdo->bit_length + 7) / 8);
            pdo->initialized = 1;
            pdo->last_change_time = now;
            // Send initial value
            send_pdo_changed(state, pdo, i, current);
            continue;
        }

        if (value_exceeds_deadband(shadow, current, pdo->deadband, pdo->bit_length)) {
            memcpy(pdo->shadow, &current, (pdo->bit_length + 7) / 8);
            pdo->last_change_time = now;
            send_pdo_changed(state, pdo, i, current);
        }
    }
}

static void process_pending_writes(driver_state_t *state) {
    // Safety check: domain_pd must be valid
    if (!state->domain_pd) return;

    unsigned int tail = atomic_load(&state->write_tail);
    unsigned int head = atomic_load(&state->write_head);

    while (tail != head) {
        pending_write_t *write = &state->pending_writes[tail % MAX_PENDING_WRITES];

        if (atomic_load(&write->state) == 0) {
            pdo_entry_t *pdo = &state->pdo_entries[write->pdo_index];

            uint64_t value = 0;
            memcpy(&value, write->data, (write->bit_length + 7) / 8);
            write_bits(state->domain_pd, pdo->byte_offset, pdo->bit_offset,
                       write->bit_length, value);

            // Update shadow immediately for outputs
            memcpy(pdo->shadow, &value, (pdo->bit_length + 7) / 8);

            atomic_store(&write->state, 1);  // Applied
        }

        tail++;
    }

    atomic_store(&state->write_tail, tail);
}

static void confirm_writes(driver_state_t *state) {
    for (int i = 0; i < MAX_PENDING_WRITES; i++) {
        pending_write_t *write = &state->pending_writes[i];

        if (atomic_load(&write->state) == 1) {
            send_output_confirmed(state, write);
            atomic_store(&write->state, 2);
        }
    }
}

static void check_master_state(driver_state_t *state) {
    ec_master_state_t ms;
    ecrt_master_state(state->master, &ms);

    if (ms.slaves_responding != state->master_state.slaves_responding ||
        ms.al_states != state->master_state.al_states ||
        ms.link_up != state->master_state.link_up) {

        // Link state change
        if (ms.link_up != state->master_state.link_up) {
            send_link_state(state, ms.link_up);
        }

        // Slave count change
        if (ms.slaves_responding != state->master_state.slaves_responding) {
            send_slave_count(state, ms.slaves_responding);
        }

        send_master_state(state, &ms);
        state->master_state = ms;
    }
}

static void* cyclic_task(void *arg) {
    driver_state_t *state = (driver_state_t *)arg;

    // Real-time setup
    mlockall(MCL_CURRENT | MCL_FUTURE);

    struct sched_param param = { .sched_priority = 80 };
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(1, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    // Timer setup
    int tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    if (tfd < 0) {
        send_error(state, "timerfd_create failed");
        atomic_store(&state->running, 0);
        return NULL;
    }

    long nsec = state->cycle_time_ns % 1000000000;
    if (nsec == 0) nsec = 1;

    struct itimerspec its = {
        .it_interval = {
            .tv_sec = state->cycle_time_ns / 1000000000,
            .tv_nsec = state->cycle_time_ns % 1000000000
        },
        .it_value = {
            .tv_sec = 0,
            .tv_nsec = nsec
        }
    };
    timerfd_settime(tfd, 0, &its, NULL);

    // Reset stats
    state->min_latency_ns = INT64_MAX;
    state->max_latency_ns = 0;
    state->sum_latency_ns = 0;
    state->cycle_count = 0;
    state->overrun_count = 0;

    uint64_t expected_time = get_time_ns();

    while (atomic_load(&state->running)) {
        uint64_t expirations;
        ssize_t ret = read(tfd, &expirations, sizeof(expirations));

        if (ret != sizeof(expirations)) {
            if (errno == EINTR) continue;
            break;
        }

        uint64_t now = get_time_ns();
        expected_time += state->cycle_time_ns * expirations;

        if (expirations > 1) {
            state->overrun_count += (expirations - 1);
        }

        int64_t latency = (int64_t)(now - expected_time);
        if (latency < state->min_latency_ns) state->min_latency_ns = latency;
        if (latency > state->max_latency_ns) state->max_latency_ns = latency;
        state->sum_latency_ns += (latency > 0) ? latency : -latency;
        state->cycle_count++;

        // Safety check: ensure master, domain, and domain_pd are valid
        if (!state->master || !state->domain || !state->domain_pd) {
            send_error(state, "Cyclic task: invalid master/domain state");
            atomic_store(&state->running, 0);
            break;
        }

        // === EtherCAT Receive ===
        ecrt_master_receive(state->master);
        ecrt_domain_process(state->domain);

        // Confirm previous cycle's writes
        confirm_writes(state);

        // Check for PDO changes (inputs only)
        check_pdo_changes(state, now);

        // Check master/link state
        check_master_state(state);

        // Apply pending writes
        process_pending_writes(state);

        // Distributed clocks
        if (state->dc_enabled) {
            ecrt_master_application_time(state->master, get_realtime_ns());
            ecrt_master_sync_reference_clock(state->master);
            ecrt_master_sync_slave_clocks(state->master);
        }

        // === EtherCAT Send ===
        ecrt_domain_queue(state->domain);
        ecrt_master_send(state->master);

        // Periodic stats
        if (state->cycle_count % STATS_REPORT_CYCLES == 0) {
            send_cycle_stats(state);
            // Reset for next interval
            state->min_latency_ns = INT64_MAX;
            state->max_latency_ns = 0;
            state->sum_latency_ns = 0;
            state->cycle_count = 0;
        }
    }

    close(tfd);
    return NULL;
}

// ============================================================================
// Driver Callbacks - Start/Stop
// ============================================================================

static ErlDrvData start(ErlDrvPort port, char *command) {
    (void)command;
    driver_state_t *state = driver_alloc(sizeof(driver_state_t));
    memset(state, 0, sizeof(driver_state_t));

    state->port = port;
    state->port_term = driver_mk_port(port);  // Store for thread-safe messaging
    state->cycle_time_ns = 1000000;  // 1ms default
    state->next_request_id = 1;

    // Pre-create atoms (driver_mk_atom is not thread-safe, so do it here)
    state->atom_ecat_pdo = driver_mk_atom("ecat_pdo");
    state->atom_ecat_link = driver_mk_atom("ecat_link");
    state->atom_ecat_master_state = driver_mk_atom("ecat_master_state");
    state->atom_ecat_stats = driver_mk_atom("ecat_stats");
    state->atom_up = driver_mk_atom("up");
    state->atom_down = driver_mk_atom("down");
    state->atom_true = driver_mk_atom("true");
    state->atom_false = driver_mk_atom("false");

    atomic_store(&state->running, 0);
    atomic_store(&state->activated, 0);
    atomic_store(&state->write_head, 0);
    atomic_store(&state->write_tail, 0);
    atomic_store(&state->pending_messages, 0);
    atomic_store(&state->msg_head, 0);
    atomic_store(&state->msg_tail, 0);

    // Create pipe for thread-safe signaling
    if (pipe(state->pipe_fd) < 0) {
        driver_free(state);
        return ERL_DRV_ERROR_GENERAL;
    }

    // Set pipe to non-blocking mode
    int flags = fcntl(state->pipe_fd[0], F_GETFL, 0);
    fcntl(state->pipe_fd[0], F_SETFL, flags | O_NONBLOCK);

    // Register pipe read end with driver_select
    driver_select(port, (ErlDrvEvent)(long)state->pipe_fd[0], ERL_DRV_READ, 1);

    set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);

    return (ErlDrvData)state;
}

static void ready_input(ErlDrvData drv_data, ErlDrvEvent event) {
    driver_state_t *state = (driver_state_t *)drv_data;
    (void)event;

    // Drain the pipe
    char buf[64];
    while (read(state->pipe_fd[0], buf, sizeof(buf)) > 0);

    // Reset pending messages counter
    atomic_store(&state->pending_messages, 0);

    // Process all queued messages
    unsigned int tail = atomic_load(&state->msg_tail);
    unsigned int head = atomic_load(&state->msg_head);

    while (tail != head) {
        message_queue_entry_t *msg = &state->message_queue[tail];

        switch (msg->type) {
            case MSG_TYPE_PDO_CHANGED: {
                ErlDrvTermData spec[] = {
                    ERL_DRV_ATOM, state->atom_ecat_pdo,
                    ERL_DRV_UINT, msg->data.pdo_changed.slave_index,
                    ERL_DRV_UINT, msg->data.pdo_changed.entry_index,
                    ERL_DRV_UINT64, (ErlDrvTermData)&msg->data.pdo_changed.value,
                    ERL_DRV_TUPLE, 4
                };
                erl_drv_output_term(state->port_term, spec, sizeof(spec)/sizeof(spec[0]));
                break;
            }

            case MSG_TYPE_LINK_STATE: {
                ErlDrvTermData spec[] = {
                    ERL_DRV_ATOM, state->atom_ecat_link,
                    ERL_DRV_ATOM, msg->data.link_state.link_up ?
                                  state->atom_up : state->atom_down,
                    ERL_DRV_TUPLE, 2
                };
                erl_drv_output_term(state->port_term, spec, sizeof(spec)/sizeof(spec[0]));
                break;
            }

            case MSG_TYPE_MASTER_STATE: {
                ErlDrvTermData spec[] = {
                    ERL_DRV_ATOM, state->atom_ecat_master_state,
                    ERL_DRV_UINT, msg->data.master_state.slaves_responding,
                    ERL_DRV_UINT, msg->data.master_state.al_states,
                    ERL_DRV_ATOM, msg->data.master_state.link_up ?
                                  state->atom_true : state->atom_false,
                    ERL_DRV_TUPLE, 4
                };
                erl_drv_output_term(state->port_term, spec, sizeof(spec)/sizeof(spec[0]));
                break;
            }

            case MSG_TYPE_CYCLE_STATS: {
                ErlDrvTermData spec[] = {
                    ERL_DRV_ATOM, state->atom_ecat_stats,
                    ERL_DRV_UINT64, (ErlDrvTermData)&msg->data.cycle_stats.cycle_count,
                    ERL_DRV_INT64, (ErlDrvTermData)&msg->data.cycle_stats.min_latency_ns,
                    ERL_DRV_INT64, (ErlDrvTermData)&msg->data.cycle_stats.max_latency_ns,
                    ERL_DRV_INT64, (ErlDrvTermData)&msg->data.cycle_stats.avg_latency_ns,
                    ERL_DRV_UINT64, (ErlDrvTermData)&msg->data.cycle_stats.overrun_count,
                    ERL_DRV_TUPLE, 6
                };
                erl_drv_output_term(state->port_term, spec, sizeof(spec)/sizeof(spec[0]));
                break;
            }

            case MSG_TYPE_OUTPUT_CONFIRMED: {
                ErlDrvTermData spec[] = {
                    ERL_DRV_ATOM, driver_mk_atom("ecat_output_confirmed"),
                    ERL_DRV_UINT, msg->data.output_confirmed.request_id,
                    ERL_DRV_TUPLE, 2
                };
                erl_drv_output_term(state->port_term, spec, sizeof(spec)/sizeof(spec[0]));
                break;
            }
        }

        tail = (tail + 1) % MESSAGE_QUEUE_SIZE;
    }

    // Update tail
    atomic_store(&state->msg_tail, tail);
}

static void stop(ErlDrvData drv_data) {
    driver_state_t *state = (driver_state_t *)drv_data;

    // Stop cyclic task first
    if (atomic_load(&state->running)) {
        atomic_store(&state->running, 0);
        pthread_join(state->cyclic_thread, NULL);
    }

    // Deactivate master
    if (atomic_load(&state->activated) && state->master) {
        ecrt_master_deactivate(state->master);
        atomic_store(&state->activated, 0);
        state->domain_pd = NULL;
    }

    // Release master (this destroys the domain)
    if (state->master) {
        ecrt_release_master(state->master);
        state->master = NULL;
        state->domain = NULL;
    }

    // Close pipe
    if (state->pipe_fd[0] >= 0) {
        driver_select(state->port, (ErlDrvEvent)(long)state->pipe_fd[0], ERL_DRV_READ, 0);
        close(state->pipe_fd[0]);
        close(state->pipe_fd[1]);
    }

    driver_free(state);
}

// ============================================================================
// Control Commands (synchronous)
// ============================================================================

static ErlDrvSSizeT control(ErlDrvData drv_data, unsigned int command,
                            char *buf, ErlDrvSizeT len,
                            char **rbuf, ErlDrvSizeT rlen) {
    driver_state_t *state = (driver_state_t *)drv_data;
    int32_t result = 0;

    switch (command) {
        case CMD_REQUEST_MASTER: {
            if (state->master) {
                result = -1;  // Already requested
                break;
            }
            
            // Read master index from buffer (default to 0 if not provided)
            uint32_t master_index = 0;
            if (len >= sizeof(uint32_t)) {
                memcpy(&master_index, buf, sizeof(uint32_t));
            }
            
            state->master = ecrt_request_master(master_index);
            if (!state->master) {
                result = -2;
                break;
            }
            state->domain = ecrt_master_create_domain(state->master);
            if (!state->domain) {
                ecrt_release_master(state->master);
                state->master = NULL;
                result = -3;
            }
            break;
        }

        case CMD_RELEASE_MASTER: {
            if (atomic_load(&state->running)) {
                atomic_store(&state->running, 0);
                pthread_join(state->cyclic_thread, NULL);
            }
            if (atomic_load(&state->activated)) {
                ecrt_master_deactivate(state->master);
                atomic_store(&state->activated, 0);
            }
            if (state->master) {
                ecrt_release_master(state->master);
                state->master = NULL;
                state->domain = NULL;
                state->domain_pd = NULL;
            }
            // Reset configuration
            state->num_slaves = 0;
            state->num_pdo_entries = 0;
            break;
        }

        case CMD_GET_LINK_STATE: {
            if (!state->master) {
                result = -1;
                break;
            }
            ec_master_state_t ms;
            ecrt_master_state(state->master, &ms);
            result = ms.link_up ? 1 : 0;
            break;
        }

        case CMD_SCAN_SLAVES: {
            if (!state->master) {
                result = -1;
                break;
            }
            ec_master_state_t ms;
            ecrt_master_state(state->master, &ms);
            result = ms.slaves_responding;
            break;
        }

        case CMD_ACTIVATE: {
            if (!state->master || !state->domain || atomic_load(&state->activated)) {
                result = -1;
                break;
            }

            // Check that domain has at least some PDO entries registered
            if (state->num_pdo_entries == 0) {
                result = -4;  // No PDOs registered
                break;
            }

            int ret = ecrt_master_activate(state->master);
            if (ret < 0) {
                result = ret;
                break;
            }
            state->domain_pd = ecrt_domain_data(state->domain);
            state->domain_size = ecrt_domain_size(state->domain);
            if (!state->domain_pd) {
                // Domain data is NULL - deactivate and fail
                ecrt_master_deactivate(state->master);
                result = -2;
                break;
            }
            atomic_store(&state->activated, 1);
            break;
        }

        case CMD_DEACTIVATE: {
            if (atomic_load(&state->running)) {
                atomic_store(&state->running, 0);
                pthread_join(state->cyclic_thread, NULL);
            }
            if (atomic_load(&state->activated)) {
                ecrt_master_deactivate(state->master);
                atomic_store(&state->activated, 0);
                state->domain_pd = NULL;
                // Note: domain pointer remains valid, owned by master
                // It will be destroyed when master is released
            }
            break;
        }

        case CMD_START_CYCLIC: {
            if (!atomic_load(&state->activated)) {
                result = -1;
                break;
            }
            if (atomic_load(&state->running)) {
                result = -2;
                break;
            }
            // Extra safety: verify domain_pd is valid before starting cyclic task
            if (!state->domain_pd) {
                result = -4;
                break;
            }
            atomic_store(&state->running, 1);
            if (pthread_create(&state->cyclic_thread, NULL, cyclic_task, state) != 0) {
                atomic_store(&state->running, 0);
                result = -3;
            }
            break;
        }

        case CMD_STOP_CYCLIC: {
            if (atomic_load(&state->running)) {
                atomic_store(&state->running, 0);
                pthread_join(state->cyclic_thread, NULL);
            }
            break;
        }

        case CMD_SET_CYCLE_TIME: {
            if (len >= 8) {
                memcpy(&state->cycle_time_ns, buf, 8);
            } else {
                result = -1;
            }
            break;
        }

        case CMD_GET_MASTER_STATE: {
            if (!state->master) {
                result = -1;
                break;
            }
            ec_master_state_t ms;
            ecrt_master_state(state->master, &ms);

            // Return packed state: slaves(1), al_states(1), link(1), activated(1)
            if (rlen < 4) *rbuf = driver_alloc(4);
            (*rbuf)[0] = ms.slaves_responding;
            (*rbuf)[1] = ms.al_states;
            (*rbuf)[2] = ms.link_up;
            (*rbuf)[3] = atomic_load(&state->activated);
            return 4;
        }

        case CMD_GET_SLAVE_INFO: {
            if (!state->master || len < 2) {
                result = -1;
                break;
            }

            uint16_t slave_position;
            memcpy(&slave_position, buf, 2);

            ec_slave_info_t slave_info;
            if (ecrt_master_get_slave(state->master, slave_position, &slave_info) < 0) {
                result = -2;
                break;
            }

            // Return: vendor_id(4) + product_code(4) + revision_no(4) + serial_no(4) = 16 bytes
            if (rlen < 16) *rbuf = driver_alloc(16);
            memcpy(*rbuf, &slave_info.vendor_id, 4);
            memcpy(*rbuf + 4, &slave_info.product_code, 4);
            memcpy(*rbuf + 8, &slave_info.revision_number, 4);
            memcpy(*rbuf + 12, &slave_info.serial_number, 4);
            return 16;
        }

        case CMD_REGISTER_PDO: {
            result = handle_register_pdo(state, buf, len);
            break;
        }

        case CMD_ADD_SLAVE: {
            result = handle_add_slave(state, buf, len);
            break;
        }

        case CMD_CONFIGURE_DC: {
            result = handle_configure_dc(state, buf, len);
            break;
        }

        default:
            result = -100;
    }

    if (rlen < 4) *rbuf = driver_alloc(4);
    memcpy(*rbuf, &result, 4);
    return 4;
}

// ============================================================================
// Output Commands (asynchronous)
// ============================================================================

static int handle_add_slave(driver_state_t *state, char *buf, size_t len) {
    if (len < 12 || state->num_slaves >= MAX_SLAVES) return -1;
    if (!state->master || atomic_load(&state->activated)) return -2;

    uint16_t alias, position;
    uint32_t vendor_id, product_code;

    memcpy(&alias, buf, 2);
    memcpy(&position, buf + 2, 2);
    memcpy(&vendor_id, buf + 4, 4);
    memcpy(&product_code, buf + 8, 4);

    ec_slave_config_t *sc = ecrt_master_slave_config(
        state->master, alias, position, vendor_id, product_code);

    if (!sc) return -3;

    slave_config_t *slave = &state->slaves[state->num_slaves];
    slave->alias = alias;
    slave->position = position;
    slave->vendor_id = vendor_id;
    slave->product_code = product_code;
    slave->config = sc;
    memset(&slave->last_state, 0, sizeof(slave->last_state));

    return state->num_slaves++;
}

static int handle_register_pdo(driver_state_t *state, char *buf, size_t len) {
    if (len < 24 || state->num_pdo_entries >= MAX_PDO_ENTRIES) return -1;
    if (!state->master || atomic_load(&state->activated)) return -2;

    // Format: slave_idx(2), pdo_index(2), subindex(1), bit_length(1),
    //         is_output(1), padding(1), deadband(8), min_interval_us(8)
    uint16_t slave_idx, pdo_index;
    uint8_t subindex, bit_length, is_output;
    uint64_t deadband, min_interval_us;

    memcpy(&slave_idx, buf, 2);
    memcpy(&pdo_index, buf + 2, 2);
    subindex = buf[4];
    bit_length = buf[5];
    is_output = buf[6];
    memcpy(&deadband, buf + 8, 8);
    memcpy(&min_interval_us, buf + 16, 8);

    if (slave_idx >= state->num_slaves) return -3;

    slave_config_t *slave = &state->slaves[slave_idx];
    unsigned int bit_position;

    int offset = ecrt_slave_config_reg_pdo_entry(
        slave->config, pdo_index, subindex, state->domain, &bit_position);

    if (offset < 0) return offset;

    pdo_entry_t *pdo = &state->pdo_entries[state->num_pdo_entries];
    pdo->slave_index = slave_idx;
    pdo->index = pdo_index;
    pdo->subindex = subindex;
    pdo->byte_offset = offset;
    pdo->bit_offset = bit_position;
    pdo->bit_length = bit_length;
    pdo->is_output = is_output;
    pdo->deadband = deadband;
    pdo->min_interval_ns = min_interval_us * 1000;
    pdo->last_change_time = 0;
    pdo->initialized = 0;
    memset(pdo->shadow, 0, sizeof(pdo->shadow));

    return state->num_pdo_entries++;
}

static int handle_configure_dc(driver_state_t *state, char *buf, size_t len) {
    if (len < 20) return -1;
    if (!state->master || atomic_load(&state->activated)) return -2;

    uint16_t slave_idx, assign_activate;
    uint32_t sync0_cycle, sync1_cycle;
    int32_t sync0_shift, sync1_shift;

    memcpy(&slave_idx, buf, 2);
    memcpy(&assign_activate, buf + 2, 2);
    memcpy(&sync0_cycle, buf + 4, 4);
    memcpy(&sync0_shift, buf + 8, 4);
    memcpy(&sync1_cycle, buf + 12, 4);
    memcpy(&sync1_shift, buf + 16, 4);

    if (slave_idx >= state->num_slaves) return -3;

    ecrt_slave_config_dc(state->slaves[slave_idx].config,
                         assign_activate, sync0_cycle, sync0_shift,
                         sync1_cycle, sync1_shift);

    state->dc_enabled = 1;
    return 0;
}

static int handle_set_output(driver_state_t *state, char *buf, size_t len,
                             ErlDrvTermData caller) {
    if (len < 4) return -1;
    if (!atomic_load(&state->running)) return -2;

    uint16_t pdo_index;
    uint8_t bit_length;

    memcpy(&pdo_index, buf, 2);
    bit_length = buf[2];

    if (pdo_index >= state->num_pdo_entries) return -3;
    if (!state->pdo_entries[pdo_index].is_output) return -4;

    unsigned int head = atomic_load(&state->write_head);
    unsigned int tail = atomic_load(&state->write_tail);

    if ((head - tail) >= MAX_PENDING_WRITES) return -5;

    pending_write_t *write = &state->pending_writes[head % MAX_PENDING_WRITES];

    // Ring buffer logic guarantees this slot is free - no spinlock needed
    write->request_id = state->next_request_id++;
    write->pdo_index = pdo_index;
    write->bit_length = bit_length;
    memcpy(write->data, buf + 3, (bit_length + 7) / 8);
    write->caller = caller;
    atomic_store(&write->state, 0);

    atomic_store(&state->write_head, head + 1);

    return (int)write->request_id;
}

static void output(ErlDrvData drv_data, char *buf, ErlDrvSizeT len) {
    driver_state_t *state = (driver_state_t *)drv_data;

    if (len < 1) return;

    uint8_t cmd = buf[0];
    char *data = buf + 1;
    size_t data_len = len - 1;

    ErlDrvTermData caller = driver_caller(state->port);
    int result;

    switch (cmd) {
        case OUT_SET_OUTPUT:
            result = handle_set_output(state, data, data_len, caller);
            // Send response immediately (error code or request_id)
            send_response(state, caller, cmd, result);
            // If successful, confirmation will come from cyclic task
            break;

        default:
            send_response(state, caller, cmd, -100);
    }
}

// ============================================================================
// Driver Entry
// ============================================================================

#ifndef DRIVER_NAME
#define DRIVER_NAME "ethercat_driver"
#endif

static ErlDrvEntry ethercat_driver_entry = {
    .init = NULL,
    .start = start,
    .stop = stop,
    .output = output,
    .ready_input = ready_input,
    .ready_output = NULL,
    .driver_name = DRIVER_NAME,
    .finish = NULL,
    .control = control,
    .timeout = NULL,
    .outputv = NULL,
    .ready_async = NULL,
    .flush = NULL,
    .call = NULL,
    .extended_marker = ERL_DRV_EXTENDED_MARKER,
    .major_version = ERL_DRV_EXTENDED_MAJOR_VERSION,
    .minor_version = ERL_DRV_EXTENDED_MINOR_VERSION,
    .driver_flags = ERL_DRV_FLAG_USE_PORT_LOCKING,
};

DRIVER_INIT(ethercat_driver) {
    return &ethercat_driver_entry;
}
