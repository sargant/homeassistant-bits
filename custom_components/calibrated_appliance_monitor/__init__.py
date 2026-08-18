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


async def async_migrate_entry(
    hass: HomeAssistant, entry: CalibratedApplianceMonitorConfigEntry
) -> bool:
    """Move appliance identity from mutable options into config-entry data."""
    if entry.version == 1:
        data = dict(entry.data)
        for key in (CONF_SOURCE_DEVICE, CONF_ALGORITHM):
            if key not in data and key in entry.options:
                data[key] = entry.options[key]

        hass.config_entries.async_update_entry(
            entry,
            data=data,
            options={},
            version=2,
        )

    return True


async def async_setup_entry(
    hass: HomeAssistant, entry: CalibratedApplianceMonitorConfigEntry
) -> bool:
    """Set up one monitored appliance."""
    algorithm_id = entry.data.get(CONF_ALGORITHM)
    source_device_id = entry.data.get(CONF_SOURCE_DEVICE)

    if not algorithm_id or not source_device_id:
        _LOGGER.error("Calibrated appliance entry is missing its appliance identity")
        return False

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
    if not hasattr(entry, "runtime_data"):
        return True

    if not await hass.config_entries.async_unload_platforms(entry, PLATFORMS):
        return False

    entry.runtime_data.unload()
    return True
