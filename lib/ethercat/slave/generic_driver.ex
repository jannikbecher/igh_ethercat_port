defmodule EtherCAT.Slave.GenericDriver do
  use GenServer
  @behaviour EtherCAT.Slave.DriverImpl

  @impl EtherCAT.Slave.DriverImpl
  def start_driver(name, config) do
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl EtherCAT.Slave.DriverImpl
  def get_sdo_config(pid) do
    GenServer.call(pid, :get_sdo_config)
  end

  @impl EtherCAT.Slave.DriverImpl
  def get_pdo_config(pid) do
    GenServer.call(pid, :get_pdo_config)
  end

  @impl EtherCAT.Slave.DriverImpl
  def register_pdo_entry(_pid, _pdo_name, _entry_name) do
    # Default implementation: no additional setup needed
    :ok
  end

  def read(slave, pdo_name, entry_name) do
    GenServer.call(slave, {:read, pdo_name, entry_name})
  end

  def write(slave, pdo_name, entry_name, value) do
    GenServer.call(slave, {:write, pdo_name, entry_name, value})
  end

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       name: config[:name],
       master: config[:master],
       sdo_config: config[:sdos],
       pdo_config: config[:sync_managers]
     }}
  end

  @impl GenServer
  def handle_call(:get_sdo_config, _from, state) do
    {:reply, state.sdo_config, state}
  end

  @impl GenServer
  def handle_call(:get_pdo_config, _from, state) do
    {:reply, state.pdo_config, state}
  end

  @impl GenServer
  def handle_call({:read, pdo_name, entry_name}, _from, state) do
    result = EtherCAT.Master.read_pdo({state.name, pdo_name, entry_name})
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    result = EtherCAT.Master.write_pdo({state.name, pdo_name, entry_name}, value)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:ecat_pdo, {slave_name, pdo_name, entry_name}, value} = msg, state) do
    IO.inspect(msg, label: "Received PDO update")
    {:noreply, state}
  end

  @doc """
  Infer type from bit length for entries without explicit type annotation.

  Used by drivers to determine encoding/decoding type from PDO entry bit lengths.
  """
  @spec infer_type_from_bit_length(pos_integer()) :: atom()
  def infer_type_from_bit_length(1), do: :bool
  def infer_type_from_bit_length(size) when size >= 2 and size < 8, do: :uint8
  def infer_type_from_bit_length(8), do: :uint8
  def infer_type_from_bit_length(16), do: :uint16
  def infer_type_from_bit_length(32), do: :uint32
  def infer_type_from_bit_length(64), do: :uint64
  def infer_type_from_bit_length(_), do: :uint16

  # ========================================================================
  # Type-Based Encoding/Decoding
  # ========================================================================

  @doc """
  Encode value by type using standard EtherCAT binary formats.
  """
  @spec encode_by_type(atom(), term()) :: {:ok, binary()} | {:error, term()}
  def encode_by_type(:bool, value) when is_boolean(value) do
    {:ok, <<if(value, do: 1, else: 0)>>}
  end

  def encode_by_type(:uint8, value) when is_integer(value) and value >= 0 and value <= 255 do
    {:ok, <<value::little-unsigned-8>>}
  end

  def encode_by_type(:int8, value) when is_integer(value) and value >= -128 and value <= 127 do
    {:ok, <<value::little-signed-8>>}
  end

  def encode_by_type(:uint16, value) when is_integer(value) and value >= 0 and value <= 65535 do
    {:ok, <<value::little-unsigned-16>>}
  end

  def encode_by_type(:int16, value)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, <<value::little-signed-16>>}
  end

  def encode_by_type(:uint32, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-32>>}
  end

  def encode_by_type(:int32, value) when is_integer(value) do
    {:ok, <<value::little-signed-32>>}
  end

  def encode_by_type(:uint64, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-64>>}
  end

  def encode_by_type(:int64, value) when is_integer(value) do
    {:ok, <<value::little-signed-64>>}
  end

  def encode_by_type(type, value) do
    {:error, {:invalid_value_for_type, value, type}}
  end

  @doc """
  Decode binary by type using standard EtherCAT binary formats.
  """
  @spec decode_by_type(atom(), binary()) :: {:ok, term()} | {:error, term()}
  def decode_by_type(:bool, <<value>>) do
    {:ok, value != 0}
  end

  def decode_by_type(:uint8, <<value::little-unsigned-8>>) do
    {:ok, value}
  end

  def decode_by_type(:int8, <<value::little-signed-8>>) do
    {:ok, value}
  end

  def decode_by_type(:uint16, <<value::little-unsigned-16>>) do
    {:ok, value}
  end

  def decode_by_type(:int16, <<value::little-signed-16>>) do
    {:ok, value}
  end

  def decode_by_type(:uint32, <<value::little-unsigned-32>>) do
    {:ok, value}
  end

  def decode_by_type(:int32, <<value::little-signed-32>>) do
    {:ok, value}
  end

  def decode_by_type(:uint64, <<value::little-unsigned-64>>) do
    {:ok, value}
  end

  def decode_by_type(:int64, <<value::little-signed-64>>) do
    {:ok, value}
  end

  def decode_by_type(type, data) do
    {:error, {:invalid_data_for_type, byte_size(data), type}}
  end
end
