defmodule FakeEtherCAT do
  @moduledoc """
  Helper for fakeethercat testing.

  This module provides utilities for testing EtherCAT applications without
  physical hardware using libfakeethercat.

  ## Key Features

  - **Environment setup**: Configures RtIPC bulletin board for process data sharing
  - **Config inversion**: Swaps sync manager directions (INPUT ↔ OUTPUT) to create
    matching slave emulators that can run back-to-back with your real application

  ## Fakeethercat Overview

  Libfakeethercat implements the complete EtherCAT master API but operates in
  userspace without requiring actual hardware. It uses RtIPC (shared memory) to
  exchange process data between applications.

  ## Testing Modes

  ### 1. Single Master (Simple)
  Just verify that configuration and writes don't crash. Fakeethercat accepts
  all operations and returns success without actual slaves.

  ```elixir
  setup do
    FakeEtherCAT.setup()
  end

  test "configure without hardware" do
    start_supervised(EtherCAT.Master)
    :ok = EtherCAT.Master.configure_hardware(my_config)
    :ok = EtherCAT.Master.start_cyclic()
    :ok = EtherCAT.Master.write_pdo({:my_slave, :channel_1, :output}, true)
  end
  ```

  ### 2. Dual Master (Advanced)
  Run two applications back-to-back: one with real config, one with inverted
  config. They share process data via RtIPC, creating a true loopback.

  ```elixir
  real_config = MyHardwareConfig.config()

  # Setup emulator master with inverted config on master_index 1
  {:ok, _inverted_config} = FakeEtherCAT.setup(real_config)

  # Start real master on default master_index 0
  start_supervised(EtherCAT.Master)
  :ok = EtherCAT.Master.configure_hardware(real_config)
  :ok = EtherCAT.Master.start_cyclic()

  # Write to master, data flows via RtIPC to emulator
  :ok = EtherCAT.Master.write_pdo({:my_slave, :channel_1, :output}, true)
  ```

  ## Environment Variables

  Fakeethercat uses these environment variables (all optional with defaults):
  - `FAKE_EC_HOMEDIR`: Directory for RtIPC bulletin board (default: system temp)
  - `FAKE_EC_NAME`: Name for RtIPC config (default: "FakeEtherCAT")
  - `FAKE_EC_PREFIX`: Prefix for RtIPC variables (default: none)

  The defaults work fine for testing, no configuration needed.
  """

  @doc """
  Sets up dual-master loopback for fakeethercat testing.

  Takes a hardware config, inverts it, and starts an emulator master with the
  inverted config. This creates a true loopback where:
  - Real master writes outputs → RtIPC → Emulator master reads as inputs
  - Emulator master writes outputs → RtIPC → Real master reads as inputs

  Returns `{:ok, emulator_master, emulator_slaves}` for use in tests.

  ## Example

      setup do
        config = SimpleHardwareConfig.hardware_config()
        {:ok, _inverted_config} = FakeEtherCAT.setup(config)

        # Now start real master
        start_supervised(EtherCAT.Master)
        :ok = EtherCAT.Master.configure_hardware(config)
        :ok = EtherCAT.Master.start_cyclic()

        :ok
      end

      test "write to real master, data flows to emulator via RtIPC" do
        # Write to real master's output
        :ok = EtherCAT.Master.write_pdo({:digital_outputs, :channel_1, :output}, true)

        # The emulator receives this via RtIPC shared memory
        # (verification would require reading from emulator master)
      end
  """
  def setup(hardware_config \\ nil)

  def setup(nil), do: :ok

  def setup(%EtherCAT.HardwareConfig{} = hardware_config) do
    inverted_config = invert_config(hardware_config)

    # Start emulator master with inverted config on master_index 1
    # Use ExUnit's start_supervised for proper cleanup
    {:ok, _pid} =
      ExUnit.Callbacks.start_supervised(
        {EtherCAT.Master, [master_index: 1]},
        id: :emulator_master
      )

    # Configure the emulator with inverted config
    :ok = EtherCAT.Master.configure_hardware(inverted_config)

    {:ok, inverted_config}
  end

  @doc """
  Inverts a hardware config for slave emulation.

  Swaps EC_DIR_INPUT ↔ EC_DIR_OUTPUT in sync manager configurations so the
  emulator writes where the master reads and vice versa. This allows running
  two applications back-to-back that exchange process data via RtIPC.

  ## How It Works

  For each slave's sync manager configuration:
  1. Extract sync manager configurations
  2. Swap `:input` ↔ `:output` for each sync manager's direction
  3. Return new config with inverted sync managers

  ## Example

      real_config = TestHardwareConfig.config()
      fake_config = FakeEtherCAT.invert_config(real_config)

      # Real config: EL2809 has outputs (master writes, slave reads)
      # Fake config: EL2809 with inverted SMs has inputs (slave writes, master reads)

      # Inverted config swaps sync manager directions for loopback testing
  """
  def invert_config(%EtherCAT.HardwareConfig{slaves: slaves} = hardware_config) do
    %{hardware_config | slaves: Enum.map(slaves, &invert_slave/1)}
  end

  defp invert_slave(%EtherCAT.HardwareConfig.SlaveConfig{} = slave) do
    # Invert sync managers in the config map
    inverted_config =
      case Map.get(slave.config, :sync_managers) do
        nil ->
          slave.config

        sync_managers ->
          Map.put(slave.config, :sync_managers, Enum.map(sync_managers, &invert_sync_manager/1))
      end

    # Invert registered_entries directions
    inverted_registered_entries =
      slave.registered_entries
      |> Enum.map(fn {domain_name, entries} ->
        inverted_entries =
          Enum.map(entries, fn {pdo_name, entry_name, deadband, interval_us} ->
            {pdo_name, entry_name, deadband, interval_us}
          end)

        {domain_name, inverted_entries}
      end)
      |> Map.new()

    %{slave | config: inverted_config, registered_entries: inverted_registered_entries}
  end

  defp invert_sync_manager(%EtherCAT.HardwareConfig.SyncManagerConfig{} = sync_manager) do
    inverted_pdos =
      sync_manager.pdos
      |> Enum.map(&invert_pdo/1)

    %{sync_manager | direction: invert_direction(sync_manager.direction), pdos: inverted_pdos}
  end

  defp invert_pdo(%EtherCAT.HardwareConfig.PdoConfig{} = pdo) do
    # PDO entries structure doesn't need direction inversion
    # The direction is at the sync manager level
    pdo
  end

  defp invert_direction(:input), do: :output
  defp invert_direction(:output), do: :input
end
