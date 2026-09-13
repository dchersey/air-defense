#!/usr/bin/env python3
"""Calibrate ANC release timing against your ear.

Runs on the Mac (your keyboard is the instrument). Polls the local receiver once a
second, tracks the aircraft crossing overhead, and records the moment you judge the
noise to have abated — press ENTER.

The point is to remove measurement lag. Messaging a mark to someone costs an unknown
5-20s of notice-plus-typing delay, which is hopeless when the quantity being measured
is worth 8 seconds. A local keypress is timestamped the instant you make the judgement.

For each pass it records three reference points and your mark against all of them:

  engage  when Air Defense actually turned ANC on  <- the number release_delta tunes

Two row kinds, because the two halves of the calibration need opposite conditions:
  mark  you pressed ENTER. Requires the headphones OFF, since you cannot time noise
        that ANC is busy suppressing.
  auto  engage->closest, recorded with no human involvement, so it collects while the
        headphones are ON. Written once per pass that ANC actually engaged.
  cliff   signal falls 10 dB off its peak (the antenna's cone of silence, ~7s before
          closest approach at a fixed elevation angle)
  closest minimum slant range

Usage:  ./noise-timing.py            # until Ctrl-C
        ./noise-timing.py --minutes 30
"""
import argparse, csv, json, math, os, sys, threading, time, urllib.request
from datetime import datetime, timezone

RECEIVER = os.environ.get("ADSB_URL", "http://adsb.internal/tar1090/data/aircraft.json")
AIRDEF   = os.environ.get("AIRDEFENSE_URL", "http://127.0.0.1:4040/api/status")
OUT      = os.path.expanduser("~/air-defense-noise-timing.csv")
HOME     = (40.722832, -73.857549)      # antenna position; override with ADSB_LAT/LON
if os.environ.get("ADSB_LAT"):
    HOME = (float(os.environ["ADSB_LAT"]), float(os.environ["ADSB_LON"]))

CLIFF_DB    = 10.0    # dB below peak that counts as the cone-of-silence edge
TRACK_NM    = 2.0     # consider aircraft inside this range
TRACK_FT    = 3000    # ...and below this altitude (the gear-down band)
KEEP_S      = 180     # remember a pass this long after it ends, so a late mark lands


def get(url, timeout=4):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def nm(a, b):
    return math.hypot((b[0] - a[0]) * 60.0,
                      (b[1] - a[1]) * 60.0 * math.cos(math.radians(a[0])))


