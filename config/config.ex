import Config

# EtherCAT Master configuration
config :ethercat,
  # Default cycle time in microseconds
  cycle_time_us: 1000,

  # Real-time thread settings
  rt_priority: 80,
  rt_cpu_affinity: 1

# Environment-specific configuration
import_config "#{config_env()}.exs"
