DOTA VS WARCRAFT - launcher
===========================

Up to five Dota 2 heroes against one Warcraft III player, as a custom map for
Warcraft III: Reforged 2.0.1.

The map ships without any Dota 2 content. When you start the mod, this launcher
takes the hero, ability and item icons, the hero voice lines, the HUD images
and the hero, creep and building models from YOUR OWN Dota 2 installation,
puts them into a personal copy of the map, and starts Warcraft III with that
map.


REQUIREMENTS
------------
- Warcraft III: Reforged 2.0.1
- Dota 2, installed through Steam (it is free). It only has to be installed;
  you do not need to run it.
- Windows 10 or 11, 64-bit. No administrator rights needed.


WHAT THE LAUNCHER DOES
----------------------
1. Reads the Dota 2 build number (steamapps\appmanifest_570.acf).
2. Exports about 750 icons, HUD images and voice lines from Dota 2 with the
   bundled Source 2 Viewer CLI (folder "vrf") into a cache.
3. Converts the hero, ability and item icons to Warcraft III BLP textures
   (64x64) and the HUD images to BLP (see HUD IMAGES below), and keeps the
   voice lines as MP3 (up to 8 move and attack lines, 4 for kills, deaths,
   level-ups, laughs and respawns, 3 per spell; about 8.5 MB in the map).
4. Exports the 11 heroes (with their default items), the Radiant lane creeps,
   towers, barracks, Ancient and fountain, the neutral creeps, Roshan, the
   heroes' summons (Zealot, treants, proximity mines, Keen Cannons), the
   March of the Machines robots, the runes and the wards as glTF and
   converts them to Warcraft III models (MDX, BLP textures; 71 models plus
   39 still portrait models, about 24 MB in the map).
   The first run takes about a minute and a half; later runs reuse the cache
   (a few seconds) until Dota 2 or the mod updates.
5. Lays the map out like Dota's own, read from game\dota\maps\dota.vpk:
   ground heights as Warcraft III cliffs and ramps, the river, the trees,
   and the towers, barracks, camps, runes, Roshan and lanes at Dota's spots
   (the Warcraft player takes the Dire base). About 20 seconds the first
   time, then cached. If this fails, the map keeps its built-in Dota-like
   layout.
6. Writes the personal map with StormLib:
     Documents\Warcraft III\Maps\DotaVsWarcraft\DotaVsWarcraft.w3x
7. Copies your Dota 2 keys and game settings (ability, item, TP, shop and
   select-hero keys, quick cast, double-tap self cast, zoom lock, auto
   attack), read without changes from Steam\userdata\<account>\570, to
     Documents\Warcraft III\CustomMapData\DotaVsWarcraft\dota_settings.txt
   The map applies them when you play a Dota hero. Without the file it uses
   Dota's default keys.
8. Starts Warcraft III with that map.

It never writes into the Warcraft III or Dota 2 folders. Files it creates:
  %LOCALAPPDATA%\DotaVsWarcraft\cache\<Dota build>\    exported files
  %LOCALAPPDATA%\DotaVsWarcraft\logs\launcher.log     log of every run
  Documents\Warcraft III\Maps\DotaVsWarcraft\         the personal map
  Documents\Warcraft III\CustomMapData\DotaVsWarcraft\dota_settings.txt
                                                      your Dota keys and settings


MULTIPLAYER
-----------
Every player builds the map on their own PC. Players with the same Dota 2 build
and the same version of this mod get byte-identical maps, so Warcraft III sees
them as the same map. After a Dota 2 update, every player should start the mod
once so their map is rebuilt. Your Dota keys are not in the map: they stay in
your own CustomMapData folder, so every player keeps their own.


RUNNING IT BY HAND
------------------
Melty starts the launcher for you. To run it yourself:

  DotaVsWarcraft.exe --game "<Warcraft III folder>" --dota "<Dota 2 folder>"

  --game          the Warcraft III folder (contains _retail_\x86_64\Warcraft III.exe)
  --dota          the Dota 2 folder, e.g.
                  C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta
  --map <file>    base map (default: DotaVsWarcraft.w3x next to the exe)
  --out <file>    where to write the personal map (default: see above)
  --prepare-only  build the map, do not start the game
  --no-wait       exit right after starting the game (default: wait for it)
  --quiet         no message boxes; errors go to the log only


TROUBLESHOOTING
---------------
The launcher shows a message box and the log path when something fails.
Exit codes: 2 wrong command line, 3 Dota 2 not found, 4 Dota 2 game data
missing or unreadable, 5 export or model conversion failed (no map is written
then), 6 base map missing or damaged,
7 map could not be written (close Warcraft III if it is running),
8 Warcraft III not found or did not start, 1 unexpected error.

To force a fresh export, delete %LOCALAPPDATA%\DotaVsWarcraft\cache.


HUD IMAGES (for map developers)
-------------------------------
specs\hud_assets.json (optional) lists extra Dota 2 images for the map's HUD;
build.ps1 checks it and bundles it into the launcher. It is a JSON list of:

  {"target":  "war3mapImported\\Hud\\minimap_frame.blp",
   "sources": ["panorama/images/hud/reborn/minimap_frame_psd.vtex_c"],
   "size":    [256, 256],
   "fit":     "stretch",
   "kind":    "hud"}

  target   the BLP path the map script uses: ASCII, backslashes, relative,
           ending in .blp, unique. Use war3mapImported\Hud\<name>.blp. The
           launcher's own folders (BTNDota_, DISBTNDota_, PASBTNDota_,
           Sound\Dota\, war3mapImported\Dota\) are refused.
  sources  required: Dota texture paths (.vtex_c, as listed in
           pak01_dir.vpk), tried in order; later ones are fallbacks. Their
           VPK folders are listed and exported automatically. If none is
           found, a dark translucent placeholder is written (the target
           always exists) and the log says so.
  size     optional [width, height] in pixels; the image is resized to it
           (aspect ratio not kept). Default: the source size (64x64 for a
           placeholder).
  fit      optional. Warcraft III's classic graphics need power-of-two
           texture sides, so each side is rounded up to the next power of
           two, at most 1024 (a longer side is scaled down to 1024):
             "stretch" (default) resizes the image to that size;
             "pad" keeps the image at the requested size in the top-left
             corner and leaves the rest transparent (use texture
             coordinates 0..width/W and 0..height/H).
           Every adjusted target is logged ("hud_resized"). Power-of-two
           sizes (64 to 512) avoid both.
  kind     optional, "hud".
  note     optional free text.
The result is a BLP1 with a 256-colour palette, 8-bit alpha and mipmaps.
The full contract is at the top of dvw_launcher\assets.py.


CREDITS
-------
Powered by Source 2 Viewer (https://s2v.app)
(ValveResourceFormat, https://github.com/ValveResourceFormat/ValveResourceFormat).
MPQ archives written with StormLib by Ladislav Zezula
(https://github.com/ladislav-zezula/StormLib).
Licences: see THIRD_PARTY_NOTICES.txt.

Dota 2 is a trademark of Valve Corporation. Warcraft III is a trademark of
Blizzard Entertainment. This mod is not affiliated with or endorsed by Valve or
Blizzard.
