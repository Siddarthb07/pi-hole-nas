#!/usr/bin/env python3
"""Rotate Pi-hole / system / NAS / network stats on a 16x2 I2C LCD.

Screens (2 metrics each):
  1 Pi-hole  — block % today, queries today
  2 System   — CPU temp C, RAM used %
  3 NAS      — free space on share, Samba up/down
  4 Network  — IPv4 address, gateway reachable

Env (optional):
  LCD_ADDRESS=0x27   # or 0x3f
  LCD_BUS=1
  LCD_COLS=16
  LCD_ROWS=2
  LCD_HOLD=5         # seconds per screen
  NAS_PATH=/srv/nas
  FTL_HOST=127.0.0.1
  FTL_PORT=4711
  DRY_RUN=1          # print to stdout, no hardware
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
import time
from pathlib import Path

COLS = int(os.environ.get("LCD_COLS", "16"))
ROWS = int(os.environ.get("LCD_ROWS", "2"))
HOLD = float(os.environ.get("LCD_HOLD", "5"))
NAS_PATH = os.environ.get("NAS_PATH", "/srv/nas")
FTL_HOST = os.environ.get("FTL_HOST", "127.0.0.1")
FTL_PORT = int(os.environ.get("FTL_PORT", "4711"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
LCD_ADDRESS = int(os.environ.get("LCD_ADDRESS", "0x27"), 0)
LCD_BUS = int(os.environ.get("LCD_BUS", "1"))


def clip(text: str, width: int = COLS) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > width:
        return text[:width]
    return text.ljust(width)


def run(cmd: list[str], timeout: float = 2.0) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=timeout)
        return out.decode("utf-8", errors="replace").strip()
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return ""


def ftl_stats() -> dict[str, str]:
    """Talk to FTL telnet API (no web password)."""
    data: dict[str, str] = {}
    try:
        with socket.create_connection((FTL_HOST, FTL_PORT), timeout=1.5) as sock:
            sock.sendall(b">stats\n>quit\n")
            sock.settimeout(1.5)
            buf = b""
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                if b"---EOT---" in buf or b">quit" in buf:
                    break
        for line in buf.decode("utf-8", errors="replace").splitlines():
            if " " not in line or line.startswith(">"):
                continue
            key, _, val = line.partition(" ")
            data[key.strip()] = val.strip()
    except OSError:
        pass
    return data


def fmt_count(n: float | int) -> str:
    n = float(n)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(int(n))


def screen_pihole() -> tuple[str, str]:
    stats = ftl_stats()
    try:
        pct = float(stats.get("ads_percentage_today", "nan"))
        line1 = f"Block {pct:.0f}%" if pct == pct else "Block --%"
    except ValueError:
        line1 = "Block --%"
    try:
        q = float(stats.get("dns_queries_today", "nan"))
        line2 = f"Q {fmt_count(q)}" if q == q else "Q --"
    except ValueError:
        line2 = "Q --"
    return line1, line2


def cpu_temp_c() -> str:
    raw = run(["vcgencmd", "measure_temp"])
    m = re.search(r"temp=([0-9.]+)", raw)
    if m:
        return f"{float(m.group(1)):.0f}C"
    try:
        milli = int(Path("/sys/class/thermal/thermal_zone0/temp").read_text().strip())
        return f"{milli / 1000:.0f}C"
    except (OSError, ValueError):
        return "--C"


def ram_used_pct() -> str:
    try:
        info: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] in ("MemTotal:", "MemAvailable:"):
                info[parts[0][:-1]] = int(parts[1])
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        if total <= 0:
            return "--%"
        used = 100.0 * (total - avail) / total
        return f"{used:.0f}%"
    except (OSError, ValueError, ZeroDivisionError):
        return "--%"


def screen_system() -> tuple[str, str]:
    return f"CPU {cpu_temp_c()}", f"RAM {ram_used_pct()}"


def fmt_bytes(n: int) -> str:
    for unit, div in (("T", 1024**4), ("G", 1024**3), ("M", 1024**2), ("K", 1024)):
        if n >= div:
            return f"{n / div:.0f}{unit}"
    return f"{n}B"


def nas_free() -> str:
    path = Path(NAS_PATH)
    if not path.exists():
        path = Path("/srv/nas-local")
    try:
        st = os.statvfs(path)
        free = st.f_bavail * st.f_frsize
        return fmt_bytes(free)
    except OSError:
        return "--"


def smb_ok() -> str:
    out = run(["systemctl", "is-active", "smbd"])
    return "OK" if out == "active" else "DOWN"


def screen_nas() -> tuple[str, str]:
    return f"NAS {nas_free()} free", f"SMB {smb_ok()}"


def primary_ipv4() -> str:
    # Prefer non-loopback IPv4 from hostname -I
    for tok in run(["hostname", "-I"]).split():
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", tok) and not tok.startswith("127."):
            return tok
    return "--"


def default_gateway() -> str:
    out = run(["ip", "route", "show", "default"])
    m = re.search(r"default via (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else ""


def gateway_ok() -> str:
    gw = default_gateway()
    if not gw:
        return "NO GW"
    # 1 packet, 1s wait
    rc = subprocess.call(
        ["ping", "-c", "1", "-W", "1", gw],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return "GW OK" if rc == 0 else "GW DOWN"


def screen_network() -> tuple[str, str]:
    ip = primary_ipv4()
    return ip[:COLS], gateway_ok()


SCREENS = (
    ("pihole", screen_pihole),
    ("system", screen_system),
    ("nas", screen_nas),
    ("network", screen_network),
)


class Display:
    def __init__(self) -> None:
        self.lcd = None
        if DRY_RUN:
            return
        from RPLCD.i2c import CharLCD  # type: ignore

        self.lcd = CharLCD(
            i2c_expander="PCF8574",
            address=LCD_ADDRESS,
            port=LCD_BUS,
            cols=COLS,
            rows=ROWS,
            auto_linebreaks=False,
        )

    def show(self, line1: str, line2: str) -> None:
        a, b = clip(line1), clip(line2)
        if self.lcd is None:
            print(f"+{'-' * COLS}+")
            print(f"|{a}|")
            print(f"|{b}|")
            print(f"+{'-' * COLS}+")
            return
        self.lcd.clear()
        self.lcd.cursor_pos = (0, 0)
        self.lcd.write_string(a)
        self.lcd.cursor_pos = (1, 0)
        self.lcd.write_string(b)

    def close(self) -> None:
        if self.lcd is not None:
            try:
                self.lcd.close(clear=True)
            except Exception:
                pass


def main() -> None:
    display = Display()
    try:
        while True:
            for _name, fn in SCREENS:
                try:
                    l1, l2 = fn()
                except Exception as exc:  # noqa: BLE001 — keep loop alive
                    l1, l2 = "ERR", str(exc)[:COLS]
                display.show(l1, l2)
                time.sleep(HOLD)
    except KeyboardInterrupt:
        pass
    finally:
        display.close()


if __name__ == "__main__":
    main()
