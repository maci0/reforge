#!/usr/bin/env python3
"""fake-camera.py - mjpg_streamer-compatible MJPEG server for the qemu harness,
so Mainsail's webcam panel shows an image with no real camera.

Robust: if Pillow imports (and works) it renders an ANIMATED test pattern with a
moving marker + clock; otherwise it falls back to a baked STATIC JPEG embedded
below, so the camera always serves something even if the guest PIL is broken.

Endpoints (mjpg_streamer shape):
    GET /?action=stream     -> multipart/x-mixed-replace MJPEG
    GET /?action=snapshot   -> a single JPEG
Listens on 0.0.0.0:PORT (env PORT, default 8081).
"""

import base64
import io
import os
import time
import http.server
import socketserver

_STATIC_JPEG = base64.b64decode("".join((
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAkGBwgHBgkIBwgKCgkLDRYPDQwMDRsUFRAWIB0iIiAd"
    "Hx8kKDQsJCYxJx8fLT0tMTU3Ojo6Iys/RD84QzQ5Ojf/2wBDAQoKCg0MDRoPDxo3JR8lNzc3Nzc3"
    "Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzf/wAARCAHgAoADASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDkaKKK"
    "+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKAC"
    "iiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAK"
    "KKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKA"
    "CiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAK"
    "KKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5"
    "Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQo"
    "oooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAK"
    "KKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv"
    "4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAo"
    "oooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigD"
    "tqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UK"
    "KKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAo"
    "oooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+P"
    "KKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAo"
    "oooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAo"
    "oooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivz"
    "w/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAo"
    "oooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq"
    "+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68Ci"
    "iigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKAC"
    "iiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6"
    "pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACi"
    "iigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAoo"
    "ooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCi"
    "iigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACi"
    "iigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3O"
    "iiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACi"
    "iigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKK"
    "KKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+h"
    "P68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAK"
    "KKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxO"
    "iiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKK"
    "KKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACii"
    "igAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+e"
    "P5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKK"
    "KKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACii"
    "igD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKK"
    "KKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAoo"
    "ooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPq"
    "KKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAo"
    "oooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACii"
    "igDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6I"
    "PwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKK"
    "KACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+dP2YKKKKACiiigAooooAKKKKAPQq"
    "KKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACiiigAooooAKKKKAPq+iiiv4zPogoo"
    "ooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKKKAPPqKKK+hP68CiiigAooooAKKK"
    "KACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACiiigAooooAKKKKACiiigDtqKKK+d"
    "P2YKKKKACiiigAooooAKKKKAPQqKKK+eP5DCiiigAooooAKKKKACiiigDxOiiiv6pP0UKKKKACii"
    "igAooooAKKKKAPq+iiiv4zPogooooAKKKKACiiigAooooA5Wiiiv6IPwgKKKKACiiigAooooAKKK"
    "KAPPqKKK+hP68CiiigAooooAKKKKACiiigD3Oiiivzw/KQooooAKKKKACiiigAooooA+PKKKKACi"
    "iigAooooAKKKKACiiigDZooorQkKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK"
    "KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoo"
    "ooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiii"
    "gAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKA"
    "CiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK"
    "KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoo"
    "ooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAorq/Dul2d1pdnL"
    "cWdtKJb2eO4le4KSpEiRN+7QONzDc5wFbnAp0HhaC11rTra7uobjdqUNpdW6yJn5mw2NjlscEEkK"
    "eR+BcDkqK6CXTYJY5Li8Fpp9vC0cZNg/2rcz7tuf3pxwjHr6cHNSXXhiOyBF5fMrxQyzXKxwbvLV"
    "J2g+U7huJcD04PtyAc3RXVf8IhH5i51SJIZTGIJZQke4tFHJ8wZwQAJVHy7j7VneH4LGZZ/ta27X"
    "G5BCl1I8cTDncNykYb7uNxxjdntQBjUV29n4e095nt57N45m0yQoskh3JcG9aBC2DjgbQR04ziqM"
    "uh2j2fhu3RfKu726aG6m3E8MIWTgnAwso6UrgctRWxKltqTLb2GmG2mN0kMTK7sCGyAHLE/NkDpg"
    "fe4ro08PaVNqN2sUMbW8tgfsnl3PmBJ/PSFWLKxBJ3KxBOBv6DjDuBwlFb+t6da2Xh7R5Y4tt5K8"
    "ouX3E7vlikQY6DCyjpVi/wBAtfP1MpcsgsJ3gMUMPmNtjABkb5gQG5wcEZzkqOaLgcxRXV634Ytb"
    "WTVpra6mW3s53AjeEZ8sTCI4Jb5iC3YYIHJB4Bq3huzguNQkguHjsbO8uonJi3SBY2iUcbsN80wH"
    "bgZPXALgcpRWtqtnbQ6bZ3FpKJVaaaDzApXzAoRgxB6HEuD/ALvfrWTQAUUUUAFFFFABRRRQAUUU"
    "UAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQ"
    "AUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFAF"
    "u31K7thbCGXaLWdp4RtB2udoJ5HP3F4PHHuasNr+ptLbym4Akt5lnRhEgJkX7rNx85Hq2e/qazKK"
    "ALdhqN1p5c2rqA+NyvGsikg5BwwIyOx6irljr08Nyst7uulWB4QpKg7Wcuc7lYN8zMfmB6+wxkUU"
    "Abd54n1Ce8mngdYVfZtUormPagQFSV+VtqjJXH4cVn2OpXVisiW7pskILJLEkikjODhgRkZPPXk1"
    "UooA0G1rUmyWumLGPyixA3FfN87rjOfM+bPXt04pl7q19ftuupyxE7zghQuHYKCRgDHCLx0GOMVS"
    "ooA05de1KWRJGnQOrmTKQom5yMbmwBubk8nJ5qG21W+tbRrWCcpCxJKhRnJZGODjI5ijP/AfrVKi"
    "gC5qGqXuo5+2TeZmZ5vuKvzuFDHgeiKMdBjirEmvag6yqJEUTAhyIlLZZAjkMQSpYD5sEZrLooA1"
    "rzxHqt7DPDc3COs42yEQRhmG8SEbgucbxu69cnuaR/EOqSStK9wjM7ySODBGVdnChyy7cHOxTyOo"
    "z15rKooAuahqVzqAj+1MG8vceBjJJyTjp6DjAwoHaqdFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFF"
    "FABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUU"
    "AFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQA"
    "UUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABR"
    "RRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFAH/2Q=="
)))

