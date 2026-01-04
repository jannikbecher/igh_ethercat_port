defmodule EtherCAT.HardwareConfig.SlaveConfig.SdoConfig do
  @moduledoc """
  Service Data Object (SDO) configuration.

  SDOs are used for acyclic configuration and parameter access.
  """

  defstruct [:index, :subindex, :data]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          subindex: non_neg_integer(),
          data: binary()
        }
end
