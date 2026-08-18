"""Calibration for the Hoover HBDOS695TAMCE-80 washer-dryer."""

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

ALGORITHM_ID = "hoover_hbdos695tamce80"

IDLE = "Idle"
WET = "Washing"
DRY = "Drying"
FINISHED = "Finished"

OUTCOME_WET = "Washing"
OUTCOME_DRY_ONLY = "Drying only"
OUTCOME_WET_DRY = "Washing + drying"

# Calibrated from recorded cycles for this specific washer-dryer.
START_W = 10.0
ACTIVE_W = 30.0
ASLEEP_W = 1.0
START_WINDOW = 3 * 60
DRY_MIN_W = 700.0
DRY_MAX_W = 1300.0
DRY_CONFIRM = 10
WET_FINISH_CONFIRM = 60
DRY_FINISH_CONFIRM = 10
DRY_ONLY_BOUNDARY = 2 * 60
FINISHED_MIN = 60
FINISHED_MAX = 10 * 60


class HooverHBDOS695TAMCE80Monitor(ApplianceMonitor):
    """Power-profile detector calibrated for the Hoover HBDOS695TAMCE-80.

    Public lifecycle: Idle -> Washing -> optional Drying -> Finished -> Idle.

    Start and finish uncertainty stay internal. A >10 W reading records a
    candidate start, and later >30 W activity confirms it while retaining the
    original candidate timestamp. Drying is latched after ten continuous seconds
    in the distinctive 700..1300 W dryer band. Completion is confirmed after
    continuous <10 W quiet: 60 seconds while washing and 10 seconds once drying
    has been seen. The official finish is backdated to the first quiet sample.
    Finished remains visible for at least one minute and at most ten.
    """

    algorithm_id: ClassVar[str] = ALGORITHM_ID
    algorithm_label: ClassVar[str] = "Hoover HBDOS695TAMCE-80 washer-dryer"
    appliance_name: ClassVar[str] = "Washer-dryer"
    manufacturer: ClassVar[str] = "Hoover"
    model: ClassVar[str] = "HBDOS695TAMCE-80"
    icon: ClassVar[str] = "mdi:washing-machine"

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        super().__init__(hass, entry)
        self.store = Store(hass, 1, f"{DOMAIN}.{entry.entry_id}")

        self.state = IDLE
        self.candidate_started_at: str | None = None
        self.candidate_start_energy_kwh: float | None = None
        self.last_started_at: str | None = None
        self.last_started_energy_kwh: float | None = None
        self.dry_seen = False
        self.dry_candidate_at: str | None = None
        self.drying_started_at: str | None = None
        self.finish_candidate_at: str | None = None
        self.finish_candidate_energy_kwh: float | None = None
        self.last_finished_at: str | None = None
        self.last_cycle_energy_kwh: float | None = None
        self.last_cycle_outcome: str | None = None
        self.finished_entered_at: str | None = None
        self.deadlines: dict[str, str] = {}

        self.power_entity_id: str | None = None
        self.energy_entity_id: str | None = None
        self.available = False
        self.power: float | None = None

        self.timers: dict[str, CALLBACK_TYPE] = {}
        self.unsub_power: CALLBACK_TYPE | None = None

    @property
    def running(self) -> bool:
        return self.state in (WET, DRY)

    async def async_setup(self) -> None:
        """Restore state and listen to the selected smart plug."""
        if stored := await self.store.async_load():
            for key in (
                "state",
                "candidate_started_at",
                "candidate_start_energy_kwh",
                "last_started_at",
                "last_started_energy_kwh",
                "dry_seen",
                "dry_candidate_at",
                "drying_started_at",
                "finish_candidate_at",
                "finish_candidate_energy_kwh",
                "last_finished_at",
                "last_cycle_energy_kwh",
                "last_cycle_outcome",
                "finished_entered_at",
                "deadlines",
            ):
                if key in stored:
                    setattr(self, key, stored[key])

        self._find_source_entities()
        if not self.power_entity_id:
            _LOGGER.warning("Selected washer-dryer source has no power sensor")
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
                "Washer-dryer power sensor %s has unsupported unit %s",
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
                "Washer-dryer energy sensor %s has unsupported unit %s",
                self.energy_entity_id,
                unit,
            )
            return None
        return EnergyConverter.convert(value, unit, UnitOfEnergy.KILO_WATT_HOUR)

    @callback
    def _power_changed(self, event: Event[EventStateChangedData]) -> None:
        new = self._power(event.data["new_state"])
        was_available = self.available
        self.power = new
        self.available = new is not None

        if new is None:
            if was_available:
                # Unknown time cannot prove a continuous dryer signature or
                # continuous quiet, so discard only those debounce windows.
                self._cancel_dry_candidate()
                self._cancel_finish_candidate()
                self._changed()
            return

        if not was_available:
            self._changed()

        self._reconcile_power(new)

    def _reconcile_power(self, power: float, *, resume: bool = False) -> None:
        """Apply one trustworthy power reading to the detector."""
        now = dt_util.now()

        if self.state in (IDLE, FINISHED):
            self._reconcile_start(power, now, resume=resume)
            if self.state == FINISHED:
                self._reconcile_finished(power, now, resume=resume)
            if self.state not in (WET, DRY):
                return

        if self.state == WET:
            if DRY_MIN_W <= power <= DRY_MAX_W:
                if "dry" not in self.timers:
                    if not self.dry_candidate_at:
                        self.dry_candidate_at = now.isoformat()
                        self._save()
                    self._schedule(
                        "dry", DRY_CONFIRM, self._dry_timeout, resume=resume
                    )
            else:
                self._cancel_dry_candidate()

        if self.state in (WET, DRY):
            if power < START_W:
                if "finish" not in self.timers:
                    if not self.finish_candidate_at:
                        self.finish_candidate_at = now.isoformat()
                        self.finish_candidate_energy_kwh = self._energy()
                        self._save()
                    self._schedule(
                        "finish",
                        DRY_FINISH_CONFIRM if self.dry_seen else WET_FINISH_CONFIRM,
                        self._finish_timeout,
                        resume=resume,
                    )
            else:
                self._cancel_finish_candidate()

    def _reconcile_start(
        self, power: float, now: datetime, *, resume: bool = False
    ) -> None:
        """Maintain the hidden candidate start while public state stays put."""
        if self.candidate_started_at:
            if resume and not self._has_future_deadline("start"):
                self._clear_start_candidate()
            else:
                if power > ACTIVE_W:
                    self._confirm_start()
                    return
                if resume:
                    self._schedule(
                        "start", START_WINDOW, self._start_timeout, resume=True
                    )
                return

        if power > START_W:
            self.candidate_started_at = now.isoformat()
            self.candidate_start_energy_kwh = self._energy()
            self._save()
            self._schedule("start", START_WINDOW, self._start_timeout)
            if power > ACTIVE_W:
                self._confirm_start()

    def _confirm_start(self) -> None:
        """Promote the hidden candidate to the official cycle start."""
        if not self.candidate_started_at:
            return
        self.last_started_at = self.candidate_started_at
        self.last_started_energy_kwh = self.candidate_start_energy_kwh
        self.candidate_started_at = None
        self.candidate_start_energy_kwh = None
        self.dry_seen = False
        self.dry_candidate_at = None
        self.drying_started_at = None
        self.finish_candidate_at = None
        self.finish_candidate_energy_kwh = None
        self.finished_entered_at = None
        self._cancel("start")
        self._cancel("finished_min")
        self._cancel("finished_max")
        self._set_state(WET)

        # The confirming reading may itself already be inside the dryer band or
        # otherwise relevant to the newly active cycle.
        if self.power is not None:
            self._reconcile_power(self.power)

    def _reconcile_finished(
        self, power: float, now: datetime, *, resume: bool = False
    ) -> None:
        if not self.finished_entered_at:
            self.finished_entered_at = now.isoformat()
            self._save()

        try:
            entered = datetime.fromisoformat(self.finished_entered_at)
        except ValueError:
            entered = now
            self.finished_entered_at = entered.isoformat()
            self._save()

        elapsed = (now - entered).total_seconds()
        if elapsed >= FINISHED_MAX:
            self._return_idle()
            return
        if elapsed >= FINISHED_MIN and power < ASLEEP_W:
            self._return_idle()
            return

        if elapsed < FINISHED_MIN and "finished_min" not in self.timers:
            self._schedule(
                "finished_min",
                max(0, int(FINISHED_MIN - elapsed)),
                self._finished_min_timeout,
                resume=resume,
            )
        if "finished_max" not in self.timers:
            self._schedule(
                "finished_max",
                max(0, int(FINISHED_MAX - elapsed)),
                self._finished_max_timeout,
                resume=resume,
            )

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

    def _clear_start_candidate(self) -> None:
        self._cancel("start")
        self.candidate_started_at = None
        self.candidate_start_energy_kwh = None
        self._save()

    def _cancel_dry_candidate(self) -> None:
        self._cancel("dry")
        if self.dry_candidate_at is not None:
            self.dry_candidate_at = None
            self._save()

    def _cancel_finish_candidate(self) -> None:
        self._cancel("finish")
        if (
            self.finish_candidate_at is not None
            or self.finish_candidate_energy_kwh is not None
        ):
            self.finish_candidate_at = None
            self.finish_candidate_energy_kwh = None
            self._save()

    @callback
    def _start_timeout(self, _now: datetime) -> None:
        self._clear_start_candidate()

    @callback
    def _dry_timeout(self, _now: datetime) -> None:
        if (
            self.state != WET
            or self.power is None
            or not (DRY_MIN_W <= self.power <= DRY_MAX_W)
        ):
            self._cancel_dry_candidate()
            return

        self.dry_seen = True
        self.drying_started_at = self.dry_candidate_at
        self.dry_candidate_at = None
        self._set_state(DRY)

    @callback
    def _finish_timeout(self, _now: datetime) -> None:
        if self.state not in (WET, DRY) or self.power is None or self.power >= START_W:
            self._cancel_finish_candidate()
            return
        if not self.finish_candidate_at:
            return

        self.last_finished_at = self.finish_candidate_at
        finish_energy = self.finish_candidate_energy_kwh
        if finish_energy is None:
            finish_energy = self._energy()

        self.last_cycle_energy_kwh = None
        if (
            finish_energy is not None
            and self.last_started_energy_kwh is not None
            and finish_energy >= self.last_started_energy_kwh
        ):
            self.last_cycle_energy_kwh = round(
                finish_energy - self.last_started_energy_kwh, 3
            )

        self.last_cycle_outcome = self._classify_outcome()
        self.finish_candidate_at = None
        self.finish_candidate_energy_kwh = None
        self.finished_entered_at = dt_util.now().isoformat()
        self._set_state(FINISHED)
        self._reconcile_finished(self.power, dt_util.now())

    def _classify_outcome(self) -> str:
        if not self.dry_seen or not self.drying_started_at:
            return OUTCOME_WET
        if not self.last_started_at:
            return OUTCOME_WET_DRY
        try:
            dry_started = datetime.fromisoformat(self.drying_started_at)
            cycle_started = datetime.fromisoformat(self.last_started_at)
        except ValueError:
            return OUTCOME_WET_DRY
        if (dry_started - cycle_started).total_seconds() <= DRY_ONLY_BOUNDARY:
            return OUTCOME_DRY_ONLY
        return OUTCOME_WET_DRY

    @callback
    def _finished_min_timeout(self, _now: datetime) -> None:
        if self.state == FINISHED and self.power is not None and self.power < ASLEEP_W:
            self._return_idle()

    @callback
    def _finished_max_timeout(self, _now: datetime) -> None:
        if self.state == FINISHED:
            self._return_idle()

    def _return_idle(self) -> None:
        self._clear_start_candidate()
        self._cancel("finished_min")
        self._cancel("finished_max")
        self.finished_entered_at = None
        self._set_state(IDLE)

    def _set_state(self, state: str) -> None:
        if self.state == state:
            self._save()
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
            "dry_seen": self.dry_seen,
            "dry_candidate_at": self.dry_candidate_at,
            "drying_started_at": self.drying_started_at,
            "finish_candidate_at": self.finish_candidate_at,
            "finish_candidate_energy_kwh": self.finish_candidate_energy_kwh,
            "last_finished_at": self.last_finished_at,
            "last_cycle_energy_kwh": self.last_cycle_energy_kwh,
            "last_cycle_outcome": self.last_cycle_outcome,
            "finished_entered_at": self.finished_entered_at,
            "deadlines": self.deadlines,
        }
        self.entry.async_create_task(self.hass, self.store.async_save(data))
