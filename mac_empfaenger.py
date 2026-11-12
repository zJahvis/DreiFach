#!/usr/bin/env python3
"""Empfängt Fotos und Videos der DreiFach-App und speichert sie in ~/Pictures/DreiFach.

Start im Terminal:  python3 mac_empfaenger.py
Beenden:            Ctrl+C

GitHub (optional): Ist ~/Pictures/DreiFach ein Git-Repository mit GitHub als
"origin", wird jede neue Datei automatisch committet und gepusht.
Achtung: GitHub nimmt keine Dateien über 100 MB an (lange Videos!).
"""
import os
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 8765
ZIEL = os.path.expanduser("~/Pictures/DreiFach")
GITHUB_MAX = 100 * 1024 * 1024
git_lock = threading.Lock()


def git(*args):
    return subprocess.run(["git", "-C", ZIEL, *args], capture_output=True, text=True)


def nach_github(name, size):
    if not os.path.isdir(os.path.join(ZIEL, ".git")):
        return
    if size >= GITHUB_MAX:
        print(f"  GitHub: {name} ist über 100 MB und bleibt nur auf dem Mac.")
        return
    with git_lock:
        git("add", "--", name)
        if git("commit", "-m", f"Neu: {name}").returncode != 0:
            return
        r = git("push")
        if r.returncode == 0:
            print(f"  GitHub: {name} hochgeladen")
        else:
            print(f"  GitHub: Push fehlgeschlagen – {r.stderr.strip().splitlines()[-1:]}")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        url = urlparse(self.path)
        name = os.path.basename(parse_qs(url.query).get("name", ["datei"])[0])
        length = int(self.headers.get("Content-Length", 0))
        if url.path != "/upload" or not name or name.startswith(".") or length <= 0:
            self.send_response(400)
            self.end_headers()
            return
        rest = length
        with open(os.path.join(ZIEL, name), "wb") as f:
            while rest > 0:
                chunk = self.rfile.read(min(rest, 1 << 20))
                if not chunk:
                    break
                f.write(chunk)
                rest -= len(chunk)
        if rest:
            os.remove(os.path.join(ZIEL, name))
            print(f"Abgebrochen: {name}")
            return
        print(f"Gespeichert: {name} ({length / 1e6:.1f} MB)")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
        nach_github(name, length)

    def log_message(self, *args):
        pass


def lokale_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.0.1", 9))  # sendet nichts, ermittelt nur die eigene Adresse
        return s.getsockname()[0]
    except OSError:
        return "unbekannt"
    finally:
        s.close()


if __name__ == "__main__":
    os.makedirs(ZIEL, exist_ok=True)
    # Bonjour-Name des Macs; gethostname() liefert je nach Router etwas wie "Mac.speedport.ip"
    r = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True)
    name = r.stdout.strip() or socket.gethostname().split(".")[0]
    name += ".local"
    print(f"Fotos und Videos landen in: {ZIEL}")
    if os.path.isdir(os.path.join(ZIEL, ".git")):
        print("Git-Repository erkannt: neue Dateien werden auch zu GitHub gepusht.")
    print("In der App unter 'Adresse des Macs' eintragen:")
    print(f"    {name}")
    print(f"  oder, falls das nicht klappt:  {lokale_ip()}")
    print("Warte auf Dateien … (Beenden mit Ctrl+C)")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
