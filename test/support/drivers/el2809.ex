defmodule Drivers.EL2809 do
  @moduledoc """
  Driver for Beckhoff EL2809 16-channel digital output terminal (24V DC, 0.5A).

  ## PDO Layout (Fixed)

  The EL2809 has a fixed PDO layout:
  - 16 output channels (1-bit each)
  - Channels 1-8 in Sync Manager 0
  - Channels 9-16 in Sync Manager 1
  - Watchdog enabled on both sync managers
  """

  use EtherCAT.Slave.Driver

  alias EtherCAT.Slave.Driver
  alias EtherCAT.HardwareConfig.{SyncManagerConfig, PdoConfig}

  defstruct [:master, :name]

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      master: opts[:master],
      name: opts[:name]
    }

    {:ok, state}
  end

  # ============================================================================
  # Driver Behaviour Callbacks
  # ============================================================================

  @impl EtherCAT.Slave.Driver
  def configurable_pdos?(_state), do: false

  @impl EtherCAT.Slave.Driver
  def get_sdo_config(_state), do: []

  @impl EtherCAT.Slave.Driver
  def get_pdo_config(_state) do
    [
      # First 8 channels in SM0
      SyncManagerConfig.new(
        index: 0,
        direction: :output,
        watchdog: :enabled,
        pdos:
          for ch <- 1..8 do
            PdoConfig.new(
              index: 0x1600 + (ch - 1),
              name: :"channel_#{ch}",
              entries: %{
                output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
              }
            )
          end
      ),
      # Second 8 channels in SM1
      SyncManagerConfig.new(
        index: 1,
        direction: :output,
        watchdog: :enabled,
        pdos:
          for ch <- 9..16 do
            PdoConfig.new(
              index: 0x1600 + (ch - 1),
              name: :"channel_#{ch}",
              entries: %{
                output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
              }
            )
          end
      )
    ]
  end

  @impl EtherCAT.Slave.Driver
  def encode_pdo_value(_pdo, :output, value, _state) do
    Driver.encode_by_type(:bool, value)
  end

  def encode_pdo_value(_pdo, _entry, value, _state) do
    Driver.encode_by_type(:bool, value)
  end

  @impl EtherCAT.Slave.Driver
  def decode_pdo_value(_pdo, _entry, _value, _state) do
    # EL2809 is output-only, no decoding needed
    {:error, :output_only_device}
  end
end
