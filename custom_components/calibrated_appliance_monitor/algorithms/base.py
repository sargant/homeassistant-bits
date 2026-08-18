"""Shared plumbing for calibrated appliance algorithms."""

from collections.abc import Callable
from typing import Any, ClassVar

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo

from ..const import CONF_SOURCE_DEVICE, DOMAIN


class ApplianceMonitor:
    """Small common surface exposed by every calibrated algorithm."""

    algorithm_id: ClassVar[str]
    algorithm_label: ClassVar[str]
    appliance_name: ClassVar[str]
    manufacturer: ClassVar[str]
    model: ClassVar[str]
    icon: ClassVar[str] = "mdi:power-plug"

    cycle_phase: str
    running: bool
    available: bool
    attributes: dict[str, Any]

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.source_device_id: str = entry.options[CONF_SOURCE_DEVICE]
        self.listeners: list[Callable[[], None]] = []

    @property
    def device_info(self) -> DeviceInfo:
        """Describe the virtual appliance owned by this config entry."""
        return DeviceInfo(
            identifiers={(DOMAIN, self.entry.entry_id)},
            name=self.appliance_name,
            manufacturer=self.manufacturer,
            model=self.model,
        )

    def unique_id(self, key: str) -> str:
        """Return an entity unique ID scoped to this appliance entry."""
        return f"{self.entry.entry_id}_{key}"

    def add_listener(self, listener: Callable[[], None]) -> CALLBACK_TYPE:
        """Subscribe an entity to monitor changes."""
        self.listeners.append(listener)

        def remove() -> None:
            self.listeners.remove(listener)

        return remove

    def _changed(self) -> None:
        """Push a changed algorithm state to its Home Assistant entities."""
        for listener in tuple(self.listeners):
            listener()
