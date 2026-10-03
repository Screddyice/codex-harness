#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest
spec = importlib.util.spec_from_file_location('plan', Path(__file__).with_name('qwen-plan-context.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PlanTests(unittest.TestCase):
    def test_boundaries_and_literal_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'plan with spaces.md'
            path.write_text('Use `code`, $(literal), and "quotes". 日本語')
            result = module.render(path)
            self.assertIn('$(literal)', result)
            self.assertIn('日本語', result)
            for payload in [b'', b'x' * (module.LIMIT + 1), b'\xff', b'a\x00b']:
                path.write_bytes(payload)
                with self.assertRaises(ValueError): module.render(path)
            path.write_bytes(b'x' * module.LIMIT)
            self.assertIn('x' * module.LIMIT, module.render(path))
    def test_missing_file(self):
        with self.assertRaises(OSError): module.render('/no-such-qwen-plan/path')

if __name__ == '__main__': unittest.main()
