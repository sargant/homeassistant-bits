# Calibrated Appliance Monitor

A deliberately small custom integration for appliance-specific power-profile
detection. Version 0.1 contains one calibration: the Indesit D2IHL326UK
dishwasher.

Each monitored appliance is a separate config entry and owns its own virtual
Home Assistant device. Appliance-specific thresholds and state machines live in
`algorithms/`; the integration lifecycle and entity platforms stay generic.

## Setup

1. Copy this directory to `/config/custom_components/calibrated_appliance_monitor`.
2. Restart Home Assistant.
3. Add **Calibrated Appliance Monitor** from **Settings → Devices & services**.
   Adding it asks no questions and creates an empty config entry.
4. Choose **Configure** for that entry and select:
   - the smart plug measuring the appliance;
   - the calibrated appliance algorithm.

After configuration, the entry is named for the appliance and the integration
creates its virtual device. Power and cumulative-energy sensors are discovered
automatically from the selected smart-plug device.

The only algorithm currently available is **Indesit D2IHL326UK dishwasher**.
Its thresholds and state machine are intentionally fixed in its algorithm module
rather than exposed as tuning options.

The integration only publishes appliance state and cycle facts. Notifications,
recipient selection, electricity pricing and message formatting belong in normal
Home Assistant automations outside the integration.
