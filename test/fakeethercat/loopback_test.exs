defmodule FakeEtherCAT.LoopbackTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat
  @moduletag :loopback

  @moduledoc """
  Tests for config inversion to enable dual-master loopback.

  These tests verify that config inversion properly swaps sync manager
  directions, preserves all other configuration, and enables future
  back-to-back process data exchange via RtIPC.
  """

  setup do
    FakeEtherCAT.setup()
  end

  describe "config inversion details" do
    test "inverts all sync managers in multi-SM slave" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # EL2809 has 2 sync managers
      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      assert length(do_orig.config.sync_managers) == 2
      assert length(do_inv.config.sync_managers) == 2

      Enum.zip(do_orig.config.sync_managers, do_inv.config.sync_managers)
      |> Enum.each(fn {orig_sm, inv_sm} ->
        assert orig_sm.direction == :output
        assert inv_sm.direction == :input
      end)
    end

    test "preserves sync manager index" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      Enum.zip(do_orig.config.sync_managers, do_inv.config.sync_managers)
      |> Enum.each(fn {orig_sm, inv_sm} ->
        assert orig_sm.index == inv_sm.index
      end)
    end

    test "preserves PDO configuration with inverted entry directions" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      Enum.zip(do_orig.config.sync_managers, do_inv.config.sync_managers)
      |> Enum.each(fn {orig_sm, inv_sm} ->
        # PDO count should be the same
        assert length(orig_sm.pdos) == length(inv_sm.pdos)

        # PDO names and indices should be preserved, entry directions inverted
        Enum.zip(orig_sm.pdos, inv_sm.pdos)
        |> Enum.each(fn {orig_pdo, inv_pdo} ->
          assert orig_pdo.name == inv_pdo.name
          assert orig_pdo.index == inv_pdo.index

          # Entry keys (directions) should be inverted, values preserved
          for {orig_key, orig_val} <- orig_pdo.entries do
            inv_key = if orig_key == :input, do: :output, else: :input
            assert Map.has_key?(inv_pdo.entries, inv_key)
            assert inv_pdo.entries[inv_key] == orig_val
          end
        end)
      end)
    end

    test "preserves watchdog configuration" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      Enum.zip(do_orig.config.sync_managers, do_inv.config.sync_managers)
      |> Enum.each(fn {orig_sm, inv_sm} ->
        assert orig_sm.watchdog == inv_sm.watchdog
      end)
    end

    test "preserves SDO configuration" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      assert do_orig.config.sdos == do_inv.config.sdos
    end
  end

  describe "complete config preservation" do
    test "inverts all slaves" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      assert length(config.slaves) == length(inverted.slaves)

      # All slaves with sync managers should have inverted directions
      for orig_slave <- config.slaves do
        inv_slave = Enum.find(inverted.slaves, &(&1.name == orig_slave.name))
        assert inv_slave

        if length(orig_slave.config.sync_managers) > 0 do
          Enum.zip(orig_slave.config.sync_managers, inv_slave.config.sync_managers)
          |> Enum.each(fn {orig_sm, inv_sm} ->
            refute orig_sm.direction == inv_sm.direction
          end)
        end
      end
    end

    test "preserves slave position and identity" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      for orig_slave <- config.slaves do
        inv_slave = Enum.find(inverted.slaves, &(&1.name == orig_slave.name))

        assert inv_slave.position == orig_slave.position
        assert inv_slave.name == orig_slave.name
        assert inv_slave.device_identity == orig_slave.device_identity
        assert inv_slave.driver == orig_slave.driver
      end
    end

    test "config remains valid after inversion" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Should be able to validate both configs
      assert :ok = EtherCAT.HardwareConfig.validate(config)
      assert :ok = EtherCAT.HardwareConfig.validate(inverted)
    end
  end

  describe "use case: loopback preparation" do
    test "inverted config ready for dual-master setup" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Original: EL2809 outputs, EL1809 inputs
      # Inverted: EL2809 inputs, EL1809 outputs
      # This allows process data exchange via RtIPC

      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      di_orig = Enum.find(config.slaves, &(&1.name == :digital_inputs))
      di_inv = Enum.find(inverted.slaves, &(&1.name == :digital_inputs))

      # Verify direction swap
      assert hd(do_orig.config.sync_managers).direction == :output
      assert hd(do_inv.config.sync_managers).direction == :input

      assert hd(di_orig.config.sync_managers).direction == :input
      assert hd(di_inv.config.sync_managers).direction == :output
    end
  end
end
