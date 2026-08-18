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

After configuration, the entry is named for the selected appliance model and the
integration creates its logical appliance device. Power and cumulative-energy
sensors are discovered automatically from the selected smart-plug device.

The public dishwasher surface is deliberately small: **Cycle phase** and
**Running**. Cycle phase exposes the algorithm's meaningful lifecycle directly;
for the current dishwasher calibration that is `Idle`, `Starting`, `Running`,
`Ending`, `Finish pending`, and `Finished`. Running is the simpler yes/no view
for consumers that do not care about the detailed phase.

Cycle metadata is carried as attributes on **Cycle phase** rather than separate
entities: `last_started`, `last_finished`, and `last_cycle_energy_kwh`.
`last_started` is populated only once >30 W confirms the cycle and retains the
retrospective candidate timestamp. The energy value is the consumption derived
for the most recently completed cycle; the source smart plug remains the proper
place for overall energy history.

Algorithm bookkeeping is exposed separately as disabled-by-default diagnostic
entities. For the dishwasher these currently include **Start time candidate**,
**Starting energy candidate**, and **Cycle start energy**. They are useful while
calibrating or debugging the detector but are not required for normal
automations or notifications.

The only algorithm currently available is **Indesit D2IHL326UK dishwasher**.
Its thresholds and state machine are intentionally fixed in its algorithm module
rather than exposed as tuning options.

The integration only publishes appliance state and cycle facts. Notifications,
recipient selection, electricity pricing and message formatting belong in normal
Home Assistant automations outside the integration.
