# Calibrated Appliance Monitor

Home Assistant integration for appliance-specific cycle detection from smart-plug
power and energy data, with algorithms derived by ChatGPT from recorded appliance
traces.

Current calibrations:

- Indesit D2IHL326UK dishwasher
- Hoover HBDOS695TAMCE-80 washer-dryer

## Setup

1. Copy this directory to `/config/custom_components/calibrated_appliance_monitor`.
2. Restart Home Assistant.
3. Add **Calibrated Appliance Monitor** from **Settings → Devices & services**.
4. Select the smart plug and appliance calibration.

Power and cumulative-energy sensors are discovered from the selected smart-plug
device. To change the plug or calibration, remove the entry and add it again.

## Entities

Every monitor exposes:

- **Cycle phase**
- **Running**

Dishwasher phases: `Idle`, `Starting`, `Running`, `Ending`, `Finish pending`,
`Finished`.

Washer-dryer phases: `Idle`, `Washing`, `Drying`, `Finished`.

**Cycle phase** also carries `last_started`, `last_finished`, and
`last_cycle_energy_kwh`. Washer-dryer entries additionally expose
`last_cycle_outcome`: `Washing`, `Drying`, or `Washing + drying`.

## Diagnostics

Both calibrations expose:

- **Cycle start candidate**
- **Cycle start energy candidate**
- **Cycle start energy**

The washer-dryer also exposes:

- **Drying start candidate** — hidden by default
- **Drying start time**
- **Cycle finish candidate** — hidden by default

Hidden diagnostics remain enabled and recorded. Visibility defaults only affect
newly created registry entries.

Thresholds and state machines live in `algorithms/` and are intentionally fixed
per appliance. Notifications and pricing stay in normal Home Assistant
automations.
