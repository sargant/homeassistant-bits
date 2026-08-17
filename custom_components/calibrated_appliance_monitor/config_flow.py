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
from homeassistant.helpers.selector import DeviceSelector

from .const import APPLIANCE_ID, APPLIANCE_NAME, CONF_SOURCE_DEVICE, DOMAIN


class CalibratedApplianceMonitorConfigFlow(ConfigFlow, domain=DOMAIN):
    """Add the fixed dishwasher monitor."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Create the entry without a setup form."""
        await self.async_set_unique_id(APPLIANCE_ID)
        self._abort_if_unique_id_configured()
        return self.async_create_entry(title=APPLIANCE_NAME, data={})

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        """Configure the source after the integration has been added."""
        return CalibratedApplianceMonitorOptionsFlow()


class CalibratedApplianceMonitorOptionsFlow(OptionsFlowWithReload):
    """Select the smart plug feeding the detector."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Select the source smart plug."""
        if user_input is not None:
            return self.async_create_entry(data=user_input)

        schema = vol.Schema({vol.Required(CONF_SOURCE_DEVICE): DeviceSelector()})
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(
                schema, self.config_entry.options
            ),
        )
