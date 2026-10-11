"""PyInstaller entry point for DotaVsWarcraft.exe."""
import sys

from dvw_launcher.cli import main

if __name__ == "__main__":
    sys.exit(main())
