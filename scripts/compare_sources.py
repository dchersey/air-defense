#!/usr/bin/env python3
"""Side-by-side comparison of FR24 vs airplanes.live over the same monitor box.

Pulls the live monitor zone(s) from the running Air Defense service, queries both
sources each tick, and reports presence agreement (both / FR24-only / ADSB-only)
plus per-aircraft field deltas (ground speed, altitude, track, position, staleness).

Usage:
  scripts/compare_sources.py [--zone ID] [--count N] [--interval S] [--all]

FR24 spends credits only when aircraft are in the box (6/flight); empty polls are
free. airplanes.live is free. Be polite: interval >= ~5s.
"""
import argparse, json, math, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime

API = "http://127.0.0.1:4040"
FR24_HOST = "https://fr24api.flightradar24.com"
UA = "air-defense-compare/0.1"


def keychain_fr24():
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", "air-defense-fr24", "-w"],
                             capture_output=True, text=True)
        return out.stdout.strip() or None
    except Exception:
        return None


def http_json(url, headers=None, timeout=12):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.load(r)


def all_coords(obj):
    """Yield every [lon, lat] pair anywhere in a GeoJSON object."""
    if isinstance(obj, dict):
        for v in obj.values():
            yield from all_coords(v)
    elif isinstance(obj, list):
        if len(obj) == 2 and all(isinstance(x, (int, float)) for x in obj):
            yield obj
        else:
            for v in obj:
                yield from all_coords(v)


def bbox_of(geojson_str):
    """Return (north, south, west, east) from a monitor-zone GeoJSON string."""
    pts = list(all_coords(json.loads(geojson_str)))
    lons = [p[0] for p in pts]; lats = [p[1] for p in pts]
    return max(lats), min(lats), min(lons), max(lons)


def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1); dl = math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2 * R * math.asin(math.sqrt(a))


def fr24_fetch(key, bbox):
    n, s, w, e = bbox
    url = f"{FR24_HOST}/api/live/flight-positions/light?bounds={n},{s},{w},{e}"
    hdrs = {"Accept": "application/json", "Accept-Version": "v1", "Authorization": "Bearer " + key}
    try:
        status, body = http_json(url, hdrs)
    except urllib.error.HTTPError as ex:
        return None, f"HTTP {ex.code}"
    except Exception as ex:
        return None, str(ex)
    out = {}
    for a in body.get("data", []):
        hx = (a.get("hex") or "").lower()
        if not hx:
            continue
        ts = a.get("timestamp")
        try:
            age = time.time() - float(ts) if ts is not None else None
        except (TypeError, ValueError):
            age = None
        out[hx] = dict(flight=(a.get("callsign") or "").strip(), lat=a.get("lat"), lon=a.get("lon"),
                       gs=a.get("gspeed"), alt=a.get("alt"), trk=a.get("track"), age=age)
    return out, None


def adsb_fetch(bbox):
    n, s, w, e = bbox
    clat, clon = (n + s) / 2, (w + e) / 2
    radius_nm = min(250, max(1, haversine_m(clat, clon, n, e) / 1852 * 1.15))
    url = f"https://api.airplanes.live/v2/point/{clat:.4f}/{clon:.4f}/{radius_nm:.1f}"
    try:
        _, body = http_json(url)
    except Exception as ex:
        return None, str(ex)
    out = {}
    for a in body.get("ac", []):
        hx = (a.get("hex") or "").lower()
        lat, lon = a.get("lat"), a.get("lon")
        if not hx or lat is None or lon is None:
            continue
        if not (s <= lat <= n and w <= lon <= e):   # trim circle → the FR24 bbox
            continue
        alt = a.get("alt_baro")
        out[hx] = dict(flight=(a.get("flight") or "").strip(), lat=lat, lon=lon,
                       gs=a.get("gs"), alt=(0 if alt == "ground" else alt), trk=a.get("track"),
                       age=a.get("seen_pos"))
    return out, None


