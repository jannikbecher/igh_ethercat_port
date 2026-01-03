defmodule FakeEtherCAT.SimulatedLoopbackTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat
  @moduletag timeout: :infinity

  @moduledoc """
  Simulated hardware tests using libfakeethercat.

  These tests validate hardware operations using fakeethercat without physical hardware.
  Tests verify that operations complete successfully and data can be written/read.

  Note: Dual-master loopback (running two masters simultaneously with inverted configs)
  is currently disabled due to NIF cleanup race conditions. The infrastructure for
  dual-master support exists (see FakeEtherCAT.setup/1 and Master :name option) but
  needs additional work to handle concurrent master shutdown gracefully.
  """

  setup do
    FakeEtherCAT.setup()

    config = SimpleHardwareConfig.hardware_config()

    # Start master with normal config
    {:ok, master} = start_supervised({EtherCAT.Master, name: EtherCAT.Master, master_index: 0})
    {:ok, slaves} = EtherCAT.configure_hardware(master, config)

    # Clear all outputs
    for ch <- 1..16 do
      pdo = String.to_atom("channel_#{ch}")
      EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
    end

    Process.sleep(100)

    {:ok, master: master, slaves: slaves}
  end

  describe "Digital I/O Operations" do
    test "single channel write and read", %{slaves: slaves} do
      # Write to output
      assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
      Process.sleep(50)

      # Read from input (with fakeethercat, returns default values)
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)

      assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, false)
      Process.sleep(50)
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)
    end

    test "all channels write operations", %{slaves: slaves} do
      # Write to all output channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, true)
      end

      Process.sleep(100)

      # Clear all outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
      end
    end

    test "all channels read operations", %{slaves: slaves} do
      # Read from all input channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
        assert is_boolean(value)
      end
    end

    test "alternating pattern write", %{slaves: slaves} do
      # Set odd channels HIGH, even LOW on real master
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, rem(ch, 2) == 1)
      end

      Process.sleep(100)

      # Verify reads complete successfully
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
        assert is_boolean(value)
      end
    end

    test "rapid toggling", %{slaves: slaves} do
      # Toggle channel 1 rapidly
      for _iteration <- 1..10 do
        assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
        Process.sleep(10)
        assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, false)
        Process.sleep(10)
      end

      # Should complete without errors
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)
    end

    test "all channels individually", %{slaves: slaves} do
      for active_ch <- 1..16 do
        # Set only this channel HIGH on real master
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, ch == active_ch)
        end

        Process.sleep(50)

        # Verify reads complete successfully
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
          assert is_boolean(value)
        end
      end
    end
  end

  describe "Configuration and Setup" do
    test "master starts and configures successfully", %{master: master, slaves: slaves} do
      # Reuse master from module setup
      # Should have expected slaves
      assert Map.has_key?(slaves, :digital_outputs)
      assert Map.has_key?(slaves, :digital_inputs)
      assert Map.has_key?(slaves, :coupler)

      # Slaves should be PIDs
      assert is_pid(slaves.digital_outputs)
      assert is_pid(slaves.digital_inputs)
      assert is_pid(slaves.coupler)
    end

    test "inverted config is valid" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Both configs should validate
      assert :ok = EtherCAT.HardwareConfig.validate(config)
      assert :ok = EtherCAT.HardwareConfig.validate(inverted)
    end
  end

  describe "Slave Operations" do
    test "real master slaves are alive", %{slaves: slaves} do
      assert Process.alive?(slaves.digital_outputs)
      assert Process.alive?(slaves.digital_inputs)
      assert Process.alive?(slaves.coupler)
    end

    test "can query slave state", %{slaves: slaves} do
      # Should be able to get state without crashing
      state = :sys.get_state(slaves.digital_outputs)
      assert state != nil
    end
  end
end
