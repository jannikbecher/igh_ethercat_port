defmodule Drivers.EL3202 do
  @moduledoc """
  Driver for Beckhoff EL3202 2-channel RTD input terminal.

  ## Configuration

  The driver accepts per-channel configuration via `:channel_1` and `:channel_2` keys:

      %{
        channel_1: %{
          rtd_element: :pt100,
          connection: :two_wire,
          enable_filter: true,
          filter_settings: :hz_50
        },
        channel_2: %{
          rtd_element: :pt1000,
          connection: :three_wire
        }
      }

  ## Channel Options

  - `:rtd_element` - RTD sensor type (default: `:pt100`)
    - `:pt100` - Pt100 (-200°C to 850°C)
    - `:ni100` - Ni100 (-60°C to 250°C)
    - `:pt1000` - Pt1000 (-200°C to 850°C)
    - `:pt500` - Pt500 (-200°C to 850°C)
    - `:pt200` - Pt200 (-200°C to 850°C)
    - `:ni1000` - Ni1000 (-60°C to 250°C)
    - `:ni1000_tk5000` - Ni1000 TK5000 (-30°C to 160°C)
    - `:ni120` - Ni120 (-60°C to 320°C)
    - `:ohm_1_16` - Resistance output, 1/16 Ohm resolution (0-4096 Ohm)
    - `:ohm_1_64` - Resistance output, 1/64 Ohm resolution (0-1024 Ohm)

  - `:connection` - Wiring configuration (default: `:two_wire`)
    - `:two_wire`, `:three_wire`, `:four_wire`, `:not_connected`

  - `:presentation` - Value presentation mode (default: `:signed`)
    - `:signed` - Signed presentation
    - `:absolute_msb_sign` - Absolute value with MSB as sign
    - `:high_resolution` - High resolution (1/100°C)

  - `:siemens_bits` - Enable S5 bits in low-order bits (default: `false`)

  - `:enable_filter` - Enable digital filter (default: `false`)
  - `:filter_settings` - Filter frequency (default: `:hz_50`)
    - `:hz_50`, `:hz_60`, `:hz_100`, `:hz_500`, `:khz_1`, `:khz_2`,
      `:khz_3_75`, `:khz_7_5`, `:khz_15`, `:khz_30`, `:hz_5`, `:hz_10`

  - `:enable_user_scale` - Enable user scaling (default: `false`)
  - `:user_scale_offset` - Scaling offset, int16 (default: `0`)
  - `:user_scale_gain` - Scaling gain, int32 (default: `65536` = 1.0)

  - `:enable_limit_1` - Enable limit 1 monitoring (default: `false`)
  - `:limit_1` - Limit 1 threshold in 0.1°C (default: `0`)
  - `:enable_limit_2` - Enable limit 2 monitoring (default: `false`)
  - `:limit_2` - Limit 2 threshold in 0.1°C (default: `0`)

  - `:enable_user_calibration` - Enable user calibration (default: `false`)
  - `:user_calibration_offset` - User calibration offset, int16 (default: `0`)
  - `:user_calibration_gain` - User calibration gain, uint16 (default: `65535`)

  - `:enable_manufacturer_calibration` - Enable manufacturer calibration (default: `true`)

  - `:wire_calibration` - Wire resistance calibration in 1/32 Ohm (default: `0`)

  ## PDO Layout (Fixed)

  The EL3202 has a fixed PDO layout and does not support PDO reconfiguration.
  Each channel provides:
  - Status bits: underrange, overrange, limit_1, limit_2, error
  - TxPDO state/toggle bits
  - 16-bit signed temperature value (0.1°C resolution, or 0.01°C in high_resolution mode)
  """

  use EtherCAT.Slave.Driver

  alias EtherCAT.Slave.Driver
  alias EtherCAT.HardwareConfig.{SdoConfig, SyncManagerConfig, PdoConfig}

  # RTD element types per docs (0x80n0:19)
  # 0: Pt100, 1: Ni100, 2: Pt1000, 3: Pt500, 4: Pt200, 5: Ni1000,
  # 6: Ni1000 TK5000, 7: Ni120, 8: Ohm 1/16, 9: Ohm 1/64
  @rtd_elements %{
    pt100: 0,
    ni100: 1,
    pt1000: 2,
    pt500: 3,
    pt200: 4,
    ni1000: 5,
    ni1000_tk5000: 6,
    ni120: 7,
    ohm_1_16: 8,
    ohm_1_64: 9
  }

  # Connection technology (0x80n0:1A)
  @connections %{
    two_wire: 0,
    three_wire: 1,
    four_wire: 2,
    not_connected: 3
  }

  # Filter settings (0x80n0:15) - enumerated values
  @filter_settings %{
    hz_50: 0,
    hz_60: 1,
    hz_100: 2,
    hz_500: 3,
    khz_1: 4,
    khz_2: 5,
    khz_3_75: 6,
    khz_7_5: 7,
    khz_15: 8,
    khz_30: 9,
    hz_5: 10,
    hz_10: 11
  }

  # Presentation mode (0x80n0:02)
  @presentations %{
    signed: 0,
    absolute_msb_sign: 1,
    high_resolution: 2
  }

  defstruct [:master, :name, :channel_1, :channel_2]

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    config = opts[:config] || %{}

    state = %__MODULE__{
      master: opts[:master],
      name: opts[:name],
      channel_1: Map.get(config, :channel_1, %{}),
      channel_2: Map.get(config, :channel_2, %{})
    }

    {:ok, state}
  end

  # ============================================================================
  # Driver Behaviour Callbacks
  # ============================================================================

  @impl EtherCAT.Slave.Driver
  def configurable_pdos?(_state), do: false

  @impl EtherCAT.Slave.Driver
  def get_sdo_config(state) do
    build_sdo_config(state.channel_1, state.channel_2)
  end

  @impl EtherCAT.Slave.Driver
  def get_pdo_config(_state) do
    pdo_config()
  end

  @impl EtherCAT.Slave.Driver
  def encode_pdo_value(_pdo, _entry, _value, _state) do
    # EL3202 is input-only, no encoding needed
    {:error, :input_only_device}
  end

  @impl EtherCAT.Slave.Driver
  def decode_pdo_value(:rtd_channel_1, :value, <<value::little-signed-16>>, %{
        channel_1: %{rtd_element: :ohm_1_64}
      }) do
    {:ok, value / 64}
  end

  def decode_pdo_value(:rtd_channel_2, :value, <<value::little-signed-16>>, %{
        channel_2: %{rtd_element: :ohm_1_16}
      }) do
    {:ok, value / 16}
  end

  def decode_pdo_value(pdo, entry, binary, _state) do
    type = get_entry_type(pdo, entry)
    Driver.decode_by_type(type, binary)
  end

  # ============================================================================
  # SDO Configuration Builder
  # ============================================================================

  defp build_sdo_config(channel_1, channel_2) do
    build_channel_sdos(channel_1, 0) ++ build_channel_sdos(channel_2, 1)
  end

  defp build_channel_sdos(config, channel_index) do
    # Base index: 0x8000 for ch1, 0x8010 for ch2
    base = 0x8000 + channel_index * 0x10

    []
    |> add_sdo_if(config[:enable_user_scale], base, 0x01, <<1>>)
    |> add_presentation_sdo(config[:presentation], base)
    |> add_sdo_if(config[:siemens_bits], base, 0x05, <<1>>)
    |> add_sdo_if(config[:enable_filter], base, 0x06, <<1>>)
    |> add_sdo_if(config[:enable_limit_1], base, 0x07, <<1>>)
    |> add_sdo_if(config[:enable_limit_2], base, 0x08, <<1>>)
    |> add_sdo_if(config[:enable_user_calibration], base, 0x0A, <<1>>)
    |> add_manufacturer_calibration_sdo(config, base)
    |> add_user_scale_sdos(config, base)
    |> add_limit_sdos(config, base)
    |> add_filter_sdo(config, base, channel_index)
    |> add_user_calibration_sdos(config, base)
    |> add_rtd_element_sdo(config[:rtd_element], base)
    |> add_connection_sdo(config[:connection], base)
    |> add_wire_calibration_sdo(config[:wire_calibration], base)
    |> Enum.reverse()
  end

  defp add_sdo_if(sdos, true, index, subindex, data) do
    [SdoConfig.new(index: index, subindex: subindex, data: data) | sdos]
  end

  defp add_sdo_if(sdos, _, _index, _subindex, _data), do: sdos

  defp add_presentation_sdo(sdos, nil, _base), do: sdos

  defp add_presentation_sdo(sdos, presentation, base) do
    value = Map.get(@presentations, presentation, 0)
    [SdoConfig.new(index: base, subindex: 0x02, data: <<value::little-8>>) | sdos]
  end

  defp add_manufacturer_calibration_sdo(sdos, config, base) do
    # Default is enabled (true), so only write if explicitly disabled
    case config[:enable_manufacturer_calibration] do
      false -> [SdoConfig.new(index: base, subindex: 0x0B, data: <<0>>) | sdos]
      _ -> sdos
    end
  end

  defp add_user_scale_sdos(sdos, config, base) do
    if config[:enable_user_scale] do
      offset = config[:user_scale_offset] || 0
      gain = config[:user_scale_gain] || 65536

      sdos
      |> then(
        &[SdoConfig.new(index: base, subindex: 0x11, data: <<offset::little-signed-16>>) | &1]
      )
      |> then(
        &[SdoConfig.new(index: base, subindex: 0x12, data: <<gain::little-signed-32>>) | &1]
      )
    else
      sdos
    end
  end

  defp add_limit_sdos(sdos, config, base) do
    sdos
    |> maybe_add_limit(config[:enable_limit_1], config[:limit_1], base, 0x13)
    |> maybe_add_limit(config[:enable_limit_2], config[:limit_2], base, 0x14)
  end

  defp maybe_add_limit(sdos, true, limit, base, subindex) do
    value = limit || 0
    [SdoConfig.new(index: base, subindex: subindex, data: <<value::little-signed-16>>) | sdos]
  end

  defp maybe_add_limit(sdos, _, _, _, _), do: sdos

  # Filter settings only apply via channel 1 (0x8000:15) per docs
  defp add_filter_sdo(sdos, config, base, 0 = _channel_index) do
    if config[:enable_filter] do
      filter_key = config[:filter_settings] || :hz_50
      value = Map.get(@filter_settings, filter_key, 0)
      [SdoConfig.new(index: base, subindex: 0x15, data: <<value::little-16>>) | sdos]
    else
      sdos
    end
  end

  defp add_filter_sdo(sdos, _config, _base, _channel_index), do: sdos

  defp add_user_calibration_sdos(sdos, config, base) do
    if config[:enable_user_calibration] do
      offset = config[:user_calibration_offset] || 0
      gain = config[:user_calibration_gain] || 0xFFFF

      sdos
      |> then(
        &[SdoConfig.new(index: base, subindex: 0x17, data: <<offset::little-signed-16>>) | &1]
      )
      |> then(
        &[SdoConfig.new(index: base, subindex: 0x18, data: <<gain::little-unsigned-16>>) | &1]
      )
    else
      sdos
    end
  end

  defp add_rtd_element_sdo(sdos, nil, _base), do: sdos

  defp add_rtd_element_sdo(sdos, rtd_element, base) do
    value = Map.get(@rtd_elements, rtd_element, 0)
    [SdoConfig.new(index: base, subindex: 0x19, data: <<value::little-16>>) | sdos]
  end

  defp add_connection_sdo(sdos, nil, _base), do: sdos

  defp add_connection_sdo(sdos, connection, base) do
    value = Map.get(@connections, connection, 0)
    [SdoConfig.new(index: base, subindex: 0x1A, data: <<value::little-16>>) | sdos]
  end

  defp add_wire_calibration_sdo(sdos, nil, _base), do: sdos

  defp add_wire_calibration_sdo(sdos, wire_cal, base) do
    [SdoConfig.new(index: base, subindex: 0x1B, data: <<wire_cal::little-signed-16>>) | sdos]
  end

  # ============================================================================
  # Fixed PDO Configuration
  # ============================================================================

  defp pdo_config do
    [
      SyncManagerConfig.new(
        index: 3,
        direction: :input,
        watchdog: :disabled,
        pdos: [
          PdoConfig.new(
            index: 0x1A00,
            name: :rtd_channel_1,
            entries: %{
              underrange: {0x6000, 0x01, 1},
              overrange: {0x6000, 0x02, 1},
              limit_1: {0x6000, 0x03, 2},
              limit_2: {0x6000, 0x05, 2},
              error: {0x6000, 0x07, 1},
              gap: {0x0000, 0x00, 7},
              txpdo_state: {0x1800, 0x07, 1},
              txpdo_toggle: {0x1800, 0x09, 1},
              value: {0x6000, 0x11, 16}
            }
          ),
          PdoConfig.new(
            index: 0x1A01,
            name: :rtd_channel_2,
            entries: %{
              underrange: {0x6010, 0x01, 1},
              overrange: {0x6010, 0x02, 1},
              limit_1: {0x6010, 0x03, 2},
              limit_2: {0x6010, 0x05, 2},
              error: {0x6010, 0x07, 1},
              gap: {0x0000, 0x00, 7},
              txpdo_state: {0x1801, 0x07, 1},
              txpdo_toggle: {0x1801, 0x09, 1},
              value: {0x6010, 0x11, 16}
            }
          )
        ]
      )
    ]
  end

  # ============================================================================
  # Entry Type Mapping
  # ============================================================================

  defp get_entry_type(_pdo, :value), do: :int16
  defp get_entry_type(_pdo, :underrange), do: :bool
  defp get_entry_type(_pdo, :overrange), do: :bool
  defp get_entry_type(_pdo, :error), do: :bool
  defp get_entry_type(_pdo, :txpdo_state), do: :bool
  defp get_entry_type(_pdo, :txpdo_toggle), do: :bool
  defp get_entry_type(_pdo, :limit_1), do: :uint8
  defp get_entry_type(_pdo, :limit_2), do: :uint8
  defp get_entry_type(_pdo, _), do: :uint8
end
