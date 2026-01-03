defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT Master state machine.

  States:
  - `:offline`      - No link, polling for connection
  - `:stale`        - Link up, waiting for topology to stabilize
  - `:synced`       - Hardware verified, ready for configuration
  - `:operational`  - Cyclic task running, real-time I/O active
  """

  @behaviour :gen_statem
  require Logger

  alias EtherCAT.HardwareConfig

  # ============================================================================
  # Types and Constants
  # ============================================================================

  # Synchronous commands
  @cmd_request_master 1
  @cmd_release_master 2
  @cmd_get_link_state 3
  @cmd_scan_slaves 4
  @cmd_activate 5
  @cmd_deactivate 6
  @cmd_start_cyclic 7
  @cmd_stop_cyclic 8
  @cmd_set_cycle_time 9
  @cmd_get_slave_info 11
  @cmd_register_pdo 12
  @cmd_add_slave 13

  # Async commands
  @out_set_output 4

  # Timeouts
  # ms
  @link_poll_interval 1000
  # ms - how long topology must be stable
  @stability_timeout 1000
  # ms - monitoring interval in :synced
  @state_check_interval 100
  # ms - wait after link-up before scanning
  @link_debounce_ms 500

  defmodule Data do
    @moduledoc "State machine data"
    defstruct [
      :port,
      :cycle_time_us,
      # List of SlaveConfig structs for target topology
      target_slave_configs: [],
      # List of device_identity maps from actual hardware
      actual_device_identities: [],
      # slave_index => %{name, device_identity, driver_pid, pdos: %{entry_index => %{pdo_name, entry_name, ...}}}
      slaves: %{},
      # {cmd, ref} => from
      pending_commands: %{},
      # request_id => from
      pending_outputs: %{},
      last_slave_count: 0,
      link_up: false,
      # Track if we should auto-restart cyclic task after recovery
      auto_start_cyclic: false
    ]
  end

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  def child_spec(opts) do
    # Allow overriding id, start args, etc. via opts
    default = %{
      id: EtherCAT.Master,
      start: {EtherCAT.Master, :start_link, [opts]},
      # or :transient / :temporary depending on your needs
      restart: :permanent,
      # give it time to cleanly stop the EtherCAT cycle
      shutdown: 5000,
      type: :worker
    }

    Supervisor.child_spec(default, [])
  end

  @doc "Get current state"
  def get_state do
    :gen_statem.call(__MODULE__, :get_state)
  end

  @doc """
  Configure hardware from HardwareConfig struct.
  This replaces add_slave and register_pdo. Only valid in :synced state.
  Master will only stay in :synced if actual hardware matches the configuration.
  """
  def configure_hardware(%HardwareConfig{} = config) do
    :gen_statem.call(__MODULE__, {:configure_hardware, config}, 30_000)
  end

  @doc "Transition to operational state (start cyclic task)"
  def start_cyclic do
    :gen_statem.call(__MODULE__, :start_cyclic, 10_000)
  end

  @doc "Stop cyclic task and return to synced state"
  def stop_cyclic do
    :gen_statem.call(__MODULE__, :stop_cyclic, 10_000)
  end

  @doc """
  Write an output PDO value. Blocks until confirmed.
  Only valid in :operational state.
  Takes a tuple {slave_name, pdo_name, entry_name} as the first parameter.
  """
  def write_pdo({slave_name, pdo_name, entry_name}, value, timeout \\ 5000) do
    :gen_statem.call(__MODULE__, {:write_pdo, {slave_name, pdo_name, entry_name}, value}, timeout)
  end

  @doc """
  Read current value of a PDO (from cache).
  Takes a tuple {slave_name, pdo_name, entry_name} as parameter.
  """
  def read_pdo({slave_name, pdo_name, entry_name}) do
    :gen_statem.call(__MODULE__, {:read_pdo, {slave_name, pdo_name, entry_name}})
  end

  @doc "Force transition back to offline (for testing/recovery)"
  def reset do
    :gen_statem.call(__MODULE__, :reset, 10_000)
  end

  # ============================================================================
  # gen_statem Callbacks
  # ============================================================================

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    # Load driver
    priv_dir = :code.priv_dir(:ethercat) |> to_string()

    case :erl_ddll.load_driver(String.to_charlist(priv_dir), ~c"ethercat_driver") do
      :ok ->
        :ok

      {:error, :already_loaded} ->
        :ok

      {:error, reason} ->
        raise "Failed to load ethercat_driver: #{:erl_ddll.format_error(reason)}"
    end

    port = Port.open({:spawn_driver, ~c"ethercat_driver"}, [:binary])

    # Extract configuration options
    cycle_time_us = Keyword.get(opts, :cycle_time_us, 1_000)

    # Set cycle time
    :erlang.port_control(port, @cmd_set_cycle_time, <<cycle_time_us * 1000::little-64>>)

    data = %Data{
      port: port,
      cycle_time_us: cycle_time_us
    }

    {:ok, :offline, data}
  end

  # ============================================================================
  # State: offline
  # ============================================================================

  def offline(:enter, old_state, data) do
    # Only log and cleanup on actual state change, not re-entry
    if old_state != :offline do
      if old_state in [:operational, :synced] do
        Logger.warning("EtherCAT Master: entering offline state (link lost)")
      else
        Logger.info("EtherCAT Master: entering offline state")
      end

      # Terminate all driver processes before clearing state
      terminate_all_drivers(data.slaves)

      # Release master if we have one
      if data.port do
        :erlang.port_control(data.port, @cmd_release_master, <<>>)
      end
    end

    # Clear runtime state but ALWAYS preserve configuration for recovery
    # Keep: target_slave_configs, cycle_time_us, auto_start_cyclic
    # Clear: slaves (runtime), actual_device_identities, pending commands
    data = %{
      data
      | slaves: %{},
        actual_device_identities: [],
        last_slave_count: 0,
        link_up: false,
        pending_commands: %{},
        pending_outputs: %{}
    }

    # Log preserved configuration for debugging
    if old_state in [:operational, :synced] and data.target_slave_configs != [] do
      Logger.info(
        "EtherCAT Master: config preserved for #{length(data.target_slave_configs)} slaves, will auto-recover"
      )
    end

    # Start polling for link
    {:keep_state, data, [{:state_timeout, @link_poll_interval, :poll_link}]}
  end

  def offline(:state_timeout, :poll_link, data) do
    # Try to request master and check link
    case :erlang.port_control(data.port, @cmd_request_master, <<>>) do
      <<0::little-signed-32>> ->
        # Master requested successfully, check link
        case :erlang.port_control(data.port, @cmd_get_link_state, <<>>) do
          <<1::little-signed-32>> ->
            # Link is up! Wait for physical stability before scanning
            Logger.info("EtherCAT Master: link detected, waiting for stabilization")

            {:keep_state, %{data | link_up: true},
             [{:state_timeout, @link_debounce_ms, :verify_link_stable}]}

          _ ->
            # No link, release and retry
            :erlang.port_control(data.port, @cmd_release_master, <<>>)
            {:keep_state_and_data, [{:state_timeout, @link_poll_interval, :poll_link}]}
        end

      _ ->
        # Failed to request master, retry
        {:keep_state_and_data, [{:state_timeout, @link_poll_interval, :poll_link}]}
    end
  end

  def offline(:state_timeout, :verify_link_stable, data) do
    # Re-check link after debounce period
    case :erlang.port_control(data.port, @cmd_get_link_state, <<>>) do
      <<1::little-signed-32>> ->
        Logger.info("EtherCAT Master: link stable, transitioning to stale")
        {:next_state, :stale, data}

      _ ->
        Logger.warning("EtherCAT Master: link unstable during debounce, retrying")
        :erlang.port_control(data.port, @cmd_release_master, <<>>)

        {:keep_state, %{data | link_up: false},
         [{:state_timeout, @link_poll_interval, :poll_link}]}
    end
  end

  def offline({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :offline}]}
  end

  def offline({:call, from}, :reset, data) do
    Logger.info("EtherCAT Master: manual reset")

    {:keep_state, data, [{:reply, from, :ok}, {:state_timeout, @link_poll_interval, :poll_link}]}
  end

  def offline({:call, from}, {:configure_hardware, config}, data) do
    # Store the hardware config for later use when link comes up
    data = %{data | target_slave_configs: config.slaves}

    Logger.info(
      "EtherCAT Master: hardware config stored (#{length(config.slaves)} slaves), will apply when link is established"
    )

    {:keep_state, data, [{:reply, from, {:ok, :config_stored}}]}
  end

  def offline({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :offline}}]}
  end

  def offline(:info, msg, data) do
    handle_port_message(msg, :offline, data)
  end

  # ============================================================================
  # State: stale
  # ============================================================================

  def stale(:enter, _old_state, data) do
    Logger.info("EtherCAT Master: entering stale state, waiting for topology to stabilize")

    # Get initial slave count
    <<slave_count::little-signed-32>> =
      :erlang.port_control(data.port, @cmd_scan_slaves, <<>>)

    data = %{data | last_slave_count: slave_count}

    # Start stability timer
    {:keep_state, data, [{:state_timeout, @stability_timeout, :check_stability}]}
  end

  def stale(:state_timeout, :check_stability, data) do
    # Check if topology is still the same
    <<slave_count::little-signed-32>> =
      :erlang.port_control(data.port, @cmd_scan_slaves, <<>>)

    <<link_state::little-signed-32>> =
      :erlang.port_control(data.port, @cmd_get_link_state, <<>>)

    cond do
      link_state != 1 ->
        # Link went down
        Logger.warning("EtherCAT Master: link lost during stabilization")
        {:next_state, :offline, %{data | link_up: false}}

      slave_count != data.last_slave_count ->
        # Topology changed, reset timer
        Logger.debug(
          "EtherCAT Master: topology changed (#{data.last_slave_count} -> #{slave_count})"
        )

        {:keep_state, %{data | last_slave_count: slave_count},
         [{:state_timeout, @stability_timeout, :check_stability}]}

      # Only transition to synced if hardware config is set AND matches
      data.target_slave_configs == [] ->
        # No hardware config set yet, stay in stale and keep checking
        Logger.debug(
          "EtherCAT Master: topology stable with #{slave_count} slaves, waiting for hardware config"
        )

        {:keep_state_and_data, [{:state_timeout, @state_check_interval, :check_stability}]}

      length(data.target_slave_configs) != slave_count ->
        # Hardware config doesn't match slave count, stay in stale
        Logger.warning(
          "EtherCAT Master: topology stable with #{slave_count} slaves, but config expects #{length(data.target_slave_configs)}"
        )

        {:keep_state_and_data, [{:state_timeout, @state_check_interval, :check_stability}]}

      true ->
        # Scan actual device identities and verify they match config
        actual_identities = scan_slave_identities(data.port, slave_count)

        if hardware_matches?(data.target_slave_configs, actual_identities) do
          # Hardware matches! Transition to synced
          Logger.info(
            "EtherCAT Master: topology stable with #{slave_count} slaves, hardware verified"
          )

          {:next_state, :synced, %{data | actual_device_identities: actual_identities}}
        else
          # Hardware doesn't match config
          Logger.warning(
            "EtherCAT Master: topology stable but hardware does not match configuration"
          )

          {:keep_state_and_data, [{:state_timeout, @state_check_interval, :check_stability}]}
        end
    end
  end

  def stale({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :stale}]}
  end

  def stale({:call, from}, :reset, data) do
    {:next_state, :offline, %{data | auto_start_cyclic: false}, [{:reply, from, :ok}]}
  end

  def stale({:call, from}, {:configure_hardware, config}, data) do
    # Store the hardware config for later verification
    data = %{data | target_slave_configs: config.slaves}
    {:keep_state, data, [{:reply, from, {:ok, :config_stored}}]}
  end

  def stale({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :stale}}]}
  end

  def stale(:info, {:ecat_link, :down}, data) do
    Logger.warning("EtherCAT Master: link lost in stale (from C driver message)")
    {:next_state, :offline, %{data | link_up: false}}
  end

  def stale(:info, {:ecat_slaves, count}, data) do
    if count != data.last_slave_count do
      # Reset stability timer
      {:keep_state, %{data | last_slave_count: count},
       [{:state_timeout, @stability_timeout, :check_stability}]}
    else
      :keep_state_and_data
    end
  end

  def stale(:info, msg, data) do
    handle_port_message(msg, :stale, data)
  end

  # ============================================================================
  # State: synced
  # ============================================================================

  def synced(:enter, _old_state, data) do
    Logger.info("EtherCAT Master: entering synced state, configuring slaves")

    # Configure each slave sequentially
    slaves =
      data.target_slave_configs
      |> Enum.with_index()
      |> Enum.map(fn {slave_config, slave_index} ->
        device_identity = Enum.at(data.actual_device_identities, slave_index)

        slave_info =
          configure_and_register_slave(slave_config, slave_index, device_identity, data.port)

        {slave_index, slave_info}
      end)
      |> Map.new()

    Logger.info("EtherCAT Master: slave configuration complete")

    data = %{data | slaves: slaves}

    # Auto-start cyclic task if recovering from link loss
    if data.auto_start_cyclic do
      Logger.info("EtherCAT Master: auto-starting cyclic task after recovery")

      # Activate master first
      case :erlang.port_control(data.port, @cmd_activate, <<>>) do
        <<0::little-signed-32>> ->
          Logger.info("EtherCAT Master: slaves activated to OP state")

          # Then start cyclic task
          case :erlang.port_control(data.port, @cmd_start_cyclic, <<>>) do
            <<0::little-signed-32>> ->
              {:next_state, :operational, data}

            <<err::little-signed-32>> ->
              Logger.error("EtherCAT Master: failed to auto-start cyclic: #{err}, deactivating")
              safe_deactivate(data.port)
              {:keep_state, data, [{:state_timeout, @state_check_interval, :monitor}]}
          end

        <<err::little-signed-32>> ->
          Logger.error("EtherCAT Master: failed to activate slaves: #{err}, returning to offline")
          {:next_state, :offline, %{data | auto_start_cyclic: false}}
      end
    else
      # Don't activate yet - wait for manual start_cyclic call
      {:keep_state, data, [{:state_timeout, @state_check_interval, :monitor}]}
    end
  end

  def synced(:state_timeout, :monitor, data) do
    # Check link and slave count
    <<link_state::little-signed-32>> =
      :erlang.port_control(data.port, @cmd_get_link_state, <<>>)

    <<slave_count::little-signed-32>> =
      :erlang.port_control(data.port, @cmd_scan_slaves, <<>>)

    cond do
      link_state != 1 ->
        Logger.warning("EtherCAT Master: link lost")
        {:next_state, :offline, %{data | link_up: false}}

      slave_count != data.last_slave_count ->
        Logger.warning("EtherCAT Master: topology changed, returning to stale")
        {:next_state, :stale, %{data | last_slave_count: slave_count}}

      true ->
        {:keep_state_and_data, [{:state_timeout, @state_check_interval, :monitor}]}
    end
  end

  def synced({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :synced}]}
  end

  def synced({:call, from}, {:configure_hardware, config}, data) do
    # Store target slave configurations and transition to stale to re-verify
    data = %{data | target_slave_configs: config.slaves}
    {:next_state, :stale, data, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, :start_cyclic, data) do
    # Activate master first
    case :erlang.port_control(data.port, @cmd_activate, <<>>) do
      <<0::little-signed-32>> ->
        Logger.info("EtherCAT Master: slaves activated to OP state")

        # Then start cyclic task
        case :erlang.port_control(data.port, @cmd_start_cyclic, <<>>) do
          <<0::little-signed-32>> ->
            {:next_state, :operational, data, [{:reply, from, :ok}]}

          <<err::little-signed-32>> ->
            Logger.error("EtherCAT Master: failed to start cyclic task, deactivating")
            safe_deactivate(data.port)
            {:keep_state_and_data, [{:reply, from, {:error, {:start_cyclic, err}}}]}
        end

      <<err::little-signed-32>> ->
        {:keep_state_and_data, [{:reply, from, {:error, {:activate, err}}}]}
    end
  end

  def synced({:call, from}, {:read_pdo, {slave_name, pdo_name, entry_name}}, data) do
    result = do_read_pdo({slave_name, pdo_name, entry_name}, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, :reset, data) do
    # Master not activated in synced state, no need to deactivate
    # Clear auto-start flag since this is a manual reset
    {:next_state, :offline, %{data | auto_start_cyclic: false}, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, {:write_pdo, _, _}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_operational}}]}
  end

  def synced(:info, {:ecat_link, :down}, data) do
    Logger.warning("EtherCAT Master: link lost in synced (from C driver message)")
    {:next_state, :offline, %{data | link_up: false}}
  end

  def synced(:info, {:ecat_slaves, count}, data) when count != data.last_slave_count do
    Logger.warning("EtherCAT Master: topology changed")
    {:next_state, :stale, %{data | last_slave_count: count}}
  end

  def synced(:info, msg, data) do
    handle_port_message(msg, :synced, data)
  end

  # ============================================================================
  # State: operational
  # ============================================================================

  def operational(:enter, _old_state, data) do
    Logger.info("EtherCAT Master: entering operational state")
    # Set flag so we auto-restart after recovery
    {:keep_state, %{data | auto_start_cyclic: true}}
  end

  def operational({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :operational}]}
  end

  def operational({:call, from}, {:write_pdo, {slave_name, pdo_name, entry_name}, value}, data) do
    case Enum.find(data.slaves, fn {_idx, info} -> info.name == slave_name end) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_slave}}]}

      {_slave_idx, slave_info} ->
        case Enum.find(slave_info.pdos, fn {_idx, info} ->
               info.pdo_name == pdo_name and info.entry_name == entry_name
             end) do
          nil ->
            {:keep_state_and_data, [{:reply, from, {:error, :unknown_pdo}}]}

          {_entry_index, %{direction: :input}} ->
            {:keep_state_and_data, [{:reply, from, {:error, :not_an_output}}]}

          {entry_index, %{bit_length: bit_length}} ->
            byte_len = div(bit_length + 7, 8)
            value_bin = <<value::little-size(byte_len * 8)>>

            cmd_data =
              <<
                @out_set_output::8,
                entry_index::little-16,
                bit_length::8,
                value_bin::binary
              >>

            Port.command(data.port, cmd_data)

            # We'll get a request_id back, then wait for confirmation
            ref = make_ref()
            pending = Map.put(data.pending_commands, {:set_output_init, ref}, from)
            {:keep_state, %{data | pending_commands: pending}}
        end
    end
  end

  def operational({:call, from}, {:read_pdo, {slave_name, pdo_name, entry_name}}, data) do
    result = do_read_pdo({slave_name, pdo_name, entry_name}, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational({:call, from}, :stop_cyclic, data) do
    safe_deactivate(data.port)
    # Clear auto-start flag since this is a manual stop
    {:next_state, :stale, %{data | auto_start_cyclic: false}, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, :reset, data) do
    safe_deactivate(data.port)
    # Clear auto-start flag since this is a manual reset
    {:next_state, :offline, %{data | auto_start_cyclic: false}, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, {:configure_hardware, _config}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :must_stop_cyclic_first}}]}
  end

  def operational({:call, from}, :start_cyclic, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_operational}}]}
  end

  def operational(:info, {:ecat_pdo, slave_index, entry_index, value}, data) do
    # O(1) lookup by slave_index
    case Map.get(data.slaves, slave_index) do
      nil ->
        :keep_state_and_data

      slave_info ->
        # O(1) lookup by entry_index within slave's PDOs
        case Map.get(slave_info.pdos, entry_index) do
          nil ->
            :keep_state_and_data

          pdo_info ->
            # Update cached value
            updated_pdo = %{pdo_info | value: value}
            updated_pdos = Map.put(slave_info.pdos, entry_index, updated_pdo)
            updated_slave = %{slave_info | pdos: updated_pdos}
            updated_slaves = Map.put(data.slaves, slave_index, updated_slave)

            # Notify driver if present
            if slave_info.driver_pid do
              pdo_key = {slave_info.name, pdo_info.pdo_name, pdo_info.entry_name}
              send(slave_info.driver_pid, {:ecat_pdo, pdo_key, value})
            end

            {:keep_state, %{data | slaves: updated_slaves}}
        end
    end
  end

  def operational(:info, {:ecat_output_confirmed, request_id}, data) do
    case Map.pop(data.pending_outputs, request_id) do
      {nil, _} ->
        :keep_state_and_data

      {from, pending} ->
        :gen_statem.reply(from, :ok)
        {:keep_state, %{data | pending_outputs: pending}}
    end
  end

  def operational(:info, {:ecat_link, :down}, data) do
    Logger.error("EtherCAT Master: link lost during operation (from C driver message)")
    safe_deactivate(data.port)
    {:next_state, :offline, %{data | link_up: false}}
  end

  def operational(:info, {:ecat_slaves, count}, data) when count != data.last_slave_count do
    Logger.error("EtherCAT Master: topology changed during operation!")
    safe_deactivate(data.port)
    {:next_state, :stale, %{data | last_slave_count: count}}
  end

  def operational(:info, {:ecat_stats, cycles, min_lat, max_lat, avg_lat, overruns}, data) do
    min_lat = Float.round(min_lat / (1000 * data.cycle_time_us) * 100, 2)
    max_lat = Float.round(max_lat / (1000 * data.cycle_time_us) * 100, 2)
    avg_lat = Float.round(avg_lat / (1000 * data.cycle_time_us) * 100, 2)

    if overruns > 0 do
      Logger.warning(
        "EtherCAT: #{cycles} cycles, latency #{min_lat}%/#{avg_lat}%/#{max_lat}%, #{overruns} overruns"
      )
    else
      Logger.debug("EtherCAT: #{cycles} cycles, latency #{min_lat}%/#{avg_lat}%/#{max_lat}%")
    end

    :keep_state_and_data
  end

  def operational(:info, msg, data) do
    handle_port_message(msg, :operational, data)
  end

  # ============================================================================
  # Common Handlers
  # ============================================================================

  defp handle_port_message({:ecat_response, @out_set_output, request_id}, _state, data)
       when request_id >= 0 do
    # This is the initial response with request_id
    case find_pending(:set_output_init, data) do
      {from, pending} ->
        outputs = Map.put(data.pending_outputs, request_id, from)
        {:keep_state, %{data | pending_commands: pending, pending_outputs: outputs}}

      nil ->
        :keep_state_and_data
    end
  end

  defp handle_port_message({:ecat_response, @out_set_output, error}, _state, data) do
    case find_pending(:set_output_init, data) do
      {from, pending} ->
        :gen_statem.reply(from, {:error, error})
        {:keep_state, %{data | pending_commands: pending}}

      nil ->
        :keep_state_and_data
    end
  end

  defp handle_port_message({:ecat_error, msg}, _state, _data) do
    Logger.error("EtherCAT driver error: #{msg}")
    :keep_state_and_data
  end

  defp handle_port_message(_msg, _state, _data) do
    :keep_state_and_data
  end

  defp find_pending(cmd, data) do
    Enum.find_value(data.pending_commands, fn
      {{^cmd, _ref}, from} = entry ->
        {from, Map.delete(data.pending_commands, elem(entry, 0))}

      _ ->
        nil
    end)
  end

  defp do_read_pdo({slave_name, pdo_name, entry_name}, data) do
    case Enum.find(data.slaves, fn {_idx, info} -> info.name == slave_name end) do
      nil ->
        {:error, :unknown_slave}

      {_slave_idx, slave_info} ->
        case Enum.find(slave_info.pdos, fn {_idx, info} ->
               info.pdo_name == pdo_name and info.entry_name == entry_name
             end) do
          nil ->
            {:error, :unknown_pdo}

          {_entry_idx, pdo_info} ->
            {:ok, pdo_info.value}
        end
    end
  end

  defp terminate_all_drivers(slaves) do
    Enum.each(slaves, fn {_idx, slave_info} ->
      if slave_info.driver_pid && Process.alive?(slave_info.driver_pid) do
        Logger.debug("Terminating driver for slave: #{slave_info.name}")
        GenServer.stop(slave_info.driver_pid, :shutdown, 5_000)
      end
    end)
  end

  defp safe_deactivate(port) do
    :erlang.port_control(port, @cmd_stop_cyclic, <<>>)
    :erlang.port_control(port, @cmd_deactivate, <<>>)
    :ok
  end

  # ============================================================================
  # Hardware Configuration Helpers
  # ============================================================================

  defp scan_slave_identities(port, slave_count) do
    0..(slave_count - 1)
    |> Enum.map(fn position ->
      case :erlang.port_control(port, @cmd_get_slave_info, <<position::little-16>>) do
        <<vendor_id::little-32, product_code::little-32, revision_no::little-32,
          serial_no::little-32>> ->
          %{
            vendor_id: vendor_id,
            product_code: product_code,
            revision_no: revision_no,
            serial_no: serial_no
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp hardware_matches?(target_slave_configs, actual_device_identities)
       when target_slave_configs == [] or actual_device_identities == [], do: false

  defp hardware_matches?(target_slave_configs, actual_device_identities) do
    # Check slave count matches
    if length(target_slave_configs) != length(actual_device_identities) do
      false
    else
      # Check each slave's device_identity matches (order-dependent)
      target_slave_configs
      |> Enum.zip(actual_device_identities)
      |> Enum.all?(fn {%HardwareConfig.SlaveConfig{device_identity: target_identity},
                       actual_identity} ->
        devices_match?(target_identity, actual_identity)
      end)
    end
  end

  defp devices_match?(target, actual) do
    target.vendor_id == actual.vendor_id and
      target.product_code == actual.product_code and
      (is_nil(target.revision_no) or target.revision_no == actual.revision_no) and
      (is_nil(target.serial_no) or target.serial_no == actual.serial_no)
  end

  # ============================================================================
  # Slave Configuration Helpers
  # ============================================================================

  defp configure_and_register_slave(slave_config, slave_index, device_identity, port) do
    Logger.debug("Configuring slave #{slave_index}: #{slave_config.name}")

    alias = 0x0000

    # Step 1: Add slave to EtherCAT master
    identity = device_identity

    cmd_data = <<
      alias::little-16,
      slave_index::little-16,
      identity.vendor_id::little-32,
      identity.product_code::little-32
    >>

    case :erlang.port_control(port, @cmd_add_slave, cmd_data) do
      <<result::little-signed-32>> when result >= 0 ->
        Logger.debug("  Added slave to master (index: #{result})")

      <<error::little-signed-32>> ->
        Logger.error("  Failed to add slave to master: #{error}")
        raise "Failed to add slave #{slave_config.name} to EtherCAT master"
    end

    # Step 2: Start driver
    driver_pid =
      if slave_config.driver do
        case slave_config.driver.start_driver(slave_config.name, slave_config.config) do
          {:ok, pid} ->
            Logger.debug("  Started driver: #{inspect(slave_config.driver)}")
            pid

          error ->
            Logger.warning("  Failed to start driver: #{inspect(error)}")
            nil
        end
      else
        nil
      end

    # Step 2: Configure SDOs
    if driver_pid && slave_config.driver do
      sdos = slave_config.driver.get_sdo_config(driver_pid)

      for sdo <- sdos do
        Logger.debug("  SDO: 0x#{Integer.to_string(sdo.index, 16)}:#{sdo.subindex}")
        # TODO: Send SDO write to C driver
      end
    end

    # Step 3: Configure PDO mapping
    if driver_pid && slave_config.driver do
      sync_managers = slave_config.driver.get_pdo_config(driver_pid)

      for sm <- sync_managers do
        Logger.debug(
          "  SyncManager #{sm.index}: #{length(sm.pdos)} PDOs, direction: #{sm.direction}"
        )

        # TODO: Send PDO mapping to C driver
      end
    end

    # Step 4: Register PDO entries from registered_entries
    pdos =
      if driver_pid && slave_config.driver do
        sync_managers = slave_config.driver.get_pdo_config(driver_pid)

        slave_config.registered_entries
        |> Enum.flat_map(fn {_domain, entries} -> entries end)
        |> Enum.reduce(%{}, fn {pdo_name, entry_name, deadband, interval_us}, acc ->
          # Find the PDO and entry in sync_managers to get technical details
          case find_pdo_entry(sync_managers, pdo_name, entry_name) do
            {:ok, {pdo_index, subindex, bit_length, direction}} ->
              # Register with C driver (synchronous - waits for entry_index)
              case register_pdo(
                     port,
                     slave_index,
                     pdo_index,
                     subindex,
                     bit_length,
                     direction,
                     deadband,
                     interval_us,
                     pdo_name,
                     entry_name
                   ) do
                {:ok, entry_index} ->
                  # Notify driver
                  case slave_config.driver.register_pdo_entry(driver_pid, pdo_name, entry_name) do
                    :ok ->
                      Logger.debug("  Registered #{pdo_name}.#{entry_name}")

                    {:error, reason} ->
                      Logger.warning(
                        "  Driver failed to register #{pdo_name}.#{entry_name}: #{inspect(reason)}"
                      )
                  end

                  # Add PDO info to map
                  pdo_info = %{
                    pdo_name: pdo_name,
                    entry_name: entry_name,
                    bit_length: bit_length,
                    direction: direction,
                    deadband: deadband,
                    interval_us: interval_us,
                    value: nil
                  }

                  Map.put(acc, entry_index, pdo_info)

                {:error, reason} ->
                  Logger.error(
                    "  Failed to register #{pdo_name}.#{entry_name}: #{inspect(reason)}"
                  )

                  acc
              end

            :not_found ->
              Logger.warning("  PDO entry #{pdo_name}.#{entry_name} not found in driver config")
              acc
          end
        end)
      else
        %{}
      end

    # Return slave_info
    %{
      name: slave_config.name,
      device_identity: device_identity,
      driver_pid: driver_pid,
      pdos: pdos
    }
  end

  defp find_pdo_entry(sync_managers, pdo_name, entry_name) do
    Enum.find_value(sync_managers, :not_found, fn sm ->
      Enum.find_value(sm.pdos, fn pdo ->
        if pdo.name == pdo_name do
          case Map.get(pdo.entries, entry_name) do
            {pdo_index, subindex, bit_length} ->
              {:ok, {pdo_index, subindex, bit_length, sm.direction}}

            nil ->
              nil
          end
        end
      end)
    end)
  end

  defp register_pdo(
         port,
         slave_index,
         pdo_index,
         subindex,
         bit_length,
         direction,
         deadband,
         interval_us,
         _pdo_name,
         _entry_name
       ) do
    is_output_byte = if direction == :output, do: 1, else: 0

    cmd_data =
      <<
        slave_index::little-16,
        pdo_index::little-16,
        subindex::8,
        bit_length::8,
        is_output_byte::8,
        0::8,
        deadband::little-64,
        interval_us::little-64
      >>

    case :erlang.port_control(port, @cmd_register_pdo, cmd_data) do
      <<entry_index::little-signed-32>> when entry_index >= 0 ->
        {:ok, entry_index}

      <<error_code::little-signed-32>> ->
        {:error, error_code}
    end
  end
end
