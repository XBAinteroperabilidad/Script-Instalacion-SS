#!/bin/bash
# =============================================================================
# Pruebas post-instalación de X-Road Security Server
# Plataforma X-BA — GCBA / Agencia de Sistemas de Información
#
# Corre sobre cualquier Security Server ya instalado, sin importar cómo se
# instaló. No instala ni modifica nada: diagnostica conectividad, TLS,
# servicios y logs, y genera un reporte .txt con lo que pasó (OK) y lo que
# no (AVISO/ERROR). Los datos del servidor se leen de la propia instalación.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# REGISTRO DE RESULTADOS — cada chequeo se imprime en pantalla Y se guarda
# para el reporte final. Nada acá interrumpe el script: es un diagnóstico,
# no una instalación, así que se corren todas las pruebas pase lo que pase.
# =============================================================================
RESULTS=()
TOTAL_OK=0
TOTAL_AVISO=0
TOTAL_ERROR=0

registrar() {
  local ESTADO=$1 CAT=$2 DESC=$3 DET=$4
  case "$ESTADO" in
    OK)    ok "$DESC";    TOTAL_OK=$((TOTAL_OK+1)) ;;
    AVISO) warn "$DESC";  TOTAL_AVISO=$((TOTAL_AVISO+1)) ;;
    ERROR) err "$DESC";   TOTAL_ERROR=$((TOTAL_ERROR+1)) ;;
  esac
  if [ -n "$DET" ]; then
    echo "        $DET"
  fi
  RESULTS+=("[$ESTADO] [$CAT] $DESC${DET:+ -> $DET}")
}

# =============================================================================
# HELPERS DE PRUEBA
# =============================================================================
probar_tcp() {
  local HOST=$1 PUERTO=$2 CAT=$3
  if timeout 5 bash -c "exec 3<>/dev/tcp/${HOST}/${PUERTO}" 2>/dev/null; then
    registrar OK "$CAT" "Conectividad a $HOST:$PUERTO OK"
  else
    registrar ERROR "$CAT" "Sin conectividad a $HOST:$PUERTO" "Solicitar apertura de este puerto a la mesa de ayuda / equipo de seguridad"
  fi
}

probar_dns() {
  local HOST=$1 CAT=$2
  local IP
  IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -z "$IP" ]; then
    IP=$(nslookup "$HOST" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
  fi
  if [ -n "$IP" ]; then
    registrar OK "$CAT" "DNS de $HOST resuelve a $IP"
  else
    registrar ERROR "$CAT" "No se pudo resolver $HOST" "Verificar DNS configurado en el servidor (probar: nslookup $HOST)"
  fi
}

probar_tls() {
  local HOST=$1 PUERTO=$2 CAT=$3
  local OUT
  OUT=$(echo | timeout 10 openssl s_client -connect "${HOST}:${PUERTO}" -showcerts 2>&1)

  # El puerto puede responder y hacer handshake OK pero devolver un
  # certificado wildcard (*.gcba.gob.ar) en vez del certificado de X-Road,
  # así que se chequea el subject antes del "Verify return code".
  local SUBJECT
  SUBJECT=$(echo "$OUT" | grep -m1 "^subject=")
  if echo "$SUBJECT" | grep -qiE "AGENCIA DE SISTEMAS DE INFORMACION|\*\.gcba\.gob\.ar"; then
    registrar ERROR "$CAT" "$HOST:$PUERTO devolvió un certificado que no corresponde a X-Road" "$SUBJECT"
    return
  fi

  if echo "$OUT" | grep -q "Verify return code: 0 (ok)"; then
    registrar OK "$CAT" "TLS de $HOST:$PUERTO válido"
  elif echo "$OUT" | grep -qiE "connection refused|connect: no route to host|Connection timed out|gethostbyname failure"; then
    registrar ERROR "$CAT" "No se pudo abrir sesión TLS con $HOST:$PUERTO" "$(echo "$OUT" | grep -iE "connect|errno" | head -1)"
  else
    local MOTIVO
    MOTIVO=$(echo "$OUT" | grep "Verify return code" | tail -1)
    registrar AVISO "$CAT" "TLS de $HOST:$PUERTO respondió pero el certificado no validó" "${MOTIVO:-sin 'Verify return code' en la respuesta, revisar manualmente: openssl s_client -connect $HOST:$PUERTO -showcerts}"
  fi
}

