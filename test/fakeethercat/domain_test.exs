defmodule FakeEtherCAT.DomainTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat

  @moduledoc """
  Tests for domain configuration using real hardware configs.

  These tests verify domain configurations work correctly with fakeethercat.
  """

  setup do
    FakeEtherCAT.setup()
  end

  describe "domain configuration" do
    test "SimpleHardwareConfig has fast domain" do
      config = SimpleHardwareConfig.hardware_config()

      assert length(config.domains) == 1
      fast_domain = hd(config.domains)
      assert fast_domain.name == :fast
      assert fast_domain.cycle_multiplier == 1
    end

    test "inverted config preserves domain structure" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Same number of domains
      assert length(config.domains) == length(inverted.domains)

      # Same domain properties
      Enum.zip(config.domains, inverted.domains)
      |> Enum.each(fn {orig, inv} ->
        assert orig.name == inv.name
        assert orig.cycle_multiplier == inv.cycle_multiplier
      end)
    end
  end

  describe "registered entries" do
    test "digital inputs registered to fast domain" do
      config = SimpleHardwareConfig.hardware_config()
      di_slave = Enum.find(config.slaves, &(&1.name == :digital_inputs))

      assert Map.has_key?(di_slave.registered_entries, :fast)
      assert length(di_slave.registered_entries.fast) == 16
    end

    test "digital outputs registered to fast domain" do
      config = SimpleHardwareConfig.hardware_config()
      do_slave = Enum.find(config.slaves, &(&1.name == :digital_outputs))

      assert Map.has_key?(do_slave.registered_entries, :fast)
      assert length(do_slave.registered_entries.fast) == 16
    end

    test "inverted config inverts registered entry directions" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Check digital inputs - original has :input, inverted should have :output
      di_orig = Enum.find(config.slaves, &(&1.name == :digital_inputs))
      di_inv = Enum.find(inverted.slaves, &(&1.name == :digital_inputs))

      # Same domain keys
      assert Map.keys(di_orig.registered_entries) == Map.keys(di_inv.registered_entries)

      # Check directions are inverted
      for {domain, entries} <- di_orig.registered_entries do
        inv_entries = di_inv.registered_entries[domain]

        for {{pdo_name, orig_dir}, {inv_pdo_name, inv_dir}} <- Enum.zip(entries, inv_entries) do
          assert pdo_name == inv_pdo_name
          assert orig_dir == :input
          assert inv_dir == :output
        end
      end

      # Check digital outputs - original has :output, inverted should have :input
      do_orig = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      do_inv = Enum.find(inverted.slaves, &(&1.name == :digital_outputs))

      for {domain, entries} <- do_orig.registered_entries do
        inv_entries = do_inv.registered_entries[domain]

        for {{pdo_name, orig_dir}, {inv_pdo_name, inv_dir}} <- Enum.zip(entries, inv_entries) do
          assert pdo_name == inv_pdo_name
          assert orig_dir == :output
          assert inv_dir == :input
        end
      end
    end
  end
end
