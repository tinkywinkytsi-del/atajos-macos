#!/usr/bin/env python3
"""Instala los atajos de macOS sin descargar ejecutables precompilados."""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
HOME = Path.home()


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def copy_template(source, destination, replacements):
    if source.is_dir():
        shutil.copytree(source, destination, dirs_exist_ok=True)
        for file in destination.rglob("*"):
            if file.is_file() and file.suffix in {".plist", ".wflow"}:
                copy_template(file, file, replacements)
    else:
        data = source.read_bytes()
        for before, after in replacements.items():
            data = data.replace(before.encode(), after.encode())
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)


def build(source, output, replacements):
    with tempfile.TemporaryDirectory(prefix="atajos-build-") as temp:
        swift = Path(temp) / source.name
        copy_template(source, swift, replacements)
        result = run("swiftc", "-O", str(swift), "-o", str(output), check=False)
        if result.returncode:
            raise RuntimeError(f"No se pudo compilar {source.name}:\n{result.stderr}")


def workflow(name, replacements, dry):
    src = PACKAGE / "templates" / f"{name}.workflow"
    with tempfile.TemporaryDirectory(prefix="atajos-workflow-") as temp:
        target = Path(temp) / src.name
        copy_template(src, target, replacements)
        for plist in (target / "Contents").glob("*.plist"):
            plistlib.loads(plist.read_bytes())
        plistlib.loads((target / "Contents/document.wflow").read_bytes())
        if not dry:
            destination = HOME / "Library/Services" / src.name
            if destination.exists():
                backup = destination.with_name(destination.name + ".antes-atajos")
                if not backup.exists():
                    shutil.copytree(destination, backup)
                shutil.rmtree(destination)
            shutil.copytree(target, destination)


def agent(label, executable, dry):
    data = {
        "Label": label,
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "LimitLoadToSessionType": "Aqua",
    }
    if dry:
        return
    destination = HOME / "Library/LaunchAgents" / f"{label}.plist"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps(data))
    run("launchctl", "bootout", f"gui/{os.getuid()}/{label}", check=False)
    result = run("launchctl", "bootstrap", f"gui/{os.getuid()}", str(destination), check=False)
    if result.returncode:
        print(f"Aviso: inicia sesión de nuevo para activar {label}: {result.stderr.strip()}")


def shortcuts(dry):
    current = run("defaults", "export", "pbs", "-", check=False)
    try:
        prefs = plistlib.loads(current.stdout.encode()) if current.returncode == 0 else {}
    except (ValueError, TypeError):
        prefs = {}
    entries = prefs.setdefault("NSServicesStatus", {})
    for name, combo in (("Enviar a WhatsApp", "@$7"), ("Buscar dossier TSI", "@$8"), ("Imprimir en A3", "@$9")):
        key = f"(null) - {name} - runWorkflowAsService"
        entry = entries.setdefault(key, {})
        entry["key_equivalent"] = combo
        entry.setdefault("presentation_modes", {"ContextMenu": True, "ServicesMenu": True})
    if not dry:
        with tempfile.NamedTemporaryFile(suffix=".plist") as temporary:
            temporary.write(plistlib.dumps(prefs))
            temporary.flush()
            run("defaults", "import", "pbs", temporary.name)


def main():
    parser = argparse.ArgumentParser(description="Instala atajos de Finder y capturas para macOS")
    parser.add_argument("--dry-run", action="store_true", help="compila y verifica sin cambiar el Mac")
    parser.add_argument("--dossiers-root", type=Path, default=HOME / "Documents", help="carpeta que buscará ⌘⇧8")
    parser.add_argument("--printer", help="nombre CUPS de una impresora A3; se usa la predeterminada si se omite")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Estos atajos usan funciones de macOS y Finder.")
    if not shutil.which("swiftc"):
        parser.error("Instala Xcode Command Line Tools: xcode-select --install")
    if not args.dry_run and not args.dossiers_root.is_dir():
        parser.error("La carpeta de dossiers no existe; usa --dossiers-root RUTA")
    printer_output = run("lpstat", "-d", check=False).stdout.strip()
    printer = args.printer or (printer_output.rsplit(":", 1)[-1].strip() if ":" in printer_output else "")
    if not printer and not args.dry_run:
        parser.error("No hay impresora predeterminada. Usa --printer NOMBRE de una impresora A3.")
    printer = printer or "CONFIGURAR_IMPRESORA_A3"
    replacements = {
        "__HOME__": str(HOME),
        "__DOSSIER_ROOT__": str(args.dossiers_root.expanduser().resolve()),
        "__A3_PRINTER__": printer,
    }
    with tempfile.TemporaryDirectory(prefix="atajos-check-") as temp:
        temp = Path(temp)
        for source in sorted((PACKAGE / "sources").glob("*.swift")):
            output = temp / source.stem if args.dry_run else {
                "BuscarDossier": HOME / "Applications/Buscar dossier TSI.app/Contents/MacOS/BuscarDossierTSI",
                "DossierHotkey": HOME / "Library/Scripts/TSIDossierHotkey",
                "Capturas": HOME / "Library/Application Support/CapturesImpresion/Captures Imprimir.app/Contents/MacOS/CapturesImprimer",
                "ImprimirA3": HOME / "Library/Application Support/ImprimirA3/imprimir-a3",
                "WhatsAppFinder": HOME / "Library/Application Support/EnviarWhatsApp/WhatsAppFinderHelper.app/Contents/MacOS/WhatsAppFinderHelper",
            }[source.stem]
            output.parent.mkdir(parents=True, exist_ok=True)
            build(source, output, replacements)
            if not args.dry_run and ".app/" in str(output):
                info = PACKAGE / "templates" / {
                    "BuscarDossier": "dossier-app-Info.plist",
                    "Capturas": "capturas-app-Info.plist",
                    "WhatsAppFinder": "whatsapp-app-Info.plist",
                }[source.stem]
                shutil.copy2(info, output.parent.parent / "Info.plist")
                run("codesign", "--force", "--sign", "-", str(output.parent.parent.parent))
        for name in ("Buscar dossier TSI", "Imprimir en A3", "Enviar a WhatsApp"):
            workflow(name, replacements, args.dry_run)
        shortcuts(args.dry_run)
        if args.dry_run:
            print("Prueba correcta: 5 programas compilan y 3 acciones de Finder son válidas. No se instaló ni imprimió nada.")
            return
        app_support = HOME / "Library/Application Support/ImprimirA3"
        (app_support / "config.plist").write_bytes(plistlib.dumps({"Printer": printer, "TestMode": False}))
        agent("ch.tsi.dossier-search.hotkey", HOME / "Library/Scripts/TSIDossierHotkey", False)
        agent("ch.local.captures-impression", HOME / "Library/Application Support/CapturesImpresion/Captures Imprimir.app/Contents/MacOS/CapturesImprimer", False)
        captures = HOME / "Desktop/captures"
        captures.mkdir(parents=True, exist_ok=True)
        run("defaults", "write", "com.apple.screencapture", "location", "-string", str(captures))
        run("defaults", "write", "com.apple.screencapture", "show-thumbnail", "-bool", "false")
        run("killall", "SystemUIServer", check=False)
        print("Instalado. Da permiso de Accesibilidad a WhatsAppFinderHelper en Ajustes del Sistema y reinicia sesión si el atajo no aparece de inmediato.")
        print("Capturas: ⌘⇧4; dossiers: ⌘⇧8; Finder → WhatsApp: ⌘⇧7; Finder → A3: ⌘⇧9.")


if __name__ == "__main__":
    main()
