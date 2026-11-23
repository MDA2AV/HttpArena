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


ARGS = types.SimpleNamespace(rate=100_000, ramp_p99_us=2_000, idle_min_s=30.0)
# Nothing closed: the idle timeout is tested on its own below.
GOOD = (800, 100_000, 5_000, 100_000, 100_000, 0)
OVER = (9_000, 100_000, 5_000, 200_000, 200_000, 0)
SILENT = (0, 0, 5_000, 150_000, 150_000, 0)

# The profile's own ramp: 1.9M idle connections opened evenly over 120 s.
IDLE, RAMP_S = 1_900_000, 120.0


def opened(t):
    return int(min(max(t, 0.0), RAMP_S) / RAMP_S * IDLE)


def ramp(closes, p99=800, rps=100_000, seconds=130):
    """A run of the profile, one row every five seconds. closes(t) says how many
    idle connections the server had closed by t."""
    rows = []
    for t in range(5, seconds + 1, 5):
        o, c = opened(t), closes(t)
        rows.append(dict(t=float(t), p99_us=p99, rps=rps,
                         active=int(4_096 + 95_904 * min(t, RAMP_S) / RAMP_S),
                         idle_opened=o, idle_open=o - c, idle_closed=c))
    return rows


def after(timeout):
    """A server that closes each idle connection `timeout` seconds after it opened."""
    return lambda t: opened(t - timeout)


def read(rows):
    found, why = conn_hold.ramp_summary(ARGS, {"timeline": rows})
    assert found is not None, why
    return found


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
                         (105_000, 105_000, "p99"))
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

    def test_reached_counts_what_was_opened_and_open_the_most_at_once(self):
        got = read(ramp(after(40)))
        self.assertEqual(got["reached"], 100_000 + IDLE)
        # the peak is when the last connection opens: 100K active and the idle
        # ones of the last 40 s
        self.assertEqual(got["connections_open"], 100_000 + opened(120) - opened(80))
        self.assertEqual(got["idle_closed"], opened(130 - 40))
        # what is open at the end of the run is less, and is not what is kept
        self.assertGreater(got["connections_open"], 100_000 + IDLE - opened(130 - 40))

    def test_no_timeline_is_an_error_not_a_zero(self):
        found, why = conn_hold.ramp_summary(ARGS, {})
        self.assertIsNone(found)
        self.assertIn("timeline", why)


class IdleTimeoutTests(unittest.TestCase):
    def test_a_server_that_never_closes_is_not_affected(self):
        got = read(ramp(lambda t: 0))
        self.assertEqual((got["stop"], got["reached"]), ("ceiling", 2_000_000))

    def test_a_five_second_timeout_ends_the_ramp_at_once(self):
        # what actix did before its timeout was raised
        got = read(ramp(after(4.6)))
        self.assertEqual((got["stop"], got["reached"], got["connections_open"]),
                         ("shed", 0, 0))
        self.assertEqual(got["stop_t"], 5.0)
        self.assertAlmostEqual(got["stop_idle_age_s"], 4.6, places=1)

    def test_the_first_lines_of_a_real_five_second_run(self):
        opened_, closed = [79_160, 158_340, 237_500], [6_250, 85_420, 164_580]
        rows = [dict(t=5.0 * (i + 1), p99_us=120, rps=100_000, active=8_000,
                     idle_opened=o, idle_open=o - c, idle_closed=c)
                for i, (o, c) in enumerate(zip(opened_, closed))]
        got = read(rows)
        self.assertEqual((got["stop"], got["reached"]), ("shed", 0))
        self.assertAlmostEqual(got["stop_idle_age_s"], 4.6, places=1)

    def test_a_twenty_second_timeout_scores_what_opened_before_its_first_closes(self):
        got = read(ramp(after(20)))
        self.assertEqual((got["stop"], got["stop_t"]), ("shed", 25.0))
        self.assertEqual(got["reached"], 20_080 + opened(20))   # the t = 20 row

    def test_thirty_seconds_is_enough(self):
        got = read(ramp(after(30)))
        self.assertEqual((got["stop"], got["reached"]), ("ceiling", 2_000_000))

    def test_a_coarse_clock_may_close_up_to_a_second_early(self):
        self.assertEqual(read(ramp(after(29.1)))["stop"], "ceiling")
        self.assertEqual(read(ramp(after(28.5)))["stop"], "shed")

    def test_the_rule_is_the_one_asked_for(self):
        rows = ramp(after(12))
        self.assertEqual(read(rows)["stop"], "shed")
        found, _ = conn_hold.ramp_summary(
            types.SimpleNamespace(rate=100_000, ramp_p99_us=2_000, idle_min_s=10.0),
            {"timeline": rows})
        self.assertEqual(found["stop"], "ceiling")

    def test_a_few_resets_are_not_shedding(self):
        # under 1% of what was opened: 500 resets in the first five seconds
        self.assertEqual(read(ramp(lambda t: 500))["stop"], "ceiling")

    def test_closing_the_whole_fleet_at_once_is_early_for_the_young_ones(self):
        got = read(ramp(lambda t: opened(t) if t >= 100 else 0))
        self.assertEqual(got["stop"], "shed")
        self.assertEqual(got["stop_t"], 100.0)

    def test_it_counts_from_where_the_server_starts_shedding_early(self):
        # a 60 s timeout until t=60, then everything older than 5 s is closed
        rows = ramp(lambda t: opened(t - 60) if t <= 60 else opened(t - 5))
        got = read(rows)
        self.assertEqual(got["stop"], "shed")
        self.assertEqual(got["stop_t"], 65.0)
        self.assertEqual(got["reached"],
                         rows[11]["active"] + rows[11]["idle_opened"])  # t = 60

    def test_the_rate_and_the_p99_are_still_the_limit(self):
        rows = ramp(lambda t: 0)
        for r in rows[6:]:
            r["p99_us"] = 5_000
        self.assertEqual(read(rows)["stop"], "p99")
        for r in rows[6:]:
            r["rps"] = 10
        self.assertEqual(read(rows)["stop"], "rate")

    def test_a_timeline_without_idle_connections_has_no_age(self):
        rows = [dict(t=5.0, p99_us=800, rps=100_000, active=5_000)]
        self.assertIsNone(conn_hold.idle_age(rows, 0))
        self.assertEqual(read(rows)["stop"], "ceiling")

    def test_the_default_minimum_is_thirty_seconds(self):
        self.assertEqual(conn_hold.IDLE_MIN_S, 30.0)
        self.assertEqual(conn_hold.IDLE_SLACK_S, 1.0)


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
