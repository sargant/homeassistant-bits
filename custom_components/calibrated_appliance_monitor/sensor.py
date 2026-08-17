"""Dishwasher sensors."""

from typing import Any

from homeassistant.components.sensor import SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import DishwasherMonitor
from .const import APPLIANCE_ID, APPLIANCE_MANUFACTURER, APPLIANCE_MODEL, APPLIANCE_NAME, DOMAIN


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    monitor: DishwasherMonitor = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([CycleStateSensor(monitor), PhaseSensor(monitor)])


class DishwasherSensor(SensorEntity):
    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(self, monitor: DishwasherMonitor) -> None:
        self.monitor = monitor
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, APPLIANCE_ID)},
            name=APPLIANCE_NAME,
            manufacturer=APPLIANCE_MANUFACTURER,
            model=APPLIANCE_MODEL,
        )

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self.monitor.add_listener(self.async_write_ha_state))

    @property
    def available(self) -> bool:
        return self.monitor.available


class CycleStateSensor(DishwasherSensor):
    _attr_name = "Cycle state"
    _attr_icon = "mdi:dishwasher"
    _attr_unique_id = f"{APPLIANCE_ID}_cycle_state"

    @property
    def native_value(self) -> str:
        return self.monitor.state

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return self.monitor.attributes


class PhaseSensor(DishwasherSensor):
    _attr_name = "Phase"
    _attr_icon = "mdi:dishwasher"
    _attr_unique_id = f"{APPLIANCE_ID}_phase"

    @property
    def native_value(self) -> str:
        return self.monitor.phase
