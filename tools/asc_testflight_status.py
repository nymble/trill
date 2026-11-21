#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Report (and optionally fix) TestFlight state for one app through the
App Store Connect API. Never prints key material; tester addresses are
masked because Actions logs on this repository are public.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (PEM or base64), ASC_APP_ID,
     FIX=1 to apply safe fixes, BUILD=<number> to target, WHAT_TO_TEST.
"""
import base64, json, os, sys, time, urllib.request, urllib.error
import jwt

API = "https://api.appstoreconnect.apple.com"


def key():
    raw = os.environ["ASC_KEY_P8"].strip()
    if "BEGIN" not in raw:
        raw = base64.b64decode(raw).decode()
    return raw


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100,
                       "aud": "appstoreconnect-v1"}, key(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


TOK = token()


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return r.status, (json.loads(data) if data else {})
    except urllib.error.HTTPError as e:
        txt = e.read().decode(errors="replace")
        try:
            errs = [(x.get("code"), x.get("detail")) for x in json.loads(txt).get("errors", [])]
        except Exception:
            errs = txt[:300]
        return e.code, {"errors": errs}


def mask(email):
    if not email or "@" not in email:
        return email
    u, d = email.split("@", 1)
    return u[:1] + "***@" + d


app = os.environ["ASC_APP_ID"]
fix = os.environ.get("FIX") == "1"
target = os.environ.get("BUILD", "")
wtt = os.environ.get("WHAT_TO_TEST", "")

s, builds = call("GET", f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=20"
                 "&include=preReleaseVersion,buildBetaDetail,betaGroups")
if s != 200:
    print("builds:", s, builds); sys.exit(1)
inc = {(x["type"], x["id"]): x for x in builds.get("included", [])}

s, groups = call("GET", f"/v1/apps/{app}/betaGroups?limit=50")
print("== Beta groups")
gmap = {}
for g in groups.get("data", []):
    a = g["attributes"]
    gmap[g["id"]] = a["name"]
    print(f"  {a['name']}: internal={a.get('isInternalGroup')} allBuilds={a.get('hasAccessToAllBuilds')}")
    s2, t = call("GET", f"/v1/betaGroups/{g['id']}/betaTesters?limit=50")
    for x in t.get("data", []):
        ta = x["attributes"]
        print(f"    tester {mask(ta.get('email'))} inviteType={ta.get('inviteType')} state={ta.get('state')}")


def show():
    s, b = call("GET", f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=20"
                "&include=preReleaseVersion,buildBetaDetail,betaGroups")
    inc = {(x["type"], x["id"]): x for x in b.get("included", [])}
    rows = []
    for x in b.get("data", []):
        a, r = x["attributes"], x["relationships"]
        pv = inc.get(("preReleaseVersions", (r["preReleaseVersion"]["data"] or {}).get("id")), {}).get("attributes", {})
        bd = inc.get(("buildBetaDetails", (r["buildBetaDetail"]["data"] or {}).get("id")), {}).get("attributes", {})
        gs = [gmap.get(g["id"], g["id"]) for g in (r.get("betaGroups", {}).get("data") or [])]
        rows.append((x["id"], pv.get("platform"), pv.get("version"), a["version"], a.get("processingState"),
                     a.get("usesNonExemptEncryption"), a.get("expired"), a.get("minOsVersion"),
                     bd.get("internalBuildState"), bd.get("externalBuildState"), gs, a.get("uploadedDate")))
        print(f"  {pv.get('platform')} {pv.get('version')} ({a['version']}) processing={a.get('processingState')} "
              f"nonExemptEnc={a.get('usesNonExemptEncryption')} expired={a.get('expired')} minOS={a.get('minOsVersion')} "
              f"internal={bd.get('internalBuildState')} external={bd.get('externalBuildState')} groups={gs} uploaded={a.get('uploadedDate')}")
    return rows


print("== Builds")
rows = show()

if fix:
    print("== Fixes")
    internal = [gid for gid, n in gmap.items() if n == "Trillium internal"]
    for (bid, plat, ver, num, proc, enc, exp, mos, ist, est, gs, up) in rows:
        if target and num != target:
            continue
        if proc != "VALID" or exp:
            continue
        if enc is None:
            s, r = call("PATCH", f"/v1/builds/{bid}", {"data": {"type": "builds", "id": bid,
                                                              "attributes": {"usesNonExemptEncryption": False}}})
            print(f"  {plat} ({num}) set usesNonExemptEncryption=false -> {s} {r.get('errors', '')}")
        for gid in internal:
            if "Trillium internal" not in gs:
                s, r = call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
                            {"data": [{"type": "builds", "id": bid}]})
                print(f"  {plat} ({num}) add to Trillium internal -> {s} {r.get('errors', '')}")
        if wtt:
            s, loc = call("GET", f"/v1/builds/{bid}/betaBuildLocalizations")
            locs = loc.get("data", [])
            if locs:
                for l in locs:
                    if not (l["attributes"].get("whatsNew") or "").strip():
                        s, r = call("PATCH", f"/v1/betaBuildLocalizations/{l['id']}", {"data": {
                            "type": "betaBuildLocalizations", "id": l["id"], "attributes": {"whatsNew": wtt}}})
                        print(f"  {plat} ({num}) What to Test ({l['attributes'].get('locale')}) -> {s} {r.get('errors', '')}")
                    else:
                        print(f"  {plat} ({num}) What to Test already set ({l['attributes'].get('locale')})")
            else:
                s, r = call("POST", "/v1/betaBuildLocalizations", {"data": {
                    "type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": wtt},
                    "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
                print(f"  {plat} ({num}) What to Test created -> {s} {r.get('errors', '')}")
    ext = os.environ.get("EXTERNAL_GROUP", "")
    egids = [gid for gid, n in gmap.items() if n == ext] if ext else []
    for (bid, plat, ver, num, proc, enc, exp, mos, ist, est, gs, up) in rows:
        if not egids or (target and num != target) or proc != "VALID" or exp:
            continue
        if ext not in gs:
            s, r = call("POST", f"/v1/betaGroups/{egids[0]}/relationships/builds",
                        {"data": [{"type": "builds", "id": bid}]})
            print(f"  {plat} ({num}) add to {ext} -> {s} {r.get('errors', '')}")
        s, sub = call("GET", f"/v1/betaAppReviewSubmissions?filter[build]={bid}")
        subs = sub.get("data", [])
        if subs:
            print(f"  {plat} ({num}) beta review: {[x['attributes'].get('betaReviewState') for x in subs]}")
        elif os.environ.get("SUBMIT_BETA_REVIEW") == "1":
            s, r = call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
                        "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
            st = (r.get("data") or {}).get("attributes", {}).get("betaReviewState")
            print(f"  {plat} ({num}) submitted for TestFlight beta review -> {s} {st or ''} {r.get('errors', '')}")
    print("== Builds after fixes")
    show()

print("== Team users (masked)")
s, u = call("GET", "/v1/users?limit=50")
for x in u.get("data", []):
    a = x["attributes"]
    print(f"  user {mask(a.get('username'))} roles={a.get('roles')} allApps={a.get('allAppsVisible')}")
s, inv = call("GET", "/v1/userInvitations?limit=50")
for x in inv.get("data", []):
    a = x["attributes"]
    print(f"  pending invite {mask(a.get('email'))} roles={a.get('roles')} expires={a.get('expirationDate')}")