probar_http() {
  local URL=$1 CAT=$2 ESPERADOS=${3:-"^(200|301|302)$"}
  local CODE
  CODE=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null)
  if echo "$CODE" | grep -qE "$ESPERADOS"; then
    registrar OK "$CAT" "$URL respondió HTTP $CODE"
  else
    registrar ERROR "$CAT" "$URL respondió HTTP ${CODE:-sin respuesta}" "Revisar conectividad/firewall hacia ese host y puerto"
  fi
}

echo ""
echo "=============================================="
echo "  Pruebas post-instalación X-Road Security Server  "
echo "  Plataforma X-BA — GCBA                     "
echo "=============================================="

if [ "$EUID" -ne 0 ]; then
  warn "No se está ejecutando como root. Algunas pruebas (logs, detalle de puertos) van a ser limitadas."
  warn "Para un diagnóstico completo: sudo bash pruebas_xroad.sh"
fi

# =============================================================================
# 0. SISTEMA OPERATIVO — el Security Server puede estar sobre RHEL 8 o
#    Ubuntu según el organismo. Se detecta acá para usar el gestor de
#    paquetes y de firewall que corresponda en el resto del script.
# =============================================================================
SO_ID="desconocido"
SO_PRETTY="desconocido"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  SO_ID="${ID:-desconocido}"
  SO_PRETTY="${PRETTY_NAME:-$SO_ID}"
fi

if command -v rpm &>/dev/null; then
  GESTOR_PAQUETES="rpm"
elif command -v dpkg &>/dev/null; then
  GESTOR_PAQUETES="dpkg"
else
  GESTOR_PAQUETES="desconocido"
fi
registrar OK "Sistema operativo" "SO detectado: $SO_PRETTY ($GESTOR_PAQUETES)"

# =============================================================================
# 1. DATOS DEL SERVIDOR — se leen de la propia instalación de X-Road (no
#    dependen de cómo se instaló): el Central Server sale del anchor, el MSS
#    del conf global y la base de datos de db.properties. Solo si el Central
#    Server no se puede detectar (ej: todavía no se cargó el anchor) se
#    pregunta el ambiente.
# =============================================================================
echo ""
echo "--- Datos del servidor ---"

CENTRAL_SERVER=""
MSS_SERVER=""
AMBIENTE=""
DB_MODE=""
DB_HOST=""
DB_PORT=""
SERVER_CODE=""

if [ -f /etc/xroad/configuration-anchor.xml ]; then
  CENTRAL_SERVER=$(LC_ALL=C grep -oP '(?<=<downloadURL>)https?://\K[^/:<]+' /etc/xroad/configuration-anchor.xml 2>/dev/null | head -1)
fi
MSS_SERVER=$(LC_ALL=C grep -rhoP '(?<=<authCertRegServiceAddress>)[^<:]+' /etc/xroad/globalconf 2>/dev/null | head -1)
if [ -z "$MSS_SERVER" ] && [[ "$CENTRAL_SERVER" == *central* ]]; then
  MSS_SERVER="${CENTRAL_SERVER/central/mss}"
fi

