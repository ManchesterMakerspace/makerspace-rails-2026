from datetime import datetime, timedelta, timezone
import json
import unittest

from welcomepi.inputs import ACTIVITY, DoorFeed, TOPICS


UTC = timezone.utc
NOW = datetime(2026, 11, 24, 17, 0, 0, tzinfo=UTC)
EPOCH = int(NOW.timestamp())


class DoorRecords(unittest.TestCase):
    def setUp(self):
        self.feed = DoorFeed()

    def receive(self, topic, text, at=0, retained=False):
        return self.feed.message(topic, text.encode(), retained, NOW, at)

    def test_activity_welcome_uses_numeric_id_time_and_leaves_uid_empty(self):
        self.assertIn((ACTIVITY, 2), TOPICS)
        for suffix in ("activeMember/00aBC01", "00aBC01"):
            with self.subTest(suffix=suffix):
                self.feed = DoorFeed()
                header = f"welcome {EPOCH - 4} "
                body = r'{"document": {"\_id": %d, "name": "River", "where": "Entry A"} }' % EPOCH
                source = "activity/checkins/" + suffix
                kind, record, _, topic, fresh = self.receive(source, header + body + "\\")
                self.assertEqual((kind, topic, fresh), ("checkin", source, True))
                self.assertEqual((record.uid, record.at, record.name, record.location),
                                 ("", NOW, "River", "Entry A"))

    def test_processed_capture_with_missing_envelope_brace_and_reader_fallback(self):
        header = f"2026-11-24 12:00:00:330\\\nprocessed {EPOCH} "
        body = (r'{"document": {"\_id": %d, "uid": "0011", "where": "  ", "validity": "activeMember",'
                r'"holder": "River   Example ", "reader":"Reader A", "time": %d}' % (EPOCH, EPOCH * 1000))
        source = "activity/checkins/activeMember/99FF"
        _, record, _, topic, fresh = self.receive(source, header + body)
        self.assertEqual(topic, source)
        self.assertEqual((record.uid, record.at, record.name, record.location, fresh),
                         ("0011", NOW, "River Example", "Reader A", True))

    def test_explicit_card_uid_and_legacy_uid_identify_the_presented_card(self):
        for identifiers, expected in (({"cardUID": "00aF"}, "00aF"),
                                      ({"cardUID": "00aF", "uid": "00AF"}, "00AF"),
                                      ({"cardUID": "00aF", "uid": "00bb"}, ""),
                                      ({"cardUID": "Card-G", "uid": "card-g"}, "")):
            with self.subTest(identifiers=identifiers):
                self.feed = DoorFeed()
                doc = {"_id": EPOCH, "name": "River", **identifiers}
                event = self.receive("activity/checkins/reader-1", f"welcome {EPOCH} " + json.dumps(doc))
                self.assertEqual((event[1].name, event[1].uid), ("River", expected))

    def test_reader_topic_and_numeric_publication_time_are_independent_of_location_and_identity(self):
        source = "activity/checkins/A0B1C2"
        body = '{"document": {"_id": "door-record", "name": "River", "uid": "1234"}}'
        for epoch in (EPOCH, EPOCH * 1000):
            with self.subTest(epoch=epoch):
                self.feed = DoorFeed()
                _, record, _, topic, fresh = self.receive(source, f"welcome {epoch} " + body)
                self.assertEqual((topic, record.uid, record.location, record.at, fresh),
                                 (source, "1234", "blank:", NOW, True))
        with self.assertRaises(ValueError):
            self.receive(source, "welcome invalid " + body)

    def test_shell_insert_with_scalar_constructors_and_seconds_or_milliseconds(self):
        body = (r"{ \_id: ObjectId('aaaaaaaaaaaaaaaaaaaaaaaa')," + "\\\n"
                "&#x20; uid: '00aBC01', name: \"River &#x20; O'Neil\", time: Double('%d'), delay: NumberInt('0'), "
                " expiry: Double('1900000000000'), timeOf: ISODate('2026-11-24T17:00:00.000Z')\n}"
                % (EPOCH * 1000))
        for prefix, fresh in (("insert %d  " % EPOCH, True), ("&#x20;insert %d " % (EPOCH * 1000), True),
                              ("insert 1234566789000 ", False)):
            with self.subTest(prefix=prefix):
                self.feed = DoorFeed()
                _, record, _, _, live = self.receive("checkins/insert", prefix + body)
                self.assertEqual((record.at, record.uid, record.name, record.location),
                                 (NOW, "00aBC01", "River &#x20; O'Neil", "blank:"))
                self.assertEqual(live, fresh)

    def test_cross_feed_copy_updates_history_and_does_not_repeat_a_welcome(self):
        welcome = f'welcome {EPOCH} {{"document": {{"_id": {EPOCH}, "uid":"00ab", "name":"River", "where":"Entry A"}}}}'
        self.assertTrue(self.receive("activity/checkins/activeMember/0011", welcome)[-1])
        # Ingested and processed copies have distinct IDs; the richer record
        # still reaches the recent list. A subsequent distinct tap may greet.
        stamp = NOW - timedelta(seconds=3)
        def inserted(identifier, location):
            return (f'insert {EPOCH} {{"document": {{"_id":{{"$oid":"{identifier}"}}, "uid":"00AB", '
                    f'"holder":"River Example", "time":{stamp.timestamp() * 1000}, "where":"{location}", '
                    f'"timeOf":{{"$date":"{NOW.isoformat()}"}}}}}}')
        copy = inserted("a" * 24, "Entry A")
        _, record, _, _, fresh = self.receive("checkins/insert", copy, at=1)
        self.assertFalse(fresh)
        self.assertEqual(record.name, "River Example")
        self.assertFalse(self.receive("checkins/insert", copy, at=2)[-1])
        self.assertTrue(self.receive("checkins/insert", inserted("b" * 24, "Entry A"), at=3)[-1])
        self.assertTrue(self.receive("checkins/insert", inserted("a" * 24, "Entry B"), at=4)[-1])

    def test_non_hex_card_identifiers_remain_case_sensitive_across_feeds(self):
        doc = f'{{"_id": {EPOCH}, "uid": "Card-G", "time": {EPOCH}, "where": "Entry A"}}'
        self.assertTrue(self.receive("activity/checkins/99FF", f"processed {EPOCH} " + doc)[-1])
        self.assertTrue(self.receive("checkins/insert", f"insert {EPOCH} " + doc.replace("Card-G", "card-g"))[-1])

    def test_name_only_greeting_can_be_verified_by_later_document_uid(self):
        topic = "activity/checkins/activeMember/99FF"
        short = f'welcome {EPOCH} {{"document": {{"_id": {EPOCH}, "name": "River", "where": "Entry A"}}}}'
        full = (f'processed {EPOCH} {{"document": {{"_id": {EPOCH}, "uid": "0011", '
                '"holder": "River Example", "where": "Entry A"}}')
        name_only = self.receive(topic, short)
        self.assertEqual((name_only[1].uid, name_only[-1]), ("", True))
        self.assertFalse(self.receive(topic, short, at=1)[-1])
        verified = self.receive("activity/checkins/99FF", full, at=2)
        self.assertEqual((verified[1].uid, verified[-1]), ("0011", True))
        self.assertFalse(self.receive("activity/checkins/99FF", full, at=3)[-1])

        # A later name-only copy must not interrupt the verified greeting.
        self.feed = DoorFeed()
        self.assertTrue(self.receive("activity/checkins/99FF", full)[-1])
        self.assertFalse(self.receive(topic, short, at=1)[-1])
        self.assertTrue(self.receive(topic, short.replace("River", "Rowan"), at=2)[-1])

    def test_richer_uid_copy_can_finish_an_intervening_name_only_greeting_once(self):
        source = "activity/checkins/reader"
        base = {"_id": EPOCH, "where": "Entry A", "time": EPOCH}
        uid_only = f"processed {EPOCH} " + json.dumps({**base, "uid": "00AF"})
        welcome = f"welcome {EPOCH} " + json.dumps({**base, "name": "River"})
        full = f"insert {EPOCH} " + json.dumps({**base, "_id": "stored", "uid": "00AF", "holder": "River Example"})
        self.assertTrue(self.receive(source, uid_only)[-1])
        self.assertTrue(self.receive(source, welcome, at=1)[-1])
        self.assertFalse(self.receive("checkins/insert", full, at=2, retained=True)[-1])
        self.assertFalse(self.receive("checkins/insert", full.replace(f"insert {EPOCH} ", "insert 1000000000 "), at=3)[-1])
        enriched = self.receive("checkins/insert", full, at=4)
        self.assertEqual((enriched[-1], enriched[1].uid), (True, "00AF"))
        self.assertFalse(self.receive("checkins/insert", full, at=5)[-1])

        for intervening in (None, welcome.replace("River", "Rowan")):
            with self.subTest(intervening=intervening):
                self.feed = DoorFeed()
                self.receive(source, uid_only)
                if intervening:
                    self.receive(source, intervening, at=1)
                self.assertFalse(self.receive("checkins/insert", full, at=2)[-1])

    def test_unsupported_expressions_and_envelope_fail_without_emitting_a_record(self):
        for body in ("{_id: 1, uid: some_method()}", "{_id: 1, uid: record.value}",
                     "{_id: 1, uid: unknown + 'FF'}", '{"document": {"_id": 1, "time":'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.receive("activity/checkins/00AA", f"processed {EPOCH} " + body)
