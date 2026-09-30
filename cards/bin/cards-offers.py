#!/usr/bin/python3
"""Deterministic post-login Chase/Amex offer activation and reporting."""
from __future__ import annotations

import argparse
import html
import importlib.util
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


HOME = Path("/Users/pattybot")
STATE = HOME / ".claude/skills/credit-card-offers/state"
AUTH_PATH = HOME / "dotfiles/cards/bin/cards-auth.py"
TELEGRAM = HOME / "dotfiles/twitter/bin/lib/telegram-send.sh"
CHAT_ID = "7953915703"
MAX_CLICKS = 500

spec = importlib.util.spec_from_file_location("cards_auth_runtime", AUTH_PATH)
auth = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = auth
spec.loader.exec_module(auth)


class OfferError(RuntimeError):
    def __init__(self, issuer: str, kind: str, message: str, screenshot: str | None = None, partial=None):
        super().__init__(message)
        self.issuer, self.kind, self.screenshot = issuer, kind, screenshot
        self.partial = partial


def atomic_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_dedup(name: str) -> set[str]:
    path = STATE / name
    if not path.exists() or not path.stat().st_size:
        return set()
    try:
        return {x.get("url") for x in json.loads(path.read_text()) if x.get("url")}
    except Exception as exc:
        raise OfferError("state", "config", f"invalid dedup file: {path.name}") from exc


def append_dedup(name: str, keys: list[str]):
    path = STATE / name
    existing = []
    if path.exists() and path.stat().st_size:
        existing = json.loads(path.read_text())
    seen = {x.get("url") for x in existing}
    now = datetime.now(timezone.utc).isoformat()
    existing.extend({"url": key, "digestedAt": now} for key in keys if key not in seen)
    atomic_json(path, existing)


def jitter():
    time.sleep(random.uniform(3, 6))


def amex(dry_run: bool):
    cdp = auth.CDP("americanexpress.com").connect()
    activated, failures = [], []
    try:
        probe = json.loads(auth.page_probe(cdp, auth.MAIN_FRAME))
        if not auth.looks_logged_in(auth.issuers({
            "CHASE_USERNAME_REF":"", "CHASE_PASSWORD_REF":"", "CHASE_OTP_REF":"",
            "AMEX_USERNAME_REF":"", "AMEX_PASSWORD_REF":"", "AMEX_OTP_REF":"",
        })[1], probe):
            raise OfferError("Amex", "auth", "Amex offers page is not authenticated")
        card_label = cdp.eval('''(()=>{
          const e=document.querySelector('[data-testid=simple_switcher_display_label]');
          return (e?.innerText||'Amex card').trim().replace(/\\s+/g,' ');
        })()''') or "Amex card"
        total = int(cdp.eval("document.querySelectorAll('[data-testid=merchantOfferListAddButton]').length") or 0)
        if dry_run:
            return {"issuer":"Amex", "ok":True, "card":card_label, "available":total, "activated":[], "failures":[]}

        clicks = 0
        empty_reloads = 0
        while clicks < MAX_CLICKS:
            info_raw = cdp.eval('''JSON.stringify((()=>{
              const btn=document.querySelector('[data-testid=merchantOfferListAddButton]');
              if(!btn) return null;
              let p=btn;
              for(let i=0;i<8&&p;i++){
                const cls=(p.className&&p.className.toString)?p.className.toString():'';
                if(cls.includes('border')) break;
                p=p.parentElement;
              }
              const lines=(p?.innerText||'').split('\\n').map(x=>x.trim()).filter(Boolean);
              if(lines[0]?.toUpperCase()==='NEW') lines.shift();
              return {merchant:lines[0]||'<unknown>',deal:lines[1]||''};
            })())''')
            info = json.loads(info_raw) if info_raw else None
            if not info:
                if empty_reloads < 3:
                    empty_reloads += 1
                    cdp.navigate("https://global.americanexpress.com/offers/eligible")
                    time.sleep(6)
                    continue
                break
            empty_reloads = 0
            before = int(cdp.eval("document.querySelectorAll('[data-testid=merchantOfferListAddButton]').length") or 0)
            before_added = None
            for _ in range(10):
                before_added = cdp.eval('''(()=>{const m=(document.body?.textContent||'').match(/Added to Card\\s*\\((\\d+)\\)/i); return m?Number(m[1]):null;})()''')
                if before_added is not None:
                    break
                time.sleep(1)
            result = cdp.eval('''(()=>{
              const b=document.querySelector('[data-testid=merchantOfferListAddButton]');
              if(!b||b.disabled) return 'missing';
              b.scrollIntoView({block:'center',behavior:'instant'}); b.click(); return 'clicked';
            })()''')
            if result != "clicked":
                raise OfferError("Amex", "dom", "Amex add control disappeared before click")
            jitter()
            verified = False
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                after = int(cdp.eval("document.querySelectorAll('[data-testid=merchantOfferListAddButton]').length") or 0)
                after_added = cdp.eval('''(()=>{const m=(document.body?.textContent||'').match(/Added to Card\\s*\\((\\d+)\\)/i); return m?Number(m[1]):null;})()''')
                next_raw = cdp.eval('''JSON.stringify((()=>{
                  const btn=document.querySelector('[data-testid=merchantOfferListAddButton]'); if(!btn)return null;
                  let p=btn; for(let i=0;i<8&&p;i++){const c=(p.className&&p.className.toString)?p.className.toString():'';if(c.includes('border'))break;p=p.parentElement;}
                  const lines=(p?.innerText||'').split('\\n').map(x=>x.trim()).filter(Boolean);if(lines[0]?.toUpperCase()==='NEW')lines.shift();
                  return {merchant:lines[0]||'<unknown>',deal:lines[1]||''};
                })())''')
                next_info = json.loads(next_raw) if next_raw else None
                counter_verified = before_added is not None and after_added is not None and int(after_added) >= int(before_added) + 1
                count_verified = after <= before - 1
                first_changed = next_info is None or next_info.get("merchant") != info.get("merchant") or next_info.get("deal") != info.get("deal")
                if counter_verified or count_verified or first_changed:
                    verified = True
                    break
                time.sleep(1)
            if not verified:
                shot = cdp.screenshot("amex-verify-fail")
                raise OfferError("Amex", "dom", "Amex add click produced no verified state transition within 15 seconds", shot)
            info["card_id"] = card_label
            info["key"] = f"{card_label}::{info['merchant']}::{info['deal']}"
            activated.append(info)
            clicks += 1
        remaining = int(cdp.eval("document.querySelectorAll('[data-testid=merchantOfferListAddButton]').length") or 0)
        if remaining:
            raise OfferError("Amex", "cap", f"Amex runaway guard reached with {remaining} offers remaining")
        return {"issuer":"Amex", "ok":True, "card":card_label, "available":total, "activated":activated, "failures":failures}
    finally:
        cdp.close()


