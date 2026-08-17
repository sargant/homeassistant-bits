# Calibrated Appliance Monitor

A deliberately small custom integration for appliance-specific power-profile
detection. Version 0.1 contains one calibration: the Indesit D2IHL326UK
dishwasher.

## Setup

1. Copy this directory to `/config/custom_components/calibrated_appliance_monitor`.
2. Restart Home Assistant.
3. Add **Calibrated Appliance Monitor** from **Settings → Devices & services**.
   Adding it asks no questions and creates the **Dishwasher** device.
4. Open the integration, choose **Configure**, and select the dishwasher smart
   plug. The integration finds that device's power and energy sensors
   automatically.

The dishwasher algorithm and notification thresholds are intentionally fixed in
code. There are no user-tunable thresholds or model abstractions yet.
