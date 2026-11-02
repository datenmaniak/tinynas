# Acerca de como generar la lista de directorios

Analizando el script que genera la lista de directorio, veo que hay un problema con la ruta que se genera. Actualmente, si ejecutas `./script ~/.config`, el script usa $ORIGEN_NORM que sería ~/.config (o su expansión), pero se desea que la lista sea como el **ejemplo abajo** que las muestras sean `.config/XXX` (sin el ~ expandido a /home/user, sino relativo).

## Ejemplo

```text
".config/foot"
".config/ghostty"
".config/herdr"
".config/hypr"
".config/kitty"
".config/lazygit"
".config/opencode"
".config/nvim"
".config/systemd"

```

## Comportamiento actual

### Problema identificado

Cuando pasas ~/.config, bash expande ~ a /home/usuario/.config. El script actual genera rutas como "/home/usuario/.config/tmux". Pero según tu ejemplo, quieres que genere ".config/tmux" (preservando el ~ como .config relativo).

Sin embargo, hay una ambigüedad: ¿qué pasa si pasas una ruta absoluta como /etc? ¿O una ruta relativa como ./mi_dir?

### Solución propuesta

El script debe preservar el argumento tal como lo escribió el usuario (sin expandir ~), y concatenar el nombre del subdirectorio. Para esto necesitamos:

Es necesario ir a la raiz de directorio **`$HOME`**, antes de ejecutar el script que genera la lista. Asi lograr una ruta limpia sin la expansion.

## script

```bash
❯ which generate-list-subdirs-with-path
/home/wpp/Repos/github/datenmaniak/dotfiles/scripts/generate-list-subdirs-with-path
```

## Generar la lista de $HOME

```bash
# Ir a la raiz del HOMEUSER
cd
generate-subdirs-list-from-directory $HOME home.txt

```

## Lista de `~/.config`

## Lista de `~/.local`

12147 generate-subdirs-list-from-directory ~/.config config.txt
12148 less config.txt
12149 generate-subdirs-list-from-directory ~/.local local.txt
12150 cat local.txt
