# dmgbuild settings for the Memoir DMG. build-dmg.sh passes both paths in
# with -D, because dmgbuild runs this file without __file__ set. The window
# geometry has to match make-background.swift.
import os

app = defines["app"]  # noqa: F821, dmgbuild injects `defines`
background = defines["background"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
# dmgbuild's default, and readable by every macOS version Memoir runs on.
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
show_tab_view = False

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 160),
    "Applications": (495, 160),
}
