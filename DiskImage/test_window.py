"""The window of the app's disk image, which window.py writes in place of dmgbuild (20 November 2026): the layout file
that Finder reads, the background's two references, and one real image.

    cd app/DiskImage && python3 -B -m unittest test_window
"""
import base64
import hashlib
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

import window

# What dmgbuild 1.6.5 wrote for this window on 20 November 2026 (an image of a test bundle, with DiskImage/settings.py
# of that day): the SHA-256 of its whole .DS_Store, and the two references to the background inside it, which name
# that image's own volume and so differ in each image.
DMGBUILD_STORE = "90adc506cfbc3d59e6c4bb95b19c4124d6e7265102b8f303072baab4eef29f33"
DMGBUILD_BOOKMARK = bytes.fromhex(
    "626f6f6b80020000000004103000000000000000000000000000000000000000000000000000000000000000000000007001000004000000"
    "010600001000000010000000010100002e6261636b67726f756e642e74696666040000000106000034000000040000000303000013000000"
    "080000000004000041c85833c2000000180000000102000001000000000000000f0000000000000000000000000000000400000003030000"
    "ffffffff14000000010100002f566f6c756d65732f466f756e646572697a657200000000000500001b0000000109000066696c653a2f2f2f"
    "566f6c756d65732f466f756e646572697a6572000b00000001010000466f756e646572697a657200040000000303000000b0300808000000"
    "0004000041c85833c1800000240000000101000037373046414239302d413042452d334246392d383646442d463036363343444244323235"
    "18000000010200008100000001000000ef130000010000000000000000000000040000000303000000020000000000000105000007000000"
    "01010000756e6b6e6f776e00040000000303000063000000c4000000feffffff010000000000000011000000041000000400000000000000"
    "051000002800000000000000101000005000000000000000401000004000000000000000022000007c0000000000000005200000a0000000"
    "0000000010200000c40000000000000011200000f40000000000000012200000d80000000000000013200000e40000000000000020200000"
    "200100000000000030200000980000000000000001c00000700000000000000011c00000540100000000000012c000006401000000000000"
    "01d000004c0100000000000010d000004001000000000000")
DMGBUILD_ALIAS = bytes.fromhex(
    "000000000152000200000b466f756e646572697a657200000000000000000000000000000000e725e083482b000000000002102e6261636b"
    "67726f756e642e74696666000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000013e725e0840000000000000000ffffffff000000000000000000000000000000000000000b466f756e646572697a6572000010"
    "00080000e725e0830000001100080000e725e08400000002001c466f756e646572697a65723a2e6261636b67726f756e642e74696666000e"
    "00220010002e006200610063006b00670072006f0075006e0064002e0074006900660066000f0018000b0046006f0075006e006400650072"
    "0069007a00650072001200112f2e6261636b67726f756e642e7469666600001300142f566f6c756d65732f466f756e646572697a6572ffff"
    "0000")


def tiff_pages(data):
    """How many pictures a TIFF file holds: the length of its chain of image directories."""
    order = "<" if data[:2] == b"II" else ">"
    pages, at = 0, struct.unpack(order + "I", data[4:8])[0]
    while at and pages < 16:
        count = struct.unpack(order + "H", data[at:at + 2])[0]
        at = struct.unpack(order + "I", data[at + 2 + 12 * count:at + 6 + 12 * count])[0]
        pages += 1
    return pages


def attached_from(folder):
    """The files of the attached images that lie in `folder`, as `hdiutil info` lists them."""
    listed = plistlib.loads(subprocess.run(["/usr/bin/hdiutil", "info", "-plist"], capture_output=True,
                                           check=True).stdout)
    inside = os.path.realpath(folder) + os.sep
    return [image["image-path"] for image in listed.get("images", [])
            if os.path.realpath(image.get("image-path", "")).startswith(inside)]


