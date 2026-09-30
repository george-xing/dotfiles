import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('secret_fill', Path(__file__).parents[1] / 'bin/cards-secret-fill.py')
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class CredentialBridgeTests(unittest.TestCase):
    def test_bank_origin_boundary(self):
        for url in ['https://secure.chase.com/login', 'https://chase.com/']:
            self.assertTrue(mod.allowed_url(url, 'chase'))
        for url in ['http://secure.chase.com/', 'https://chase.com.attacker.test/',
                    'https://evilchase.com/', 'https://chase.com@evil.test/',
                    'https://global.americanexpress.com/']:
            self.assertFalse(mod.allowed_url(url, 'chase'))

    def test_config_preserves_vault_space_and_rejects_other_vaults(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'refs'
            text = ''.join(f'{i}_{f}_REF=op://AI agents/item/{f.lower()}\n'
                           for i in ['CHASE', 'AMEX'] for f in ['USERNAME', 'PASSWORD'])
            path.write_text(text); path.chmod(0o600)
            self.assertEqual(len(mod.load_references(path)), 4)
            path.write_text(text.replace('AI agents', 'Private'))
            with self.assertRaises(mod.FillError): mod.load_references(path)

    def test_op_error_does_not_include_secret_output(self):
        result = subprocess.CompletedProcess([], 1, 'secret-value', 'token-value')
        with mock.patch.object(mod.subprocess, 'run', return_value=result):
            with self.assertRaises(mod.FillError) as caught:
                mod.read_secret('op://AI agents/item/password', {})
        self.assertNotIn('secret-value', str(caught.exception))
        self.assertNotIn('token-value', str(caught.exception))

    def test_check_never_connects_to_browser_or_prints_values(self):
        refs = {f'{i}_{f}_REF': 'op://AI agents/item/field'
                for i in ['CHASE', 'AMEX'] for f in ['USERNAME', 'PASSWORD']}
        with mock.patch('sys.argv', ['fill', '--check']), \
             mock.patch.object(mod, 'load_references', return_value=refs), \
             mock.patch.object(mod, 'token_environment', return_value={}), \
             mock.patch.object(mod, 'read_secret', return_value='private-secret') as read, \
             mock.patch.object(mod, 'CDP') as browser, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(mod.main(), 0)
        self.assertEqual(read.call_count, 4)
        browser.assert_not_called()
        self.assertNotIn('private-secret', out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['browser_actions'], 0)

    @unittest.skipUnless(shutil.which('node'), 'Node needed for isolated DOM simulation')
    def test_actual_fill_function_origin_ambiguity_and_no_submission(self):
        script = '''
const assert = require('node:assert/strict');
const fill = FUNCTION;
let stored = '', events = [], submissions = 0;
class Input {
  constructor(type) {this.type=type; this.tagName='INPUT';this.disabled=false;this.readOnly=false;}
  get value() {return stored;} set value(v) {stored=v;}
  getClientRects() {return [1];}
  dispatchEvent(e) {events.push(e.type);}
  click() {submissions++;}
}
let el=new Input('password');
global.location={protocol:'https:',hostname:'secure.chase.com'};
global.document={location,defaultView:{HTMLInputElement:Input,Event:class {constructor(type){this.type=type;}}},querySelectorAll:()=>[el]};
const run=()=>fill('chase.com','','input','password','synthetic-test-secret');
assert.deepEqual(run(),{ok:true});
assert.equal(stored,'synthetic-test-secret');
assert.deepEqual(events,['input','change']);assert.equal(submissions,0);
stored=''; location.hostname='chase.com.evil.test';assert.deepEqual(run(),{ok:false});assert.equal(stored,'');
location.hostname='secure.chase.com';document.querySelectorAll=()=>[el,el];
assert.deepEqual(run(),{ok:false});assert.equal(stored,'');
document.querySelectorAll=()=>[el];el.type='text';assert.deepEqual(run(),{ok:false});
el.type='password';el.disabled=true;assert.deepEqual(run(),{ok:false});
el.disabled=false;
const hostileDocument={...document,location:{protocol:'https:',hostname:'evil.test'}};
document.querySelectorAll=()=>[{tagName:'IFRAME',contentDocument:hostileDocument}];
assert.deepEqual(fill('chase.com','#login','input','password','synthetic-test-secret'),{ok:false});
assert.equal(stored,'');assert.equal(submissions,0);
'''.replace('FUNCTION', mod.FILL_FUNCTION)
        result = subprocess.run([shutil.which('node')], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
