# Reservation-to-MQTT daemon

`res2mqtt.py` polls MongoDB for approved shop and tool reservations and publishes
ongoing reservations plus retained `UpNext` messages. It refreshes its eight-hour
cache every 30 minutes by default and also publishes a reservation when its start
time arrives.

## Setup and use

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
cp tools/config.yaml.example tools/config.yaml
.venv/bin/python tools/res2mqtt.py
```

Configuration precedence is CLI, environment, then YAML. The default YAML path
is `tools/config.yaml`; change it with `--config` or `RES2MQTT_CONFIG`.
Every YAML key has a same-named kebab-case CLI option. Environment variables are:

`MLAB_URI` (required), `MONGO_DATABASE`, `MQTT_HOST` (required), `MQTT_PORT`,
`MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_CLIENT_ID`, `MQTT_TLS`,
`MQTT_TOPIC_PREFIX`, `REFRESH_MINUTES`, `WINDOW_HOURS`, `TIMEZONE`, and
`LOG_LEVEL`.

Topics use the resource's human-readable name without modification:
`reservations/<SHOPNAME>` for shop reservations and
`reservations/<SHOPNAME>/<TOOLNAME>` for tools. The next approved reservation
for each resource is retained at the same topic with `/UpNext` appended. MQTT
QoS 1 is used. Ensure shop and tool names are valid for your broker's topic
policy (MQTT itself permits spaces in topic names).

Both the legacy `paho-mqtt` 1.6.1 callback API and the versioned callback API
from `paho-mqtt` 2.x are supported.
