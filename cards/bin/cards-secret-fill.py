#!/Users/pattybot/.hermes/hermes-agent/venv/bin/python
"""Fill an agent-selected bank field from 1Password; never navigate or submit."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

from dotenv import dotenv_values
import websocket

CONFIG = Path('/Users/pattybot/.config/cards/onepassword.conf')
HERMES = Path('/Users/pattybot/.hermes')
OP = '/Users/pattybot/.local/bin/op'
DOMAINS = {'chase': 'chase.com', 'amex': 'americanexpress.com'}


class FillError(Exception):
    pass


def allowed_url(url, issuer):
    parsed = urlsplit(url)
    host = parsed.hostname or ''
    domain = DOMAINS[issuer]
    return parsed.scheme == 'https' and (host == domain or host.endswith('.' + domain))


def load_references(path=CONFIG):
    if path.stat().st_mode & 0o077:
        raise FillError('Reference config must have mode 0600')
    refs = dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line and not line.startswith('#'))
    for issuer in DOMAINS:
        for field in ('username', 'password'):
            ref = refs.get(f'{issuer}_{field}_REF'.upper(), '')
            if not ref.startswith('op://AI agents/') or len(ref.split('/')) != 5:
                raise FillError('Missing or invalid AI agents credential reference')
    return refs


def token_environment():
    # Share Hermes's bootstrap credential. Do not load unrelated provider keys.
    token = os.environ.get('OP_SERVICE_ACCOUNT_TOKEN', '')
    for filename in ('.env', '.op.env'):
        if not token and (HERMES / filename).is_file():
            token = dotenv_values(HERMES / filename).get('OP_SERVICE_ACCOUNT_TOKEN', '')
    if not token:
        raise FillError('Hermes OP_SERVICE_ACCOUNT_TOKEN is not configured')
    env = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'OP_CONFIG_DIR', 'XDG_CONFIG_HOME') if k in os.environ}
    env['OP_SERVICE_ACCOUNT_TOKEN'] = token
    return env


def read_secret(ref, env):
    result = subprocess.run([OP, 'read', '--no-newline', '--', ref],
                            env=env, capture_output=True, text=True, timeout=25)
    if result.returncode or not result.stdout:
        raise FillError('1Password could not resolve a required credential')
    return result.stdout


class CDP:
    def __init__(self, issuer, tab_id):
        with urlopen('http://127.0.0.1:19223/json', timeout=5) as response:
            tabs = json.load(response)
        matches = [t for t in tabs if t.get('type') == 'page'
                   and t.get('id') == tab_id and allowed_url(t.get('url', ''), issuer)]
        if len(matches) != 1:
            raise FillError('Select exactly one HTTPS bank tab on cards Chrome')
        self.ws = websocket.create_connection(matches[0]['webSocketDebuggerUrl'],
                                              suppress_origin=True, timeout=10)
        self.seq = 0

    def call(self, method, params):
        self.seq += 1
        self.ws.send(json.dumps({'id': self.seq, 'method': method, 'params': params}))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            self.ws.settimeout(max(0.1, deadline - time.monotonic()))
            result = json.loads(self.ws.recv())
            if result.get('id') != self.seq:
                continue
            if 'error' in result or 'exceptionDetails' in result.get('result', {}):
                raise FillError('Browser operation failed; details suppressed')
            return result['result']
        raise FillError('Browser operation timed out')

    def close(self):
        self.ws.close()


# No credential value appears in the expression, command arguments, or output.
# The agent chooses the tab, optional iframe selector, and exact input selector.
FILL_FUNCTION = r'''function(domain, frameSelector, selector, field, secret) {
  const allowed = loc => loc.protocol === 'https:' &&
    (loc.hostname === domain || loc.hostname.endsWith('.' + domain));
  if (!allowed(location)) return {ok:false};
  let d = document;
  if (frameSelector) {
    const frames = d.querySelectorAll(frameSelector);
    if (frames.length !== 1 || frames[0].tagName !== 'IFRAME') return {ok:false};
    d = frames[0].contentDocument;
  }
  if (!d || !allowed(d.location)) return {ok:false};
  const inputs = [...d.querySelectorAll(selector)].filter(el =>
    el.tagName === 'INPUT' && !el.disabled && !el.readOnly && el.getClientRects().length);
  if (inputs.length !== 1) return {ok:false};
  const el = inputs[0];
  if (field === 'password' ? el.type !== 'password' : !['text','email','tel'].includes(el.type))
    return {ok:false};
  const setter = Object.getOwnPropertyDescriptor(d.defaultView.HTMLInputElement.prototype, 'value').set;
  setter.call(el, secret);
  el.dispatchEvent(new d.defaultView.Event('input', {bubbles:true}));
  el.dispatchEvent(new d.defaultView.Event('change', {bubbles:true}));
  return {ok:el.value === secret};
}'''


def fill(cdp, issuer, frame, selector, field, secret):
    obj = cdp.call('Runtime.evaluate', {'expression': 'document', 'returnByValue': False})
    object_id = obj.get('result', {}).get('objectId')
    if not object_id:
        raise FillError('Browser document is unavailable')
    try:
        result = cdp.call('Runtime.callFunctionOn', {
            'objectId': object_id, 'functionDeclaration': FILL_FUNCTION,
            'arguments': [{'value': v} for v in (DOMAINS[issuer], frame, selector, field, secret)],
            'returnByValue': True, 'userGesture': True,
        })
        if result.get('result', {}).get('value') != {'ok': True}:
            raise FillError('Field was not filled: check bank origin, iframe, selector and input type')
    finally:
        cdp.call('Runtime.releaseObject', {'objectId': object_id})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check vault reads only; no browser actions')
    parser.add_argument('--issuer', choices=DOMAINS)
    parser.add_argument('--tab-id')
    parser.add_argument('--frame-selector', default='')
    parser.add_argument('--field', choices=['username', 'password'])
    parser.add_argument('--selector')
    args = parser.parse_args()
    if not args.check and not all([args.issuer, args.tab_id, args.field, args.selector]):
        parser.error('filling requires --issuer, --tab-id, --field, and --selector')
    try:
        refs, env = load_references(), token_environment()
        if args.check:
            for issuer in ([args.issuer] if args.issuer else DOMAINS):
                for field in ('username', 'password'):
                    read_secret(refs[f'{issuer}_{field}_REF'.upper()], env)
            print(json.dumps({'ok': True, 'credentials': 'resolvable', 'browser_actions': 0}))
            return 0
        cdp = CDP(args.issuer, args.tab_id)
        try:
            secret = read_secret(refs[f'{args.issuer}_{args.field}_REF'.upper()], env)
            fill(cdp, args.issuer, args.frame_selector, args.selector, args.field, secret)
        finally:
            cdp.close()
        print(json.dumps({'ok': True, 'issuer': args.issuer, 'field': args.field, 'submitted': False}))
        return 0
    except FillError as error:
        print(json.dumps({'ok': False, 'message': str(error)}))
    except Exception:
        print(json.dumps({'ok': False, 'message': 'Credential operation failed; details suppressed'}))
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
