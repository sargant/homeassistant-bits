"""Configuration for Calibrated Appliance Monitor."""

from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult
from homeassistant.helpers.selector import (
    DeviceSelector,
    SelectSelector,
    SelectSelectorConfig,
)

from .algorithms import ALGORITHMS, ALGORITHM_OPTIONS
from .const import CONF_ALGORITHM, CONF_SOURCE_DEVICE, DOMAIN


class CalibratedApplianceMonitorConfigFlow(ConfigFlow, domain=DOMAIN):
    """Create one calibrated appliance monitor."""

    VERSION = 2

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Select the appliance identity and create its config entry."""
        if user_input is not None:
            monitor_type = ALGORITHMS[user_input[CONF_ALGORITHM]]
            return self.async_create_entry(
                title=f"{monitor_type.manufacturer} {monitor_type.model}",
                data=user_input,
            )

        schema = vol.Schema(
            {
                vol.Required(CONF_SOURCE_DEVICE): DeviceSelector(),
                vol.Required(CONF_ALGORITHM): SelectSelector(
                    SelectSelectorConfig(options=ALGORITHM_OPTIONS)
                ),
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema)
