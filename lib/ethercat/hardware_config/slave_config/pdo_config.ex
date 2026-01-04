defmodule EtherCAT.HardwareConfig.SlaveConfig.PdoConfig do
  @moduledoc """
  Process Data Object (PDO) configuration.

  PDOs are used for cyclic process data exchange between master and slaves.
  """

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
