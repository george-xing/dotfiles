#!/usr/bin/python3
"""Secure Chase/Amex authentication for the dedicated cards Chrome.

Secrets are read from 1Password just-in-time and passed directly over the
loopback CDP websocket. They are never written to disk or included in output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import websocket


HOME = Path("/Users/pattybot")
CONFIG = Path(os.environ.get("CARDS_ONEPASSWORD_CONFIG", HOME / ".config/cards/onepassword.conf"))
OP = HOME / ".local/bin/op"
KEYCHAIN = HOME / ".local/bin/cards-keychain"
CDP_BASE = "http://127.0.0.1:19223"
LOGIN_REJECTION_GRACE_SECONDS = 12


class AuthError(RuntimeError):
    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


def load_config(path: Path = CONFIG) -> dict[str, str]:
    if not path.is_file():
        raise AuthError("config", f"missing config: {path}")
    if path.stat().st_mode & 0o077:
        raise AuthError("config", f"config permissions must be 0600: {path}")
    result = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise AuthError("config", "malformed 1Password config line")
        key, value = line.split("=", 1)
        if key not in {
            "CHASE_USERNAME_REF", "CHASE_PASSWORD_REF", "CHASE_OTP_REF",
            "AMEX_USERNAME_REF", "AMEX_PASSWORD_REF", "AMEX_OTP_REF",
        }:
            raise AuthError("config", f"unknown config key: {key}")
        if value and (not value.startswith("op://") or "\n" in value):
            raise AuthError("config", f"invalid secret reference for {key}")
        result[key] = value
    for issuer in ("CHASE", "AMEX"):
        for field in ("USERNAME_REF", "PASSWORD_REF"):
            if not result.get(f"{issuer}_{field}"):
                raise AuthError("config", f"missing {issuer}_{field}")
    return result


def service_token() -> str:
    proc = subprocess.run(
        [str(KEYCHAIN), "get"],
        text=True, capture_output=True, timeout=10,
    )
    token = proc.stdout.rstrip("\n")
    if proc.returncode or not token:
        raise AuthError("onepassword", "1Password service-account token unavailable in Login Keychain")
    return token


def op_read(ref: str, token: str, required: bool = True) -> str | None:
    if not ref:
        return None
    env = os.environ.copy()
    env["OP_SERVICE_ACCOUNT_TOKEN"] = token
    proc = subprocess.run(
        [str(OP), "read", "--no-newline", ref], env=env,
        text=True, capture_output=True, timeout=20,
    )
    if proc.returncode:
        if required:
            raise AuthError("onepassword", "could not resolve a required 1Password reference")
        return None
    if not proc.stdout:
        if required:
            raise AuthError("onepassword", "1Password returned an empty required field")
        return None
    return proc.stdout


class CDP:
    def __init__(self, needle: str):
        self.needle = needle
        self.ws = None
        self.seq = 0

    def connect(self):
        tabs = json.loads(urllib.request.urlopen(f"{CDP_BASE}/json", timeout=3).read())
        target = next((t for t in tabs if t.get("type") == "page" and self.needle in (t.get("url") or "")), None)
        if not target:
            raise AuthError("browser", f"missing {self.needle} tab in cards Chrome")
        self.ws = websocket.create_connection(target["webSocketDebuggerUrl"], suppress_origin=True, timeout=10)
        return self

    def close(self):
        if self.ws:
            self.ws.close()
            self.ws = None

    def call(self, method, params=None):
        self.seq += 1
        ident = self.seq
        self.ws.send(json.dumps({"id": ident, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == ident:
                if "error" in msg:
                    raise AuthError("browser", f"CDP {method} failed")
                return msg.get("result", {})

    def eval(self, expression, await_promise=True):
        result = self.call("Runtime.evaluate", {
            "expression": expression, "awaitPromise": await_promise,
            "returnByValue": True, "userGesture": True,
        }).get("result", {})
        if result.get("subtype") == "error":
            raise AuthError("dom", "browser expression failed")
        return result.get("value")

    def call_function(self, object_expression, function_declaration, arguments):
        obj = self.call("Runtime.evaluate", {
            "expression": object_expression, "returnByValue": False,
        }).get("result", {})
        object_id = obj.get("objectId")
        if not object_id:
            raise AuthError("dom", "could not resolve browser document")
        try:
            result = self.call("Runtime.callFunctionOn", {
                "objectId": object_id,
                "functionDeclaration": function_declaration,
                "arguments": [{"value": value} for value in arguments],
                "returnByValue": True,
                "userGesture": True,
                "awaitPromise": True,
            }).get("result", {})
            if result.get("subtype") == "error":
                raise AuthError("dom", "browser function failed")
            return result.get("value")
        finally:
            self.call("Runtime.releaseObject", {"objectId": object_id})

    def navigate(self, url):
        self.call("Page.navigate", {"url": url})

    def screenshot(self, label):
        # Screenshot intentionally occurs only after secrets have left inputs
        # or on challenge pages. Login pages containing filled secrets are not captured.
        state = HOME / ".claude/skills/credit-card-offers/state/screenshots"
        state.mkdir(parents=True, exist_ok=True)
        path = state / f"{int(time.time())}-{label}.png"
        data = self.call("Page.captureScreenshot", {"format": "png", "fromSurface": True}).get("data")
        if data:
            import base64
            path.write_bytes(base64.b64decode(data))
            os.chmod(path, 0o600)
            return str(path)
        return None


def js_string(value: str) -> str:
    return json.dumps(value)


def ensure_tab(needle: str, url: str):
    tabs = json.loads(urllib.request.urlopen(f"{CDP_BASE}/json", timeout=3).read())
    if any(t.get("type") == "page" and needle in (t.get("url") or "") for t in tabs):
        return
    req = urllib.request.Request(f"{CDP_BASE}/json/new?{urllib.parse.quote(url, safe='')}", method="PUT")
    urllib.request.urlopen(req, timeout=5).read()


def wait_until(fn, timeout=35, interval=1.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    return last


@dataclass
class Issuer:
    name: str
    needle: str
    login_url: str
    offers_url: str
    username_ref: str
    password_ref: str
    otp_ref: str | None
    frame_expr: str
    user_selector: str
    pass_selector: str
    submit_selector: str


CHASE_FRAME = 'document.querySelector("#logonbox")?.contentDocument || document'
MAIN_FRAME = "document"


def page_probe(cdp: CDP, frame_expr: str):
    return cdp.eval(f'''JSON.stringify((()=>{{
      const d={frame_expr}; const text=(d.body?.innerText||"").slice(0,6000);
      return {{url:location.href,title:document.title,text,textLen:text.length,
        hasUsername:!!d.querySelector('input[autocomplete*=username],input[name=username],input[id*=user i]'),
        hasPassword:!!d.querySelector('input[type=password]'),
        hasSignOut:Array.from(d.querySelectorAll('a,button,[role=button]')).some(x=>/^(sign out|log out|logout)$/i.test((x.innerText||x.getAttribute('aria-label')||'').trim())),
        otpCount:Array.from(d.querySelectorAll('input')).filter(x=>/otp|code|verification|security/i.test([x.id,x.name,x.autocomplete,x.placeholder,x.getAttribute('aria-label')].join(' '))).length
      }};
    }})())''')


def fill_and_submit(cdp: CDP, issuer: Issuer, username: str, password: str):
    function = '''function(username,password,userSelector,passSelector,submitSelector){
      const d=this, u=d.querySelector(userSelector), p=d.querySelector(passSelector), b=d.querySelector(submitSelector);
      if(!u||!p||!b||b.disabled) return 'missing';
      const set=(el,v)=>{const proto=Object.getPrototypeOf(el); const s=Object.getOwnPropertyDescriptor(proto,'value')?.set; s?s.call(el,v):(el.value=v); el.dispatchEvent(new d.defaultView.Event('input',{bubbles:true})); el.dispatchEvent(new d.defaultView.Event('change',{bubbles:true}));};
      set(u,username); set(p,password); b.click(); return 'submitted';
    }'''
    if cdp.call_function(issuer.frame_expr, function, [username, password, issuer.user_selector, issuer.pass_selector, issuer.submit_selector]) != "submitted":
        raise AuthError("dom", f"{issuer.name} login form changed")


def submit_totp(cdp: CDP, issuer: Issuer, otp: str) -> bool:
    function = '''function(otp){
      const d=this;
      const inputs=Array.from(d.querySelectorAll('input')).filter(x=>/otp|code|verification|security/i.test([x.id,x.name,x.autocomplete,x.placeholder,x.getAttribute('aria-label')].join(' ')) && !x.disabled);
      if(inputs.length!==1) return 'ambiguous-input';
      const buttons=Array.from(d.querySelectorAll('button,[role=button],input[type=submit]')).filter(x=>/^(verify|continue|submit|confirm|next)$/i.test((x.innerText||x.value||x.getAttribute('aria-label')||'').trim()) && !x.disabled);
      if(buttons.length!==1) return 'ambiguous-submit';
      const el=inputs[0], proto=Object.getPrototypeOf(el), s=Object.getOwnPropertyDescriptor(proto,'value')?.set; s?s.call(el,otp):(el.value=otp); el.dispatchEvent(new d.defaultView.Event('input',{bubbles:true})); el.dispatchEvent(new d.defaultView.Event('change',{bubbles:true})); buttons[0].click(); return 'submitted';
    }'''
    return cdp.call_function(issuer.frame_expr, function, [otp]) == "submitted"


def looks_logged_in(issuer: Issuer, probe: dict) -> bool:
    if probe.get("hasPassword") or probe.get("hasUsername"):
        return False
    url = probe.get("url", "")
    text = probe.get("text", "")
    if probe.get("hasSignOut") and issuer.needle in url:
        return True
    if probe.get("textLen", 0) < 150:
        return False
    if issuer.name == "Chase":
        return ("chase.com" in url and "dashboard" in url
                and bool(re.search(r"account|pay & transfer|credit journey|offers|good (morning|afternoon|evening)", text, re.I))
                and not re.search(r"sign in|enter your username|\bloading\b", text, re.I))
    return ("americanexpress.com" in url and "/account/login" not in url
            and bool(re.search(r"account|statement|payment|membership rewards|offers", text, re.I))
            and not re.search(r"log in to my account|enter your user id|\bloading\b", text, re.I))


def login_form_ready(probe: dict) -> bool:
    return bool(probe.get("hasUsername") and probe.get("hasPassword"))


def finish_authenticated_navigation(cdp: CDP, issuer: Issuer):
    if issuer.name == "Chase":
        # Chase's hash router can cancel dashboard bootstrap if the offers
        # route is applied immediately after login. Let overview settle first.
        wait_until(lambda: (lambda p: p if looks_logged_in(issuer, p) and p.get("textLen", 0) >= 150 else None)(json.loads(page_probe(cdp, issuer.frame_expr))), timeout=20)
    if issuer.offers_url not in str(cdp.eval("location.href")):
        cdp.navigate(issuer.offers_url)
        time.sleep(10 if issuer.name == "Chase" else 5)


def login_one(issuer: Issuer, token: str, dry_run=False):
    ensure_tab(issuer.needle, issuer.login_url)
    cdp = CDP(issuer.needle).connect()
    try:
        # Amex's protected offers URL is authoritative. Chase must bootstrap
        # dashboard overview before its offers hash route is applied.
        initial_url = issuer.login_url if issuer.name == "Chase" else issuer.offers_url
        cdp.navigate(initial_url)
        probe = wait_until(lambda: (lambda p: p if login_form_ready(p) or looks_logged_in(issuer, p) else None)(json.loads(page_probe(cdp, issuer.frame_expr))), timeout=25)
        if not probe:
            raise AuthError("dom", f"{issuer.name} login page did not become ready")
        if looks_logged_in(issuer, probe):
            finish_authenticated_navigation(cdp, issuer)
            return {"issuer": issuer.name, "status": "already_authenticated"}
        if dry_run:
            return {"issuer": issuer.name, "status": "login_required"}

        # Fetch credentials only after verifying that the expected login form exists.
        username = op_read(issuer.username_ref, token)
        password = op_read(issuer.password_ref, token)
        try:
            fill_and_submit(cdp, issuer, username, password)
        finally:
            username = password = None
        submitted_at = time.monotonic()

        def settled():
            try:
                p = json.loads(page_probe(cdp, issuer.frame_expr))
                if (looks_logged_in(issuer, p) or p.get("otpCount", 0)
                        or (login_form_ready(p) and time.monotonic() - submitted_at >= LOGIN_REJECTION_GRACE_SECONDS)
                        or re.search(r"verification|security code|one-time|approve|text message|call us|captcha", p.get("text", ""), re.I)):
                    return p
            except Exception:
                pass
            return None
        probe = wait_until(settled, timeout=40)
        if not probe:
            raise AuthError("auth", f"{issuer.name} login did not settle")
        if looks_logged_in(issuer, probe):
            finish_authenticated_navigation(cdp, issuer)
            return {"issuer": issuer.name, "status": "authenticated"}
        if login_form_ready(probe) and not re.search(r"verification|security code|one-time", probe.get("text", ""), re.I):
            raise AuthError("auth", f"{issuer.name} rejected the login or returned to the sign-in form")

        # Only an unambiguous TOTP form may be automated. Push/SMS/CAPTCHA is manual.
        if probe.get("otpCount") == 1 and issuer.otp_ref:
            otp = op_read(issuer.otp_ref, token)
            try:
                submitted = submit_totp(cdp, issuer, otp)
            finally:
                otp = None
            if submitted:
                success = wait_until(lambda: looks_logged_in(issuer, json.loads(page_probe(cdp, issuer.frame_expr))), timeout=35)
                if success:
                    finish_authenticated_navigation(cdp, issuer)
                    return {"issuer": issuer.name, "status": "authenticated_totp"}
        # Remove anything secret-like before forensic capture.
        cdp.eval(f'''(()=>{{const d={issuer.frame_expr}; for(const x of d.querySelectorAll('input[type=password],input')){{if(x.type==='password'||/otp|code|verification|security/i.test([x.id,x.name,x.autocomplete,x.placeholder,x.getAttribute('aria-label')].join(' '))) x.value='';}} return true;}})()''')
        shot = cdp.screenshot(f"{issuer.name.lower()}-mfa")
        raise AuthError("mfa", f"{issuer.name} requires manual MFA; screenshot={shot}")
    finally:
        cdp.close()


def logout_one(issuer: Issuer):
    cdp = CDP(issuer.needle).connect()
    try:
        probe = json.loads(page_probe(cdp, issuer.frame_expr))
        if looks_logged_out(issuer, probe):
            return {"issuer": issuer.name, "status": "already_logged_out"}
        # Sign-out is explicitly authorized. Require one exact visible label;
        # ambiguous menus are left untouched and reported for manual inspection.
        result = cdp.eval('''(()=>{
          const els=Array.from(document.querySelectorAll('a,button,[role=button]')).filter(x=>/^(sign out|log out|logout)$/i.test((x.innerText||x.getAttribute('aria-label')||'').trim()) && x.offsetParent!==null);
          if(els.length!==1) return `matches:${els.length}`; els[0].click(); return 'clicked';
        })()''')
        if result != "clicked":
            return {"issuer": issuer.name, "status": "logout_not_found"}
        verified = wait_until(lambda: (lambda p: p if login_form_ready(p) or re.search(r"sign in|log in", p.get("text", ""), re.I) or (issuer.name == "Chase" and "/logout" in str(p.get("url") or "").lower()) else None)(json.loads(page_probe(cdp, issuer.frame_expr))), timeout=20)
        return {"issuer": issuer.name, "status": "logged_out" if verified else "logout_unverified"}
    finally:
        cdp.close()


def looks_logged_out(issuer: Issuer, probe: dict) -> bool:
    current_url = str(probe.get("url") or "").lower()
    return bool(probe.get("hasPassword") or (issuer.name == "Chase" and "/logout" in current_url))


def issuers(cfg):
    return [
        Issuer("Chase", "chase.com", "https://secure.chase.com/web/auth/dashboard#/dashboard/overview",
               "https://secure.chase.com/web/auth/dashboard?navKey=reviewMerchantOffers",
               cfg["CHASE_USERNAME_REF"], cfg["CHASE_PASSWORD_REF"], cfg.get("CHASE_OTP_REF"),
               CHASE_FRAME, "#userId-input-field-input", "#password-input-field-input", "#signin-button"),
        Issuer("Amex", "americanexpress.com", "https://www.americanexpress.com/en-us/account/login",
               "https://global.americanexpress.com/offers/eligible",
               cfg["AMEX_USERNAME_REF"], cfg["AMEX_PASSWORD_REF"], cfg.get("AMEX_OTP_REF"),
               MAIN_FRAME, "#eliloUserID", "#eliloPassword", "#loginSubmit"),
    ]


def self_test():
    assert js_string('a"b') == '"a\\"b"'
    assert not looks_logged_in(Issuer("Chase", "", "", "", "", "", None, "", "", "", ""), {"hasPassword": True})
    amex = Issuer("Amex", "", "", "", "", "", None, "", "", "", "")
    chase = Issuer("Chase", "", "", "", "", "", None, "", "", "", "")
    assert not looks_logged_in(amex, {"hasPassword": False, "hasUsername": False, "textLen": 0, "text": "", "url": "https://www.americanexpress.com/en-us/account/login"})
    assert looks_logged_in(amex, {"hasPassword": False, "hasUsername": False, "textLen": 300, "text": "Account Summary " * 20, "url": "https://global.americanexpress.com/dashboard"})
    assert not looks_logged_in(chase, {"hasPassword": False, "hasUsername": False, "textLen": 7, "text": "loading", "url": "https://secure.chase.com/web/auth/dashboard#/dashboard/overview"})
    assert login_form_ready({"hasUsername": True, "hasPassword": True})
    print(json.dumps({"ok": True, "tests": 6}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("login", "logout", "self-test"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.action == "self-test":
        self_test(); return 0
    if args.action == "logout":
        cfg = {f"{issuer}_{field}_REF": "" for issuer in ("CHASE", "AMEX") for field in ("USERNAME", "PASSWORD", "OTP")}
        banks = issuers(cfg)
        results = []
        for bank in banks:
            try:
                results.append(logout_one(bank))
            except AuthError as exc:
                results.append({"issuer": bank.name, "status": "error", "kind": exc.kind, "message": str(exc)})
        ok = all(x["status"] in ("logged_out", "already_logged_out") for x in results)
        print(json.dumps({"ok": ok, "results": results}))
        return 0 if ok else 3
    cfg = load_config()
    banks = issuers(cfg)
    token = None if args.dry_run else service_token()
    results = []
    for bank in banks:
        try:
            results.append(login_one(bank, token, args.dry_run))
        except AuthError as exc:
            results.append({"issuer": bank.name, "status": "error", "kind": exc.kind, "message": str(exc)})
    ok = any(x["status"] not in ("error", "login_required") for x in results) if not args.dry_run else True
    print(json.dumps({"ok": ok, "results": results}))
    return 0 if ok else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AuthError as exc:
        print(json.dumps({"ok": False, "kind": exc.kind, "message": str(exc)}))
        raise SystemExit(2)
