defmodule EtherCAT.HardwareConfig do
  @moduledoc """
  Complete EtherCAT system hardware configuration.
  """

  alias EtherCAT.HardwareConfig.MasterConfig
  alias EtherCAT.HardwareConfig.DomainConfig
  alias EtherCAT.HardwareConfig.SlaveConfig

  defstruct [
    :master,
    :domains,
    :slaves
  ]

  @type t :: %__MODULE__{
          master: MasterConfig.t() | nil,
          domains: [DomainConfig.t()],
          slaves: [SlaveConfig.t()]
        }
end
