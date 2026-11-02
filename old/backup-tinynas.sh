#!/usr/bin/env bash
#
# backup-tinynas.sh
# Respaldo del home del usuario ${USER} y de /etc local hacia /mnt/tinynas (NFS).
#
# Características:
#   - Sin --delete (respaldo acumulativo, limpieza manual).
#   - Lock con flock no bloqueante (evita solapamiento con ejecución manual).
#   - Validación de autofs con timeout.
#   - Centinela .tinynas-id solo como advertencia.
#   - Log en /home/${USER}/backup.log.
#   - Códigos de salida rsync aceptables: 0 y 24.
#
# Uso:
#   ./backup-tinynas.sh
#   (También invocado por systemd vía backup-tinynas.service)
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
#USER="${USER}"
HOME_USER="/home/${USER}"
SCRIPT_DIR="/home/${USER}/admin/tinynas"
EXCLUDE_FILE="${SCRIPT_DIR}/exclude-tinynas.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas.lock"

NFS_ROOT="/var/mnt/tinynas/ryzen/"
CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"
DESTINO_HOME="${DESTINO_BASE}/home/${USER}"
DESTINO_ETC="${DESTINO_BASE}/etc"

LOG_FILE="/home/${USER}/backup.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

# Opciones rsync comunes
#    -avHAX  --no-group   #  Con esto se soluciona el problema de re-asignacion del grupo. Dejando asi, que actue la ACL 
#
RSYNC_OPTS=(
    -aHAX
    --numeric-ids
    --timeout=30
    --exclude-from="${EXCLUDE_FILE}"
    --info=progress2
    -z
    -n
)

#    --no-group
#    --bwlimit=12000  # utilizado en Raspbery
#
#
# ---------------------------------------------------------------------------
# Utilidades de log
# ---------------------------------------------------------------------------
log() {
    local nivel="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${nivel}] $*" >> "${LOG_FILE}"
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

log_info "=== Inicio de respaldo ==="

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
if ! command -v rsync >/dev/null 2>&1; then
    log_error "rsync no está instalado. Abortando."
    exit 1
fi

if [[ ! -r "${EXCLUDE_FILE}" ]]; then
    log_error "No se puede leer ${EXCLUDE_FILE}. Abortando."
    exit 1
fi

# Forzar montaje autofs con timeout
if ! timeout 20 ls "${NFS_ROOT}" >/dev/null 2>&1; then
    log_error "No se pudo acceder a ${NFS_ROOT} (autofs no montó o NFS caído). Abortando."
    exit 1
fi
log_info "autofs/NFS accesible en ${NFS_ROOT}."

# Centinela: solo advertencia
if [[ ! -e "${CENTINELA}" ]]; then
    log_warn "Centinela ${CENTINELA} no encontrado. Se continúa (sin --delete no hay riesgo de borrado)."
else
    log_info "Centinela encontrado: $(cat "${CENTINELA}" 2>/dev/null | head -n1)"
fi

# Espacio libre en destino
ESPACIO_LIBRE_MB=$(df -Pm "${NFS_ROOT}" | awk 'NR==2 {print $4}')
if [[ -z "${ESPACIO_LIBRE_MB}" || "${ESPACIO_LIBRE_MB}" -lt "${ESPACIO_MIN_MB}" ]]; then
    log_error "Espacio libre insuficiente en ${NFS_ROOT} (${ESPACIO_LIBRE_MB:-?} MiB < ${ESPACIO_MIN_MB} MiB). Abortando."
    exit 1
fi
log_info "Espacio libre en destino: ${ESPACIO_LIBRE_MB} MiB."

# Crear estructura destino si no existe
sudo mkdir -p "${DESTINO_HOME}" "${DESTINO_ETC}" 2>/dev/null || {
    log_error "No se pudo crear la estructura en ${DESTINO_BASE}. Abortando."
    exit 1
}

# ---------------------------------------------------------------------------
# Respaldo del home (sin sudo)
# ---------------------------------------------------------------------------
log_info "Iniciando rsync del home: ${HOME_USER}/ -> ${DESTINO_HOME}/"
sudo rsync "${RSYNC_OPTS[@]}" \
    "${HOME_USER}/" \
    "${DESTINO_HOME}/" >> "${LOG_FILE}" 2>&1
RC_HOME=$?
case "${RC_HOME}" in
    0)  log_info "Home: rsync OK (código 0)." ;;
    24) log_warn "Home: rsync completó con código 24 (archivos desaparecieron durante la copia)." ;;
    *)  log_error "Home: rsync falló con código ${RC_HOME}." ;;
esac

# ---------------------------------------------------------------------------
# Respaldo de /etc (con sudo, NOPASSWD asumido)
# ---------------------------------------------------------------------------
log_info "Iniciando rsync de /etc: /etc/ -> ${DESTINO_ETC}/"
sudo rsync "${RSYNC_OPTS[@]}" \
    /etc/ \
    "${DESTINO_ETC}/" >> "${LOG_FILE}" 2>&1
RC_ETC=$?
case "${RC_ETC}" in
    0)  log_info "/etc: rsync OK (código 0)." ;;
    24) log_warn "/etc: rsync completó con código 24." ;;
    *)  log_error "/etc: rsync falló con código ${RC_ETC}." ;;
esac

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
TAM_HOME=$(du -sh "${DESTINO_HOME}" 2>/dev/null | awk '{print $1}')
TAM_ETC=$(du -sh "${DESTINO_ETC}" 2>/dev/null | awk '{print $1}')
log_info "Tamaño destino home: ${TAM_HOME:-?}"
log_info "Tamaño destino /etc: ${TAM_ETC:-?}"

RC_FINAL=0
[[ "${RC_HOME}" -ne 0 && "${RC_HOME}" -ne 24 ]] && RC_FINAL=1
[[ "${RC_ETC}"  -ne 0 && "${RC_ETC}"  -ne 24 ]] && RC_FINAL=1

log_info "=== Fin de respaldo (código agregado: ${RC_FINAL}) ==="
exit "${RC_FINAL}"

