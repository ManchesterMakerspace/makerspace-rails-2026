"""One HDMI connector, two XRGB scanout buffers, and real KMS power control."""
import logging
import mmap
from pathlib import Path

from PIL import Image


LOG = logging.getLogger(__name__)
TRANSPOSE = {90: Image.Transpose.ROTATE_90, 180: Image.Transpose.ROTATE_180,
             270: Image.Transpose.ROTATE_270}


def orientation(setting, connector_name, panel, plane, cmdline, console):
    if setting != "auto":
        return {"normal": 0, "left": 90, "right": 270}[setting]
    # Linux DRM uses counterclockwise angles and adds the connector's boot
    # setting to its mounting property. fbcon, in contrast, counts clockwise.
    panel_angle = {0: 0, 1: 180, 2: 90, 3: 270}.get(panel, 0)
    for arg in cmdline.split():
        prefix = f"video={connector_name}:"
        if arg.startswith(prefix):
            for option in arg[len(prefix):].split(","):
                if option in ("rotate=0", "rotate=90", "rotate=180", "rotate=270"):
                    return (panel_angle + int(option.split("=")[1])) % 360
    if plane & 14:
        return {2: 90, 4: 180, 8: 270}.get(plane & 15, 0)
    return panel_angle or {"1": 270, "2": 180, "3": 90}.get(console, 0)


def read_text(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


class Output:
    def __init__(self, kms, card_path, name, setting):
        self.kms = kms
        self.card = kms.Card(card_path)
        self.conn = next((c for c in self.card.connectors if c.fullname == name and c.connected()), None)
        if self.conn is None:
            raise OSError("HDMI connector unavailable")
        active = self.conn.get_current_crtc()
        self.crtc = active or self.conn.get_possible_crtcs()[0]
        mode = active.mode if active else None
        if not mode or not mode.hdisplay or not mode.vdisplay:
            # DRM_MODE_TYPE_PREFERRED is bit 3. Older panels may mark no mode.
            mode = next((m for m in self.conn.get_modes() if m.type & 8), self.conn.get_default_mode())
        if not mode.hdisplay or not mode.vdisplay:
            raise OSError("HDMI has no usable mode")
        self.blob = mode.to_blob(self.card)
        self.plane = next(p for p in self.card.planes if p.supports_crtc(self.crtc)
                          and p.get_prop_value("type") == 1)
        panel = self.conn.get_prop_value("panel orientation") if self.conn.has_prop("panel orientation") else None
        self.has_rotation = self.plane.has_prop("rotation")
        plane_rotation = self.plane.get_prop_value("rotation") if self.has_rotation else 1
        self.angle = orientation(setting, name, panel, plane_rotation, read_text("/proc/cmdline"),
                                 read_text("/sys/class/graphics/fbcon/rotate"))
        w, h = mode.hdisplay, mode.vdisplay
        self.size = (h, w) if self.angle in (90, 270) else (w, h)
        self.frames = [kms.DumbFramebuffer(self.card, w, h, "XR24") for _ in range(2)]
        self.maps = [mmap.mmap(fb.fd(0), fb.stride(0) * h, access=mmap.ACCESS_WRITE) for fb in self.frames]
        self.back = 0
        self.active = False
        LOG.info("HDMI %s: %dx%d, rotation %d degrees CCW", name, w, h, self.angle)

    def present(self, image):
        if self.angle:
            image = image.transpose(TRANSPOSE[self.angle])
        fb = self.frames[self.back]
        self.maps[self.back][:] = image.tobytes("raw", "BGRX", fb.stride(0), 1)
        req = self.kms.AtomicReq(self.card)
        if not self.active:
            req.add(self.conn, "CRTC_ID", self.crtc.id)
            req.add(self.crtc, {"MODE_ID": self.blob.id, "ACTIVE": 1})
        req.add_plane(self.plane, fb, self.crtc)
        if self.has_rotation:
            req.add(self.plane, "rotation", 1)  # Pillow owns the transform.
        if req.commit_sync(allow_modeset=not self.active):
            raise OSError("Cannot present HDMI frame")
        self.active = True
        self.back = 1 - self.back

    def standby(self):
        req = self.kms.AtomicReq(self.card)
        req.add(self.plane, {"FB_ID": 0, "CRTC_ID": 0})
        req.add(self.conn, "CRTC_ID", 0)
        req.add(self.crtc, {"ACTIVE": 0, "MODE_ID": 0})
        if req.commit_sync(allow_modeset=True):
            raise OSError("Cannot disable HDMI output")
        self.active = False

    def close(self):
        for mapping in self.maps:
            mapping.close()


class Display:
    def __init__(self, setting):
        import pykms
        self.kms = pykms
        self.setting = setting
        self.output = self.port = None
        self.lost_signal = False
        self.next_probe = 0

    def probe(self, at):
        if at < self.next_probe:
            return False
        self.next_probe = at + 2
        paths = sorted(Path("/sys/class/drm").glob("card*-HDMI-*/status"))
        port = next((p.parent.name for p in paths if read_text(p) == "connected"), None)
        if port is None and self.output and (not self.output.active or self.lost_signal):
            # Some monitors deassert hotplug detect in standby. Retain the
            # mode and connector so the first fresh frame can restore signal.
            self.lost_signal = True
            return False
        if self.port == port and not self.lost_signal:
            return False
        self.close()
        if port:
            device, name = port.split("-", 1)
            self.output = Output(self.kms, "/dev/dri/" + device, name, self.setting)
            self.port = port
        return True

    def close(self):
        if self.output:
            self.output.close()
        self.output = self.port = None
        self.lost_signal = False
