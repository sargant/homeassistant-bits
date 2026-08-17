"""Constants for Calibrated Appliance Monitor."""

DOMAIN = "calibrated_appliance_monitor"
CONF_SOURCE_DEVICE = "source_device"

APPLIANCE_ID = "dishwasher_indesit_d2ihl326uk"
APPLIANCE_NAME = "Dishwasher"
APPLIANCE_MANUFACTURER = "Indesit"
APPLIANCE_MODEL = "D2IHL326UK"

IDLE = "Idle"
STARTING = "Starting"
RUNNING = "Running"
ENDING = "Ending"
FINISH_PENDING = "Finish pending"
FINISHED = "Finished"
RUNNING_STATES = {STARTING, RUNNING, ENDING, FINISH_PENDING}

START_W = 5.0
ACTIVE_W = 30.0
ASLEEP_W = 1.0
START_CONFIRM = 6 * 60
END_WINDOW = 15 * 60
FINISH_CONFIRM = 60
ASLEEP_CONFIRM = 60

NOTIFY_LABEL = "Receive push notifications"
UNIT_RATE_ENTITY = (
    "sensor.octopus_energy_electricity_15p0128357_1640000213346_current_rate"
)