def bookmark_items(data):
    """{key: (type, payload)} of the one table of a bookmark, as CFURL's format lays it out (a reader for the test)."""
    data_at, toc_at = 48, 48 + struct.unpack("<I", data[48:52])[0]
    count = struct.unpack("<I", data[toc_at + 16:toc_at + 20])[0]
    items = {}
    for n in range(count):
        key, offset, _ = struct.unpack("<III", data[toc_at + 20 + 12 * n:toc_at + 32 + 12 * n])
        size, kind = struct.unpack("<II", data[data_at + offset:data_at + offset + 8])
        items[key] = (kind, data[data_at + offset + 8:data_at + offset + 8 + size])
    return items


def blob(store, code):
    """The value of the one blob record of `code` in the folder's own records of a .DS_Store."""
    at = store.index(code + b"blob")
    size = struct.unpack(">I", store[at + 8:at + 12])[0]
    return store[at + 12:at + 12 + size]


class Layout(unittest.TestCase):
    def test_the_window_is_byte_for_byte_the_one_that_dmgbuild_wrote(self):
        """The customer's install window: the two icons' places, their size, no toolbar or sidebar, the background,
        and the file's own blocks that Finder reads. A changed number or order here changes what every customer sees."""
        layout = window.store(window.window_records("Founderizer.app", DMGBUILD_BOOKMARK, DMGBUILD_ALIAS))
        self.assertEqual(len(layout), window.STORE_BYTES)
        self.assertEqual(hashlib.sha256(layout).hexdigest(), DMGBUILD_STORE)

    def test_the_bookmark_of_the_background_is_the_one_that_mac_alias_wrote(self):
        """Finder's newer reference to the background: the volume's path, URL, name, UUID, size and time, the file's
        name, catalog number and time, and no other path."""
        made = window.bookmark("Founderizer", "770fab90-a0be-3bf9-86fd-f0663cdbd225", 137408512, 1795174403,
                               "/Volumes/Founderizer", ".background.tiff", 19, 1795174404)
        self.assertEqual(made, DMGBUILD_BOOKMARK)

    def test_the_alias_of_the_background_is_the_one_that_mac_alias_wrote(self):
        """Finder's older reference to the background: the volume, the file's catalog numbers and times, its paths."""
        made = window.alias("Founderizer", 1795174403, "/Volumes/Founderizer", ".background.tiff", 19, 2, 1795174404)
        self.assertEqual(made, DMGBUILD_ALIAS)


