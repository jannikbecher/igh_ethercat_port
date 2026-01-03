defmodule Drivers.EL1809 do
  @moduledoc """
  Driver for Beckhoff EL1809 16-channel digital input terminal (24V DC).

  ## PDO Layout (Fixed)

  The EL1809 has a fixed PDO layout:
  - 16 input channels (1-bit each)
  - All channels in Sync Manager 3 (inputs)
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
      SyncManagerConfig.new(
        index: 3,
        direction: :input,
        watchdog: :disabled,
        pdos:
          for ch <- 1..16 do
            PdoConfig.new(
              index: 0x1A00 + (ch - 1),
              name: :"channel_#{ch}",
              entries: %{
                input: {0x6000 + (ch - 1) * 0x10, 0x01, 1}
              }
            )
          end
      )
    ]
  end

  @impl EtherCAT.Slave.Driver
  def encode_pdo_value(_pdo, _entry, _value, _state) do
    # EL1809 is input-only, no encoding needed
    {:error, :input_only_device}
  end

  @impl EtherCAT.Slave.Driver
  def decode_pdo_value(_pdo, :input, binary, _state) do
    Driver.decode_by_type(:bool, binary)
  end

  def decode_pdo_value(_pdo, entry, binary, _state) do
    Driver.decode_by_type(:bool, binary)
  end
end
