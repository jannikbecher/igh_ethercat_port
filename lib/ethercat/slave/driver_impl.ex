defmodule EtherCAT.Slave.DriverImpl do
  @moduledoc """
  ## Callbacks

  Required callbacks (state-based):
  - `start_driver/2` - Initialize driver state (standard GenServer callback)
  - `get_sdo_config/1` - Return SDO configuration list
  - `get_pdo_config/1` - Return sync manager/PDO configuration
  """

  require Logger

  # ========================================================================
  # Types
  # ========================================================================

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  # ========================================================================
  # Behaviour Callbacks
  # ========================================================================

  @doc """
  Initialize driver with slave configuration.

  Parameters:
  - name: The slave name (atom)
  - config: The slave-specific configuration struct/map (from SlaveConfig.config)

  Returns:
  - {:ok, pid} - GenServer pid
  - {:error, reason} - if startup failed
  """
  @callback start_driver(name :: atom(), config :: map()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Get SDO configuration for this slave.

  Called with the driver pid.
  Returns a list of SDO writes to perform before PDO configuration.
  """
  @callback get_sdo_config(pid :: pid()) :: [EtherCAT.HardwareConfig.SdoConfig.t()]

  @doc """
  Get PDO configuration for this slave.

  Called with the driver pid.
  Returns the sync manager structure defining PDO layout.
  """
  @callback get_pdo_config(pid :: pid()) :: [EtherCAT.HardwareConfig.SyncManagerConfig.t()]

  @doc """
  Called when a PDO entry has been successfully registered with the EtherCAT master.

  The driver can use this to initialize internal state, set up monitoring, or perform
  any other setup needed for handling this PDO entry.

  Parameters:
  - pid: driver process pid
  - pdo_name: the PDO name (e.g., :rtd_channel_1)
  - entry_name: the entry name within the PDO (e.g., :value)

  Returns:
  - :ok - registration successful
  - {:error, reason} - if registration failed
  """
  @callback register_pdo_entry(
              pid :: pid(),
              pdo_name :: pdo_name(),
              entry_name :: entry_name()
            ) :: :ok | {:error, term()}
end
