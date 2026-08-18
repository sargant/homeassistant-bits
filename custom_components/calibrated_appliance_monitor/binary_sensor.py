"""Binary sensors exposed by a calibrated appliance monitor."""

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import CalibratedApplianceMonitorConfigEntry
from .algorithms.base import ApplianceMonitor


async def async_setup_entry(
    hass: HomeAssistant,
    entry: CalibratedApplianceMonitorConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Expose the selected algorithm's running state."""
    async_add_entities([RunningSensor(entry.runtime_data)])


class RunningSensor(BinarySensorEntity):
    """Simple running / not-running view over the algorithm lifecycle."""

    _attr_device_class = BinarySensorDeviceClass.RUNNING
    _attr_has_entity_name = True
    _attr_name = "Running"
    _attr_should_poll = False

    def __init__(self, monitor: ApplianceMonitor) -> None:
        self.monitor = monitor
        self._attr_device_info = monitor.device_info
        self._attr_unique_id = monitor.unique_id("running")

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self.monitor.add_listener(self.async_write_ha_state))

    @property
    def available(self) -> bool:
        return self.monitor.available

    @property
    def is_on(self) -> bool:
        return self.monitor.running
