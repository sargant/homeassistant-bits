"""Calibration for the Indesit D2IHL326UK dishwasher."""

from collections.abc import Callable
from datetime import datetime, timedelta
import logging
from typing import ClassVar

from homeassistant.components.sensor import SensorDeviceClass, SensorStateClass
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import (
    EntityStateAttribute,
    Platform,
    STATE_UNAVAILABLE,
    STATE_UNKNOWN,
    UnitOfEnergy,
    UnitOfPower,
)
from homeassistant.core import (
    CALLBACK_TYPE,
    Event,
    EventStateChangedData,
    HomeAssistant,
    State,
    callback,
)
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.event import async_call_later, async_track_state_change_event
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util
from homeassistant.util.unit_conversion import EnergyConverter, PowerConverter

from ..const import DOMAIN
from .base import ApplianceMonitor

_LOGGER = logging.getLogger(__name__)

ALGORITHM_ID = "indesit_d2ihl326uk"

IDLE = "Idle"
STARTING = "Starting"
RUNNING = "Running"
ENDING = "Ending"
FINISH_PENDING = "Finish pending"
FINISHED = "Finished"

# Calibrated from recorded cycles for this specific dishwasher.
START_W = 5.0
ACTIVE_W = 30.0
ASLEEP_W = 1.0
START_CONFIRM = 6 * 60
END_WINDOW = 15 * 60
FINISH_CONFIRM = 60
ASLEEP_CONFIRM = 60


