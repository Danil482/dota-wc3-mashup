"""PyInstaller entry point for DotaVsCommander.exe."""
import sys

from dvc_launcher.cli import main

if __name__ == "__main__":
    sys.exit(main())