def hhmmss(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%H:%M:%S")


class Pass:
    """One aircraft's transit: peak signal, cone-of-silence cliff, closest approach."""
    def __init__(self, key, flight):
        self.key, self.flight = key, flight
        self.peak_rssi, self.peak_at = -999.0, None
        self.cliff_at = self.cliff_rssi = None
        self.min_nm, self.closest_at, self.alt = 999.0, None, None
        self.last_seen = time.time()
        self.auto_written = False

    def update(self, rssi, rng, alt, now):
        self.last_seen = now
        if alt is not None:
            self.alt = alt
        if rng is not None and rng < self.min_nm:
            self.min_nm, self.closest_at = rng, now
        if rssi is None:
            return
        if rssi > self.peak_rssi:
            self.peak_rssi, self.peak_at = rssi, now
            self.cliff_at = None          # a new peak invalidates an earlier "cliff"
        elif self.cliff_at is None and rssi <= self.peak_rssi - CLIFF_DB:
            self.cliff_at, self.cliff_rssi = now, rssi


def engage_time(flight):
    """When Air Defense actually engaged ANC for this callsign, if it did."""
    s = get(AIRDEF)
    if not s:
        return None
    for f in s.get("recent", []):
        if (f.get("callsign") or "").strip() == flight and f.get("engaged") is not False:
            return f.get("at", 0) + f.get("enters_in", 0)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=0, help="stop after N minutes")
    args = ap.parse_args()

    marks = []
    def reader():
        for _ in sys.stdin:
            marks.append(time.time())
    threading.Thread(target=reader, daemon=True).start()

    new = not os.path.exists(OUT)
    fh = open(OUT, "a", newline="", buffering=1)
    w = csv.writer(fh)
    if new:
        w.writerow(["kind", "mark_utc", "flight", "alt_ft", "min_nm",
                    "engage_utc", "mark_minus_engage_s",
                    "cliff_utc", "cliff_to_closest_s",
                    "closest_utc", "mark_minus_closest_s", "peak_rssi", "cliff_rssi"])

    print(f"Receiver : {RECEIVER}")
    print(f"Recording: {OUT}")
    print("Press ENTER the moment the noise abates.  Ctrl-C to stop.\n")

    passes, done, end = {}, [], (time.time() + args.minutes * 60) if args.minutes else None
    while end is None or time.time() < end:
        now = time.time()
        d = get(RECEIVER)
        if d:
            for a in d.get("aircraft", []):
                if "lat" not in a:
                    continue
                alt = a.get("alt_baro")
                alt = alt if isinstance(alt, int) else None
                rng = nm(HOME, (a["lat"], a["lon"]))
                if rng > TRACK_NM or (alt or 99999) > TRACK_FT:
                    continue
                key = a.get("hex") or (a.get("flight") or "").strip()
                if not key:
                    continue
                p = passes.get(key) or Pass(key, (a.get("flight") or "?").strip())
                p.update(a.get("rssi"), rng, alt, now)
                passes[key] = p

            for k, p in list(passes.items()):          # retire finished passes
                if now - p.last_seen > 20:
                    # The engage->closest interval is the missing half of the
                    # calibration, and measuring it needs no ear: Air Defense knows when
                    # it engaged, the receiver knows when the aircraft was closest. So
                    # record it automatically -- it can be collected with the headphones
                    # ON, doing their job, which is exactly when the ear cannot help.
                    eng = engage_time(p.flight)
                    if eng and p.closest_at and not p.auto_written:
                        p.auto_written = True
                        # Record the cliff too. It is the candidate real-time trigger:
                        # unlike closest approach it is OBSERVABLE as it happens rather
                        # than only after the range starts growing. Whether it is stable
                        # enough is the open question, and it can only be answered at a
                        # fixed gain -- the cliff is defined relative to peak, so tuning
                        # the gain mid-capture moves the threshold and fakes variance.
                        w.writerow(["auto", "", p.flight, p.alt, f"{p.min_nm:.2f}",
                                    hhmmss(eng), "",
                                    hhmmss(p.cliff_at) if p.cliff_at else "",
                                    f"{p.closest_at-p.cliff_at:.0f}" if p.cliff_at else "",
                                    hhmmss(p.closest_at), f"{p.closest_at-eng:.0f}",
                                    f"{p.peak_rssi:.1f}",
                                    f"{p.cliff_rssi:.1f}" if p.cliff_rssi else ""])
                        c = f"cliff->closest {p.closest_at-p.cliff_at:+.0f}s" if p.cliff_at else "cliff -"
                        print(f"\r  auto {p.flight:8} engage->closest {p.closest_at-eng:+.0f}s  "
                              f"{c}   (alt {p.alt}, {p.min_nm:.2f} nm)      ")
                    done.append(p); del passes[k]
            done[:] = [p for p in done if now - p.last_seen < KEEP_S]

        while marks:                                   # a keypress landed
            m = marks.pop(0)
            cands = list(passes.values()) + done
            cands = [c for c in cands if c.closest_at and c.closest_at <= m]
            if not cands:
                print("  (mark ignored — no pass to attribute it to)")
                continue
            p = max(cands, key=lambda c: c.closest_at)
            eng = engage_time(p.flight)
            row = ["mark", hhmmss(m), p.flight, p.alt, f"{p.min_nm:.2f}",
                   hhmmss(eng) if eng else "", f"{m-eng:.0f}" if eng else "",
                   hhmmss(p.cliff_at) if p.cliff_at else "",
                   f"{m-p.cliff_at:.0f}" if p.cliff_at else "",
                   hhmmss(p.closest_at), f"{m-p.closest_at:.0f}",
                   f"{p.peak_rssi:.1f}", f"{p.cliff_rssi:.1f}" if p.cliff_rssi else ""]
            w.writerow(row)
            print(f"\r  MARK {p.flight:8} alt {p.alt}  "
                  + (f"engage{m-eng:+.0f}s  " if eng else "engage —      ")
                  + (f"cliff{m-p.cliff_at:+.0f}s  " if p.cliff_at else "cliff —     ")
                  + f"closest{m-p.closest_at:+.0f}s")

        live = sorted(passes.values(), key=lambda p: p.min_nm)
        if live:
            p = live[0]
            state = "CLIFF" if p.cliff_at else ("peak " if p.peak_at else "     ")
            sys.stdout.write(f"\r  {p.flight:8} {p.min_nm:5.2f}nm {str(p.alt or '-'):>5}ft "
                             f"peak {p.peak_rssi:6.1f} {state}   ")
        else:
            sys.stdout.write("\r  (nothing overhead)                              ")
        sys.stdout.flush()
        time.sleep(1.0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped")
