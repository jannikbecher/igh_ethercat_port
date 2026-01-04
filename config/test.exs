import Config

# Test environment uses fake EtherCAT driver for testing without hardware
config :ethercat,
  driver: :fake

# Optional: Configure fake EtherCAT environment variables
# These would be set by test_helper.exs if needed:
# - FAKE_EC_HOMEDIR: Directory for RtIPC bulletin board and SDO json files
# - FAKE_EC_NAME: Name for RtIPC config and SDO json file
# - FAKE_EC_PREFIX: Prefix for RtIPC variables
