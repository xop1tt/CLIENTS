from __future__ import annotations

from leadgen.integrations.base import Adapter
from leadgen.integrations.hunter import HunterAdapter
from leadgen.integrations.webhook import WebhookAdapter

# Apollo и Snov.io сознательно не подключены: см. docs/integrations.md
ADAPTER_TYPES: dict[str, type[Adapter]] = {
    WebhookAdapter.name: WebhookAdapter,
    HunterAdapter.name: HunterAdapter,
}
