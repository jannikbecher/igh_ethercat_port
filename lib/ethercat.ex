defmodule EtherCAT do
  @moduledoc """
  This module is the public API for the EtherCAT library.

  EtherCAT.wait_for_state(:synced)
  EtherCAT.configure_hardware()
  """

  alias EtherCAT.Master

  @doc """
  Configure the EtherCAT hardware.
  """
  @spec configure_hardware(module(), EtherCAT.HardwareConfig.t()) :: :ok | {:error, term()}
  def configure_hardware(master \\ EtherCAT.Master, hardware_config) do
    master.configure_hardware(hardware_config)
  end

  @doc """
  Wait for the master to reach a specific state.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 30000)

  ## Examples

      :synced = EtherCAT.wait_for_state(:synced)
      {:error, :timeout} = EtherCAT.wait_for_state(:operational, timeout: 100)
  """
  @spec wait_for_state(atom(), keyword()) :: atom() | {:error, :timeout}
  def wait_for_state(target_state, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_state(target_state, deadline)
  end

  defp do_wait_for_state(target, deadline) do
    case Master.get_state() do
      ^target ->
        target

      _other ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_wait_for_state(target, deadline)
        end
    end
  end
end