if [ -z "$CENTRAL_SERVER" ]; then
  warn "No se pudo detectar el Central Server (¿todavía no se cargó el anchor?). Indique el ambiente."
  echo ""
  echo "  [1] QA"
  echo "  [2] HML - Homologación"
  echo "  [3] PRD - Producción"
  echo ""
  while true; do
    read -p "  Opción (1/2/3): " OPT </dev/tty
    case $OPT in
      1) CENTRAL_SERVER="xroad-central-qa.gcba.gob.ar";  MSS_SERVER="xroad-mss-qa.gcba.gob.ar";  break ;;
      2) CENTRAL_SERVER="xroad-central-hml.gcba.gob.ar"; MSS_SERVER="xroad-mss-hml.gcba.gob.ar"; break ;;
      3) CENTRAL_SERVER="xroad-central.buenosaires.gob.ar"; MSS_SERVER="xroad-mss.buenosaires.gob.ar"; break ;;
      *) warn "Opción inválida, ingrese 1, 2 o 3." ;;
    esac
  done
fi

if [ -z "$MSS_SERVER" ]; then
  read -p "  No se pudo detectar el MSS. Ingrese su host: " MSS_SERVER </dev/tty
fi

case "$CENTRAL_SERVER" in
  *-qa.*)  AMBIENTE="QA" ;;
  *-hml.*) AMBIENTE="HML" ;;
  *.buenosaires.gob.ar) AMBIENTE="PRD" ;;
  *) AMBIENTE="desconocido" ;;
esac

DB_URL=$(LC_ALL=C grep -m1 -oP '^serverconf\.hibernate\.connection\.url\s*=\s*jdbc:postgresql://\K[^/\s]+' /etc/xroad/db.properties 2>/dev/null)
if [ -n "$DB_URL" ]; then
  DB_HOST="${DB_URL%%:*}"
  DB_PORT="${DB_URL##*:}"
  [ "$DB_PORT" == "$DB_URL" ] && DB_PORT=5432
  case "$DB_HOST" in
    127.0.0.1|localhost|"["*) DB_MODE="interna" ;;
    *) DB_MODE="externa" ;;
  esac
fi

if [ -f /etc/xroad/organismo.conf ]; then
  SERVER_CODE=$(LC_ALL=C grep -oP '^SERVER_CODE=\K.*' /etc/xroad/organismo.conf 2>/dev/null | head -1)
fi

echo "  Ambiente        : $AMBIENTE"
echo "  Central Server  : $CENTRAL_SERVER"
echo "  MSS Server      : $MSS_SERVER"
echo "  Base de datos   : ${DB_MODE:-no detectada}${DB_HOST:+ ($DB_HOST:$DB_PORT)}"

echo ""
read -p "  ¿Desea agregar otros hosts para probar (ej: SS Provider/Consumer de otro organismo)? (s/n): " AGREGAR_HOSTS </dev/tty
ADICIONALES_LABEL=()
ADICIONALES_HOST=()
ADICIONALES_PUERTOS=()
if [[ "$AGREGAR_HOSTS" == "s" || "$AGREGAR_HOSTS" == "S" ]]; then
  while true; do
    echo ""
    read -p "  Etiqueta (ej: 'SS Provider Salud'): " L </dev/tty
    read -p "  Host/DNS: " H </dev/tty
    read -p "  Puertos separados por coma (ej: 443,5500,5577): " P </dev/tty
    if [ -n "$H" ]; then
      ADICIONALES_LABEL+=("$L")
      ADICIONALES_HOST+=("$H")
      ADICIONALES_PUERTOS+=("$P")
    fi
    read -p "  ¿Agregar otro host? (s/n): " MAS </dev/tty
    [[ "$MAS" == "s" || "$MAS" == "S" ]] || break
  done
fi

# =============================================================================
# 2. VERIFICACIÓN DE INSTALACIÓN
# =============================================================================
echo ""
echo "--- Verificación de instalación ---"

PAQUETE_INSTALADO=""
if [ "$GESTOR_PAQUETES" == "rpm" ] && rpm -q xroad-securityserver &>/dev/null; then
  PAQUETE_INSTALADO=$(rpm -q xroad-securityserver)
