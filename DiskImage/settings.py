# The window of the app's disk image, for `dmgbuild` (release.sh gives it `-D app=... -D background=... -D icon=...`).
#
# What the customer sees when the image opens (the owner's yes of 14 November 2026: "Arrow only"): the Founderizer
# icon on the left, the Applications folder on the right, the gray arrow of background.png between them, big icons,
# and no toolbar, sidebar or status bar. The disk on the desktop wears the app's icon.
#
# dmgbuild writes the window's layout (.DS_Store) itself, with no Finder and no screen, so the release job makes the
# same window on a locked Mac. This file is Python that dmgbuild runs: `defines` is the dict of its -D values.

app = defines["app"]                                        # noqa: F821 (dmgbuild gives it)
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = ["Founderizer.app"]

background = defines["background"]                          # noqa: F821
icon = defines["icon"]                                      # noqa: F821

format = "UDZO"
filesystem = "HFS+"

# 640 x 400 of content, the size of background.png, under a title bar of 32 points.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
# The centres of the two icons, in the content's points: the arrow of background.png runs between them.
icon_locations = {"Founderizer.app": (160, 190), "Applications": (480, 190)}
