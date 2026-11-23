"""The connections-ramp-h1 reading of a gcannon run: how far the ramp got before
the active connections' p99 went over the limit, and what the score makes of it."""

from pathlib import Path
import sys
import tempfile
import types
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import conn_hold  # noqa: E402
import latency_score  # noqa: E402


ARGS = types.SimpleNamespace(rate=100_000, ramp_p99_us=2_000)
GOOD = (800, 100_000, 5_000, 100_000, 90_000, 10_000)
OVER = (9_000, 100_000, 5_000, 200_000, 150_000, 50_000)
SILENT = (0, 0, 5_000, 150_000, 90_000, 60_000)


def summary(*spec):
    """spec: (p99_us, rps, active, idle_opened, idle_open, idle_closed) per interval."""
    rows = [dict(t=5.0 * (i + 1), p99_us=p, rps=r, active=a, idle_opened=o,
                 idle_open=n, idle_closed=c)
            for i, (p, r, a, o, n, c) in enumerate(spec)]
    found, why = conn_hold.ramp_summary(ARGS, {"timeline": rows})
    assert found is not None, why
    return found


class RampSummaryTests(unittest.TestCase):
    def test_a_ramp_that_held_the_limit_reaches_its_ceiling(self):
        got = summary(GOOD, GOOD, GOOD)
        self.assertEqual((got["reached"], got["stop"]), (105_000, "ceiling"))

    def test_two_intervals_over_stop_it_at_the_last_one_that_held(self):
        got = summary(GOOD, OVER, OVER, OVER)
        self.assertEqual((got["reached"], got["connections_open"], got["stop"]),
                         (105_000, 95_000, "p99"))
        self.assertEqual(got["stop_t"], 10.0)

    def test_one_interval_over_on_its_own_is_noise(self):
        self.assertEqual(summary(GOOD, OVER, GOOD, GOOD)["stop"], "ceiling")

    def test_an_interval_over_at_the_end_still_counts(self):
        got = summary(GOOD, GOOD, OVER)
        self.assertEqual((got["reached"], got["stop"]), (105_000, "p99"))

    def test_a_server_that_stops_answering_is_a_rate_failure(self):
        got = summary(GOOD, SILENT, SILENT)
        self.assertEqual((got["reached"], got["stop"]), (105_000, "rate"))

    def test_nothing_is_reached_when_the_first_interval_is_over(self):
        got = summary(OVER, OVER)
        self.assertEqual((got["reached"], got["connections_open"]), (0, 0))

    def test_reached_counts_what_was_opened_and_open_what_is_left(self):
        shedding = (700, 100_000, 5_000, 300_000, 60_000, 240_000)
        got = summary(GOOD, shedding, OVER, OVER)
        self.assertEqual((got["reached"], got["connections_open"], got["idle_closed"]),
                         (305_000, 65_000, 240_000))

    def test_no_timeline_is_an_error_not_a_zero(self):
        found, why = conn_hold.ramp_summary(ARGS, {})
        self.assertIsNone(found)
        self.assertIn("timeline", why)


class RampScoreTests(unittest.TestCase):
    P = "connections-ramp-h1"

    def test_the_score_is_the_share_of_two_million_reached(self):
        rows = [{"reached": r} for r in (2_000_000, 1_000_000, 0, None)]
        latency_score.score_rows(rows, self.P)
        self.assertEqual([r["score"] for r in rows], [100.0, 50.0, 0.0, 0.0])

    def test_pick_keeps_the_run_that_got_furthest(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            for run, reached in ((1, 900_000), (2, 1_400_000), (3, 1_100_000)):
                (d / f"{run}.kv").write_text(
                    f"rps=100000\nramp_reached={reached}\nstatus_2xx=1\n")
                (d / f"{run}.meta").write_text("cpu_usec=1\n")
            self.assertEqual(latency_score.pick(directory, self.P), 2)

    def test_the_board_scores_the_same_rows_the_same_way(self):
        html = (ROOT / "site/leaderboard/index.html").read_text()
        self.assertIn("'connections-ramp-h1':2000000", html)
        self.assertEqual(latency_score.FULL_RATE[self.P], 2_000_000.0)
        self.assertIn(self.P, latency_score.RAMP)


if __name__ == "__main__":
    unittest.main()
