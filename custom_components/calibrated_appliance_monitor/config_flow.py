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

from .const import (
    ALGORITHM_INDESIT_D2IHL326UK,
    APPLIANCE_ID,
    APPLIANCE_NAME,
    CONF_ALGORITHM,
    CONF_SOURCE_DEVICE,
    DOMAIN,
)


class CalibratedApplianceMonitorConfigFlow(ConfigFlow, domain=DOMAIN):
    """Add the appliance monitor."""

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
        """Configure the source and calibration after the integration is added."""
        return CalibratedApplianceMonitorOptionsFlow()


class CalibratedApplianceMonitorOptionsFlow(OptionsFlowWithReload):
    """Select the inputs used by the detector."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Select the source device and calibrated algorithm."""
        if user_input is not None:
            return self.async_create_entry(data=user_input)

        schema = vol.Schema(
            {
                vol.Required(CONF_SOURCE_DEVICE): DeviceSelector(),
                vol.Required(CONF_ALGORITHM): SelectSelector(
                    SelectSelectorConfig(
                        options=[
                            {
                                "value": ALGORITHM_INDESIT_D2IHL326UK,
                                "label": "Indesit D2IHL326UK dishwasher",
                            }
                        ]
                    )
                ),
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(
                schema, self.config_entry.options
            ),
        )
