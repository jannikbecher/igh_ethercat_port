defmodule EtherCAT.HardwareConfig.DomainConfig do
  @moduledoc """
  EtherCAT domain configuration.
  """

  defstruct [
    :name,
    :cycle_multiplier
  ]

  @type t :: %__MODULE__{
          name: atom(),
          cycle_multiplier: pos_integer()
        }
end
