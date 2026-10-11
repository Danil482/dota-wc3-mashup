"""Dota vs Warcraft launcher: builds a personalized Warcraft III map from the
player's own Dota 2 install, then starts Warcraft III."""

__version__ = "1.0.0"

# Bump when the asset plan or the conversion changes, so cached plans and
# extracted files from older launcher versions are not trusted blindly.
PLAN_VERSION = 3
