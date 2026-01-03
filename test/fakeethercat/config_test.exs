defmodule FakeEtherCAT.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat

  @moduledoc """
  Tests for basic configuration without physical hardware using libfakeethercat.

  These tests verify that the fakeethercat library properly simulates EtherCAT
  operations without requiring physical hardware.
  """

  setup do
    FakeEtherCAT.setup()
  end

  describe "fakeethercat environment" do
    test "master can be started" do
      {:ok, master} = start_supervised({EtherCAT.Master, [name: EtherCAT.Master]})
      assert Process.alive?(master)
    end

    test "can query master state" do
      {:ok, master} = start_supervised({EtherCAT.Master, [name: EtherCAT.Master]})
      # With fakeethercat, this should not crash
      state = :sys.get_state(master)
      assert state != nil
    end
  end

  describe "config inversion" do
    test "inverts sync manager directions" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Verify slave count preserved
      assert length(config.slaves) == length(inverted.slaves)

      # Check digital outputs slave (has output sync managers)
      digital_output_slave = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      inverted_output_slave = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      if digital_output_slave && inverted_output_slave do
        # Get first sync manager from each
        original_sm = hd(digital_output_slave.config.sync_managers)
        inverted_sm = hd(inverted_output_slave.config.sync_managers)

        # Directions should be opposite
        assert original_sm.direction == :output
        assert inverted_sm.direction == :input
      end
    end

    test "inverts all sync managers in a slave" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Find digital inputs slave (has input sync managers)
      digital_input_slave = Enum.find(config.slaves, &(&1.name == :digital_inputs))
      inverted_input_slave = Enum.find(inverted.slaves, &(&1.name == :digital_inputs))

      if digital_input_slave && inverted_input_slave do
        # All sync managers should be inverted
        Enum.zip(
          digital_input_slave.config.sync_managers,
          inverted_input_slave.config.sync_managers
        )
        |> Enum.each(fn {orig_sm, inv_sm} ->
          assert orig_sm.direction == :input
          assert inv_sm.direction == :output
        end)
      end
    end

    test "preserves slave metadata" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Check a slave with metadata
      original_slave = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      inverted_slave = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      # Position, name, device_identity should be preserved
      assert original_slave.position == inverted_slave.position
      assert original_slave.name == inverted_slave.name
      assert original_slave.device_identity == inverted_slave.device_identity
    end

    test "preserves domain configuration" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Domains should be identical
      assert length(config.domains) == length(inverted.domains)

      Enum.zip(config.domains, inverted.domains)
      |> Enum.each(fn {orig, inv} ->
        assert orig.name == inv.name
        assert orig.cycle_multiplier == inv.cycle_multiplier
      end)
    end

    test "preserves master configuration" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      assert config.master.index == inverted.master.index
      assert config.master.cycle_interval == inverted.master.cycle_interval
      assert config.master.nif_yield_interval == inverted.master.nif_yield_interval
    end
  end

  describe "hardware config structure" do
    test "SimpleHardwareConfig has expected slaves" do
      config = SimpleHardwareConfig.hardware_config()

      assert length(config.slaves) == 3
      assert Enum.find(config.slaves, &(&1.name == :coupler))
      assert Enum.find(config.slaves, &(&1.name == :digital_inputs))
      assert Enum.find(config.slaves, &(&1.name == :digital_outputs))
    end

    test "SimpleHardwareConfig has one domain" do
      config = SimpleHardwareConfig.hardware_config()

      assert length(config.domains) == 1
      assert hd(config.domains).name == :fast
      assert hd(config.domains).cycle_multiplier == 1
    end

    test "digital inputs have input sync managers" do
      config = SimpleHardwareConfig.hardware_config()
      di_slave = Enum.find(config.slaves, &(&1.name == :digital_inputs))

      assert length(di_slave.config.sync_managers) == 1
      assert hd(di_slave.config.sync_managers).direction == :input
    end

    test "digital outputs have output sync managers" do
      config = SimpleHardwareConfig.hardware_config()
      do_slave = Enum.find(config.slaves, &(&1.name == :digital_outputs))

      assert length(do_slave.config.sync_managers) == 2
      assert Enum.all?(do_slave.config.sync_managers, &(&1.direction == :output))
    end
  end
end