try:
    if os.environ.get("FORCE_STATIC"):
        raise ImportError("FORCE_STATIC")  # skip the heavy PIL import in-guest
    from PIL import Image, ImageDraw
    _W, _H = 640, 480
    _BARS = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
             (0, 255, 255), (255, 0, 255), (235, 235, 235), (15, 15, 15)]

    def _render(n):
        img = Image.new("RGB", (_W, _H), (18, 22, 28))
        d = ImageDraw.Draw(img)
        bw = _W // len(_BARS)
        for i, c in enumerate(_BARS):
            d.rectangle([i * bw, 0, (i + 1) * bw, _H // 2], fill=c)
        x = (n * 12) % _W
        d.rectangle([x, _H // 2, x + 48, _H], fill=(255, 140, 0))
        d.text((12, _H - 26),
               "ReForge SIM CAM  frame %d  %s" % (n, time.strftime("%H:%M:%S")),
               fill=(255, 255, 255))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=70)
        return buf.getvalue()

    # Prove PIL actually works (encode path) at startup; else fall back.
    _render(0)
    _HAVE_PIL = True
except Exception:
    _HAVE_PIL = False


def make_frame(n):
    if _HAVE_PIL:
        try:
            return _render(n)
        except Exception:
            pass
    return _STATIC_JPEG


PORT = int(os.environ.get("PORT", "8081"))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if "snapshot" in self.path:
            f = make_frame(int(time.time()))
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(f)))
            self.end_headers()
            self.wfile.write(f)
            return
        self.send_response(200)
        self.send_header("Age", "0")
        self.send_header("Cache-Control", "no-cache, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Type",
                         "multipart/x-mixed-replace; boundary=frame")
        self.end_headers()
        n = 0
        try:
            while True:
                f = make_frame(n)
                n += 1
                self.wfile.write(b"--frame\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(b"Content-Length: %d\r\n\r\n" % len(f))
                self.wfile.write(f)
                self.wfile.write(b"\r\n")
                time.sleep(0.4)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    Server(("0.0.0.0", PORT), Handler).serve_forever()
