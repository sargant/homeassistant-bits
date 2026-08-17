"""Sensors exposed by a calibrated appliance monitor."""

from typing import Any

from homeassistant.components.sensor import SensorEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import CalibratedApplianceMonitorConfigEntry
from .algorithms.base import ApplianceMonitor


async def async_setup_entry(
    hass: HomeAssistant,
    entry: CalibratedApplianceMonitorConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Expose the selected algorithm's public sensors."""
    monitor = entry.runtime_data
    async_add_entities([CycleStateSensor(monitor), PhaseSensor(monitor)])


class ApplianceSensor(SensorEntity):
    """Base sensor backed by the selected appliance algorithm."""

    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(self, monitor: ApplianceMonitor) -> None:
        self.monitor = monitor
        self._attr_device_info = monitor.device_info

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self.monitor.add_listener(self.async_write_ha_state))

    @property
    def available(self) -> bool:
        return self.monitor.available


class CycleStateSensor(ApplianceSensor):
    """Detailed lifecycle from the selected calibrated algorithm."""

    _attr_name = "Cycle state"

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_icon = monitor.icon
        self._attr_unique_id = monitor.unique_id("cycle_state")

    @property
    def native_value(self) -> str:
        return self.monitor.state

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return self.monitor.attributes


class PhaseSensor(ApplianceSensor):
    """Simplified public appliance phase."""

    _attr_name = "Phase"

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_icon = monitor.icon
        self._attr_unique_id = monitor.unique_id("phase")

    @property
    def native_value(self) -> str:
        return self.monitor.phase
