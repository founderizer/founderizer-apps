#!/usr/bin/env python3
"""The app's disk image and the window that it opens on (the owner's yes of 14 November 2026: "Arrow only"): the
Founderizer icon on the left, the Applications folder on the right, the gray arrow of background.png between them,
big icons, and no toolbar, sidebar or status bar. The disk on the desktop wears the app's icon.

    /usr/bin/python3 -I DiskImage/window.py <app bundle> <volume name> <image.dmg>

It is our own code, with the standard library and Apple's own programs alone (hdiutil, ditto, tiffutil, xattr,
diskutil), so it runs on the Command Line Tools' Python 3.9 and needs no package: on 20 November 2026 it took the place
of dmgbuild, ds_store and mac_alias, about 6,400 lines of outside Python (the owner's "Own disk image writer"). It
writes the window's layout (.DS_Store) itself, with no Finder and no screen, so the release job makes the same window
on a locked Mac.

Finder reads the window from the volume's .DS_Store: a buddy allocator ("Bud1") that holds one B-tree ("DSDB") of one
leaf with seven records. The blocks stand where ds_store 1.3.1 put them for these seven records, and test_window.py holds
the file to the bytes that dmgbuild 1.6.5 wrote for this window. The background is named twice, as dmgbuild named it:
as a bookmark (`pBBk`) and as an alias record of version 2 (`backgroundImageAlias`), both in mac_alias 2.2.2's form and
both from the volume's own facts. Apple's NSURL bookmark is not used: it holds the path of the image file behind the
volume, which is in the release Mac's home folder, and it grows with that path past one page of the layout. Both
references name the mount point where a customer's Mac mounts the image, /Volumes/<volume> (CUSTOMER_MOUNT), whatever
the release Mac's own mount point was: with an older image of the same name still attached there, it is
"/Volumes/<volume> 1".
dmgbuild's setting `hide_extension` never took effect (its name for it is `hide_extensions`), so the app's name keeps
Finder's own rule here too.
"""
import os
import plistlib
import shutil
import signal
import struct
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
BACKGROUND = os.path.join(HERE, "background.png")       # 640 x 400; make-background.py writes it and its @2x
BACKGROUND_2X = os.path.join(HERE, "background@2x.png")
ICON = os.path.join(os.path.dirname(HERE), "AppIcon.icns")

# 640 x 400 of content, the size of background.png, under a title bar of 32 points, at (200, 120) of the screen.
WINDOW_BOUNDS = "{{200, 120}, {640, 432}}"
ICON_SIZE = 128.0
TEXT_SIZE = 13.0
# The centres of the two icons, in the content's points: the arrow of background.png runs between them
# (make-background.py draws it there; change both together).
APP_AT = (160, 190)
APPLICATIONS_AT = (480, 190)
BACKGROUND_NAME = ".background.tiff"
PLACEHOLDER = ".layout"             # the .DS_Store's room in the staged folder, renamed once the image is attached

STORE_BYTES = 16388                 # every .DS_Store that store() writes: 4 bytes and 16 KiB of blocks
PAGE = 4096
# The allocator's header after its offsets: what ds_store 1.3.1 writes, and Finder's own files carry too.
HEADER_UNKNOWN = bytes.fromhex("0000100c000000870000200b00000000")
# Blocks as (offset, log2 of the size): the allocator's own at 2048, the tree's head at 32, its one leaf at 8192.
INFO, HEAD, LEAF = (2048, 11), (32, 5), (8192, 13)
MAC_EPOCH = 2082844800              # seconds from 1 January 1904, the Mac's epoch, to 1 January 1970
CF_EPOCH = 978307200                # seconds from 1 January 1970 to 1 January 2001, a bookmark's epoch
CUSTOM_ICON = 0x0400                # kHasCustomIcon of a folder's Finder flags (bytes 8 and 9 of its FinderInfo)
# The waits between the tries of a detach that macOS refuses while the volume is busy (Spotlight, a scan): about five
# minutes in all, near dmgbuild's own, before the force that ends a step that failed.
DETACH_WAITS = (1, 2, 4, 8, 15, 30, 60, 60, 60, 60)
SMALL_WAIT = 120                    # seconds for one call of diskutil, xattr or hdiutil info


class WindowError(Exception):
    """A step of the image that failed: the release then makes a plain image and says so."""


# ------------------------------------------------------------------ the .DS_Store

