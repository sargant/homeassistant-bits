# Calibrated Appliance Monitor

A deliberately small custom integration for appliance-specific power-profile
detection. Version 0.2 contains calibrations for the Indesit D2IHL326UK
dishwasher and Hoover HBDOS695TAMCE-80 washer-dryer.

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

The public surface is deliberately small: **Cycle phase** and **Running**. Cycle
phase exposes only meaningful appliance lifecycle states; Running is the simpler
yes/no view for consumers that do not care about the detailed phase.

For the dishwasher, cycle phase is `Idle`, `Starting`, `Running`, `Ending`,
`Finish pending`, and `Finished`.

For the washer-dryer, uncertainty is deliberately kept internal and cycle phase
is only `Idle`, `Washing`, `Drying`, and `Finished`. A hidden >10 W start
candidate is confirmed by >30 W activity within a three-minute window. Drying is
latched after 10 seconds in the calibrated 700–1300 W dryer band. Finish is
backdated to the first <10 W sample after 60 seconds of quiet while washing, or
10 seconds once drying has been seen. `Finished` remains visible for at least 60
seconds; after that it returns to `Idle` below 1 W, with a hard maximum of 10
minutes.

Cycle metadata is carried as attributes on **Cycle phase** rather than separate
entities: `last_started`, `last_finished`, and `last_cycle_energy_kwh`.
Washer-dryer entries also expose `last_cycle_outcome`, classified as `Washing`,
`Drying only`, or `Washing + drying`. The drying-only boundary is currently two
minutes from the retrospective cycle start and is intentionally easy to
recalibrate in the algorithm module.

For the dishwasher, `last_started` is populated only once >30 W confirms the
cycle and retains the retrospective candidate timestamp. The energy value is the
consumption derived for the most recently completed cycle; the source smart plug
remains the proper place for overall energy history.

Algorithm bookkeeping is exposed separately as diagnostic entities. For the
dishwasher these currently include **Start time candidate**, **Starting energy
candidate**, and **Cycle start energy**. They are enabled and visible by default
so the detector's retrospective decisions remain easy to inspect while still
being clearly classified as diagnostics. Washer-dryer start, drying and finish
candidates remain entirely internal so they never become part of its public
state model.

Thresholds and state machines are intentionally fixed in each algorithm module
rather than exposed as tuning options.

The integration only publishes appliance state and cycle facts. Notifications,
recipient selection, electricity pricing and message formatting belong in normal
Home Assistant automations outside the integration.