def chase(dry_run: bool):
    cdp = auth.CDP("chase.com").connect()
    activated = []
    try:
        probe = json.loads(auth.page_probe(cdp, auth.CHASE_FRAME))
        issuer = auth.issuers({
            "CHASE_USERNAME_REF":"", "CHASE_PASSWORD_REF":"", "CHASE_OTP_REF":"",
            "AMEX_USERNAME_REF":"", "AMEX_PASSWORD_REF":"", "AMEX_OTP_REF":"",
        })[0]
        if not auth.looks_logged_in(issuer, probe):
            raise OfferError("Chase", "auth", "Chase offers page is not authenticated")
        # The visible hub is authoritative. Chase's background service can
        # return ACCOUNTS:UnexpectedException while these tiles are healthy.
        if "offer-hub" not in str(cdp.eval("location.href") or ""):
            cdp.navigate(issuer.offers_url)
        auth.wait_until(lambda: int(cdp.eval("document.querySelectorAll('[data-testid=commerce-tile]').length") or 0) > 0, timeout=12)

        tile_js = '''JSON.stringify((()=>{
          const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
          const added=(()=>{const m=(document.body?.innerText||'').match(/(\\d+)\\s*\\nAdded offers/i);return m?Number(m[1]):null;})();
          const all=Array.from(document.querySelectorAll('[data-testid=commerce-tile]'));
          const candidates=all.filter(t=>/^(CDLX:|FIGG:)/.test(t.id||'')
            && !/Success Added/i.test(t.getAttribute('aria-label')||'')
            && !Array.from(t.querySelectorAll('[data-testid=offer-tile-alert-container-success]')).some(visible));
          const t=candidates[0];
          if(!t)return {added,count:0,tile:null};
          const lines=(t.innerText||'').split(/\\n+/).map(x=>x.trim()).filter(Boolean)
            .filter(x=>!/^(New|Exclusive|Expiring soon|Last day|\\d+d left)$/i.test(x));
          return {added,count:candidates.length,tile:{id:t.id,merchant:lines[0]||'<unknown>',deal:lines[1]||''}};
        })())'''
        initial = json.loads(cdp.eval(tile_js))
        available = int(initial.get("count") or 0)
        if dry_run:
            return {"issuer":"Chase", "ok":True, "available":available, "activated":[], "failures":[]}

        for _ in range(MAX_CLICKS):
            state = json.loads(cdp.eval(tile_js))
            tile = state.get("tile")
            if not tile:
                return {"issuer":"Chase", "ok":True, "available":available, "activated":activated, "failures":[]}
            offer_id = tile["id"]
            clicked = cdp.call_function("document", '''function(id){
              const t=Array.from(this.querySelectorAll('[data-testid=commerce-tile]')).find(x=>x.id===id);
              if(!t)return 'missing';t.scrollIntoView({block:'center'});t.click();return 'clicked';
            }''', [offer_id])
            if clicked != "clicked":
                raise OfferError("Chase", "dom", "Chase offer tile disappeared before click", partial=activated)
            jitter()
            detail_ok = bool(cdp.eval(f'''location.href.includes('/offer-activated/{offer_id}') && /Success\\s+Added to card/i.test(document.body?.innerText||'')'''))
            cdp.navigate(issuer.offers_url)
            rendered = auth.wait_until(lambda: int(cdp.eval("document.querySelectorAll('[data-testid=commerce-tile]').length") or 0) > 0, timeout=12)
            hub = cdp.call_function("document", '''function(id){
              const body=this.body?.innerText||'';const m=body.match(/(\\d+)\\s*\\nAdded offers/i);
              const t=Array.from(this.querySelectorAll('[data-testid=commerce-tile]')).find(x=>x.id===id);
              const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
              return JSON.stringify({added:m?Number(m[1]):null,success:!!t&&(/Success Added/i.test(t.getAttribute('aria-label')||'')||Array.from(t.querySelectorAll('[data-testid=offer-tile-alert-container-success]')).some(visible))});
            }''', [offer_id]) if rendered else "{}"
            hub_state = json.loads(hub)
            counter_ok = state.get("added") is not None and hub_state.get("added") is not None and int(hub_state["added"]) > int(state["added"])
            if not (detail_ok and (hub_state.get("success") or counter_ok)):
                shot = cdp.screenshot("chase-verify-fail")
                raise OfferError("Chase", "dom", "Chase tile click did not produce a verified activation", shot, activated)
            activated.append({"merchant":tile["merchant"], "deal":tile["deal"], "offer_id":offer_id, "key":"chase::"+offer_id})
        remaining = json.loads(cdp.eval(tile_js)).get("count", 0)
        raise OfferError("Chase", "cap", f"Chase runaway guard reached with {remaining} offers remaining", partial=activated)
    finally:
        cdp.close()


