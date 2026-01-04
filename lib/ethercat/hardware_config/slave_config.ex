defmodule EtherCAT.HardwareConfig.SlaveConfig do
  @moduledoc """
  EtherCAT slave device configuration.

  Defines the complete configuration for a single slave device including
  device identity, driver module, PDO/SDO configuration, and domain registrations.
  """

  alias EtherCAT.HardwareConfig.SlaveConfig.DomainEntry

  defstruct [
    :name,
    :device_identity,
    :driver,
    :config,
    :registered_entries
  ]

  @type device_identity :: %{
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          revision_no: non_neg_integer() | nil,
          serial_no: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          name: atom(),
          device_identity: device_identity(),
          driver: module() | nil,
          config: map(),
          registered_entries: %{atom() => [DomainEntry.t()]}
        }
end
