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
4. Home Assistant creates the appliance entry and immediately continues into
   **Appliance configuration**. Select:
   - the smart plug measuring the appliance;
   - the calibrated appliance algorithm.

After configuration, the entry is named for the appliance and the integration
creates its virtual device. Power and cumulative-energy sensors are discovered
automatically from the selected smart-plug device.

The public dishwasher surface is deliberately small: **Phase**, **Running**,
**Last started**, **Last finished**, and **Last cycle energy**. Candidate
detection remains private until it is confirmed, so the public appliance stays
Idle / not running during the dishwasher's `Starting` detector state.

Algorithm internals are exposed separately as disabled-by-default diagnostic
entities. For the dishwasher these currently include **Cycle state**,
**Candidate started**, **Candidate start energy**, and **Cycle start energy**.
They are useful while calibrating or debugging the detector but are not required
for normal automations or notifications.

The only algorithm currently available is **Indesit D2IHL326UK dishwasher**.
Its thresholds and state machine are intentionally fixed in its algorithm module
rather than exposed as tuning options.

The integration only publishes appliance state and cycle facts. Notifications,
recipient selection, electricity pricing and message formatting belong in normal
Home Assistant automations outside the integration.
