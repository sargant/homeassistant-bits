"""Sensors exposed by a calibrated appliance monitor."""

from datetime import datetime

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity
from homeassistant.const import EntityCategory, UnitOfEnergy
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import CalibratedApplianceMonitorConfigEntry
from .algorithms.base import ApplianceMonitor
from .algorithms.indesit_d2ihl326uk import ALGORITHM_ID as INDESIT_D2IHL326UK


async def async_setup_entry(
    hass: HomeAssistant,
    entry: CalibratedApplianceMonitorConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Expose public appliance facts plus algorithm-specific diagnostics."""
    monitor = entry.runtime_data

    entities: list[SensorEntity] = [
        CyclePhaseSensor(monitor),
        LastStartedSensor(monitor),
        LastFinishedSensor(monitor),
        LastCycleEnergySensor(monitor),
    ]

    # Diagnostics describe the implementation of this specific calibration, so
    # they deliberately do not become part of the common ApplianceMonitor base.
    if monitor.algorithm_id == INDESIT_D2IHL326UK:
        entities.extend(
            [
                CandidateStartedSensor(monitor),
                CandidateStartEnergySensor(monitor),
                CycleStartEnergySensor(monitor),
            ]
        )

    async_add_entities(entities)


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


class CyclePhaseSensor(ApplianceSensor):
    """Public lifecycle phase chosen by the selected appliance algorithm."""

    _attr_name = "Cycle phase"

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_icon = monitor.icon
        # This is the same lifecycle entity previously called Cycle state. Keep
        # its unique ID stable so existing installations upgrade it in place.
        self._attr_unique_id = monitor.unique_id("cycle_state")

    @property
    def native_value(self) -> str:
        return self.monitor.cycle_phase


class LastStartedSensor(ApplianceSensor):
    """Confirmed start time of the most recent cycle."""

    _attr_name = "Last started"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("last_started")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "last_started_at", None)
        return datetime.fromisoformat(value) if value else None


class LastFinishedSensor(ApplianceSensor):
    """Confirmed finish time of the most recent cycle."""

    _attr_name = "Last finished"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("last_finished")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "last_finished_at", None)
        return datetime.fromisoformat(value) if value else None


class LastCycleEnergySensor(ApplianceSensor):
    """Energy consumed by the most recently completed cycle."""

    _attr_name = "Last cycle energy"
    _attr_device_class = SensorDeviceClass.ENERGY
    _attr_native_unit_of_measurement = UnitOfEnergy.KILO_WATT_HOUR

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("last_cycle_energy")

    @property
    def native_value(self) -> float | None:
        return getattr(self.monitor, "last_cycle_energy_kwh", None)


class DishwasherDiagnosticSensor(ApplianceSensor):
    """Disabled-by-default diagnostic from the dishwasher calibration."""

    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_entity_registry_enabled_default = False


class CandidateStartedSensor(DishwasherDiagnosticSensor):
    """Earliest plausible start awaiting high-power confirmation."""

    _attr_name = "Candidate started"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("candidate_started")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "candidate_started_at", None)
        return datetime.fromisoformat(value) if value else None


class CandidateStartEnergySensor(DishwasherDiagnosticSensor):
    """Cumulative meter reading captured at the candidate start."""

    _attr_name = "Candidate start energy"
    _attr_device_class = SensorDeviceClass.ENERGY
    _attr_native_unit_of_measurement = UnitOfEnergy.KILO_WATT_HOUR

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("candidate_start_energy")

    @property
    def native_value(self) -> float | None:
        return getattr(self.monitor, "candidate_start_energy_kwh", None)


class CycleStartEnergySensor(DishwasherDiagnosticSensor):
    """Cumulative meter reading retained for the confirmed cycle start."""

    _attr_name = "Cycle start energy"
    _attr_device_class = SensorDeviceClass.ENERGY
    _attr_native_unit_of_measurement = UnitOfEnergy.KILO_WATT_HOUR

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("cycle_start_energy")

    @property
    def native_value(self) -> float | None:
        return getattr(self.monitor, "last_started_energy_kwh", None)
