from contextlib import redirect_stderr
from io import StringIO
import logging
from pathlib import Path
import socket
import sys
from tempfile import TemporaryDirectory
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import paho.mqtt.client as mqtt
from pymongo import MongoClient
from pymongo.errors import NetworkTimeout, OperationFailure, ServerSelectionTimeoutError
from pymongo.monitoring import CommandFailedEvent

from welcomepi.config import Settings
from welcomepi.inputs import TOPICS, start_mqtt
from welcomepi.logs import MongoFailures, driver_detail, kiosk_logging


def settings(**extra):
    return Settings.load({"MLAB_URI": "mongodb://app:p%40ss@db.example/test",
                          "LEDGER_URI": "mongodb://localhost/ledger", "MQTT_HOST": "localhost",
                          "MQTT_TLS": "false", **extra})


class SyslogTests(unittest.TestCase):
    def test_configuration_defaults_ipv6_and_invalid_pairs(self):
        self.assertIsNone(settings().syslog_server)
        self.assertEqual(settings().i2c_addresses, (0x24,))
        self.assertEqual(settings(WELCOMEPI_SYSLOG_HOST="::1", WELCOMEPI_SYSLOG_PORT="1514").syslog_server,
                         ("::1", 1514))
        for extra in ({"WELCOMEPI_SYSLOG_HOST": "192.0.2.1"}, {"WELCOMEPI_SYSLOG_PORT": "514"},
                      {"WELCOMEPI_SYSLOG_HOST": "host.invalid", "WELCOMEPI_SYSLOG_PORT": "514"},
                      {"WELCOMEPI_SYSLOG_HOST": "192.0.2.1", "WELCOMEPI_SYSLOG_PORT": "65536"},
                      {"WELCOMEPI_I2C_ADDRESSES": "0x80"}, {"WELCOMEPI_I2C_BUS": "/dev/mem"}):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                settings(**extra)

    def test_default_uses_local_syslog(self):
        sink = Mock(level=logging.NOTSET)
        with patch("welcomepi.logs.Path.is_socket", return_value=True), \
                patch("welcomepi.logs.SysLogHandler", return_value=sink) as handler:
            with kiosk_logging(settings()):
                logging.getLogger("welcomepi").info("local only")
        self.assertEqual(Path(handler.call_args.kwargs["address"]), Path("/dev/log"))
        self.assertEqual(sink.handle.call_args.args[0].getMessage(), "local only")

    @unittest.skipIf(sys.platform == "win32", "Unix syslog socket on the Linux host")
    def test_local_unix_socket_receives_tag_and_priority(self):
        with TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as collector:
            path = Path(directory) / "dev-log"
            collector.bind(str(path))
            collector.settimeout(2)
            with patch("welcomepi.logs.LOCAL_SYSLOG", path), kiosk_logging(settings()):
                logging.getLogger("welcomepi").warning("No PN532 found")
            self.assertRegex(collector.recv(4096), rb"^<28>welcomepi\[\d+\]: WARNING No PN532 found")

    def test_real_udp_delivers_syslog_priorities_and_redacts_without_local_copy(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(("127.0.0.1", 0))
            server.settimeout(2)
            config = settings(WELCOMEPI_SYSLOG_HOST="127.0.0.1", WELCOMEPI_SYSLOG_PORT=str(server.getsockname()[1]),
                              MQTT_PASSWORD="mqtt-private", WELCOMEPI_SLACK_TOKEN="slack-private")
            stderr = StringIO()
            with redirect_stderr(stderr), kiosk_logging(config):
                log = logging.getLogger("welcomepi.test")
                log.info("Card scan at MQTT checkins/insert (Door A), member Test Member")
                log.warning("No valid member found at local PN532 UART")
                log.error("MongoDB timeout\n%s p@ss mqtt-private slack-private", config.rails_uri + "?authMechanism=x")
            messages = [server.recv(9000).decode() for _ in range(3)]
        self.assertEqual(stderr.getvalue(), "")
        for line, prefix in zip(messages, ("<30>", "<28>", "<27>")):
            self.assertTrue(line.startswith(prefix), line)
            self.assertIn("welcomepi[", line)
        self.assertIn("Door A), member Test Member", messages[0])
        self.assertIn("No valid member found", messages[1])
        self.assertIn("MongoDB timeout", messages[2])
        for value in ("p@ss", "p%40ss", "mqtt-private", "slack-private", "Mechanism", "\n"):
            self.assertNotIn(value, messages[2])

    def test_mongo_retries_heartbeat_and_server_error_without_full_reply(self):
        listener = MongoFailures()
        command = Mock(spec=CommandFailedEvent, command_name="find", connection_id=("db", 27017),
                       failure={"code": 50, "errmsg": "operation exceeded time limit", "query": "private"})
        with self.assertLogs("welcomepi.logs", level="ERROR") as log:
            listener.failed(command)
            listener.failed(SimpleNamespace(connection_id=("db", 27017), reply=NetworkTimeout("read timed out")))
        self.assertIn("operation exceeded time limit (code 50)", log.output[0])
        self.assertIn("heartbeat", log.output[1])
        self.assertIn("NetworkTimeout: read timed out", log.output[1])
        error = OperationFailure("failure", 50, command.failure)
        self.assertIn("operation exceeded time limit", driver_detail(error))
        self.assertNotIn("private", str(log.output) + driver_detail(error))

    def test_real_pymongo_reports_unavailable_loopback_in_heartbeat(self):
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
            with self.assertLogs("welcomepi.logs", level="ERROR") as log, \
                    MongoClient("127.0.0.1", port, connect=False, serverSelectionTimeoutMS=200,
                                connectTimeoutMS=200, event_listeners=[MongoFailures()]) as client:
                with self.assertRaises(ServerSelectionTimeoutError):
                    client.test.members.find_one()
        self.assertIn("MongoDB heartbeat failed", str(log.output))
        self.assertIn(str(port), str(log.output))


class MqttErrors(unittest.TestCase):
    def setUp(self):
        self.factory = self.enterContext(patch("welcomepi.inputs.mqtt.Client"))
        self.client = self.factory.return_value
        self.client.loop_start.return_value = None  # Bookworm Paho 1.6.1
        self.client.subscribe.return_value = (0, 7)
        self.timer = self.enterContext(patch("welcomepi.inputs.Timer"))
        self.emit = Mock()
        start_mqtt(settings(), self.emit)

    def test_connack_subscription_rejection_and_keepalive_driver_reasons(self):
        with self.assertLogs("welcomepi.inputs", level="ERROR") as log:
            self.client.on_connect(self.client, None, {}, 5)
            self.client.on_connect(self.client, None, {}, 0)
            self.client.on_subscribe(self.client, None, 7, [128] + [2] * (len(TOPICS) - 1))
            self.client.on_disconnect(self.client, None, mqtt.MQTT_ERR_KEEPALIVE)
            self.client.on_log(self.client, None, mqtt.MQTT_LOG_ERR, "detailed Paho error")
        self.assertIn(mqtt.connack_string(5), log.output[0])
        self.assertIn("checkins/insert", log.output[1])
        self.assertIn("128", log.output[1])
        self.assertIn(mqtt.error_string(mqtt.MQTT_ERR_KEEPALIVE), log.output[2])
        self.assertIn("detailed Paho error", log.output[3])
        self.assertEqual(self.emit.call_count, 3)

    def test_v2_disconnect_preserves_broker_reason(self):
        reason = Mock(value=135, is_failure=True)
        reason.__str__ = lambda _: "Not authorized"
        with self.assertLogs("welcomepi.inputs", level="ERROR") as log:
            self.client.on_disconnect(self.client, None, object(), reason, SimpleNamespace(ReasonString="ACL denied"))
        self.assertIn("Not authorized (135) — ACL denied", log.output[0])

    def test_suback_timeout_retries_and_ignores_late_ack(self):
        self.client.subscribe.side_effect = [(0, 7), (0, 8)]
        self.client.on_connect(self.client, None, {}, 0)
        timeout = self.timer.call_args.args[1]
        with self.assertLogs("welcomepi.inputs", level="ERROR") as log:
            timeout()
        self.assertIn("ACK timed out", log.output[0])
        self.client.on_subscribe(self.client, None, 7, [2] * len(TOPICS))
        self.emit.assert_not_called()
        self.client.on_subscribe(self.client, None, 8, [2] * len(TOPICS))
        self.emit.assert_called_once_with("subscribed")

    def test_failed_submit_and_startup_report_driver_detail(self):
        self.client.subscribe.return_value = mqtt.MQTT_ERR_NO_CONN, None
        with self.assertLogs("welcomepi.inputs", level="ERROR") as log:
            self.client.on_connect(self.client, None, {}, 0)
            self.client.tls_set.side_effect = OSError("certificate verify failed")
            with self.assertRaises(OSError):
                start_mqtt(settings(MQTT_TLS="true"), self.emit)
        self.assertIn(mqtt.error_string(mqtt.MQTT_ERR_NO_CONN), log.output[0])
        self.assertIn("certificate verify failed", log.output[1])


class MqttSocketError(unittest.TestCase):
    def test_real_paho_reports_socket_refusal(self):
        signaled = Event()
        class Capture(logging.Handler):
            def emit(self, record):
                self.message = record.getMessage()
                signaled.set()
        handler = Capture(logging.ERROR)
        logger = logging.getLogger("welcomepi.inputs")
        logger.addHandler(handler)
        self.addCleanup(logger.removeHandler, handler)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))  # Reserved, with no listening broker.
            config = settings(MQTT_HOST="127.0.0.1", MQTT_PORT=str(reserved.getsockname()[1]))
            client = start_mqtt(config, Mock())
            try:
                self.assertTrue(signaled.wait(6))
                self.assertIn("ConnectionRefusedError", handler.message)
                self.assertIn("127.0.0.1", handler.message)
            finally:
                client.disconnect()
                client.loop_stop()