elif [ "$GESTOR_PAQUETES" == "dpkg" ] && dpkg -s xroad-securityserver &>/dev/null; then
  PAQUETE_INSTALADO="xroad-securityserver $(dpkg-query -W -f='${Version}' xroad-securityserver 2>/dev/null)"
fi

if [ -n "$PAQUETE_INSTALADO" ]; then
  registrar OK "Instalación" "Paquete xroad-securityserver instalado ($PAQUETE_INSTALADO)"
else
  registrar ERROR "Instalación" "El paquete xroad-securityserver no está instalado"
fi

# =============================================================================
# 3. SERVICIOS X-ROAD
# =============================================================================
echo ""
echo "--- Servicios de X-Road ---"

# Los obligatorios existen en todas las versiones; los opcionales dependen de
# la versión y de los addons instalados, así que si no existen se omiten.
SERVICIOS_OBLIGATORIOS=(xroad-signer xroad-confclient xroad-proxy xroad-proxy-ui-api)
SERVICIOS_OPCIONALES=(xroad-base xroad-monitor xroad-opmonitor xroad-addon-messagelog)

verificar_servicio() {
  local SERVICIO=$1 OBLIGATORIO=$2
  if ! systemctl cat "$SERVICIO" &>/dev/null; then
    if [ "$OBLIGATORIO" == "si" ]; then
      registrar ERROR "Servicios" "$SERVICIO: no está instalado" "Revisar: systemctl status $SERVICIO"
    fi
    return
  fi
  if systemctl is-active "$SERVICIO" &>/dev/null; then
    local DESDE
    DESDE=$(systemctl show "$SERVICIO" -p ActiveEnterTimestamp --value 2>/dev/null)
    registrar OK "Servicios" "$SERVICIO: activo" "desde: ${DESDE:-desconocido}"
  else
    registrar ERROR "Servicios" "$SERVICIO: $(systemctl is-active "$SERVICIO" 2>/dev/null)" "Revisar: systemctl status $SERVICIO"
  fi
}

for SERVICIO in "${SERVICIOS_OBLIGATORIOS[@]}"; do verificar_servicio "$SERVICIO" si; done
for SERVICIO in "${SERVICIOS_OPCIONALES[@]}"; do verificar_servicio "$SERVICIO" no; done

# =============================================================================
# 4. IP PROPIA — para reportarle a X-BA (privada y pública/NAT de salida)
# =============================================================================
echo ""
echo "--- Identificación del servidor ---"

IP_PRIVADA=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | head -1)
registrar OK "Red" "IP privada del servidor: ${IP_PRIVADA:-no detectada}"

IP_PUBLICA=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
if [ -n "$IP_PUBLICA" ]; then
  registrar OK "Red" "IP pública/NAT de salida: $IP_PUBLICA" "Es la IP que X-BA debe habilitar del lado de ellos"
else
  registrar AVISO "Red" "No se pudo determinar la IP pública/NAT de salida" "Puede indicar falta de salida a internet; consultar manualmente con: curl https://api.ipify.org"
fi

# =============================================================================
# 5. DNS — Central Server, MSS y hosts adicionales
# =============================================================================
echo ""
echo "--- Resolución DNS ---"

probar_dns "$CENTRAL_SERVER" "DNS"
probar_dns "$MSS_SERVER" "DNS"
for i in "${!ADICIONALES_HOST[@]}"; do
  probar_dns "${ADICIONALES_HOST[$i]}" "DNS (${ADICIONALES_LABEL[$i]})"
done

# =============================================================================
# 6. CONECTIVIDAD TCP — puertos según lo que X-BA pide validar en cada
#    integración (Central 80/4001, MSS 5500/5577, y adicionales)
# =============================================================================
echo ""
echo "--- Conectividad TCP ---"

probar_tcp "$CENTRAL_SERVER" 80   "Conectividad"
probar_tcp "$CENTRAL_SERVER" 4001 "Conectividad"
probar_tcp "$MSS_SERVER" 5500 "Conectividad"
probar_tcp "$MSS_SERVER" 5577 "Conectividad"