@unittest.skipUnless(sys.platform == "darwin" and os.path.exists("/usr/bin/hdiutil"), "macOS makes disk images")
class RealImage(unittest.TestCase):
    def test_an_image_carries_the_window_for_its_own_volume(self):
        """What release.sh ships: the app, the Applications link, the background, the volume's icon and its flag, and a
        layout whose two references name this image's own background, which macOS resolves."""
        work = tempfile.mkdtemp(prefix="window-test.")
        self.addCleanup(shutil.rmtree, work, True)
        bundle = os.path.join(work, "Founderizer.app")
        os.makedirs(os.path.join(bundle, "Contents"))
        with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleName": "Founderizer"}, f)
        image = os.path.join(work, "Founderizer-test.dmg")
        window.make(bundle, "Founderizer Test", image)
        self.assertEqual(sorted(os.listdir(work)), ["Founderizer-test.dmg", "Founderizer.app"])    # no window.* left
        self.assertEqual(attached_from(work), [])                                               # nothing attached
        # Attached where hdiutil chooses (under /Volumes), as window.attach does: macOS refuses a mount point in a
        # folder of ship's disk in memory ("Permission denied"), where this test's files are during a ship run.
        self.addCleanup(lambda: [window.force_detach(device) for device in window.devices_of(image)])
        said = plistlib.loads(subprocess.run(["/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-readonly",
                                              "-noautoopen", image], check=True, capture_output=True,
                                             stdin=subprocess.DEVNULL).stdout)
        self.addCleanup(subprocess.run, ["/usr/bin/hdiutil", "detach", "-quiet", "-force",
                                         window.whole_disk(said["system-entities"])], stdin=subprocess.DEVNULL)
        mount = next(entity["mount-point"] for entity in said["system-entities"] if entity.get("mount-point"))
        self.assertEqual(len(attached_from(work)), 1)          # the path match finds a real attachment, so the
        self.assertEqual(len(window.devices_of(image)), 1)     # checks of none above, and window's sweep, mean it
        self.assertEqual(os.readlink(os.path.join(mount, "Applications")), "/Applications")
        self.assertTrue(os.path.isfile(os.path.join(mount, "Founderizer.app", "Contents", "Info.plist")))
        with open(os.path.join(mount, ".VolumeIcon.icns"), "rb") as f, open(window.ICON, "rb") as icon:
            self.assertEqual(f.read(), icon.read())
        self.assertTrue(struct.unpack(">H", window.finder_info(mount)[8:10])[0] & window.CUSTOM_ICON)
        self.assertFalse(os.path.exists(os.path.join(mount, window.PLACEHOLDER)))
        with open(os.path.join(mount, window.BACKGROUND_NAME), "rb") as f:
            self.assertEqual(tiff_pages(f.read()), 2)          # the picture for normal and for Retina screens
        with open(os.path.join(mount, ".DS_Store"), "rb") as f:
            layout = f.read()
        bookmark, alias = blob(layout, b"pBBk"), plistlib.loads(blob(layout, b"icvp"))["backgroundImageAlias"]
        # what every customer downloads names no folder of the machine that made it: not the image file behind the
        # volume, not this test's folder (on the release Mac, a folder in its user's home)
        self.assertNotIn(b"writable.dmg", layout)
        self.assertNotIn(os.path.realpath(work).encode(), layout)
        self.assertNotIn(work.encode(), layout)
        # the facts that the bookmark names are this volume's own: the file's catalog number, the volume's path, name
        # and UUID (as diskutil gives it for the volume's device)
        items = bookmark_items(bookmark)
        cnids = items[0x1005][1]
        self.assertEqual(len(cnids), 4)                                  # an array of one item: its offset
        at = struct.unpack("<I", cnids)[0] + 48
        self.assertEqual(struct.unpack("<IIi", bookmark[at:at + 12])[2],
                         os.stat(os.path.join(mount, window.BACKGROUND_NAME)).st_ino)
        self.assertEqual(items[0x2002][1].decode(), "/Volumes/Founderizer Test")    # where a customer mounts it
        self.assertEqual(items[0x2010][1].decode(), "Founderizer Test")
        device = next(entity["dev-entry"] for entity in said["system-entities"] if entity.get("mount-point"))
        volume = plistlib.loads(subprocess.run(["/usr/sbin/diskutil", "info", "-plist", device], capture_output=True,
                                               check=True).stdout)
        self.assertEqual(items[0x2011][1].decode(), volume["VolumeUUID"].upper())
        self.assertEqual(layout, window.store(window.window_records("Founderizer.app", bookmark, alias)))
        background = os.path.join(mount, window.BACKGROUND_NAME)
        self.assertEqual(alias[:4], b"\0\0\0\0")
        self.assertIn("Founderizer Test".encode("utf-16-be"), alias)
        self.assertEqual(struct.unpack(">I", alias[114:118])[0], os.stat(background).st_ino)    # the file's number
        self.assertEqual(struct.unpack(">I", alias[46:50])[0], os.stat(mount).st_ino)           # its folder's
        script = ('ObjC.import("Foundation"); function run(argv) { var d = $.NSData.alloc.initWithBase64EncodedStringOptions'
                  '(argv[0], 0); var u = $.NSURL.URLByResolvingBookmarkDataOptionsRelativeToURLBookmarkDataIsStaleError'
                  '(d, 0, $(), null, null); return u.isNil() ? "" : u.path.js; }')
        resolved = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script,
                                   base64.b64encode(bookmark).decode()], capture_output=True, text=True, check=True)
        self.assertEqual(os.path.realpath(resolved.stdout.strip()), os.path.realpath(background))


if __name__ == "__main__":
    unittest.main()
