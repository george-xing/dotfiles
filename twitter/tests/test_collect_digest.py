import importlib.util
import json
import pathlib
import os
import subprocess
import sys
import time
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = pathlib.Path(__file__).parents[1] / "bin" / "lib" / "collect-digest.py"
SPEC = importlib.util.spec_from_file_location("collect_digest", MODULE_PATH)
collect_digest = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(collect_digest)


class ChooseStallActionTests(unittest.TestCase):
    def test_page_probe_recovers_read_timeout_without_repeating_mutations(self):
        ready = {"origin": "https://x.com", "path": "/home"}
        with patch.object(collect_digest, "browser_eval", side_effect=[subprocess.TimeoutExpired("eval", 30), ready]) as evaluate, \
             patch.object(collect_digest.time, "sleep"):
            self.assertEqual(collect_digest.page_probe(), ready)
            self.assertEqual(evaluate.call_count, 2)
        with patch.object(collect_digest, "run", side_effect=subprocess.TimeoutExpired("keys", 30)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                collect_digest.browser("keys", "Escape")
            self.assertEqual(run.call_count, 1)

    def test_read_transport_recovery_is_bounded(self):
        with patch.object(collect_digest, "browser_eval", side_effect=RuntimeError("transport")) as evaluate, \
             patch.object(collect_digest.time, "sleep"):
            with self.assertRaises(RuntimeError):
                collect_digest.page_probe()
            self.assertEqual(evaluate.call_count, 3)

    def test_timeout_kills_command_descendants(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = pathlib.Path(temp) / "orphan"
            child = "import time,pathlib; time.sleep(0.8); pathlib.Path(%r).touch()" % str(marker)
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',%r]); time.sleep(10)" % child
            with self.assertRaises(subprocess.TimeoutExpired):
                collect_digest.run([sys.executable, "-c", parent], timeout=0.2)
            time.sleep(1)
            self.assertFalse(marker.exists())

    def eval_js(self, expression, fixture):
        result = subprocess.run(
            ["/opt/homebrew/bin/node", "-e", fixture + "\nconsole.log(" + expression + ")"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    def test_for_you_selection_never_reclicks_active_tab(self):
        for selected, clicks in [("true", 0), ("false", 1)]:
            fixture = """
let clicks = 0;
const tab = {innerText: 'For you ', getAttribute: () => %s, click: () => clicks++};
global.document = {querySelectorAll: () => [tab]};
""" % json.dumps(selected)
            expression = "JSON.stringify({result:JSON.parse(" + collect_digest.ENSURE_FOR_YOU_JS + "),clicks})"
            result = self.eval_js(expression, fixture)
            self.assertEqual(result["clicks"], clicks)
            self.assertEqual(result["result"], {"found": True, "clicked": bool(clicks)})

    def test_missing_for_you_tab_does_not_click_another_tab(self):
        result = self.eval_js(collect_digest.ENSURE_FOR_YOU_JS,
                              "global.document = {querySelectorAll: () => []};")
        self.assertEqual(result, {"found": False, "clicked": False})

    def test_dialog_with_zero_height_root_and_fixed_child_is_detected(self):
        fixture = """
const child = {getBoundingClientRect: () => ({width:600,height:400}),getClientRects:()=>[{}]};
const dialog = {innerText:'Snooze Topics',getBoundingClientRect:()=>({width:1200,height:0}),getClientRects:()=>[{}],querySelectorAll:()=>[child]};
global.document = {querySelectorAll:()=>[dialog]};
global.getComputedStyle = () => ({visibility:'visible',display:'block'});
"""
        self.assertEqual(self.eval_js(collect_digest.DIALOG_JS, fixture), "Snooze Topics")
        self.assertIsNone(self.eval_js(collect_digest.DIALOG_JS, fixture +
                                      "\nglobal.getComputedStyle = () => ({visibility:'hidden',display:'none'});"))

    def test_absent_dialog_is_json_null_not_truthy_python_none_text(self):
        self.assertIsNone(self.eval_js(collect_digest.DIALOG_JS,
                                      "global.document = {querySelectorAll: () => []};"))
        with patch.object(collect_digest, "browser", return_value=subprocess.CompletedProcess([], 0, "result: null", "")):
            self.assertIsNone(collect_digest.dialog_signature())

    def test_escape_must_clear_dialog_before_collection_resumes(self):
        with patch.object(collect_digest, "browser", return_value=subprocess.CompletedProcess([], 0, "sent: Escape", "")), \
             patch.object(collect_digest.time, "sleep"), \
             patch.object(collect_digest, "dialog_signature", return_value="Snooze Topics"), \
             patch.object(collect_digest, "capture_stall_screenshot", return_value=("/tmp/stall.png", None)), \
             patch.object(collect_digest, "fail", side_effect=RuntimeError("blocked")) as fail:
            with self.assertRaisesRegex(RuntimeError, "blocked"):
                collect_digest.dismiss_dialog()
            self.assertEqual(fail.call_args.args[0], "stall")

    def test_startup_warms_a_frame_then_only_hidden_collection_needs_more(self):
        for hidden in (True, False):
            with self.subTest(hidden=hidden), tempfile.TemporaryDirectory() as directory:
                clock = [0.0]
                def sleep(seconds):
                    clock[0] += seconds
                def evaluate(js):
                    if js == collect_digest.ENSURE_FOR_YOU_JS:
                        return {"found": True, "clicked": False}
                    return True
                post = {"statusUrl": "https://x.com/example/status/123", "timeISO": "2026-09-22T00:00:00Z", "text": "Example"}
                with patch.object(collect_digest, "RUN_DIR", pathlib.Path(directory)), \
                     patch.object(collect_digest, "STATE_DIR", pathlib.Path(directory)), \
                     patch.object(collect_digest, "WALL_SECONDS", 3), \
                     patch.object(collect_digest.time, "monotonic", side_effect=lambda: clock[0]), \
                     patch.object(collect_digest.time, "sleep", side_effect=sleep), \
                     patch.object(collect_digest, "browser", return_value=subprocess.CompletedProcess([], 0, "", "")), \
                     patch.object(collect_digest, "browser_eval", side_effect=evaluate), \
                     patch.object(collect_digest, "verify_page", side_effect=lambda: (self.assertGreaterEqual(frame.call_count, 1), hidden)[1]), \
                     patch.object(collect_digest, "dialog_signature", return_value=None), \
                     patch.object(collect_digest, "extract_tiles", return_value=[post]), \
                     patch.object(collect_digest, "render_background_frame") as frame:
                    self.assertEqual(collect_digest.main(), 0)
                    metadata = json.loads((pathlib.Path(directory) / "collection.json").read_text())
                    self.assertEqual(frame.call_count, 5 if hidden else 1)
                    self.assertEqual(metadata["backgroundFrames"], frame.call_count - 1)
                    self.assertEqual(metadata["scanned"], 1)
                    self.assertEqual(metadata["reason"], "wall_budget")

    def test_background_frame_failure_is_not_a_clean_plateau(self):
        with patch.object(collect_digest, "browser", return_value=subprocess.CompletedProcess([], 1, "", "capture failed")), \
             patch.object(collect_digest, "fail", side_effect=RuntimeError("no frame")) as fail:
            with self.assertRaisesRegex(RuntimeError, "no frame"):
                collect_digest.render_background_frame()
            self.assertEqual(fail.call_args.args[0], "visibility")

    def test_default_collection_target_and_bounded_budget(self):
        assert SPEC is not None and SPEC.loader is not None
        with patch.dict(os.environ, {}, clear=True):
            module = importlib.util.module_from_spec(SPEC)
            SPEC.loader.exec_module(module)
        self.assertEqual(module.HEALTHY_TARGET, 150)
        self.assertEqual(module.WALL_SECONDS, 300)
        self.assertEqual(module.MATURE_PLATEAU_SECONDS, 120)
        self.assertEqual((module.ESCAPE_CAP, module.TOP_CAP, module.HOME_RECOVERY_CAP), (3, 3, 2))

    def test_collection_environment_overrides_remain_supported(self):
        assert SPEC is not None and SPEC.loader is not None
        with patch.dict(os.environ, {
            "TWITTER_DIGEST_HEALTHY_TARGET": "175",
            "TWITTER_DIGEST_WALL_SECONDS": "360",
            "TWITTER_DIGEST_MATURE_PLATEAU_SECONDS": "140",
        }):
            module = importlib.util.module_from_spec(SPEC)
            SPEC.loader.exec_module(module)
        self.assertEqual((module.HEALTHY_TARGET, module.WALL_SECONDS,
                          module.MATURE_PLATEAU_SECONDS), (175, 360, 140))

    def test_target_does_not_end_immature_plateau(self):
        self.assertEqual(collect_digest.choose_stall_action(
            scanned=150, elapsed=119, dialog_signature=None,
            handled_dialogs=set(), escape_used=0, top_used=0, home_used=0,
        ), "scroll_top")

    def test_mature_plateau_target_boundary(self):
        for scanned, expected in [(149, "scroll_top"), (150, "stop_clean_plateau")]:
            with self.subTest(scanned=scanned):
                self.assertEqual(collect_digest.choose_stall_action(
                    scanned=scanned, elapsed=120, dialog_signature=None,
                    handled_dialogs=set(), escape_used=0, top_used=0, home_used=0,
                ), expected)

    def test_collection_metadata_reports_target_and_actual_shortfall(self):
        for scanned, shortfall in [(0, 150), (149, 1), (150, 0), (151, 0)]:
            with self.subTest(scanned=scanned), \
                 patch.object(collect_digest, "atomic_write_json") as write:
                metadata = collect_digest.write_collection(
                    seen={str(i): {} for i in range(scanned)}, articles={},
                    elapsed=300, reason="wall_budget", escape_used=0,
                    top_used=0, home_used=0,
                )
                self.assertEqual(metadata["scanned"], scanned)
                self.assertEqual(metadata.get("scanTarget"), 150)
                self.assertEqual(metadata.get("scanShortfall"), shortfall)
                self.assertEqual(metadata.get("wallBudgetSeconds"), 300)
                self.assertEqual(write.call_args.args, (collect_digest.RUN_DIR / "collection.json", metadata))

    def test_hidden_page_requires_authenticated_expected_route_and_real_content(self):
        valid = {"origin": "https://x.com", "path": "/home", "title": "", "vis": "hidden",
                 "iw": 1200, "ih": 800, "hasPrimaryColumn": True,
                 "hasAuthenticatedNav": True, "hasLoginWall": False}
        post = {"statusUrl": "https://x.com/example/status/123", "timeISO": "2026-09-21T00:00:00Z", "text": "Example"}
        def failure(kind, message):
            raise ValueError(kind)
        with patch.object(collect_digest, "bring_x_target_to_front"), \
             patch.object(collect_digest, "render_background_frame"), \
             patch.object(collect_digest.time, "sleep"), \
             patch.object(collect_digest, "fail", side_effect=failure):
            with patch.object(collect_digest, "page_probe", return_value=valid), \
                 patch.object(collect_digest, "extract_tiles", return_value=[post]):
                self.assertTrue(collect_digest.verify_page())
            cases = [({"hasLoginWall": True}, [post], "auth"),
                     ({"hasAuthenticatedNav": False}, [post], "dom"),
                     ({"path": "/search"}, [post], "dom"),
                     ({"origin": "https://example.com"}, [post], "dom"),
                     ({"iw": 0}, [post], "visibility"),
                     ({"hasPrimaryColumn": False}, [post], "dom"),
                     ({}, [], "visibility"),
                     ({}, [{**post, "isPromoted": True}], "visibility")]
            for overrides, posts, kind in cases:
                with self.subTest(overrides=overrides, posts=posts), \
                     patch.object(collect_digest, "page_probe", return_value={**valid, **overrides}), \
                     patch.object(collect_digest, "extract_tiles", return_value=posts), \
                     self.assertRaisesRegex(ValueError, kind):
                    collect_digest.verify_page()

    def test_hidden_feed_gets_a_real_frame_before_content_is_judged(self):
        probe = {"origin": "https://x.com", "path": "/home", "vis": "hidden",
                 "iw": 1200, "ih": 800, "hasPrimaryColumn": True,
                 "hasAuthenticatedNav": True, "hasLoginWall": False}
        post = {"statusUrl": "https://x.com/example/status/123", "timeISO": "2026-09-21T00:00:00Z", "text": "Example"}
        events = []
        def extract():
            events.append("extract")
            return [post] if events.count("extract") == 2 else []
        with patch.object(collect_digest, "page_probe", return_value=probe), \
             patch.object(collect_digest, "bring_x_target_to_front"), \
             patch.object(collect_digest.time, "sleep"), \
             patch.object(collect_digest, "render_background_frame", side_effect=lambda: events.append("frame")), \
             patch.object(collect_digest, "extract_tiles", side_effect=extract):
            self.assertTrue(collect_digest.verify_page())
        self.assertEqual(events, ["frame", "extract", "frame", "extract"])

    def test_readiness_waits_for_hydration_without_navigating_again(self):
        loading = {"origin": "https://x.com", "path": "/home"}
        ready = {**loading, "hasAuthenticatedNav": True, "hasPrimaryColumn": True}
        with patch.object(collect_digest, "page_probe", side_effect=[loading, loading, ready]) as probe, \
             patch.object(collect_digest.time, "sleep"), \
             patch.object(collect_digest, "browser") as browser:
            self.assertEqual(collect_digest.ready_page_probe(), ready)
            self.assertEqual(probe.call_count, 3)
            browser.assert_not_called()

    def test_readiness_stops_immediately_on_login_wall_and_bounds_loading(self):
        loading = {"origin": "https://x.com", "path": "/home"}
        with patch.object(collect_digest.time, "sleep"):
            with patch.object(collect_digest, "page_probe", return_value={**loading, "hasLoginWall": True}) as probe:
                self.assertTrue(collect_digest.ready_page_probe()["hasLoginWall"])
                self.assertEqual(probe.call_count, 1)
            with patch.object(collect_digest, "page_probe", return_value=loading) as probe:
                self.assertEqual(collect_digest.ready_page_probe(attempts=3), loading)
                self.assertEqual(probe.call_count, 3)

    def test_new_dialog_gets_one_escape(self):
        self.assertEqual(
            collect_digest.choose_stall_action(
                scanned=130,
                elapsed=154,
                dialog_signature="Snooze Topics",
                handled_dialogs=set(),
                escape_used=0,
                top_used=0,
                home_used=0,
            ),
            "escape",
        )

    def test_recurring_dialog_cannot_be_called_clean_plateau(self):
        self.assertEqual(
            collect_digest.choose_stall_action(
                scanned=150,
                elapsed=154,
                dialog_signature="Snooze Topics",
                handled_dialogs={"Snooze Topics"},
                escape_used=1,
                top_used=1,
                home_used=0,
            ),
            "blocked_dialog",
        )

    def test_under_target_feed_exhausts_recovery_caps_before_shipping(self):
        self.assertEqual(
            collect_digest.choose_stall_action(
                scanned=12,
                elapsed=130,
                dialog_signature=None,
                handled_dialogs=set(),
                escape_used=0,
                top_used=0,
                home_used=0,
            ),
            "scroll_top",
        )
        self.assertEqual(
            collect_digest.choose_stall_action(
                scanned=12,
                elapsed=160,
                dialog_signature=None,
                handled_dialogs=set(),
                escape_used=0,
                top_used=collect_digest.TOP_CAP,
                home_used=0,
            ),
            "home_refresh",
        )
        self.assertEqual(
            collect_digest.choose_stall_action(
                scanned=12,
                elapsed=175,
                dialog_signature=None,
                handled_dialogs=set(),
                escape_used=0,
                top_used=collect_digest.TOP_CAP,
                home_used=collect_digest.HOME_RECOVERY_CAP,
            ),
            "stop_clean_plateau",
        )


if __name__ == "__main__":
    unittest.main()
