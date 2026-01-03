# EtherCAT Link Recovery Troubleshooting Guide

## Symptoms: Frequent "Link state changed to DOWN" Errors

If you're experiencing frequent link disconnections with errors like:
```
[T1171400] EtherCAT 0: Link state of ecm0 changed to DOWN.
[T1171400] EtherCAT ERROR 0-0: Failed to receive SII read datagram: Datagram error.
```

## Root Cause: TX Queue Overflow

The most common cause is **network transmit queue overflow**, not actual physical link failure.

### Diagnosis

Check your network interface statistics:
```bash
ip -s link show <interface_name>
```

Look for **TX dropped packets**:
```
TX:  bytes packets errors dropped carrier collsns           
     419467853 6472681      0     963       0       0 
                                    ^^^
                                Non-zero = Problem!
```

If you see non-zero `dropped` count in TX line, you have queue overflow.

## Quick Fix

### 1. Increase TX Queue Length
```bash
# Increase transmit queue length (temporary - resets on reboot)
sudo ip link set <interface_name> txqueuelen 10000

# Monitor if drops continue
watch -n 1 'ip -s link show <interface_name> | grep -A 2 TX'
```

### 2. Verify Network Interface Settings
```bash
# Check current settings
ethtool <interface_name>

# Should show:
# - Speed: 100Mb/s or 1000Mb/s (Full Duplex)
# - Link detected: yes
# - No errors in statistics
```

## Permanent Solution

### Option A: Optimize Queue Discipline (qdisc)

The default `pfifo_fast` qdisc can drop packets under real-time load.

```bash
# Use minimal-latency queue (recommended for EtherCAT)
sudo tc qdisc replace dev <interface_name> root noqueue

# OR keep pfifo_fast but increase queue length permanently
# Add to /etc/network/interfaces or NetworkManager config:
# txqueuelen 10000
```

### Option B: Real-Time Kernel Tuning

For production EtherCAT systems:

```bash
# 1. Find NIC IRQ number
grep <interface_name> /proc/interrupts

# 2. Pin IRQ to dedicated CPU core (e.g., core 0)
echo 1 | sudo tee /proc/irq/<IRQ_NUMBER>/smp_affinity

# 3. Increase network buffers
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608
sudo sysctl -w net.core.rmem_default=262144
sudo sysctl -w net.core.wmem_default=262144

# Make permanent by adding to /etc/sysctl.conf:
# net.core.rmem_max = 8388608
# net.core.wmem_max = 8388608
# net.core.rmem_default = 262144
# net.core.wmem_default = 262144
```

### Option C: Verify EtherCAT Master Configuration

Check that IgH master is using native device mode:

```bash
# Show master configuration
ethercat config

# Show master state
ethercat master

# The master should have direct device access, not routing through network stack
```

## Physical Layer Issues

If TX drops are zero but link still goes down, check:

### Cable Quality
- Use **industrial-grade shielded Ethernet cables**
- Maximum segment length: 100m per segment
- Check for damaged connectors or cable crimping
- Reseat all cable connections

### EMI/Grounding
- Ensure proper grounding of all devices
- Separate EtherCAT cables from high-power cables
- Check for electromagnetic interference sources (motors, VFDs, etc.)

### Slave Devices
- Verify all slaves are powered correctly
- Check for overheating
- Update slave firmware if available
- Review slave watchdog timeout settings

## Recovery System

The Elixir EtherCAT Master includes automatic recovery with:

- **Link debouncing** (500ms wait after link-up before scanning)
- **Driver cleanup** (terminates old GenServers before restart)
- **Automatic re-activation** (brings slaves to OP state after recovery)
- **Recovery attempt limiting** (max 3 attempts before manual intervention required)
- **Safe deactivation** (proper cleanup on all error paths)

### Manual Recovery

If master exceeds recovery attempts:
```elixir
# In IEx console
EtherCAT.Master.reset()
```

### Configuration Options

Adjust recovery behavior in your application:
```elixir
# config/config.exs or in supervisor
{EtherCAT.Master, [
  cycle_time_us: 10_000,
  max_recovery_attempts: 3  # Adjust as needed
]}
```

## Diagnostic Commands

```bash
# Real-time network statistics
watch -n 1 'ip -s link show <interface_name>'

# Kernel messages (filter EtherCAT)
dmesg -w | grep -i ethercat

# Check for packet errors at PHY level
ethtool -S <interface_name>

# Network interface details
ethtool <interface_name>

# EtherCAT master state
ethercat master

# EtherCAT slave information
ethercat slaves
```

## Best Practices

1. **Always increase txqueuelen** for EtherCAT interfaces (10000 minimum)
2. **Use real-time kernel** (PREEMPT_RT) for production systems
3. **Isolate EtherCAT CPU core** using kernel boot parameters (`isolcpus`)
4. **Monitor TX dropped packets** regularly
5. **Use quality industrial cables** with proper shielding
6. **Document your hardware configuration** (slave positions, cable lengths)
7. **Test recovery** by intentionally disconnecting cables during development

## Summary

**90% of "link down" issues are TX queue overflow, not physical disconnection.**

**Immediate action**: `sudo ip link set <interface> txqueuelen 10000`

**Verify**: Monitor `ip -s link show` for dropped TX packets going to zero.
