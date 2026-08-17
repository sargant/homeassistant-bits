# Calibrated Appliance Monitor

A deliberately small custom integration for appliance-specific power-profile
detection. Version 0.1 contains one calibration: the Indesit D2IHL326UK
dishwasher.

## Setup

1. Copy this directory to `/config/custom_components/calibrated_appliance_monitor`.
2. Restart Home Assistant.
3. Add **Calibrated Appliance Monitor** from **Settings → Devices & services**.
   Adding it asks no questions and creates the **Dishwasher** entry/device.
4. Open the integration and choose **Configure**. Select:
   - the smart plug measuring the appliance;
   - the calibrated appliance algorithm;
   - the sensor containing the current electricity unit rate.

Power and cumulative-energy sensors are discovered automatically from the
selected smart-plug device.

The only algorithm currently available is **Indesit D2IHL326UK dishwasher**.
Its thresholds and state machine are intentionally fixed in code rather than
exposed as tuning options.