for i in "${!ADICIONALES_HOST[@]}"; do
  IFS=',' read -ra PUERTOS <<< "${ADICIONALES_PUERTOS[$i]}"
  for PTO in "${PUERTOS[@]}"; do
    PTO=$(echo "$PTO" | xargs)
    [ -n "$PTO" ] && probar_tcp "${ADICIONALES_HOST[$i]}" "$PTO" "Conectividad (${ADICIONALES_LABEL[$i]})"
  done
done

# =============================================================================
# 7. VALIDACIÓN TLS — mismo chequeo que X-BA pide correr a mano
#    (openssl s_client -connect host:puerto -showcerts)
# =============================================================================
echo ""
echo "--- Validación TLS ---"

probar_tls "$CENTRAL_SERVER" 4001 "TLS"
probar_tls "$MSS_SERVER" 5500 "TLS"
for i in "${!ADICIONALES_HOST[@]}"; do
  IFS=',' read -ra PUERTOS <<< "${ADICIONALES_PUERTOS[$i]}"
  PRIMER_PUERTO=$(echo "${PUERTOS[0]}" | xargs)
  [ -n "$PRIMER_PUERTO" ] && probar_tls "${ADICIONALES_HOST[$i]}" "$PRIMER_PUERTO" "TLS (${ADICIONALES_LABEL[$i]})"
done

# =============================================================================
# 8. HTTP — anchor/internalconf (caso real: timeout en puerto 80 hacia el
#    Central Server bloqueó la validación del anchor) y XSDs externos que
#    valida el anchor al cargarse.
# =============================================================================
echo ""
echo "--- Validación HTTP (anchor y dependencias externas) ---"

probar_http "http://${CENTRAL_SERVER}/internalconf" "Anchor"
probar_http "http://x-road.eu/xsd/identifiers" "Anchor (XSD externo)"
probar_http "http://x-road.eu/xsd/xroad.xsd" "Anchor (XSD externo)"

# =============================================================================
# 9. UI LOCAL Y PUERTO EXTERNO
# =============================================================================
echo ""
echo "--- UI local y puerto externo ---"

