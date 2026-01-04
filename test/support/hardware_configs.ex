defmodule HardwareConfigs do
  @moduledoc """
  Simplified hardware configuration for basic digital I/O testing with multi-domain support.

  Physical Hardware Setup:
  - Position 0: EK1100 EtherCAT Coupler (Vendor: 0x00000002, Product: 0x044c2c52)
  - Position 1: EL1809 16-channel digital input (24V DC)
  - Position 2: EL2809 16-channel digital output (24V DC, 0.5A)

  Wiring:
  - Each EL2809 output channel is connected to the corresponding EL1809 input channel
    (Output Ch1 → Input Ch1, Output Ch2 → Input Ch2, etc.)

  Domain Configuration:
  - :fast domain (cycle_multiplier=1, every cycle = 10ms)
    - Input channels 1-16
    - Output channels 1-16

  Note: In IgH EtherCAT, once a slave's sync managers are configured, ALL of them
  must be registered to the SAME domain. You cannot split a slave's SMs across domains.
  Both EL1809 and EL2809 must have all their channels in one domain.
  """

  alias EtherCAT.HardwareConfig

  def simple_hardware_config do
    %HardwareConfig{
      slaves: [
        # EK1100 - EtherCAT Coupler at position 0
        %{
          name: :coupler,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x044C2C52,
            revision_no: nil,
            serial_no: nil
          },
          driver: nil,
          config: %{
            sync_managers: [],
            sdos: []
          },
          registered_entries: %{}
        },
        # EL1809 - 16-channel digital input at position 1
        %{
          name: :digital_inputs,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x07113052,
            revision_no: nil,
            serial_no: nil
          },
          driver: GenericDriver,
          config: %{
            sdos: [],
            sync_managers: [
              %{
                index: 3,
                direction: :input,
                watchdog: :disabled,
                pdos:
                  for ch <- 1..16 do
                    %{
                      index: 0x1A00 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        input: {0x6000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              }
            ]
          },
          registered_entries: %{
            # EL1809 has single SM with all 16 channels - cannot be split across domains
            # All channels must go to ONE domain to avoid double allocation
            fast:
              for ch <- 1..16 do
                {:"channel_#{ch}", :input, 0, 0}
              end
          }
        },
        # EL2809 - 16-channel digital output at position 2
        %{
          name: :digital_outputs,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x0AF93052,
            revision_no: nil,
            serial_no: nil
          },
          driver: GenericDriver,
          config: %{
            sdos: [],
            sync_managers: [
              # First 8 channels in SM0
              %{
                index: 0,
                direction: :output,
                watchdog: :enabled,
                pdos:
                  for ch <- 1..8 do
                    %{
                      index: 0x1600 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              },
              # Second 8 channels in SM1
              %{
                index: 1,
                direction: :output,
                watchdog: :enabled,
                pdos:
                  for ch <- 9..16 do
                    %{
                      index: 0x1600 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              }
            ]
          },
          registered_entries: %{
            # EL1809 has single SM with all 16 channels - cannot be split across domains
            # All channels must go to ONE domain to avoid double allocation
            fast:
              for ch <- 1..16 do
                {:"channel_#{ch}", :output, 0, 0}
              end
          }
        }
      ]
    }
  end
end
