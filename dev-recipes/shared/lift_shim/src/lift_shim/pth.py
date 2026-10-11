from pathlib import Path

PTH_NAME = "lift_shim_autoload.pth"


def write_pth(site_packages: Path) -> Path:
    p = Path(site_packages) / PTH_NAME
    p.write_text("import lift_shim.autoload\n")
    return p


def remove_pth(site_packages: Path) -> None:
    (Path(site_packages) / PTH_NAME).unlink(missing_ok=True)
