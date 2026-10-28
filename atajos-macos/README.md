# Cuatro atajos para macOS

Este paquete instala **⌘⇧4, ⌘⇧7, ⌘⇧8 y ⌘⇧9**. Funciona en macOS. No es compatible con Windows ni Linux.

| Atajo | Dónde funciona | Qué hace |
|---|---|---|
| ⌘⇧4 | En cualquier aplicación | Usa la captura de área de macOS. La guarda en `~/Desktop/captures` y abre una sola ventana de vista previa. Allí puedes copiar con ⌘C, imprimir con ⌘P o elegir A3 con ⌘⇧9. |
| ⌘⇧7 | Finder, con archivos seleccionados | Abre WhatsApp, permite buscar un contacto y prepara el archivo para revisar antes de enviarlo. No pulsa «Enviar». Requiere la aplicación de escritorio de WhatsApp. |
| ⌘⇧8 | En cualquier aplicación | Abre un buscador de carpetas dentro de la raíz elegida. Acepta números, nombres y pequeñas faltas de ortografía. Abre en Finder el dossier escogido. |
| ⌘⇧9 | Finder, con PDF o imágenes seleccionados | Ajusta cada página a A3, conserva el contenido completo y envía un único trabajo a la impresora A3 configurada. **Imprime de verdad**; usa `--dry-run` para comprobarlo sin papel. |

## Instalar

1. Instala las herramientas de desarrollo de Apple si faltan: `xcode-select --install`.
2. Descarga este repositorio y abre Terminal en esta carpeta.
3. Comprueba la instalación sin modificar nada: `python3 instalar.py --dry-run --dossiers-root "$HOME/Documents"`.
4. Instala con tu carpeta de dossiers y el nombre de tu impresora A3:

   ```bash
   python3 instalar.py --dossiers-root "$HOME/Documents/Client" --printer NOMBRE_DE_LA_IMPRESORA
   ```

   Puedes consultar el nombre de impresora con `lpstat -p`. Si omites `--printer`, se usa la impresora predeterminada del Mac. Esa impresora debe admitir A3.

5. En **Ajustes del Sistema → Privacidad y seguridad → Accesibilidad**, permite `WhatsAppFinderHelper`. macOS exige este permiso para abrir el selector de archivos de WhatsApp. Si vuelves a compilar la aplicación, macOS puede pedir que quites y añadas esa entrada otra vez.
   La primera vez que uses la vista previa de capturas, macOS puede pedirte que elijas la carpeta `captures` para poder observarla.
6. Cierra sesión y entra de nuevo si los atajos no aparecen enseguida. En macOS puedes revisar o cambiar ⌘⇧7/8/9 en **Ajustes del Sistema → Teclado → Atajos de teclado → Servicios**.

El instalador compila el código fuente en tu Mac y guarda los programas en tu cuenta de usuario. No instala servicios de red ni necesita contraseña de administrador. Se conserva una copia `*.antes-atajos` de cada acción de Finder que el instalador reemplace.

## Uso y límites

- **WhatsApp:** selecciona un archivo, pulsa ⌘⇧7, escribe el contacto y abre su conversación. Revisa el nombre del adjunto antes de enviarlo. La automatización del selector puede requerir una actualización si WhatsApp cambia su interfaz.
- **Capturas:** pulsa ⌘⇧4 y selecciona un área. El instalador cambia el destino de las capturas y oculta la miniatura flotante. Los archivos que ya existían en el escritorio no se mueven. La ventana muestra la imagen completa al máximo tamaño; si la proporción no coincide con el papel, queda un margen.
- **Dossiers:** pulsa ⌘⇧8 desde cualquier aplicación y escribe un número o nombre. La búsqueda se limita a las carpetas dentro de `--dossiers-root`. No cambia ni mueve dossiers.
- **A3:** selecciona uno o varios PDF o imágenes en Finder y pulsa ⌘⇧9. Cada página se ajusta completa, sin recorte. Si la proporción de la imagen y el papel difiere, quedará un margen. El atajo imprime en una sola cara. Antes de usarlo con documentos importantes, comprueba que la impresora seleccionada es la correcta.
- En algunos teclados o aplicaciones, una combinación puede estar ocupada por otra función. Puedes cambiarla en los ajustes de teclado.

## Archivos

- `instalar.py`: compila, copia y registra los atajos.
- `sources/`: código Swift editable.
- `templates/`: acciones de Finder y metadatos de las aplicaciones.

## Desinstalar

En **Ajustes del Sistema → Teclado → Atajos de teclado → Servicios**, desactiva ⌘⇧7/8/9. Borra las tres acciones en `~/Library/Services/`, las aplicaciones y ejecutables instalados en `~/Applications/Buscar dossier TSI.app`, `~/Library/Scripts/TSIDossierHotkey`, `~/Library/Application Support/CapturesImpresion/`, `~/Library/Application Support/ImprimirA3/` y `~/Library/Application Support/EnviarWhatsApp/`. Retira también `~/Library/LaunchAgents/ch.tsi.dossier-search.hotkey.plist`, `~/Library/LaunchAgents/ch.local.captures-impression.plist` y la entrada de Accesibilidad del ayudante. Para recuperar el destino anterior de las capturas, selecciónalo en la app Captura de pantalla de macOS. Si tenías acciones anteriores, puedes recuperar las carpetas `*.antes-atajos`.

No borres la carpeta elegida para buscar dossiers ni tus documentos: el instalador nunca los copia ni los modifica.