def utf16_len(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def digest(results, errors):
    today = datetime.now().astimezone().strftime("%Y-%m-%d")
    by = {x["issuer"]: x for x in results}
    header = [f"💳 <b>Offer Roundup — {today}</b>", ""]
    offer_lines = []
    for issuer, icon in (("Chase","🏦"),("Amex","💎")):
        r = by.get(issuer, {"activated":[]})
        items = r.get("activated", [])
        label = issuer + ((" " + r.get("card","")) if issuer == "Amex" and r.get("card") else "")
        offer_lines.extend([f"{icon} <b>{html.escape(label)}</b> ({len(items)} new)"])
        if items:
            offer_lines.extend(f"• {html.escape(x.get('merchant','<unknown>'))} — {html.escape(x.get('deal',''))}" for x in items)
        else:
            offer_lines.append("• <i>no new offers</i>")
        offer_lines.append("")
    total = sum(len(x.get("activated",[])) for x in results)
    footer = ["—", f"{total} activated • {len(errors)} failures"]
    if errors:
        footer += ["", "⚠️ <b>Couldn't complete</b>"] + [f"• {html.escape(e.issuer)} — {html.escape(e.kind)}: {html.escape(str(e))}" for e in errors]
    kept=[]
    for line in offer_lines:
        candidate="\n".join(header+kept+[line]+footer)
        if utf16_len(candidate) > 3700:
            break
        kept.append(line)
    omitted = sum(1 for x in offer_lines[len(kept):] if x.startswith("• ") and "no new" not in x)
    if omitted:
        kept.append(f"• <i>…and {omitted} more activated offers</i>")
        kept.append("")
    return "\n".join(header+kept+footer)


def send_telegram(message: str):
    run_dir = Path(tempfile.mkdtemp(prefix="cards-offers-", dir="/tmp"))
    os.chmod(run_dir, 0o700)
    try:
        html_path, plain_path = run_dir/"digest.html", run_dir/"digest.txt"
        html_path.write_text(message)
        plain_path.write_text(html.unescape(re.sub(r"<[^>]+>", "", message)))
        env = os.environ.copy()
        env.update({"TELEGRAM_CHAT_ID":CHAT_ID, "TELEGRAM_MESSAGE_FILE":str(html_path),
                    "TELEGRAM_MESSAGE_PLAIN_FILE":str(plain_path), "RUN_DIR":str(run_dir)})
        proc = subprocess.run([str(TELEGRAM)], env=env, timeout=30)
        if proc.returncode:
            raise OfferError("Telegram", "telegram", f"Telegram helper exited {proc.returncode}")
    finally:
        shutil.rmtree(run_dir, ignore_errors=True)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--dry-run", action="store_true"); args=parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True)
    results=[]; errors=[]
    available_raw = os.environ.get("CARDS_AVAILABLE_ISSUERS")
    available = (
        {x.strip() for x in available_raw.split(",") if x.strip()}
        if available_raw is not None else {"Chase", "Amex"}
    )
    try:
        auth_failures = {
            x.get("issuer"): x
            for x in json.loads(os.environ.get("CARDS_AUTH_FAILURES_JSON", "[]"))
        }
    except Exception:
        auth_failures = {}
    for fn, name in ((chase,"Chase"),(amex,"Amex")):
        if name not in available:
            failure = auth_failures.get(name, {})
            exc = OfferError(
                name,
                failure.get("kind", "auth"),
                failure.get("message", f"{name} was unavailable after authentication"),
            )
            errors.append(exc)
            results.append({"issuer":name,"ok":False,"activated":[],"failures":[str(exc)]})
            continue
        try: results.append(fn(args.dry_run))
        except OfferError as exc:
            errors.append(exc); results.append({"issuer":name,"ok":False,"activated":exc.partial or [],"failures":[str(exc)]})
    summary={"ok":not errors,"dryRun":args.dry_run,
             "results":[{"issuer":x["issuer"],"ok":x.get("ok"),"available":x.get("available"),"activated":len(x.get("activated",[]))} for x in results],
             "errors":[{"issuer":e.issuer,"kind":e.kind,"message":str(e),"screenshot":e.screenshot} for e in errors]}
    if args.dry_run:
        print(json.dumps(summary)); return 0 if len(errors) < 2 else 2
    pending={"runAt":datetime.now(timezone.utc).isoformat(),"chaseActivated":len(next(x for x in results if x["issuer"]=="Chase").get("activated",[])),"amexActivated":len(next(x for x in results if x["issuer"]=="Amex").get("activated",[])),"telegramOk":None}
    atomic_json(STATE/"pending.json",pending)
    try:
        send_telegram(digest(results,errors))
    except OfferError as exc:
        errors.append(exc); atomic_json(STATE/"last-failure.json",{"kind":exc.kind,"at":datetime.now(timezone.utc).isoformat(),"message":str(exc)}); print(json.dumps(summary)); return 4
    append_dedup("amex-activated.json",[x["key"] for r in results if r["issuer"]=="Amex" for x in r.get("activated",[])])
    append_dedup("chase-activated.json",[x["key"] for r in results if r["issuer"]=="Chase" for x in r.get("activated",[])])
    pending["telegramOk"]=True
    if len(errors) < 2:
        atomic_json(STATE/"last-success.json",pending)
    (STATE/"pending.json").unlink(missing_ok=True)
    if errors:
        atomic_json(STATE/"last-failure.json",{"kind":"partial" if len(errors)<2 else "both_failed","at":datetime.now(timezone.utc).isoformat(),"failures":summary["errors"]})
    else:
        (STATE/"last-failure.json").unlink(missing_ok=True)
    print(json.dumps(summary)); return 0 if len(errors) < 2 else 2


if __name__ == "__main__":
    raise SystemExit(main())
