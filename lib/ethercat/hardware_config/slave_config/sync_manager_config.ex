defmodule EtherCAT.HardwareConfig.SlaveConfig.SyncManagerConfig do
  @moduledoc """
  Sync Manager (SM) configuration.

  Sync Managers control the data flow direction and organize PDOs into
  logical groups within a slave device.
  """

  alias EtherCAT.HardwareConfig.SlaveConfig.PdoConfig

  defstruct [:index, :direction, :watchdog, :pdos]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          direction: :invalid | :output | :input | :count,
          watchdog: :default | :enabled | :disabled,
          pdos: [PdoConfig.t()]
        }
end
