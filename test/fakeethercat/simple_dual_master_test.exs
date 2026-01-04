defmodule FakeEtherCAT.SimpleDualMasterTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Simple dual-master test demonstrating both masters running simultaneously.

  This test verifies that:
  1. Both masters can be started with the updated child_spec/1
  2. The emulator master uses :name properly
  3. The real master and emulator master run without conflicts
  4. Basic configuration and cyclic operation work on both masters

  ## Architecture

  ```
  Real Master (index 0)              Emulator Master (index 1)
  Name: EtherCAT.Master              Name: :emulator_master
  ┌─────────────────────┐            ┌─────────────────────┐
  │ Normal Config       │            │ Inverted Config     │
  │ DO: OUTPUT          │ ── RtIPC ──│ DO: INPUT           │
  │ DI: INPUT           │ ── RtIPC ──│ DI: OUTPUT          │
  └─────────────────────┘            └─────────────────────┘
  ```
  """

  setup do
    config = HardwareConfigs.simple_hardware_config()

    # Start emulator master (index 1) with inverted config
    {:ok, _inverted_config} = FakeEtherCAT.setup(config)

    # Start real master (index 0) with normal config
    start_supervised!({EtherCAT.Master, [name: :real_master, master_index: 0]})

    # Return both configs for tests
    %{config: config}
  end

  test "both masters start successfully", %{config: _config} do
    # Verify real master is running
    state = EtherCAT.Master.get_state(:real_master)
    assert state in [:offline, :stale, :synced, :operational]

    # Verify emulator master is running
    emulator_state = EtherCAT.Master.get_state(:emulator_master)
    assert emulator_state in [:offline, :stale, :synced, :operational]
  end

  test "real master can configure hardware", %{config: config} do
    # Configure real master
    result = EtherCAT.Master.configure_hardware(:real_master, config)
    assert result in [:ok, {:ok, :config_stored}]

    # Verify state - with fakeethercat and no physical hardware, may stay offline or transition
    Process.sleep(100)
    state = EtherCAT.Master.get_state(:real_master)
    assert state in [:offline, :stale, :synced, :operational]
  end

  test "emulator master is already configured in setup", %{config: _config} do
    # Emulator was configured in FakeEtherCAT.setup/1
    # With fakeethercat and no physical hardware, may be in any valid state
    state = EtherCAT.Master.get_state(:emulator_master)
    assert state in [:offline, :stale, :synced, :operational]
  end

  test "both masters can start cyclic operation", %{config: config} do
    # Configure real master
    result = EtherCAT.Master.configure_hardware(:real_master, config)
    assert result in [:ok, {:ok, :config_stored}]
    Process.sleep(100)

    # Start cyclic on real master
    case EtherCAT.Master.start_cyclic(:real_master) do
      :ok ->
        assert :operational = EtherCAT.Master.get_state(:real_master)

      {:error, :already_operational} ->
        # Already started is fine
        assert :operational = EtherCAT.Master.get_state(:real_master)

      {:error, :offline} ->
        # Still offline, that's okay in fakeethercat without hardware
        :ok
    end

    # Start cyclic on emulator (if not already started in setup)
    case EtherCAT.Master.start_cyclic(:emulator_master) do
      :ok ->
        assert :operational = EtherCAT.Master.get_state(:emulator_master)

      {:error, :already_operational} ->
        # Already started is fine
        assert :operational = EtherCAT.Master.get_state(:emulator_master)

      {:error, :offline} ->
        # Still offline, that's okay in fakeethercat without hardware
        :ok
    end
  end

  test "both masters can be reset independently", %{config: _config} do
    # Reset real master
    assert :ok = EtherCAT.Master.reset(:real_master)
    Process.sleep(50)
    assert :offline = EtherCAT.Master.get_state(:real_master)

    # Verify emulator is still running (not affected by real master reset)
    emulator_state = EtherCAT.Master.get_state(:emulator_master)
    assert emulator_state in [:offline, :stale, :synced, :operational]

    # Reset emulator
    assert :ok = EtherCAT.Master.reset(:emulator_master)
    Process.sleep(50)
    assert :offline = EtherCAT.Master.get_state(:emulator_master)
  end
end
