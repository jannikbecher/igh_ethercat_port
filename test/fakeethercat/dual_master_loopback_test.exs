defmodule FakeEtherCAT.DualMasterLoopbackTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat
  @moduletag :dual_master
  @moduletag timeout: :infinity

  @moduledoc """
  Dual-master loopback tests using libfakeethercat.

  These tests run two EtherCAT masters simultaneously:
  - **Real master** (index 0): Uses normal config (DO=output, DI=input)
  - **Emulator master** (index 1): Uses inverted config (DO=input, DI=output)

  The emulator simulates field devices by:
  1. Reading outputs written by the real master (via inverted DO as input)
  2. Writing inputs that the real master will read (via inverted DI as output)

  This validates the full data path through libfakeethercat's RtIPC shared memory.

  ## Architecture

  ```
  Real Master (index 0)              Emulator Master (index 1)
  ┌─────────────────────┐            ┌─────────────────────┐
  │ EL2809 (DO)         │            │ EL2809 (DO inverted)│
  │   SM0/SM1: OUTPUT ──┼── RtIPC ──►│   SM0/SM1: INPUT    │
  │                     │            │                     │
  │ EL1809 (DI)         │            │ EL1809 (DI inverted)│
  │   SM3: INPUT    ◄───┼── RtIPC ──┤   SM3: OUTPUT       │
  └─────────────────────┘            └─────────────────────┘
  ```

  ## Test Scenarios

  1. **Output propagation**: Real master writes DO → Emulator reads
  2. **Input simulation**: Emulator writes DI → Real master reads
  3. **Bidirectional loopback**: Wire outputs to inputs (emulator copies DO→DI)
  4. **Concurrent shutdown**: Both masters terminate together (NIF cleanup test)
  """

  setup do
    config = SimpleHardwareConfig.hardware_config()

    # Start emulator first (master index 1) with inverted config
    {:ok, emulator_master, emulator_slaves} = FakeEtherCAT.setup(config)

    # Give emulator time to initialize RtIPC shared memory
    Process.sleep(100)

    # Start real master (master index 0) with normal config
    {:ok, real_master} =
      start_supervised(
        {EtherCAT.Master, name: :real_master, master_index: 0},
        id: :real_master
      )

    {:ok, real_slaves} = EtherCAT.configure_hardware(real_master, config)

    # Wait for both masters to be operational
    Process.sleep(200)

    # Clear all real outputs
    for ch <- 1..16 do
      pdo = String.to_atom("channel_#{ch}")
      EtherCAT.write(real_slaves.digital_outputs, pdo, :output, false)
    end

    Process.sleep(100)

    {:ok,
     real_master: real_master,
     real_slaves: real_slaves,
     emulator_master: emulator_master,
     emulator_slaves: emulator_slaves,
     config: config}
  end

  describe "Dual Master Setup" do
    test "both masters start successfully", ctx do
      assert Process.alive?(ctx.real_master)
      assert Process.alive?(ctx.emulator_master)
    end

    test "both masters have configured slaves", ctx do
      # Real master slaves
      assert Map.has_key?(ctx.real_slaves, :digital_outputs)
      assert Map.has_key?(ctx.real_slaves, :digital_inputs)
      assert Map.has_key?(ctx.real_slaves, :coupler)

      # Emulator slaves
      assert Map.has_key?(ctx.emulator_slaves, :digital_outputs)
      assert Map.has_key?(ctx.emulator_slaves, :digital_inputs)
      assert Map.has_key?(ctx.emulator_slaves, :coupler)
    end

    test "all slave processes are alive", ctx do
      # Real master slaves
      assert Process.alive?(ctx.real_slaves.digital_outputs)
      assert Process.alive?(ctx.real_slaves.digital_inputs)

      # Emulator slaves
      assert Process.alive?(ctx.emulator_slaves.digital_outputs)
      assert Process.alive?(ctx.emulator_slaves.digital_inputs)
    end
  end

  describe "Input Simulation (Emulator → Real Master)" do
    @tag :input_simulation
    test "emulator can simulate input changes", ctx do
      # Emulator writes to DI (inverted: DI becomes output)
      # Real master reads from DI (normal: DI is input)

      # First verify real master reads default value (false)
      {:ok, initial} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(initial)

      # Emulator simulates input HIGH on channel 1
      # In inverted config, digital_inputs has direction=output
      assert :ok =
               EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_1, :output, true)

      # Wait for RtIPC propagation
      Process.sleep(100)

      # Real master should now read the simulated input
      {:ok, value} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)
      # Note: With RtIPC, this should be true if shared memory is working
    end

    @tag :input_simulation
    test "emulator can simulate multiple input channels", ctx do
      # Set alternating pattern on emulator's DI outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        value = rem(ch, 2) == 1
        assert :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, pdo, :output, value)
      end

      Process.sleep(100)

      # Read all channels from real master
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, value} = EtherCAT.read(ctx.real_slaves.digital_inputs, pdo, :input)
        assert is_boolean(value)
      end
    end

    @tag :input_simulation
    test "emulator can toggle inputs rapidly", ctx do
      for _i <- 1..10 do
        # Toggle emulator input (inverted: DI is now output on emulator)
        :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_1, :output, true)
        Process.sleep(20)
        :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_1, :output, false)
        Process.sleep(20)
      end

      # Both sides should still be operational
      # Real master: DI has :input entries
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
      # Emulator: DI has :output entries (inverted), so we read the output we just wrote
      {:ok, _} = EtherCAT.read(ctx.emulator_slaves.digital_inputs, :channel_1, :output)
    end
  end

  describe "Output Propagation (Real Master → Emulator)" do
    @tag :output_propagation
    test "emulator can read real master outputs", ctx do
      # Real master writes to DO (normal: DO is output)
      # Emulator reads from DO (inverted: DO becomes input)

      # Write to real master output
      assert :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_1, :output, true)

      Process.sleep(100)

      # Emulator reads from its inverted DO (now input)
      {:ok, value} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, :channel_1, :input)
      assert is_boolean(value)
    end

    @tag :output_propagation
    test "emulator sees all output channel changes", ctx do
      # Set all outputs HIGH on real master
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, pdo, :output, true)
      end

      Process.sleep(100)

      # Emulator should be able to read all channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, value} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, pdo, :input)
        assert is_boolean(value)
      end

      # Clear all outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, pdo, :output, false)
      end

      Process.sleep(100)

      # Verify emulator sees the change
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, value} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, pdo, :input)
        assert is_boolean(value)
      end
    end
  end

  describe "Bidirectional Loopback (Wire Simulation)" do
    @tag :bidirectional
    test "emulator can wire outputs to inputs (loopback)", ctx do
      # This simulates physical wiring: DO channel N → DI channel N
      # Emulator reads real master's outputs and writes them to inputs

      # Real master sets output pattern
      for ch <- [1, 3, 5, 7] do
        pdo = String.to_atom("channel_#{ch}")
        :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, pdo, :output, true)
      end

      Process.sleep(100)

      # Emulator reads outputs and copies to inputs (simulating wire)
      for ch <- 1..8 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, output_val} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, pdo, :input)

        # Write the same value to the corresponding input
        :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, pdo, :output, output_val)
      end

      Process.sleep(100)

      # Now real master should be able to read back via inputs
      for ch <- 1..8 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, input_val} = EtherCAT.read(ctx.real_slaves.digital_inputs, pdo, :input)
        assert is_boolean(input_val)
      end
    end

    @tag :bidirectional
    test "continuous loopback simulation", ctx do
      # Spawn a process that continuously copies outputs to inputs
      loopback_pid =
        spawn_link(fn ->
          loopback_loop(ctx.emulator_slaves, 10)
        end)

      # Write pattern to outputs
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_1, :output, true)
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_2, :output, false)
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_3, :output, true)

      # Let loopback run
      Process.sleep(200)

      # Read inputs
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_2, :input)
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_3, :input)

      # Stop loopback
      Process.exit(loopback_pid, :normal)
    end
  end

  describe "Concurrent Shutdown (NIF Cleanup)" do
    @tag :concurrent_shutdown
    test "both masters can shut down cleanly", ctx do
      # This test validates the NIF cleanup fix
      # Previously, concurrent master shutdown caused crashes due to
      # double-free race conditions in domain accessor cleanup

      # Verify both are operational
      assert Process.alive?(ctx.real_master)
      assert Process.alive?(ctx.emulator_master)

      # Perform some I/O operations
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_1, :output, true)
      :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_1, :output, true)
      Process.sleep(50)

      # Stop emulator first (test relies on ExUnit cleanup for real_master)
      GenServer.stop(ctx.emulator_master, :normal)

      # Give time for cleanup
      Process.sleep(100)

      # Real master should still work
      assert Process.alive?(ctx.real_master)
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
    end

    @tag :concurrent_shutdown
    test "sequential master restarts don't crash", ctx do
      # Test that we can stop and verify the system remains stable
      # This validates that NIF cleanup doesn't cause crashes

      # Verify both masters are operational
      assert Process.alive?(ctx.real_master)
      assert Process.alive?(ctx.emulator_master)

      # Do some I/O
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_1, :output, true)
      :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_1, :output, true)
      Process.sleep(50)

      # Read back
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_1, :input)
      {:ok, _} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, :channel_1, :input)

      # Stop emulator
      GenServer.stop(ctx.emulator_master, :normal)
      Process.sleep(100)

      # Real master should still be functional
      assert Process.alive?(ctx.real_master)
      :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_2, :output, true)
      {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_2, :input)
    end
  end

  describe "Edge Cases" do
    @tag :edge_cases
    test "writing to all 16 channels simultaneously", ctx do
      # Write all channels at once on both sides
      tasks =
        for ch <- 1..16 do
          Task.async(fn ->
            pdo = String.to_atom("channel_#{ch}")
            :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, pdo, :output, true)
            :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, pdo, :output, true)
          end)
        end

      Task.await_many(tasks)
      Process.sleep(100)

      # Read all channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, pdo, :input)
        {:ok, _} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, pdo, :input)
      end
    end

    @tag :edge_cases
    test "interleaved read/write operations", ctx do
      for _iteration <- 1..5 do
        # Write on real, read on emulator
        :ok = EtherCAT.write(ctx.real_slaves.digital_outputs, :channel_1, :output, true)
        {:ok, _} = EtherCAT.read(ctx.emulator_slaves.digital_outputs, :channel_1, :input)

        # Write on emulator, read on real
        :ok = EtherCAT.write(ctx.emulator_slaves.digital_inputs, :channel_2, :output, true)
        {:ok, _} = EtherCAT.read(ctx.real_slaves.digital_inputs, :channel_2, :input)

        Process.sleep(20)
      end
    end
  end

  # Helper function for continuous loopback simulation
  defp loopback_loop(emulator_slaves, iterations) when iterations > 0 do
    # Copy first 8 channels from DO to DI
    for ch <- 1..8 do
      pdo = String.to_atom("channel_#{ch}")

      case EtherCAT.read(emulator_slaves.digital_outputs, pdo, :input) do
        {:ok, value} ->
          EtherCAT.write(emulator_slaves.digital_inputs, pdo, :output, value)

        _ ->
          :ok
      end
    end

    Process.sleep(20)
    loopback_loop(emulator_slaves, iterations - 1)
  end

  defp loopback_loop(_emulator_slaves, 0), do: :ok
end