def plist(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def iloc(point):
    """An icon's place: its centre, then the four bytes of ffff and two of 0 that Finder writes after it."""
    return struct.pack(">II", *point) + bytes.fromhex("ffffffffffff0000")


def window_records(app_name, bookmark, alias):
    """The seven records of the window, as (file name, code, type, value): the window (`bwsp`), the icon view (`icvl`
    and `icvp`, with the background's alias), the background's bookmark (`pBBk`), the version (`vSrn`) and the place of
    each of the two icons (`Iloc`)."""
    bwsp = {"ContainerShowSidebar": False, "PreviewPaneVisibility": False, "ShowPathbar": False, "ShowSidebar": False,
            "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 180,
            "WindowBounds": WINDOW_BOUNDS}
    icvp = {"arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
            "backgroundImageAlias": alias, "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
            "gridSpacing": 100.0, "iconSize": ICON_SIZE, "labelOnBottom": True, "scrollPositionX": 0.0,
            "scrollPositionY": 0.0, "showIconPreview": False, "showItemInfo": False, "textSize": TEXT_SIZE,
            "viewOptionsVersion": 1}
    return [(".", b"bwsp", b"blob", plist(bwsp)), (".", b"icvl", b"type", b"icnv"), (".", b"icvp", b"blob", plist(icvp)),
            (".", b"pBBk", b"blob", bookmark), (".", b"vSrn", b"long", 1),
            ("Applications", b"Iloc", b"blob", iloc(APPLICATIONS_AT)), (app_name, b"Iloc", b"blob", iloc(APP_AT))]


def record_bytes(name, code, kind, value):
    """One record of the tree: the file's name in UTF-16 with its count of units, the code, the type and the value."""
    text = name.encode("utf-16-be")
    head = struct.pack(">I", len(text) // 2) + text + code + kind
    if kind == b"blob":
        return head + struct.pack(">I", len(value)) + value
    if kind == b"long":
        return head + struct.pack(">I", value)
    if kind == b"type":
        return head + value
    raise ValueError(f"no record of the type {kind!r}")


def store(records):
    """The bytes of a .DS_Store that holds these records, sorted as Finder sorts them: by the file's name in lower case,
    then by the code. Every block that holds nothing is on the free list of its size."""
    records = sorted(records, key=lambda one: (one[0].lower(), one[1]))
    leaf = struct.pack(">II", 0, len(records)) + b"".join(record_bytes(*one) for one in records)
    if len(leaf) > PAGE:            # Finder's tree splits a node at the page size that the head names
        raise ValueError("the records do not fit in one leaf")
    head = struct.pack(">IIIII", 2, 0, len(records), 1, PAGE)     # the leaf's block, no level above it, the counts
    blocks = [INFO, HEAD, LEAF]
    info = struct.pack(">II", len(blocks), 0)
    info += struct.pack(">256I", *([offset | width for offset, width in blocks] + [0] * (256 - len(blocks))))
    info += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)       # the table: "DSDB" is block 1
    taken = {width for _offset, width in blocks}
    for width in range(32):         # the buddy free lists: one free block of each size from 2**6 to 2**30
        info += struct.pack(">II", 1, 1 << width) if 6 <= width <= 30 and width not in taken else struct.pack(">I", 0)
    body = bytearray(STORE_BYTES - 4)   # every offset counts from byte 4 of the file
    body[0:32] = b"Bud1" + struct.pack(">III", INFO[0], 1 << INFO[1], INFO[0]) + HEADER_UNKNOWN
    for (offset, width), data in ((HEAD, head), (INFO, info), (LEAF, leaf)):
        assert len(data) <= 1 << width
        body[offset:offset + len(data)] = data
    return struct.pack(">I", 1) + bytes(body)


# ------------------------------------------------------------------ the background's two references

def alias(volume, volume_created, mount, name, cnid, parent, created, type_code=b"\0\0\0\0", creator=b"\0\0\0\0"):
    """The alias record (version 2) of the file `name` at the top of a mounted HFS+ volume, as mac_alias 2.2.2 writes
    it for a file there: the volume's name and creation time, the file's catalog numbers and creation time, then the
    tags of the folder's name, the two exact times, the Carbon path, the two names in UTF-16, the file's path on the
    volume and the volume's mount point. Times are seconds since 1970 (HFS+ keeps whole seconds)."""
    def tag(number, data):
        return struct.pack(">hh", number, len(data)) + data + (b"\0" if len(data) & 1 else b"")

    def utf16(number, text):
        data = text.replace(":", "/").encode("utf-16-be")
        return struct.pack(">hhh", number, len(data) + 2, len(data) // 2) + data

    voldate, crdate = int(volume_created) + MAC_EPOCH, int(created) + MAC_EPOCH
    carbon = volume.replace(":", "/").encode()
    out = struct.pack(">h28pI2shI64pII4s4shhI2s10s", 0, carbon, voldate, b"H+", 0, parent,
                      name.replace(":", "/").encode(), cnid, crdate, creator, type_code, -1, -1, 0, b"\0\0", b"\0" * 10)
    out += tag(0, os.path.basename(mount).replace(":", "/").encode())
    out += struct.pack(">hhQhhQ", 16, 8, voldate * 65536, 17, 8, crdate * 65536)
    out += tag(2, carbon + b":" + name.replace(":", "/").encode())
    out += utf16(14, name) + utf16(15, volume)
    out += tag(18, ("/" + name).encode()) + tag(19, mount.encode())
    out += struct.pack(">hh", -1, 0)
    return b"\0\0\0\0" + struct.pack(">hh", len(out) + 8, 2) + out


CUSTOMER_MOUNT = "/Volumes"         # where a customer's Mac mounts the image: the folder of the volume's own name


def alias_of(path, volume, mount):
    """The alias record of a file at the top of the volume mounted at `mount`, from what the file system says of it,
    for the volume as a customer's Mac mounts it (CUSTOMER_MOUNT)."""
    here, top = os.stat(path), os.stat(mount)
    finder = finder_info(path)
    return alias(volume, top.st_birthtime, os.path.join(CUSTOMER_MOUNT, volume), os.path.basename(path), here.st_ino,
                 top.st_ino, here.st_birthtime,
                 finder[0:4], finder[4:8])


class Date(float):
    """A time in a bookmark: seconds since 1 January 2001."""


class Url(str):
    """An absolute URL in a bookmark."""


def bookmark_item(value, offset):
    """(the offset after it, its bytes) of one value at `offset` of a bookmark's data, in CFURL's own format as
    mac_alias 2.2.2 writes it: a length, a type, the value, and zeros to a multiple of 4 bytes."""
    if value is True or value is False:
        out = struct.pack("<II", 0, 0x0501 if value else 0x0500)
    elif isinstance(value, Url):
        data = value.encode("utf-8")
        out = struct.pack("<II", len(data), 0x0901) + data
    elif isinstance(value, str):
        data = value.encode("utf-8")
        out = struct.pack("<II", len(data), 0x0101) + data
    elif isinstance(value, bytes):
        out = struct.pack("<II", len(value), 0x0201) + value
    elif isinstance(value, Date):
        out = struct.pack("<II", 8, 0x0400) + struct.pack(">d", value)
    elif isinstance(value, int):
        out = struct.pack("<IIi", 4, 0x0303, value) if -0x80000000 < value < 0x7FFFFFFF else \
            struct.pack("<IIq", 8, 0x0304, value)
    elif isinstance(value, list):
        at, heads, parts = offset + 8 + 4 * len(value), [], []
        for one in value:
            heads.append(struct.pack("<I", at))
            at, data = bookmark_item(one, at)
            parts.append(data)
        out = struct.pack("<II", 4 * len(value), 0x0601) + b"".join(heads + parts)
    else:
        raise ValueError(f"no bookmark item of {type(value).__name__}")
    out += b"\0" * (-(offset + len(out)) % 4)
    return offset + len(out), out


def bookmark(volume, volume_uuid, volume_size, volume_created, mount, name, cnid, created):
    """The bookmark of the file `name` at the top of a mounted HFS+ volume, as mac_alias 2.2.2's Bookmark.for_file
    writes it for such a file: one table of the file's path, catalog number, time and kind, and of the volume's path,
    URL, name, size, time, UUID and kind, with the user "unknown" (uid 99). Times are seconds since 1970."""
    table = [(0x1004, [name]), (0x1005, [cnid]), (0x1040, Date(created - CF_EPOCH)),
             (0x1010, struct.pack("<QQQ", 0x1, 0x0F, 0)), (0xC001, -1), (0x2002, mount), (0x2030, mount == "/"),
             (0x2005, Url("file://" + mount)), (0x2010, volume), (0x2012, volume_size),
             (0x2013, Date(volume_created - CF_EPOCH)), (0x2011, volume_uuid.upper()),
             (0x2020, struct.pack("<QQQ", 0x81 | 0x100000000, 0x13EF | 0x100000000, 0)), (0xD010, 512),
             (0xD001, True), (0xC011, "unknown"), (0xC012, 99)]
    offset, data, entries = 4, [], []
    for key, value in table:
        entries.append((key, offset))
        offset, part = bookmark_item(value, offset)
        data.append(part)
    entries.sort()
    toc = b"".join(struct.pack("<III", key, at, 0) for key, at in entries)
    data.append(struct.pack("<IIIII", len(toc) - 8, 0xFFFFFFFE, 1, 0, len(entries)) + toc)
    size = offset + 20 + len(toc)
    return struct.pack("<4sIIIQQQQI", b"book", size + 48, 0x10040000, 48, 0, 0, 0, 0, offset) + b"".join(data)


def bookmark_of(path, volume, mount):
    """The bookmark of a file at the top of the volume mounted at `mount`, from what the file system says of it: the
    volume's UUID from diskutil, its size from statvfs (as getattrlist's ATTR_VOL_SIZE gives it), and the times and the
    catalog number of the file; for the volume as a customer's Mac mounts it (CUSTOMER_MOUNT)."""
    try:
        said = plistlib.loads(run(["/usr/sbin/diskutil", "info", "-plist", mount], timeout=SMALL_WAIT))
    except WindowError:
        raise
    except Exception:
        raise WindowError(f"diskutil said nothing that could be read about the volume at {mount}") from None
    uuid = said.get("VolumeUUID") if isinstance(said, dict) else None
    if not isinstance(uuid, str) or not uuid:
        raise WindowError(f"diskutil gives no UUID of the volume at {mount}")
    space, here, top = os.statvfs(mount), os.stat(path), os.stat(mount)
    return bookmark(volume, uuid, space.f_blocks * space.f_frsize, top.st_birthtime,
                    os.path.join(CUSTOMER_MOUNT, volume), os.path.basename(path),
                    here.st_ino, here.st_birthtime)


# ------------------------------------------------------------------ the image

def run(command, **options):
    try:
        done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                              **options)
    except subprocess.TimeoutExpired:
        raise WindowError(f"{os.path.basename(command[0])} {command[1]} did not end in time") from None
    if done.returncode != 0:
        said = done.stderr.decode(errors="replace").strip().splitlines()
        raise WindowError(f"{os.path.basename(command[0])} {command[1]} failed: {(said or ['no word'])[-1]}")
    return done.stdout


def finder_info(path):
    """The 32 bytes of a file's FinderInfo, zeros when it has none."""
    try:
        done = subprocess.run(["/usr/bin/xattr", "-px", "com.apple.FinderInfo", path], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=SMALL_WAIT)
    except subprocess.TimeoutExpired:
        raise WindowError(f"xattr did not read the Finder flags of {path} in time") from None
    data = bytes.fromhex(done.stdout.decode().replace(" ", "").replace("\n", "")) if done.returncode == 0 else b""
    return data.ljust(32, b"\0")[:32]


def mark_custom_icon(path):
    """Set the custom-icon flag of a folder (the volume's top, which then wears .VolumeIcon.icns)."""
    data = bytearray(finder_info(path))
    data[8:10] = struct.pack(">H", struct.unpack(">H", bytes(data[8:10]))[0] | CUSTOM_ICON)
    run(["/usr/bin/xattr", "-wx", "com.apple.FinderInfo", bytes(data).hex(), path], timeout=SMALL_WAIT)


def attach(image):
    """(device, mount point) of the image, attached read-write out of Finder's sight. An attach that gives no mount
    point, or an answer that cannot be read, is detached again before the step fails."""
    said = run(["/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-noautoopen", image])
    try:
        entities = plistlib.loads(said).get("system-entities", [])
    except Exception:
        for device in devices_of(image):
            force_detach(device)
        raise WindowError("hdiutil said nothing that could be read about the attached image") from None
    for entity in entities:
        if entity.get("mount-point"):
            return entity["dev-entry"], unicodedata.normalize("NFC", entity["mount-point"])
    force_detach(whole_disk(entities))
    raise WindowError("hdiutil attached the image at no mount point")


def whole_disk(entities):
    """The device of the whole disk among an attached image's entities (/dev/diskN, not one of its slices): its one
    detach takes the whole image away, and a second detach of a slice could name a disk that another image took."""
    devices = [entity.get("dev-entry") or "" for entity in entities]
    return next((device for device in devices if re.fullmatch(r"/dev/disk[0-9]+", device)),
                next((device for device in devices if device), None))


def devices_of(image):
    """The whole disk of every attached image whose file is `image`, as `hdiutil info` lists them."""
    try:
        listed = plistlib.loads(run(["/usr/bin/hdiutil", "info", "-plist"], timeout=SMALL_WAIT))
    except Exception:
        return []
    return [device for device in (whole_disk(attached.get("system-entities", [])) for attached in
                                  listed.get("images", [])
                                  if os.path.realpath(attached.get("image-path", "")) == os.path.realpath(image))
            if device]


def detach(device):
    """True once the image detached; False when macOS kept it busy through every wait of DETACH_WAITS."""
    for wait in DETACH_WAITS + (None,):
        if subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", device], stdin=subprocess.DEVNULL).returncode == 0:
            return True
        if wait is not None:
            time.sleep(wait)
    return False


def force_detach(device):
    if device:
        subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", "-force", device], stdin=subprocess.DEVNULL)


def make(bundle, volume, image):
    """The compressed image of the app with its window. The app goes in with ditto, which keeps its signature; the
    window's files go in first, and the layout as a placeholder of its final size under another name (`hdiutil create
    -srcfolder` leaves every .DS_Store out), which the attached volume renames and fills: so writing the layout needs
    no new block of a volume that hdiutil made just big enough."""
    bundle = os.path.abspath(bundle.rstrip("/"))
    if not os.path.isdir(bundle):
        raise WindowError(f"no app bundle at {bundle}")
    for path in (BACKGROUND, BACKGROUND_2X, ICON):
        if not os.path.isfile(path):
            raise WindowError(f"{path} is missing")
    work = tempfile.mkdtemp(prefix="window.", dir=os.path.dirname(os.path.abspath(image)))
    writable = os.path.join(work, "writable.dmg")
    try:
        stage = os.path.join(work, "stage")
        os.mkdir(stage)
        run(["/usr/bin/ditto", bundle, os.path.join(stage, os.path.basename(bundle))])
        os.symlink("/Applications", os.path.join(stage, "Applications"))
        run(["/usr/bin/tiffutil", "-cathidpicheck", BACKGROUND, BACKGROUND_2X, "-out",
             os.path.join(stage, BACKGROUND_NAME)])
        shutil.copyfile(ICON, os.path.join(stage, ".VolumeIcon.icns"))
        with open(os.path.join(stage, PLACEHOLDER), "wb") as f:
            f.write(b"\0" * STORE_BYTES)
        run(["/usr/bin/hdiutil", "create", "-quiet", "-ov", "-srcfolder", stage, "-volname", volume, "-fs", "HFS+",
             "-format", "UDRW", writable])
        device, mount = attach(writable)
        detached = False
        try:
            background = os.path.join(mount, BACKGROUND_NAME)
            layout = store(window_records(os.path.basename(bundle), bookmark_of(background, volume, mount),
                                          alias_of(background, volume, mount)))
            os.rename(os.path.join(mount, PLACEHOLDER), os.path.join(mount, ".DS_Store"))
            with open(os.path.join(mount, ".DS_Store"), "r+b") as f:
                f.write(layout)
                f.truncate()
            mark_custom_icon(mount)
            shutil.rmtree(os.path.join(mount, ".Trashes"), ignore_errors=True)
            os.sync()
            detached = detach(device)
            if not detached:
                raise WindowError(f"{device} stayed busy and did not detach cleanly")
        finally:
            if not detached:        # every failure, a signal included (main): the volume never stays attached
                force_detach(device)
        final = os.path.join(work, "final.dmg")    # a convert that fails half way leaves nothing at `image`
        run(["/usr/bin/hdiutil", "convert", "-quiet", writable, "-format", "UDZO", "-o", final])
        os.replace(final, image)
    finally:                        # whatever stopped the run, a signal during the attach itself included
        for device in devices_of(writable):
            force_detach(device)
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if len(argv) != 4:
        print("usage: window.py <app bundle> <volume name> <image.dmg>", file=sys.stderr)
        return 2
    for number in (signal.SIGTERM, signal.SIGHUP):     # launchd's stop runs the cleanups of make() too
        if signal.getsignal(number) is not signal.SIG_IGN:     # a signal that the caller ignores (nohup) stays so
            signal.signal(number, lambda got, frame: sys.exit(128 + got))
    try:
        make(argv[1], argv[2], argv[3])
    except (WindowError, OSError) as e:
        print(f"window.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
