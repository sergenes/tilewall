# Layout of the disk image window, read by dmgbuild from scripts/release.sh:
#   dmgbuild -s scripts/dmg_settings.py -D app=dist/tilewall.app "tilewall 0.2.0" dist/tilewall-0.2.0.dmg
# dmgbuild writes the window layout itself, so no Finder scripting and no permission prompt is involved.
import os.path

app = defines["app"]  # noqa: F821, provided by dmgbuild
name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# The app on the left, Applications on the right. The window is tall enough for a Finder that shows its tab and path bars.
window_rect = ((200, 200), (580, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {name: (160, 150), "Applications": (420, 150)}
