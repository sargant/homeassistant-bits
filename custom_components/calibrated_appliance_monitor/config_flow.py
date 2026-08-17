"""Configuration for Calibrated Appliance Monitor."""

from typing import Any

import voluptuous as vol

from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
    OptionsFlowWithReload,
)
from homeassistant.core import callback
from homeassistant.helpers.selector import (
    DeviceSelector,
    SelectSelector,
    SelectSelectorConfig,
)

from .algorithms import ALGORITHMS, ALGORITHM_OPTIONS
from .const import CONF_ALGORITHM, CONF_SOURCE_DEVICE, DOMAIN


class CalibratedApplianceMonitorConfigFlow(ConfigFlow, domain=DOMAIN):
    """Add an empty appliance monitor entry."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Create an entry without asking setup questions."""
        return self.async_create_entry(title="Calibrated Appliance Monitor", data={})

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        """Configure the source device and calibrated algorithm afterwards."""
        return CalibratedApplianceMonitorOptionsFlow()


class CalibratedApplianceMonitorOptionsFlow(OptionsFlowWithReload):
    """Select the source device and algorithm for one appliance entry."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Configure one monitored appliance."""
        if user_input is not None:
            monitor_type = ALGORITHMS[user_input[CONF_ALGORITHM]]
            self.hass.config_entries.async_update_entry(
                self.config_entry, title=monitor_type.appliance_name
            )
            return self.async_create_entry(data=user_input)

        schema = vol.Schema(
            {
                vol.Required(CONF_SOURCE_DEVICE): DeviceSelector(),
                vol.Required(CONF_ALGORITHM): SelectSelector(
                    SelectSelectorConfig(options=ALGORITHM_OPTIONS)
                ),
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(
                schema, self.config_entry.options
            ),
        )
