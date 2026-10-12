#!/usr/bin/env python3
"""Regression tests for repeated Qwen searches across malformed tool calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('qwen-progress-guard.py')


class HookCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, QWEN_PROGRESS_STATE_DIR=self.tmp.name)

    def call(self, event='PreToolUse', name='run_shell_command', args=None,
             result=None, session='test', **fields):
        data = dict(hook_event_name=event, session_id=session, cwd='/repo',
                    tool_name=name, tool_input=args or {'command': 'cd /repo && grep -rn "ToolType" src/index.ts'}, **fields)
        if result is not None:
            data['tool_response'] = result
        if not SCRIPT.exists():
            return {}  # Baseline: launcher has no progress hook.
        p = subprocess.run(['python3', str(SCRIPT)], input=json.dumps(data),
                           text=True, capture_output=True, env=self.env, check=True)
        return json.loads(p.stdout or '{}')

    def result(self, pgid=100, text='(empty)'):
        return {'response_parts': [{'functionResponse': {'id': str(pgid), 'name': 'run_shell_command',
                'response': {'output': f'Output: {text}\nError: (none)\nExit Code: 1\nProcess Group PGID: {pgid}'}}}]}

    def executed(self, **kwargs):
        self.call(**kwargs)
        return self.call(event='PostToolUse', result=self.result(), **kwargs)


class GuardTests(HookCase):
    def test_pipeline_and_unknown_shell_commands_have_a_backstop(self):
        commands = [
            'grep -rin "reddit" src/reddit.ts | head && echo "---index---" && grep -n "ddit" src/index.ts',
            'custom-inspector --summary', 'npm test',
        ]
        for command in commands:
            with self.subTest(command=command):
                args = {'command': command}
                for _ in range(4):
                    self.assertEqual(self.call(args=args), {})
                    self.call('PostToolUse', args=args, result=self.result())
                out = self.call(args=args)
                self.assertEqual(out.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                self.call(args=args)
                self.assertIs(self.call(args=args).get('continue'), False)

    def test_generic_backstop_requires_four_unchanged_results(self):
        args = {'command': 'custom-status | head'}
        for n in range(8):
            self.assertEqual(self.call(args=args), {})
            self.call('PostToolUse', args=args, result=self.result(text=str(n // 3)))

    def test_git_inspection_chain_is_guarded(self):
        args = {'command': 'git log --oneline -20 && echo "---STATUS---" && git status',
                'directory': '/repo'}
        self.executed(args=args); self.executed(args=args)
        self.assertEqual(self.call(args=args)['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_chains_with_mutations_or_builds_are_not_guarded(self):
        for command in ['git status && git commit -m fix', 'git log && make',
                        'git log --output=result.txt', 'echo hello', 'rg x file &&']:
            args = {'command': command}
            self.executed(args=args); self.executed(args=args)
            self.assertEqual(self.call(args=args), {})

    def test_quoted_regex_alternation_is_guarded(self):
        for command in [
            r'cd ~/projects/example && grep -rn "account-session\|AccountSession" src/account-capture.ts',
            "rg 'account-session|AccountSession' src/account-capture.ts",
        ]:
            with self.subTest(command=command):
                args = {'command': command}
                self.executed(args=args); self.executed(args=args)
                self.assertEqual(self.call(args=args).get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')

    def test_shell_control_operators_remain_outside_guard(self):
        for command in ['grep x file | head', 'grep x file&& make', 'rg x file>out',
                        'rg "$(date)" file', 'rg `date` file', 'rg "unterminated',
                        'rg x file\nmake']:
            with self.subTest(command=command):
                args = {'command': command}
                self.executed(args=args); self.executed(args=args)
                self.assertEqual(self.call(args=args), {})

    def test_same_empty_search_with_interleaved_malformed_call_is_denied(self):
        self.executed()
        self.call(args={'function': 'grep ToolType src/index.ts'})
        self.call('PostToolUseFailure', args={'function': 'grep ToolType src/index.ts'}, error='missing command')
        self.call('PostToolUse', result=self.result(200), args={'description': 'another description', 'command': 'cd /repo && grep -rn "ToolType" src/index.ts'})
        out = self.call()
        self.assertEqual(out.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
        self.assertIn('different', out['hookSpecificOutput']['permissionDecisionReason'])

    def test_no_match_explanation_reaches_model(self):
        out = self.executed()
        self.assertIn('no matches', out.get('hookSpecificOutput', {}).get('additionalContext', ''))

    def test_persistent_retries_stop_without_allowing_permission_bypass(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='task')
        self.executed(); self.executed()
        self.call(); self.call()
        out = self.call()
        self.assertIs(out.get('continue'), False)
        self.assertNotIn('permissionDecision', out.get('hookSpecificOutput', {}))
        self.assertIs(self.call('UserPromptSubmit', prompt_id='p1', prompt='').get('continue'), False)

    def test_changing_results_allow_polling(self):
        for n in range(4):
            out = self.call()
            self.assertEqual(out, {})
            self.call('PostToolUse', result=self.result(n, str(n)))

    def test_successful_edit_and_user_prompt_reset(self):
        for event in ['PostToolUse', 'UserPromptSubmit']:
            self.executed(); self.executed()
            self.call(event, name='edit', result={'execution_status': 'success'}, prompt='new task')
            self.assertEqual(self.call(), {})

    def test_tool_continuation_does_not_reset_prompt_history(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='task')
        self.executed()
        self.call('UserPromptSubmit', prompt_id='p1', prompt='')
        self.executed()
        self.call('UserPromptSubmit', prompt_id='p1', prompt='')
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')
        self.call('UserPromptSubmit', prompt_id='p2', prompt='new task')
        self.assertEqual(self.call(), {})

    def test_failed_edit_does_not_reset(self):
        self.executed(); self.executed()
        self.call('PostToolUseFailure', name='edit', error='not found')
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_new_session_and_new_search_are_independent(self):
        self.executed(); self.executed()
        self.assertEqual(self.call(session='other'), {})
        self.assertEqual(self.call(args={'command': 'rg ToolType src/'}), {})

    def test_non_search_commands_are_not_guarded_or_approved(self):
        for _ in range(3):
            self.executed(args={'command': 'pytest -q'})
            self.assertEqual(self.call(args={'command': 'pytest -q'}), {})

    def test_read_file_detects_same_result_despite_call_ids(self):
        args = {'file_path': '/repo/src/index.ts'}
        for i in range(2):
            self.call('PostToolUse', name='read_file', args=args, result={'response_parts': [{'functionResponse': {'id': str(i), 'response': {'output': 'unchanged'}}}]})
        self.assertEqual(self.call(name='read_file', args=args)['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_native_scheduler_payload_ignores_display_and_pgid(self):
        for i in range(2):
            self.call('PostToolUse', result={'llmContent': f'Output: (empty)\nError: (none)\nExit Code: 1\nProcess Group PGID: {i}', 'returnDisplay': str(i)})
        self.assertEqual(self.call()['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_state_does_not_store_commands_or_results(self):
        self.executed()
        content = ''.join(p.read_text() for p in Path(self.tmp.name).glob('*.json'))
        self.assertNotIn('ToolType', content)
        self.assertNotIn('Process Group', content)


class RereadTests(HookCase):
    """Qwen Code keeps only the last few tool results, so re-reading cleared pages loops."""

    def setUp(self):
        super().setUp()
        self.files = Path(self.tmp.name) / 'repo'
        self.files.mkdir()
        self.readme = self.write('README.md', 1065)
        self.plan = self.write('plan.md', 184)
        self.pkg = self.write('package.json', 20)

    def write(self, name, lines):
        path = self.files / name
        path.write_text(''.join(f'line {n} of {name}\n' for n in range(1, lines + 1)))
        return str(path)

    def page(self, first, last, total):
        return f'Showing lines {first}-{last} of {total} total lines.\n\n---\n\nbody'

    def read(self, path, span=None, **args):
        """Run read_file through the hook like Qwen Code does; returns the Pre decision."""
        args = dict(args, file_path=path)
        decision = self.call(name='read_file', args=args)
        if decision:
            return decision
        text = self.page(*span) if span else 'whole file'
        response = {'response_parts': [{'functionResponse': {'id': 'x', 'name': 'read_file', 'response': {'output': text}}}]}
        self.post = self.call('PostToolUse', name='read_file', args=args, result=response)
        return decision

    def denied(self, decision):
        return decision.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'

    def test_rereading_a_cleared_page_is_refused_despite_offset_jitter(self):
        self.read(self.readme, (974, 1065, 1065), offset=973, limit=1065)
        decision = self.read(self.readme, offset=974, limit=533)
        self.assertTrue(self.denied(decision))
        reason = decision['hookSpecificOutput']['permissionDecisionReason']
        self.assertIn('Old tool result content cleared', reason)
        self.assertIn('grep_search', reason)

    def test_first_page_reread_without_offset_is_refused(self):
        self.read(self.readme, (1, 133, 1065))
        self.assertTrue(self.denied(self.read(self.readme, limit=1065)))

    def test_paging_a_large_file_stops_once_early_pages_are_cleared(self):
        self.assertFalse(self.denied(self.read(self.readme, (1, 133, 1065))))
        self.assertIn('1065 lines', self.post['hookSpecificOutput']['additionalContext'])
        self.assertFalse(self.denied(self.read(self.readme, (134, 232, 1065), offset=133, limit=533)))
        self.assertFalse(self.denied(self.read(self.readme, (233, 367, 1065), offset=232, limit=533)))
        self.assertFalse(self.denied(self.read(self.readme, (368, 515, 1065), offset=367, limit=533)))
        decision = self.read(self.readme, offset=515, limit=533)
        self.assertTrue(self.denied(decision))
        self.assertIn('grep_search', decision['hookSpecificOutput']['permissionDecisionReason'])

    def test_a_plan_that_fits_is_read_in_full_without_a_nudge(self):
        for span, args in [((1, 75, 184), {}), ((76, 170, 184), {'offset': 75, 'limit': 184}),
                           ((171, 184, 184), {'offset': 170, 'limit': 184})]:
            self.assertFalse(self.denied(self.read(self.plan, span, **args)))
            self.assertEqual(self.post, {})

    def test_targeted_read_of_seen_lines_stays_allowed_for_edits(self):
        self.read(self.readme, (1, 133, 1065))
        self.assertFalse(self.denied(self.read(self.readme, (40, 79, 1065), offset=39, limit=40)))

    def test_changed_file_can_be_read_again(self):
        self.read(self.pkg)
        Path(self.pkg).write_text('{"name": "changed"}\n')
        self.assertFalse(self.denied(self.read(self.pkg)))

    def test_new_prompt_keeps_read_coverage(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='build it')
        self.read(self.readme, (1, 133, 1065))
        self.call('UserPromptSubmit', prompt_id='p2', prompt='stop inspecting and start building')
        self.assertTrue(self.denied(self.read(self.readme)))

    def test_ignored_reread_redirects_stop_the_turn(self):
        self.call('UserPromptSubmit', prompt_id='p1', prompt='task')
        self.read(self.pkg)
        self.assertTrue(self.denied(self.read(self.pkg)))
        self.assertTrue(self.denied(self.read(self.pkg)))
        out = self.read(self.pkg)
        self.assertIs(out.get('continue'), False)
        self.assertNotIn('permissionDecision', out.get('hookSpecificOutput', {}))
        self.assertIn('@', out['stopReason'])

    def test_following_a_redirect_resets_the_stop_count(self):
        self.read(self.pkg)
        for n in range(4):
            self.assertTrue(self.denied(self.read(self.pkg)))
            self.executed(args={'command': f'grep -n name{n} {self.pkg}'})

    def test_state_does_not_store_file_paths(self):
        self.read(self.readme, (1, 133, 1065))
        content = ''.join(p.read_text() for p in Path(self.tmp.name).glob('*.json'))
        self.assertNotIn('README', content)
        self.assertNotIn(self.tmp.name, content)

    def test_replay_of_the_hypercrawl_loop_stops_it(self):
        """The read_file calls of the 2026-09-20 session that looped for 70 minutes."""
        agents = self.write('AGENTS.md', 20)
        replay = [
            (self.readme, (1, 133, 1065), {}),
            (agents, None, {}),
            (self.plan, (1, 75, 184), {}),
            (self.plan, (76, 170, 184), {'offset': 75, 'limit': 184}),
            (self.plan, (171, 184, 184), {'offset': 170, 'limit': 184}),
            (self.pkg, None, {}),
            (self.readme, (1, 133, 1065), {}),
            (self.readme, (135, 233, 1065), {'offset': 134, 'limit': 1065}),
            (self.readme, (235, 369, 1065), {'offset': 234, 'limit': 1065}),
            (self.readme, (371, 517, 1065), {'offset': 370, 'limit': 1065}),
            (self.readme, (519, 656, 1065), {'offset': 518, 'limit': 1065}),
            (self.readme, (739, 838, 1065), {'offset': 738, 'limit': 1065}),
            (self.readme, (840, 972, 1065), {'offset': 839, 'limit': 1065}),
            (self.readme, (974, 1065, 1065), {'offset': 973, 'limit': 1065}),
            (self.plan, (1, 75, 184), {'offset': 0, 'limit': 1065}),
            (self.plan, (77, 170, 184), {'offset': 76, 'limit': 1065}),
            (self.plan, (171, 184, 184), {'offset': 170, 'limit': 1065}),
            (self.pkg, None, {}),
            (self.readme, (1, 133, 1065), {}),
        ]
        self.call('UserPromptSubmit', prompt_id='p1', prompt='Lets proceed with the Hypercrawl build')
        outcomes = [self.read(path, span, **args) for path, span, args in replay]
        self.assertEqual([i for i, o in enumerate(outcomes) if o][:1], [6], 'first re-read of README page 1')
        stops = [i for i, o in enumerate(outcomes) if o.get('continue') is False]
        self.assertTrue(stops and stops[0] <= 12, outcomes)

    def test_page_budget_matches_the_launcher_config(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('guard', SCRIPT)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        cfg = json.loads((SCRIPT.parent.parent / 'config/qwen-code-local.json').read_text())
        self.assertEqual(guard.RESULTS_KEPT, cfg['context']['clearContextOnIdle']['toolResultsNumToKeep'])


if __name__ == '__main__':
    unittest.main()
