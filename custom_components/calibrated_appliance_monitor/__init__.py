"""Calibrated Appliance Monitor integration lifecycle."""

import logging

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant

from .algorithms import ALGORITHMS, create_monitor
from .algorithms.base import ApplianceMonitor
from .const import CONF_ALGORITHM, CONF_SOURCE_DEVICE

_LOGGER = logging.getLogger(__name__)
PLATFORMS = [Platform.SENSOR, Platform.BINARY_SENSOR]

type CalibratedApplianceMonitorConfigEntry = ConfigEntry[ApplianceMonitor]


async def async_setup_entry(
    hass: HomeAssistant, entry: CalibratedApplianceMonitorConfigEntry
) -> bool:
    """Set up one monitored appliance."""
    algorithm_id = entry.options.get(CONF_ALGORITHM)
    source_device_id = entry.options.get(CONF_SOURCE_DEVICE)

    # Adding the integration creates an empty entry by design. The appliance is
    # created only after Configure has supplied a source device and algorithm.
    if not algorithm_id or not source_device_id:
        return True

    if algorithm_id not in ALGORITHMS:
        _LOGGER.error("Unknown calibrated appliance algorithm: %s", algorithm_id)
        return False

    monitor = create_monitor(hass, entry, algorithm_id)
    await monitor.async_setup()
    entry.runtime_data = monitor

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(
    hass: HomeAssistant, entry: CalibratedApplianceMonitorConfigEntry
) -> bool:
    """Unload one monitored appliance."""
    if not entry.options.get(CONF_ALGORITHM) or not entry.options.get(CONF_SOURCE_DEVICE):
        return True

    if not await hass.config_entries.async_unload_platforms(entry, PLATFORMS):
        return False

    entry.runtime_data.unload()
    return True
