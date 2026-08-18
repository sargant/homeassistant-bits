"""Available calibrated appliance algorithms."""

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant

from .base import ApplianceMonitor
from .indesit_d2ihl326uk import IndesitD2IHL326UKMonitor

ALGORITHMS: dict[str, type[ApplianceMonitor]] = {
    IndesitD2IHL326UKMonitor.algorithm_id: IndesitD2IHL326UKMonitor,
}

ALGORITHM_OPTIONS = [
    {"value": algorithm_id, "label": monitor.algorithm_label}
    for algorithm_id, monitor in ALGORITHMS.items()
]


def create_monitor(
    hass: HomeAssistant, entry: ConfigEntry, algorithm_id: str
) -> ApplianceMonitor:
    """Create the monitor selected by a config entry."""
    return ALGORITHMS[algorithm_id](hass, entry)
