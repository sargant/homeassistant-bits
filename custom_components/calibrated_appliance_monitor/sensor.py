"""Sensors exposed by a calibrated appliance monitor."""

from datetime import datetime

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity
from homeassistant.const import EntityCategory, UnitOfEnergy
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import CalibratedApplianceMonitorConfigEntry
from .algorithms.base import ApplianceMonitor
from .algorithms.hoover_hbdos695tamce80 import ALGORITHM_ID as HOOVER_HBDOS695TAMCE80
from .algorithms.indesit_d2ihl326uk import ALGORITHM_ID as INDESIT_D2IHL326UK


async def async_setup_entry(
    hass: HomeAssistant,
    entry: CalibratedApplianceMonitorConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Expose public appliance facts plus algorithm-specific diagnostics."""
    monitor = entry.runtime_data

    entities: list[SensorEntity] = [CyclePhaseSensor(monitor)]

    # Diagnostics describe the implementation of each calibration, so they
    # deliberately do not become part of the common ApplianceMonitor base.
    if monitor.algorithm_id == INDESIT_D2IHL326UK:
        entities.extend(
            [
                CandidateStartedSensor(monitor),
                CandidateStartEnergySensor(monitor),
                CycleStartEnergySensor(monitor),
            ]
        )
    elif monitor.algorithm_id == HOOVER_HBDOS695TAMCE80:
        entities.extend(
            [
                CandidateStartedSensor(monitor),
                CandidateStartEnergySensor(monitor),
                CycleStartEnergySensor(monitor),
                DryingCandidateSensor(monitor),
                DryingStartedSensor(monitor),
                FinishCandidateSensor(monitor),
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
    """Public lifecycle phase and metadata for the most recent cycle."""

    _attr_name = "Cycle phase"

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_icon = monitor.icon
        self._attr_unique_id = monitor.unique_id("cycle_phase")

    @property
    def native_value(self) -> str:
        return self.monitor.cycle_phase

    @property
    def extra_state_attributes(self) -> dict[str, str | float | None]:
        attributes: dict[str, str | float | None] = {
            "last_started": getattr(self.monitor, "last_started_at", None),
            "last_finished": getattr(self.monitor, "last_finished_at", None),
            "last_cycle_energy_kwh": getattr(
                self.monitor, "last_cycle_energy_kwh", None
            ),
        }
        if hasattr(self.monitor, "last_cycle_outcome"):
            attributes["last_cycle_outcome"] = getattr(
                self.monitor, "last_cycle_outcome", None
            )
        return attributes


class DiagnosticSensor(ApplianceSensor):
    """Diagnostic entity exposing calibration internals."""

    _attr_entity_category = EntityCategory.DIAGNOSTIC


class CandidateStartedSensor(DiagnosticSensor):
    """Earliest plausible start awaiting high-power confirmation."""

    _attr_name = "Start time candidate"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("candidate_started")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "candidate_started_at", None)
        return datetime.fromisoformat(value) if value else None


class CandidateStartEnergySensor(DiagnosticSensor):
    """Cumulative meter reading captured at the candidate start."""

    _attr_name = "Starting energy candidate"
    _attr_device_class = SensorDeviceClass.ENERGY
    _attr_native_unit_of_measurement = UnitOfEnergy.KILO_WATT_HOUR

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("candidate_start_energy")

    @property
    def native_value(self) -> float | None:
        return getattr(self.monitor, "candidate_start_energy_kwh", None)


class CycleStartEnergySensor(DiagnosticSensor):
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


class DryingCandidateSensor(DiagnosticSensor):
    """First dryer-band sample awaiting drying confirmation."""

    _attr_name = "Drying time candidate"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("drying_candidate")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "dry_candidate_at", None)
        return datetime.fromisoformat(value) if value else None


class DryingStartedSensor(DiagnosticSensor):
    """Retrospective start of confirmed tumble drying."""

    _attr_name = "Drying started"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("drying_started")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "drying_started_at", None)
        return datetime.fromisoformat(value) if value else None


class FinishCandidateSensor(DiagnosticSensor):
    """First quiet sample awaiting cycle-finish confirmation."""

    _attr_name = "Finish time candidate"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, monitor: ApplianceMonitor) -> None:
        super().__init__(monitor)
        self._attr_unique_id = monitor.unique_id("finish_candidate")

    @property
    def native_value(self) -> datetime | None:
        value = getattr(self.monitor, "finish_candidate_at", None)
        return datetime.fromisoformat(value) if value else None