class IndesitD2IHL326UKMonitor(ApplianceMonitor):
    """Power-profile detector calibrated for the Indesit D2IHL326UK.

    Idle -> Starting -> Running -> Ending -> Finish pending -> Finished -> Idle

    A >5 W rise creates a candidate start. Reaching >30 W within six minutes
    confirms it and backdates the real start to that candidate time. During a
    confirmed cycle, 15 continuous minutes below 30 W arms the end sequence.
    After the final activity, one minute below 5 W confirms completion, and one
    minute below 1 W returns the appliance from Finished to Idle.
    """

    algorithm_id: ClassVar[str] = ALGORITHM_ID
    algorithm_label: ClassVar[str] = "Indesit D2IHL326UK dishwasher"
    appliance_name: ClassVar[str] = "Dishwasher"
    manufacturer: ClassVar[str] = "Indesit"
    model: ClassVar[str] = "D2IHL326UK"
    icon: ClassVar[str] = "mdi:dishwasher"

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        super().__init__(hass, entry)
        self.store = Store(hass, 1, f"{DOMAIN}.{entry.entry_id}")

        # Persist the facts needed to survive a restart or calculate the
        # completed cycle; the public entities are only views over this state.
        self.state = IDLE
        self.candidate_started_at: str | None = None
        self.candidate_start_energy_kwh: float | None = None
        self.last_started_at: str | None = None
        self.last_started_energy_kwh: float | None = None
        self.last_finished_at: str | None = None
        self.last_cycle_energy_kwh: float | None = None
        self.deadlines: dict[str, str] = {}

        self.power_entity_id: str | None = None
        self.energy_entity_id: str | None = None
        self.available = False
        self.power: float | None = None

        self.timers: dict[str, CALLBACK_TYPE] = {}
        self.unsub_power: CALLBACK_TYPE | None = None

    @property
    def running(self) -> bool:
        # Starting is immediately useful publicly even though the official
        # retrospective start timestamp is only promoted after confirmation.
        return self.state not in (IDLE, FINISHED)

    async def async_setup(self) -> None:
        """Restore state and listen to the selected smart plug."""
        if stored := await self.store.async_load():
            for key in (
                "state",
                "candidate_started_at",
                "candidate_start_energy_kwh",
                "last_started_at",
                "last_started_energy_kwh",
                "last_finished_at",
                "last_cycle_energy_kwh",
                "deadlines",
            ):
                if key in stored:
                    setattr(self, key, stored[key])

        # The user selects the smart-plug device, not individual entities. Find
        # its power and cumulative-energy sensors by device class at runtime.
        self._find_source_entities()
        if not self.power_entity_id:
            _LOGGER.warning("Selected dishwasher source has no power sensor")
            return

        self.power = self._power(self.hass.states.get(self.power_entity_id))
        self.available = self.power is not None
        self.unsub_power = async_track_state_change_event(
            self.hass, self.power_entity_id, self._power_changed
        )
        if self.power is not None:
            self._reconcile_power(self.power, resume=True)

    def unload(self) -> None:
        """Cancel callbacks."""
        if self.unsub_power:
            self.unsub_power()
        for cancel in self.timers.values():
            cancel()
        self.timers.clear()

    def _find_source_entities(self) -> None:
        registry = er.async_get(self.hass)
        for entity in er.async_entries_for_device(registry, self.source_device_id):
            if entity.domain != Platform.SENSOR:
                continue
            state = self.hass.states.get(entity.entity_id)
            device_class = entity.original_device_class
            if device_class is None and state:
                device_class = state.attributes.get(EntityStateAttribute.DEVICE_CLASS)
            if device_class == SensorDeviceClass.POWER and not self.power_entity_id:
                self.power_entity_id = entity.entity_id
            elif device_class == SensorDeviceClass.ENERGY:
                if not self.energy_entity_id:
                    self.energy_entity_id = entity.entity_id
                if (
                    state
                    and state.attributes.get("state_class")
                    == SensorStateClass.TOTAL_INCREASING
                ):
                    self.energy_entity_id = entity.entity_id

    @staticmethod
    def _number(state: State | None) -> float | None:
        if state is None or state.state in (STATE_UNKNOWN, STATE_UNAVAILABLE):
            return None
        try:
            return float(state.state)
        except ValueError:
            return None

    def _power(self, state: State | None) -> float | None:
        value = self._number(state)
        if state is None or value is None:
            return None
        unit = state.attributes.get(EntityStateAttribute.UNIT_OF_MEASUREMENT)
        if unit not in PowerConverter.VALID_UNITS:
            _LOGGER.warning(
                "Dishwasher power sensor %s has unsupported unit %s",
                self.power_entity_id,
                unit,
            )
            return None
        return PowerConverter.convert(value, unit, UnitOfPower.WATT)

    def _energy(self) -> float | None:
        if not self.energy_entity_id:
            return None
        state = self.hass.states.get(self.energy_entity_id)
        value = self._number(state)
        if state is None or value is None:
            return None
        unit = state.attributes.get(EntityStateAttribute.UNIT_OF_MEASUREMENT)
        if unit not in EnergyConverter.VALID_UNITS:
            _LOGGER.warning(
                "Dishwasher energy sensor %s has unsupported unit %s",
                self.energy_entity_id,
                unit,
            )
            return None
        return EnergyConverter.convert(value, unit, UnitOfEnergy.KILO_WATT_HOUR)

    @callback
    def _power_changed(self, event: Event[EventStateChangedData]) -> None:
        old = self._power(event.data["old_state"])
        new = self._power(event.data["new_state"])
        was_available = self.available
        self.power = new
        self.available = new is not None

        if new is None:
            if was_available:
                # Unknown time cannot prove continuous low power, so discard
                # only the debounce windows that require continuous readings.
                for name in ("end", "finish", "asleep"):
                    self._cancel(name)
                self._changed()
            return

        if not was_available:
            self._changed()

        if old is None:
            self._reconcile_power(new)
            return

        now = dt_util.now()

        # The machine has genuine low-power gaps mid-cycle. Only 15 continuous
        # minutes below 30 W are enough to arm the end sequence.
        if old >= ACTIVE_W > new and self.state == RUNNING:
            self._schedule("end", END_WINDOW, self._end_timeout)

        # Once final activity has happened, require a full minute below 5 W
        # before confirming completion.
        if old >= START_W > new and self.state == FINISH_PENDING:
            self._schedule("finish", FINISH_CONFIRM, self._finish_timeout)

        # Finished stays visible until the control electronics are properly idle.
        if old >= ASLEEP_W > new:
            self._schedule("asleep", ASLEEP_CONFIRM, self._asleep_timeout, persist=False)

        if old < ASLEEP_W <= new:
            self._cancel("asleep")

        if old <= START_W < new:
            if self.state == IDLE:
                self._begin_start(now)
            elif self.state == ENDING:
                # Recorded cycles contain a final burst after the long quiet gap.
                self._set_state(FINISH_PENDING)
            elif self.state == FINISH_PENDING:
                self._cancel("finish")

        if old <= ACTIVE_W < new:
            if self.state == STARTING and "start" in self.timers:
                self._confirm_start()
            elif self.state in (RUNNING, ENDING, FINISH_PENDING):
                # Renewed >30 W activity proves any pending finish was premature.
                self._cancel("end")
                self._cancel("finish")
                self._set_state(RUNNING)

    def _begin_start(self, now: datetime) -> None:
        """Record the earliest plausible cycle start."""
        self.candidate_started_at = now.isoformat()
        self.candidate_start_energy_kwh = self._energy()
        self._set_state(STARTING)
        self._schedule("start", START_CONFIRM, self._start_timeout)

    def _confirm_start(self) -> None:
        """Promote the retrospective start candidate to a confirmed cycle."""
        self.last_started_at = self.candidate_started_at
        self.last_started_energy_kwh = self.candidate_start_energy_kwh
        self._cancel("start")
        self._set_state(RUNNING)

    def _reconcile_power(self, power: float, *, resume: bool = False) -> None:
        """Reconcile a trustworthy reading after setup, restart, or outage."""
        if self.state == IDLE and power > START_W:
            self._begin_start(dt_util.now())
            if power > ACTIVE_W:
                self._confirm_start()
        elif self.state == STARTING:
            if power > ACTIVE_W:
                self._confirm_start()
            elif resume:
                if self._has_future_deadline("start"):
                    self._schedule("start", START_CONFIRM, self._start_timeout, resume=True)
                else:
                    self._set_state(IDLE)
        elif self.state == RUNNING and power < ACTIVE_W:
            self._schedule("end", END_WINDOW, self._end_timeout, resume=resume)
        elif self.state == ENDING:
            if power > ACTIVE_W:
                self._set_state(RUNNING)
            elif START_W < power < ACTIVE_W:
                self._set_state(FINISH_PENDING)
        elif self.state == FINISH_PENDING:
            if power > ACTIVE_W:
                self._cancel("end")
                self._cancel("finish")
                self._set_state(RUNNING)
            elif power < START_W:
                self._schedule(
                    "finish", FINISH_CONFIRM, self._finish_timeout, resume=resume
                )
        elif self.state == FINISHED and power < ASLEEP_W:
            self._schedule("asleep", ASLEEP_CONFIRM, self._asleep_timeout, persist=False)

    def _has_future_deadline(self, name: str) -> bool:
        saved = self.deadlines.get(name)
        if not saved:
            return False
        try:
            return datetime.fromisoformat(saved) > dt_util.now()
        except ValueError:
            return False

    def _schedule(
        self,
        name: str,
        seconds: int,
        handler: Callable[[datetime], None],
        *,
        resume: bool = False,
        persist: bool = True,
    ) -> None:
        saved = self.deadlines.get(name) if resume else None
        self._cancel(name)
        deadline = dt_util.now() + timedelta(seconds=seconds)
        if saved:
            try:
                candidate = datetime.fromisoformat(saved)
                if candidate > dt_util.now():
                    deadline = candidate
            except ValueError:
                pass

        # Start/end/finish windows survive restarts. The asleep debounce does
        # not need to: losing it merely leaves Finished visible a little longer.
        if persist:
            self.deadlines[name] = deadline.isoformat()
            self._save()

        @callback
        def fire(now: datetime) -> None:
            self.timers.pop(name, None)
            self.deadlines.pop(name, None)
            self._save()
            handler(now)

        self.timers[name] = async_call_later(
            self.hass,
            max(0.0, (deadline - dt_util.now()).total_seconds()),
            fire,
        )

    def _cancel(self, name: str) -> None:
        if cancel := self.timers.pop(name, None):
            cancel()
        if name in self.deadlines:
            self.deadlines.pop(name)
            self._save()

    @callback
    def _start_timeout(self, _now: datetime) -> None:
        if self.state == STARTING:
            self._set_state(IDLE)

    @callback
    def _end_timeout(self, _now: datetime) -> None:
        if self.state == RUNNING and self.power is not None and self.power < ACTIVE_W:
            # If 5..30 W activity is already present it can be the final burst;
            # otherwise wait in Ending for that burst to appear.
            self._set_state(FINISH_PENDING if self.power > START_W else ENDING)

    @callback
    def _finish_timeout(self, _now: datetime) -> None:
        if self.state != FINISH_PENDING or self.power is None or self.power >= START_W:
            return

        # The confirmation delay is not part of the cycle. Backdate the finish
        # by one minute so the public timestamps report the real boundary.
        finished = dt_util.now() - timedelta(seconds=FINISH_CONFIRM)
        self.last_finished_at = finished.isoformat()
        self.last_cycle_energy_kwh = None
        if (
            (energy := self._energy()) is not None
            and self.last_started_energy_kwh is not None
            and energy >= self.last_started_energy_kwh
        ):
            self.last_cycle_energy_kwh = round(energy - self.last_started_energy_kwh, 3)

        self._set_state(FINISHED)
        if self.power < ASLEEP_W and "asleep" not in self.timers:
            self._schedule("asleep", ASLEEP_CONFIRM, self._asleep_timeout, persist=False)

    @callback
    def _asleep_timeout(self, _now: datetime) -> None:
        if (
            self.power is not None
            and self.power < ASLEEP_W
            and self.state in (STARTING, FINISHED)
        ):
            self._cancel("start")
            self._set_state(IDLE)

    def _set_state(self, state: str) -> None:
        if self.state == state:
            return
        self.state = state
        self._save()
        self._changed()

    def _save(self) -> None:
        data = {
            "state": self.state,
            "candidate_started_at": self.candidate_started_at,
            "candidate_start_energy_kwh": self.candidate_start_energy_kwh,
            "last_started_at": self.last_started_at,
            "last_started_energy_kwh": self.last_started_energy_kwh,
            "last_finished_at": self.last_finished_at,
            "last_cycle_energy_kwh": self.last_cycle_energy_kwh,
            "deadlines": self.deadlines,
        }
        self.entry.async_create_task(self.hass, self.store.async_save(data))
