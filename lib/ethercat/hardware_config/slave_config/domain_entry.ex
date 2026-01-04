defmodule EtherCAT.HardwareConfig.SlaveConfig.DomainEntry do
  @moduledoc """
  Represents a PDO entry registration for a specific domain.

  Each entry specifies which PDO entry from a slave should be registered
  to a domain, along with optional deadband filtering and update intervals.
  """

  defstruct [
    :pdo_name,
    :entry_name,
    :deadband,
    :interval_us
  ]

  @type t :: %__MODULE__{
          pdo_name: atom(),
          entry_name: atom(),
          deadband: non_neg_integer(),
          interval_us: non_neg_integer()
        }
end
