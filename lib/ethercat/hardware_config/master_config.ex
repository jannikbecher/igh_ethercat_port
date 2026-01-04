defmodule EtherCAT.HardwareConfig.MasterConfig do
  @moduledoc """
  EtherCAT master configuration.
  """

  defstruct [
    :index,
    :cycle_interval
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          cycle_interval: pos_integer()
        }
end
