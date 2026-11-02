#!/usr/bin/env bash
#
# backup-etc-iteractivo-tinynas.sh
# Respaldo selectivo de archivos y directorios de /etc hacia /mnt/tinynas (NFS)
# leyendo los objetivos desde un archivo de configuración externo y depurando eliminados.
#
# Uso:
#   sudo ./backup-etc-iteractivo-tinynas.sh              # copia real
#   sudo DRY_RUN=1 ./backup-etc-iteractivo-tinynas.sh    # solo simula
#   sudo DELETE_AFTER=1 ./backup-etc-iteractivo-tinynas.sh  # con --delete-after
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

HOST="ryzen"  # nombre del equipo: ryzen o victus

SCRIPT_DIR="/home/${USER}/admin/tinynas"
DIRECTORIOS_ETC_FILE="${SCRIPT_DIR}/directorios_etc.txt"
EXCLUDE_ETC_FILE="${SCRIPT_DIR}/exclude-etc.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas-etc.lock"

NFS_ROOT="/var/mnt/tinynas/${HOST}"
CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"
DESTINO_ETC="${DESTINO_BASE}/etc"

LOG_FILE="/home/${USER}/backup.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

# Variables de control (override por entorno)
DRY_RUN="${DRY_RUN:-0}"           # 1 = simular, 0 = copiar de verdad
DELETE_AFTER="${DELETE_AFTER:-0}" # 1 = añadir --delete-after a rsync

# ---------------------------------------------------------------------------
# Opciones rsync optimizadas para archivos de sistema
# ---------------------------------------------------------------------------
RSYNC_OPTS=(
  -aHAX
  --numeric-ids
  --filter='-x security.selinux'
  --filter='-x system.nfs4_acl'
  --info=progress2
  --ignore-times
)

  # --partial
  # --inplace
#  --stats


[[ "${DRY_RUN}" == "1" ]] && RSYNC_OPTS+=( -n )
[[ "${DELETE_AFTER}" == "1" ]] && RSYNC_OPTS+=( --delete-after )

# Añadir archivo de exclusión opcional si existe
if [[ -r "${EXCLUDE_ETC_FILE}" ]]; then
  RSYNC_OPTS+=( --exclude-from="${EXCLUDE_ETC_FILE}" )
fi