def num(x):
    return x if isinstance(x, (int, float)) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone"); ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--interval", type=float, default=30.0); ap.add_argument("--all", action="store_true")
    ap.add_argument("--bbox", help="override: N,S,W,E (skip the live zones; e.g. an area you know has traffic)")
    args = ap.parse_args()

    key = keychain_fr24()
    if not key:
        print("No FR24 key in keychain (air-defense-fr24)."); sys.exit(1)

    if args.bbox:
        n, s, w, e = (float(x) for x in args.bbox.split(","))
        boxes = [("custom", "custom bbox", (n, s, w, e))]
    else:
        _, zs = http_json(f"{API}/api/zonesets")
        zones = zs["zonesets"]
        if args.zone:
            zones = [z for z in zones if z["id"] == args.zone]
        elif not args.all:
            zones = zones[:1]
        if not zones:
            print("No matching zonesets."); sys.exit(1)
        boxes = [(z["id"], z["name"], bbox_of(z["monitor_geojson"])) for z in zones]
    print(f"Comparing {len(boxes)} zone(s), {args.count}× every {args.interval:g}s:")
    for zid, name, bb in boxes:
        print(f"  • {zid} ({name}) bbox N={bb[0]:.3f} S={bb[1]:.3f} W={bb[2]:.3f} E={bb[3]:.3f}")
    print()

    ticks = both_n = fr24_only = adsb_only = empty_agree = 0
    gs_d: list[float] = []
    pos_d: list[float] = []
    alt_d: list[float] = []

    for i in range(args.count):
        for zid, name, bb in boxes:
            fr, ferr = fr24_fetch(key, bb)
            ad, aerr = adsb_fetch(bb)
            ts = datetime.now().strftime("%H:%M:%S")
            if fr is None or ad is None:
                print(f"[{ts}] {zid}: FR24={'ERR ' + ferr if ferr else '?'} "
                      f"ADSB={'ERR ' + aerr if aerr else '?'}  (skipped)")
                continue
            ticks += 1
            fset, aset = set(fr), set(ad)
            both, fonly, aonly = fset & aset, fset - aset, aset - fset
            both_n += len(both); fr24_only += len(fonly); adsb_only += len(aonly)
            if not fset and not aset:
                empty_agree += 1
            print(f"[{ts}] {zid}: FR24={len(fr)} ADSB={len(ad)} | both={len(both)} "
                  f"FR24-only={sorted(fonly) or '-'} ADSB-only={sorted(aonly) or '-'}")
            for hx in sorted(both):
                f, a = fr[hx], ad[hx]
                dpos = haversine_m(f["lat"], f["lon"], a["lat"], a["lon"]) if None not in (f["lat"], f["lon"], a["lat"], a["lon"]) else None
                dgs = abs(f["gs"] - a["gs"]) if None not in (num(f["gs"]), num(a["gs"])) else None
                dalt = abs(f["alt"] - a["alt"]) if None not in (num(f["alt"]), num(a["alt"])) else None
                dtrk = None
                if None not in (num(f["trk"]), num(a["trk"])):
                    d = abs(f["trk"] - a["trk"]) % 360; dtrk = min(d, 360 - d)
                if dgs is not None: gs_d.append(dgs)
                if dpos is not None: pos_d.append(dpos)
                if dalt is not None: alt_d.append(dalt)
                fl = f["flight"] or a["flight"] or hx
                print(f"        {hx} {fl:<8} Δgs={fmt(dgs,'kt')} Δalt={fmt(dalt,'ft')} "
                      f"Δpos={fmt(dpos,'m',0)} Δtrk={fmt(dtrk,'°')} | age FR24={fmt(f['age'],'s',0)} ADSB={fmt(a['age'],'s',0)}")
        if i < args.count - 1:
            time.sleep(args.interval)

    print("\n=== summary ===")
    print(f"ticks={ticks}  matched(both)={both_n}  FR24-only={fr24_only}  ADSB-only={adsb_only}  "
          f"empty-agree ticks={empty_agree}")
    for label, v in [("|Δgs| kt", gs_d), ("|Δpos| m", pos_d), ("|Δalt| ft", alt_d)]:
        if v:
            med = sorted(v)[len(v) // 2]
            print(f"  {label}: n={len(v)} mean={sum(v)/len(v):.1f} median={med:.1f} max={max(v):.1f}")


def fmt(x, unit, prec=1):
    return f"{x:.{prec}f}{unit}" if isinstance(x, (int, float)) else "—"


if __name__ == "__main__":
    main()
