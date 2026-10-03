#!/usr/bin/env python3
"""Exercise the real Qwen CLI against a deterministic local OpenAI fixture.

QWEN_CODE_TEST_BIN must name an installed Qwen Code cli.js (0.24.1 tested).
No Ollama request, network credential, or existing session is used.
"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
BIN = os.environ.get('QWEN_CODE_TEST_BIN')


@unittest.skipUnless(BIN, 'set QWEN_CODE_TEST_BIN to the installed cli.js')
class RuntimeTests(unittest.TestCase):
    def run_client(self, root, respond, prompt, append_prompt=None):
        """Run real Qwen Code in root against a fixture API; respond(text) scripts each turn.

        respond gets the request's messages as JSON text and returns (tool, args),
        or (None, None) to finish. Returns the process and every request body.
        """
        requests = []

        class API(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                name, args = respond(json.dumps(body.get('messages', [])))
                delta = {'role': 'assistant'}
                if name:
                    delta['tool_calls'] = [{'index': 0, 'id': 'call_' + str(len(requests)), 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]
                else:
                    delta['content'] = 'Recovered and verified the output.'
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for change, finish in [(delta, None), ({}, 'tool_calls' if name else 'stop')]:
                    item = {'id': 'fixture', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'fixture', 'choices': [{'index': 0, 'delta': change, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(item) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_port}/v1'
        cfg = json.loads((ROOT / 'config/qwen-code-local.json').read_text())
        provider = cfg['modelProviders']['openai'][0]
        provider.update(id='fixture', envKey='OPENAI_API_KEY', baseUrl=url)
        provider['generationConfig']['maxRetries'] = 0
        cfg['modelProviders']['openai'] = [provider]
        cfg['model']['name'] = 'fixture'
        cfg['fastModel'] = 'fixture'
        cfg['model']['maxToolCallsPerTurn'] = 10
        cfg['security']['folderTrust'] = {'enabled': False}
        settings = root / 'settings.json'
        settings.write_text(json.dumps(cfg))
        env = dict(os.environ, HOME=str(root), QWEN_CODE_SYSTEM_DEFAULTS_PATH=str(settings),
                   QWEN_HARNESS_ROOT=str(ROOT), QWEN_PROGRESS_STATE_DIR=str(root / 'progress'),
                   QWEN_DISABLE_AUTO_TITLE='1', OPENAI_API_KEY='fixture',
                   OPENAI_BASE_URL=url, QWEN_SESSION_MODEL='fixture', QWEN_FAST_MODEL='fixture', QWEN_LOCAL_BASE_URL=url)
        for key in ['OPENAI_API_KEY', 'OPENROUTER_API_KEY', 'GOOGLE_API_KEY', 'GEMINI_API_KEY']:
            env.pop(key, None)
        proc = subprocess.run(['node', BIN, '--auth-type', 'openai', '--model', 'fixture',
                               '--openai-base-url', url, '-y', '-p', prompt, '-o', 'stream-json'] + (['--append-system-prompt', append_prompt] if append_prompt else []),
                              cwd=root, env=env, text=True, capture_output=True, timeout=90)
        return proc, requests

    def test_main_requests_disable_thinking_across_tool_result(self):
        with tempfile.TemporaryDirectory(prefix='qwen-thinking-runtime-') as tmp:
            root = Path(tmp)
            (root / 'input.txt').write_text('TOOL_RESULT_PRESENT_7831\n')
            count = [0]

            def respond(text):
                count[0] += 1
                if count[0] == 1:
                    return 'read_file', {'file_path': str(root / 'input.txt')}
                return None, None

            proc, requests = self.run_client(root, respond, 'Read input.txt and report its contents.')
            self.assertEqual(proc.returncode, 0, proc.stderr[-2000:])
            self.assertGreaterEqual(len(requests), 2)
            for request in requests:
                self.assertEqual(request.get('reasoning_effort'), 'none')
            self.assertIn('TOOL_RESULT_PRESENT_7831', json.dumps(requests[-1]['messages']))

    def run_fixture(self, recover, quoted_search=False, git_chain=False, pipeline=False):
        with tempfile.TemporaryDirectory(prefix='qwen-hook-runtime-') as tmp:
            root = Path(tmp)
            (root / 'input.txt').write_text('export const ActualType = 1;\n')
            if git_chain:
                subprocess.run(['git', 'init', '-q', str(root)], check=True)
            if pipeline:
                for rel in ['packages/platforms/src/providers/reddit.ts', 'packages/mcp-server/src/index.ts']:
                    path = root / rel
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('export const reddit = 1;\n')
            redirect = ('This exact shell command returned unchanged output four times' if pipeline
                        else 'This inspection already returned the same result twice')
            stage = [0]

            def respond(text):
                if recover and redirect in text:
                    stage[0] += 1
                    if stage[0] == 1:
                        return 'write_file', {'file_path': str(root / 'result.txt'), 'content': 'RECOVERED\n'}
                    if stage[0] == 2:
                        return 'run_shell_command', {'command': 'test -f result.txt && grep -qx RECOVERED result.txt', 'description': 'Verify recovered output'}
                    return None, None
                command = r'cd . && grep -n "ActualType\|OtherType" input.txt' if quoted_search else 'grep -n Missing input.txt'
                if git_chain:
                    command = 'git log --all --oneline -20 && echo "---STATUS---" && git status'
                if pipeline:
                    command = 'grep -rin "reddit" packages/platforms/src/providers/reddit.ts | head && echo "---mcp-server index reddit lines---" && grep -n "ddit" packages/mcp-server/src/index.ts'
                return 'run_shell_command', {'command': command, 'description': 'Search attempt ' + str(text.count('"tool"'))}

            proc, requests = self.run_client(root, respond, 'Inspect input.txt, recover from a repeated search, write result.txt and verify it.')
            evidence = proc.stdout + proc.stderr
            self.assertGreater(len(requests), 2, evidence[-5000:])
            model_context = json.dumps(requests)
            if not quoted_search and not git_chain and not pipeline:
                self.assertTrue('The search completed with no matches' in model_context, evidence[-2500:])
            self.assertTrue(redirect in model_context, evidence[-2500:])
            if recover:
                self.assertEqual((root / 'result.txt').read_text(), 'RECOVERED\n')
                self.assertEqual(proc.returncode, 0, evidence[-5000:])
                self.assertIn('Verify recovered output', evidence)
                last_tool = [m for m in requests[-1]['messages'] if m['role'] == 'tool'][-1]
                self.assertIn('Exit Code: 0', json.dumps(last_tool['content']))
            else:
                self.assertIn('Qwen progress guard:', evidence)
                self.assertLessEqual(len(requests), 7 if pipeline else 5, evidence[-5000:])
            print(f'Runtime {"recovery" if recover else "hard stop"}: {len(requests)} model requests, exit {proc.returncode}')

    def test_model_can_recover_and_finish(self):
        self.run_fixture(True)

    def test_ignored_redirect_stops_the_actual_runtime(self):
        self.run_fixture(False)

    def test_successful_quoted_search_can_recover_and_finish(self):
        self.run_fixture(True, quoted_search=True)

    def test_successful_quoted_search_stops_when_redirect_ignored(self):
        self.run_fixture(False, quoted_search=True)

    def test_git_chain_can_recover_and_finish(self):
        self.run_fixture(True, git_chain=True)

    def test_git_chain_stops_when_redirect_ignored(self):
        self.run_fixture(False, git_chain=True)

    def test_screenshot_pipeline_recovers(self):
        self.run_fixture(True, pipeline=True)

    def test_screenshot_pipeline_stops(self):
        self.run_fixture(False, pipeline=True)

    def test_persistent_plan_survives_clearing_and_guides_build(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('plan_context', ROOT / 'scripts/qwen-plan-context.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='qwen-plan-runtime-') as tmp:
            root = Path(tmp)
            plan = root / 'plan with spaces.md'
            plan.write_text('PLAN_FACT_9123: Write result.txt containing BUILT and verify it.\n')
            for i in range(5):
                (root / f'page{i}.txt').write_text('details ' * 850)
            step = [0]
            def respond(text):
                n = step[0]; step[0] += 1
                if n < 5:
                    return 'read_file', {'file_path': str(root / f'page{n}.txt')}
                if n == 5:
                    return 'write_file', {'file_path': str(root / 'result.txt'), 'content': 'BUILT\n'}
                if n == 6:
                    return 'run_shell_command', {'command': 'test "$(cat result.txt)" = BUILT'}
                return None, None
            proc, requests = self.run_client(root, respond, 'Implement the retained plan.', module.render(plan))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(any('[Old tool result content cleared]' in json.dumps(r) for r in requests))
            for request in requests:
                system = [m for m in request['messages'] if m['role'] == 'system']
                self.assertIn('PLAN_FACT_9123', json.dumps(system))
            self.assertEqual((root / 'result.txt').read_text(), 'BUILT\n')
            self.assertIn('Exit Code: 0', json.dumps(requests[-1]['messages'][-1]))

    def run_reread_fixture(self, recover):
        """The 2026-09-20 loop: a big file, four more reads, then back to page one."""
        with tempfile.TemporaryDirectory(prefix='qwen-hook-reread-') as tmp:
            root = Path(tmp)
            pad = 'x' * 60
            (root / 'big.md').write_text(''.join(f'big line {n} {pad}\n' for n in range(1, 1201)))
            for name in ['a.md', 'b.md', 'c.md', 'd.md']:
                (root / name).write_text(''.join(f'{name} line {n} {pad}\n' for n in range(1, 131)))
            (root / 'plan.md').write_text('# Plan\n\nPLAN-MARKER-7731: add the endpoint, then its test.\n')
            reads = ['big.md', 'a.md', 'b.md', 'c.md', 'd.md', 'big.md', 'big.md', 'big.md', 'big.md']
            turn = [0]

            def respond(text):
                turn[0] += 1
                if recover and 'That is how this session loops' in text:
                    if not (root / 'result.txt').exists():
                        return 'write_file', {'file_path': str(root / 'result.txt'), 'content': 'BUILT\n'}
                    return None, None
                return 'read_file', {'file_path': str(root / reads[min(turn[0], len(reads)) - 1])}

            proc, requests = self.run_client(root, respond, '@plan.md Build the plan.')
            evidence = proc.stdout + proc.stderr
            contexts = [json.dumps(r.get('messages', [])) for r in requests]
            self.assertGreater(len(requests), 6, evidence[-5000:])
            self.assertIn('Do not page through the rest', contexts[1], 'paging nudge after the first page')
            # Qwen clears before adding the newest result, so four 8K pages stay
            # visible and the fifth clears page one. The @plan content survives.
            self.assertNotIn('[Old tool result content cleared]', contexts[4])
            self.assertIn('[Old tool result content cleared]', contexts[5], evidence[-2500:])
            self.assertIn('PLAN-MARKER-7731', contexts[5], '@path content should survive clearing')
            self.assertIn('That is how this session loops', contexts[6], evidence[-2500:])
            if recover:
                self.assertEqual((root / 'result.txt').read_text(), 'BUILT\n')
                self.assertEqual(proc.returncode, 0, evidence[-5000:])
            else:
                self.assertIn('Qwen progress guard: the model kept re-reading', evidence)
                self.assertLessEqual(len(requests), 9, evidence[-5000:])
            print(f'Runtime re-read {"recovery" if recover else "hard stop"}: {len(requests)} model requests, exit {proc.returncode}')

    def test_reread_of_cleared_page_is_redirected_and_model_recovers(self):
        self.run_reread_fixture(True)

    def test_ignored_reread_redirects_stop_the_actual_runtime(self):
        self.run_reread_fixture(False)


if __name__ == '__main__':
    unittest.main()