# ---------------------------------------------------------------------------
# Utilidades de log
# ---------------------------------------------------------------------------
log() {
  local nivel="$1"
  shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [ETC] [${nivel}] $*" >>"${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Lock para evitar solapamiento
# ---------------------------------------------------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log_warn "Ejecución previa en curso (lock ${LOCK_FILE} tomado). Abortando."
  exit 0
fi

log_info "=== Inicio de respaldo de /etc (DRY_RUN=${DRY_RUN}, DELETE_AFTER=${DELETE_AFTER}) ==="

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
#if [[ $EUID -ne 0 ]]; then
#  log_error "Este script requiere privilegios de superusuario (sudo) para leer /etc correctamente."
#  exit 1
#fi

if ! command -v rsync >/dev/null 2>&1; then
  log_error "rsync no está instalado. Abortando."
  exit 1
fi

if [[ ! -r "${DIRECTORIOS_ETC_FILE}" ]]; then
  log_error "No se puede leer ${DIRECTORIOS_ETC_FILE}. Abortando."
  exit 1
fi

if [[ ! -r "${EXCLUDE_ETC_FILE}" ]]; then
  log_warn "No se puede leer ${EXCLUDE_ETC_FILE}. Se continúa sin exclusiones."
fi

# Forzar montaje autofs con timeout
if ! timeout 20 ls "${NFS_ROOT}" >/dev/null 2>&1; then
  log_error "No se pudo acceder a ${NFS_ROOT} (autofs no montó o NFS caído). Abortando."
  exit 1
fi
log_info "autofs/NFS accesible en ${NFS_ROOT}."

# Centinela: solo advertencia
if [[ ! -e "${CENTINELA}" ]]; then
  log_warn "Centinela ${CENTINELA} no encontrado. Se continúa."
else
  log_info "Centinela encontrado: $(head -n1 "${CENTINELA}" 2>/dev/null)"
fi

# Espacio libre en destino
ESPACIO_LIBRE_MB=$(df -Pm "${NFS_ROOT}" | awk 'NR==2 {print $4}')
if [[ -z "${ESPACIO_LIBRE_MB}" || "${ESPACIO_LIBRE_MB}" -lt "${ESPACIO_MIN_MB}" ]]; then
  log_error "Espacio libre insuficiente en ${NFS_ROOT} (${ESPACIO_LIBRE_MB:-?} MiB < ${ESPACIO_MIN_MB} MiB). Abortando."
  exit 1
fi
log_info "Espacio libre en destino: ${ESPACIO_LIBRE_MB} MiB."

# Crear estructura base destino si no existe
mkdir -p "${DESTINO_ETC}" || {
  log_error "No se pudo crear la estructura en ${DESTINO_ETC}. Abortando."
  exit 1
}

# ---------------------------------------------------------------------------
# Cargar rutas válidas en un array asociativo
# ---------------------------------------------------------------------------
declare -A RUTAS_VALIDAS
while IFS= read -r linea || [[ -n "${linea}" ]]; do
  linea="${linea%%#*}"                       # quita comentarios al final de línea
  linea="$(echo "${linea}" | xargs)"         # trim espacios
  [[ -z "${linea}" ]] && continue
  RUTAS_VALIDAS["${linea}"]=1
done <"${DIRECTORIOS_ETC_FILE}"

if [[ ${#RUTAS_VALIDAS[@]} -eq 0 ]]; then
  log_error "No hay rutas válidas en ${DIRECTORIOS_ETC_FILE}. Abortando."
  exit 1
fi
log_info "Rutas válidas a respaldar: ${#RUTAS_VALIDAS[@]}."

# ---------------------------------------------------------------------------
# Depuración previa: eliminar del destino rutas que ya no están en directorios_etc.txt
# (recursiva, comparando rutas relativas completas)
# ---------------------------------------------------------------------------
if [[ -d "${DESTINO_ETC}" ]]; then
  while IFS= read -r -d '' destino_item; do
    rel="${destino_item#"${DESTINO_ETC}"/}"

    es_valida=0
    for valida in "${!RUTAS_VALIDAS[@]}"; do
      if [[ "${rel}" == "${valida}" || "${rel}" == "${valida}/"* ]]; then
        es_valida=1
        break
      fi
    done

    if [[ "${es_valida}" -eq 0 ]]; then
      log_warn "Ruta '/etc/${rel}' ya no está en ${DIRECTORIOS_ETC_FILE}. Eliminando del destino..."
      rm -rf "${destino_item}"
      log_info "Ruta '${rel}' eliminada del NAS (dry)."
    fi
  done < <(find "${DESTINO_ETC}" -mindepth 1 -print0)
fi

# ---------------------------------------------------------------------------
# Respaldo iterativo leyendo directorios_etc.txt
# ---------------------------------------------------------------------------
RC_ETC=0

while IFS= read -r ruta || [[ -n "${ruta}" ]]; do
  ruta="${ruta%%#*}"
  ruta="$(echo "${ruta}" | xargs)"
  [[ -z "${ruta}" ]] && continue

  ORIGEN_ITEM="/etc/${ruta}"
  DESTINO_ITEM="${DESTINO_ETC}/${ruta}"

  if [[ -d "${ORIGEN_ITEM}" ]]; then
    log_info "Iniciando rsync del directorio: /etc/${ruta}"
    mkdir -p "${DESTINO_ITEM}"
    rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_ITEM}/" \
      "${DESTINO_ITEM}/" >>"${LOG_FILE}" 2>&1
    RC_SUB=$?

  elif [[ -f "${ORIGEN_ITEM}" ]]; then
    log_info "Iniciando rsync del archivo: /etc/${ruta}"
    mkdir -p "$(dirname "${DESTINO_ITEM}")"
    rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_ITEM}" \
      "$(dirname "${DESTINO_ITEM}")/" >>"${LOG_FILE}" 2>&1
    RC_SUB=$?

  else
    log_warn "El origen ${ORIGEN_ITEM} no existe en el sistema operativo instalado. Omitiendo."
    continue
  fi

  case "${RC_SUB}" in
    0)  log_info  "Elemento [${ORIGEN_ITEM}]: rsync OK." ;;
    24) log_warn  "Elemento [${ORIGEN_ITEM}]: completó con código 24 (archivos desaparecieron)." ;;
    *)
      log_error "Elemento [${ORIGEN_ITEM}]: rsync falló con código ${RC_SUB}."
      RC_ETC=1
      ;;
  esac
done <"${DIRECTORIOS_ETC_FILE}"

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
TAM_ETC=$(du -sh "${DESTINO_ETC}" 2>/dev/null | awk '{print $1}')
log_info "Tamaño total destino /etc: ${TAM_ETC:-?}"

RC_FINAL=0
[[ "${RC_ETC}" -ne 0 ]] && RC_FINAL=1

log_info "=== Fin de respaldo de /etc (código agregado: ${RC_FINAL}) ==="
log_info "--- terminado $(date) ---"
exit "${RC_FINAL}"
