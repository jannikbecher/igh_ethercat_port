defmodule EtherCAT.HardwareConfig do
  @moduledoc """
  Complete EtherCAT system hardware configuration.
  """

  defmodule MasterConfig do
    defstruct [
      :index,
      :cycle_interval
    ]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            cycle_interval: pos_integer()
          }
  end

  defmodule DomainConfig do
    defstruct [
      :name,
      :cycle_multiplier
    ]

    @type t :: %__MODULE__{
            name: atom(),
            cycle_multiplier: pos_integer()
          }
  end

  defmodule PdoConfig do
    defstruct [:index, :name, :entries]

    @type entry_tuple :: {
            index :: non_neg_integer(),
            subindex :: non_neg_integer(),
            bit_length :: pos_integer()
          }

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            name: atom(),
            entries: %{atom() => entry_tuple()}
          }
  end

  defmodule SdoConfig do
    defstruct [:index, :subindex, :data]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            subindex: non_neg_integer(),
            data: binary()
          }
  end

  defmodule SyncManagerConfig do
    alias EtherCAT.HardwareConfig.PdoConfig

    defstruct [:index, :direction, :watchdog, :pdos]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            direction: :invalid | :output | :input | :count,
            watchdog: :default | :enabled | :disabled,
            pdos: [PdoConfig.t()]
          }
  end

  defmodule SlaveConfig do
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
            registered_entries: %{
              domain() => [{pdo_name(), entry_name(), deadband(), interval_us()}]
            }
          }

    @type domain() :: atom()
    @type pdo_name() :: atom()
    @type entry_name() :: atom()
    @type deadband() :: non_neg_integer()
    @type interval_us() :: non_neg_integer()
  end

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