HTTP_CODE=$(curl -sk --max-time 10 https://localhost:4000 -o /dev/null -w "%{http_code}" 2>/dev/null)
if echo "$HTTP_CODE" | grep -qE "200|302|401"; then
  registrar OK "UI" "UI de X-Road respondiendo en puerto 4000 (HTTP $HTTP_CODE)"
else
  registrar ERROR "UI" "UI no responde en puerto 4000 (HTTP ${HTTP_CODE:-sin respuesta})" "Revisar: systemctl status xroad-proxy-ui-api"
fi

if ss -tlnp 2>/dev/null | grep -q ":5500 "; then
  registrar OK "UI" "Puerto externo 5500 escuchando"
else
  registrar ERROR "UI" "Puerto 5500 no está escuchando" "Revisar: systemctl status xroad-proxy"
fi

if [ -d /etc/xroad/globalconf ] && [ -n "$(ls -A /etc/xroad/globalconf 2>/dev/null)" ]; then
  ULTIMA_MOD=$(find /etc/xroad/globalconf -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [ -n "$ULTIMA_MOD" ]; then
    AHORA=$(date +%s)
    HORAS=$(( (AHORA - ${ULTIMA_MOD%.*}) / 3600 ))
    if [ "$HORAS" -lt 24 ]; then
      registrar OK "Configuración global" "El conf global se actualizó hace ${HORAS}h"
    else
      registrar AVISO "Configuración global" "El conf global no se actualiza hace ${HORAS}h" "Revisar conectividad al Central Server y el estado de xroad-confclient"
    fi
  fi
else
  registrar ERROR "Configuración global" "No hay conf global descargado en /etc/xroad/globalconf" "El Security Server todavía no sincronizó con el Central Server (¿anchor cargado?)"
fi

# =============================================================================
# 10. BASE DE DATOS EXTERNA
# =============================================================================
if [ "$DB_MODE" == "externa" ] && [ -n "$DB_HOST" ]; then
  echo ""
  echo "--- Base de datos externa ---"
  probar_tcp "$DB_HOST" "${DB_PORT:-5432}" "Base de datos"
fi

# =============================================================================
# 11. LOGS — patrones de error conocidos (relevados de casos de soporte
#     reales) + búsqueda opcional de un ID de correlación puntual.
# =============================================================================
echo ""
echo "--- Revisión de logs ---"

if [ -d /var/log/xroad ]; then
  ENCONTRO_ALGO=0

  buscar_patron() {
    local PATRON=$1 CAT=$2 DESC=$3 SUGERENCIA=$4
    local COINCIDENCIA
    COINCIDENCIA=$(grep -rl "$PATRON" /var/log/xroad/ 2>/dev/null | head -1)
    if [ -n "$COINCIDENCIA" ]; then
      ENCONTRO_ALGO=1
      registrar AVISO "$CAT" "$DESC" "$SUGERENCIA (ver: $COINCIDENCIA)"
    fi
  }

  buscar_patron "TLS certificate does not match in global conf" "Certificados" \
    "Se encontró el error 'Central server TLS certificate does not match in global conf'" \
    "Verificar que el anchor cargado sea el del ambiente correcto y que el conf global esté sincronizado; si persiste, consultar a X-BA"

  buscar_patron "SignerNotReachableException\|Signer is not currently reachable" "Certificados" \
    "Se encontró el error 'Signer is not currently reachable' al registrar un certificado" \
    "Revisar systemctl status xroad-signer, reiniciarlo si hace falta y reintentar el registro del certificado AUTH"

  buscar_patron "Connection timed out" "Red" \
    "Se encontraron timeouts de conexión en los logs de X-Road" \
    "Puede indicar un puerto bloqueado; revisar los resultados de conectividad TCP de este reporte"

  buscar_patron "CSRF token not found" "Sesión web" \
    "Se encontró 'CSRF token not found in header' en los logs de la UI" \
    "Suele ser inofensivo en el primer request de una sesión nueva; ignorar si el login funciona con normalidad"

  buscar_patron "authentication failure" "Autenticación" \
    "Se encontraron fallos de autenticación del usuario administrador" \
    "Confirmar la contraseña del usuario admin; resetear con: passwd <usuario> si hace falta"

  if [ "$ENCONTRO_ALGO" -eq 0 ]; then
    registrar OK "Logs" "No se encontraron patrones de error conocidos en /var/log/xroad"
  fi
else
  registrar AVISO "Logs" "No se encontró /var/log/xroad (¿corriendo sin permisos suficientes?)"
fi

BUSQUEDA_ID_RESULTADO=""
echo ""
read -p "  ¿Desea buscar un ID de correlación puntual en los logs (el que muestra la UI en un error)? (s/n): " BUSCAR_ID </dev/tty
if [[ "$BUSCAR_ID" == "s" || "$BUSCAR_ID" == "S" ]]; then
  read -p "  ID a buscar: " ID_BUSCADO </dev/tty
  if [ -n "$ID_BUSCADO" ] && [ -d /var/log/xroad ]; then
    BUSQUEDA_ID_RESULTADO=$(grep -R "$ID_BUSCADO" /var/log/xroad/ 2>/dev/null)
    if [ -n "$BUSQUEDA_ID_RESULTADO" ]; then
      registrar AVISO "Logs" "Se encontraron coincidencias para el ID $ID_BUSCADO" "Ver detalle completo en el reporte .txt"
    else
      registrar OK "Logs" "No se encontraron coincidencias para el ID $ID_BUSCADO"
    fi
  fi
fi

# =============================================================================
# 12. FIREWALL
# =============================================================================
echo ""
echo "--- Firewall ---"

if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
  for PUERTO in 80/tcp 443/tcp 4000/tcp 5500/tcp 5577/tcp 8080/tcp; do
    if firewall-cmd --zone=public --query-port="$PUERTO" &>/dev/null; then
      registrar OK "Firewall" "Puerto $PUERTO habilitado en firewalld"
    else
      registrar AVISO "Firewall" "Puerto $PUERTO no está habilitado en firewalld"
    fi
  done
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "^Status: active"; then
  for PUERTO in 80 443 4000 5500 5577 8080; do
    if ufw status 2>/dev/null | grep -qE "^${PUERTO}(/tcp)?[[:space:]]+ALLOW"; then
      registrar OK "Firewall" "Puerto $PUERTO habilitado en ufw"
    else
      registrar AVISO "Firewall" "Puerto $PUERTO no está habilitado en ufw"
    fi
  done
else
  registrar AVISO "Firewall" "No se detectó firewalld ni ufw activos, no se pudo verificar el estado de los puertos"
fi

# =============================================================================
# REPORTE FINAL
# =============================================================================
FECHA=$(date '+%d/%m/%Y %H:%M:%S')
FECHA_ARCHIVO=$(date '+%Y%m%d_%H%M%S')
NOMBRE_REPORTE="reporte_pruebas_xroad_${SERVER_CODE:-$(hostname)}_${FECHA_ARCHIVO}.txt"

{
  echo "=============================================="
  echo "  Reporte de pruebas post-instalación X-Road"
  echo "  Plataforma X-BA — GCBA"
  echo "=============================================="
  echo ""
  echo "Fecha           : $FECHA"
  echo "Hostname        : $(hostname)"
  echo "SO              : $SO_PRETTY"
  echo "IP privada      : ${IP_PRIVADA:-desconocida}"
  echo "IP pública/NAT  : ${IP_PUBLICA:-desconocida}"
  echo "Ambiente        : ${AMBIENTE:-desconocido}"
  echo "Server Code     : ${SERVER_CODE:-no informado}"
  echo "Central Server  : $CENTRAL_SERVER"
  echo "MSS Server      : $MSS_SERVER"
  echo "Base de datos   : ${DB_MODE:-desconocida}${DB_HOST:+ ($DB_HOST)}"
  echo ""
  echo "=============================================="
  echo "  Resultado de las pruebas"
  echo "=============================================="
  for LINEA in "${RESULTS[@]}"; do
    echo "$LINEA"
  done
  echo ""
  echo "=============================================="
  echo "  Resumen"
  echo "=============================================="
  echo "  OK    : $TOTAL_OK"
  echo "  AVISO : $TOTAL_AVISO"
  echo "  ERROR : $TOTAL_ERROR"
  echo ""
  if [ -n "$BUSQUEDA_ID_RESULTADO" ]; then
    echo "=============================================="
    echo "  Búsqueda de ID '$ID_BUSCADO' en /var/log/xroad"
    echo "=============================================="
    echo "$BUSQUEDA_ID_RESULTADO"
    echo ""
  fi
  echo "=============================================="
  echo "*** Enviá este archivo completo al equipo de X-BA"
  echo "*** para que puedan validar el estado de la integración."
  echo "=============================================="
} > "$NOMBRE_REPORTE"

echo ""
echo "=============================================="
if [ "$TOTAL_ERROR" -eq 0 ]; then
  echo -e "${GREEN}  Pruebas finalizadas sin errores${NC}"
else
  echo -e "${RED}  Pruebas finalizadas con errores${NC}"
fi
echo "=============================================="
echo "  OK    : $TOTAL_OK"
echo "  AVISO : $TOTAL_AVISO"
echo "  ERROR : $TOTAL_ERROR"
echo ""
echo "  Reporte guardado en: $(pwd)/$NOMBRE_REPORTE"
echo "  Enviá ese archivo al equipo de X-BA."
echo "=============================================="

[ "$TOTAL_ERROR" -eq 0 ]
