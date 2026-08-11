#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

rollback() {
  echo ""
  warn "Ocurrió un error durante la instalación. Ejecutando rollback..."
  if [ "$MODO" == "db" ]; then
    for svc in $(systemctl list-units --type=service --all 'postgresql-*' --no-legend 2>/dev/null | awk '{print $1}'); do
      systemctl stop "$svc" 2>/dev/null || true
    done
    dnf remove -y 'postgresql*' pgdg-redhat-repo 2>/dev/null || true
    rm -f /etc/yum.repos.d/pgdg*
    rm -rf /var/lib/pgsql
    dnf clean all 2>/dev/null || true
  else
    systemctl stop xroad-proxy xroad-proxy-ui-api xroad-confclient xroad-signer \
      xroad-monitor xroad-addon-messagelog xroad-base xroad-opmonitor 2>/dev/null || true
    dnf remove -y 'xroad-*' pgdg-redhat-repo 2>/dev/null || true
    if [ "$DB_MODE" != "externa" ]; then
      dnf remove -y postgresql-server postgresql-contrib postgresql 2>/dev/null || true
    fi
    if [ "$DB_MODE" == "externa" ]; then
      warn "Base de datos externa: no se realiza DROP remoto. Si hace falta, limpiá manualmente las bases/usuarios en ${DB_HOST}."
    else
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS serverconf;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS messagelog;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"op-monitor\";" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS serverconf;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS serverconf_admin;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS messagelog;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS messagelog_admin;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS opmonitor;" 2>/dev/null || true
      sudo -u postgres psql -c "DROP USER IF EXISTS opmonitor_admin;" 2>/dev/null || true
    fi
    rm -f /etc/yum.repos.d/artifactory* /etc/yum.repos.d/epel.repo /etc/yum.repos.d/pgdg*
    rm -rf /etc/xroad /var/lib/xroad /var/log/xroad /etc/xroad.properties
    if [ "$DB_MODE" != "externa" ]; then
      rm -rf /var/lib/pgsql
    fi
    dnf clean all 2>/dev/null || true
  fi
  warn "Rollback completado. El servidor quedó en el estado anterior."
  warn "Revisá el error de arriba, corregilo y volvé a ejecutar el script."
  exit 1
}
trap rollback ERR

preguntar() {
  local LABEL=$1
  local VARNAME=$2
  local VALOR=""
  while true; do
    echo ""
    read -p "  Ingrese $LABEL: " VALOR </dev/tty
    if [ -z "$VALOR" ]; then
      warn "El campo no puede estar vacío."
      continue
    fi
    read -p "  Confirme $LABEL [${VALOR}] (s/n): " CONFIRM </dev/tty
    if [[ "$CONFIRM" == "s" || "$CONFIRM" == "S" ]]; then
      eval "$VARNAME='$VALOR'"
      break
    else
      warn "Volviendo a ingresar $LABEL..."
    fi
  done
}

preguntar_secreta() {
  local LABEL=$1
  local VARNAME=$2
  local VALOR=""
  local VALOR2=""
  while true; do
    echo ""
    read -s -p "  Ingrese $LABEL: " VALOR </dev/tty
    echo ""
    if [ -z "$VALOR" ]; then
      warn "El campo no puede estar vacío."
      continue
    fi
    read -s -p "  Confirme $LABEL: " VALOR2 </dev/tty
    echo ""
    if [ "$VALOR" == "$VALOR2" ]; then
      eval "$VARNAME='$VALOR'"
      break
    else
      warn "No coincide. Volviendo a ingresar $LABEL..."
    fi
  done
}

diagnosticar_postgres() {
  local SERVICIO=$1
  warn "PostgreSQL no pudo iniciar/reiniciar. Diagnóstico:"
  echo "--- journalctl -u $SERVICIO ---"
  journalctl -u "$SERVICIO" --no-pager -n 30 2>/dev/null
  echo "--- log de PostgreSQL ---"
  cat "/var/lib/pgsql/${PG_VERSION}/data/log/"*.log 2>/dev/null | tail -50
  echo "--- posibles denegaciones de SELinux ---"
  ausearch -m avc -ts recent 2>/dev/null | tail -20
}

verificar_baseos() {
  dnf makecache &>/dev/null
  dnf repolist enabled 2>/dev/null | grep -qi baseos
}

asegurar_suscripcion_redhat() {
  if ! verificar_baseos; then
    warn "Esta VM no está registrada ante Red Hat (o el registro quedó roto)."
    preguntar "usuario de tu cuenta de Red Hat (subscription-manager)" RH_USER
    subscription-manager clean &>/dev/null || true
    if ! subscription-manager register --username="$RH_USER" </dev/tty; then
      fail "No se pudo registrar la VM ante Red Hat. Verificá el usuario/contraseña y volvé a ejecutar el script."
    fi
    ok "VM registrada ante Red Hat"
    local MAJOR
    MAJOR=$(grep -oP '\d+' /etc/redhat-release | head -1)
    subscription-manager repos \
      --enable "rhel-${MAJOR}-for-x86_64-baseos-rpms" \
      --enable "rhel-${MAJOR}-for-x86_64-appstream-rpms" 2>/dev/null || true
  fi

  local DNF_CHECK_LOG
  DNF_CHECK_LOG=$(mktemp)
  if ! dnf makecache >"$DNF_CHECK_LOG" 2>&1; then
    cat "$DNF_CHECK_LOG"
    rm -f "$DNF_CHECK_LOG"
    fail "No se pudieron descargar los repositorios de Red Hat aun después de registrar. Revisá: subscription-manager status"
  fi
  rm -f "$DNF_CHECK_LOG"
  if ! dnf repolist enabled 2>/dev/null | grep -qi baseos; then
    fail "El repositorio BaseOS de Red Hat no aparece habilitado. Revisá: subscription-manager repos --list-enabled"
  fi
  ok "Suscripción de Red Hat OK (repositorios accesibles)"
}

echo ""
echo "=============================================="
echo "  Instalación X-Road Security Server v7.6.4  "
echo "  Plataforma X-BA — GCBA                     "
echo "=============================================="

if [ "$EUID" -ne 0 ]; then
  fail "Este script debe ejecutarse como root: sudo bash instalar_xroad.sh"
fi

echo ""
echo "--- ¿Qué se va a instalar en este servidor? ---"
echo "  [1] Security Server de X-Road"
echo "  [2] Servidor de Base de Datos externa (PostgreSQL) para un Security Server"
echo ""
while true; do
  read -p "  Opción (1/2): " MODO_OPT </dev/tty
  case $MODO_OPT in
    1) MODO="ss"; break ;;
    2) MODO="db"; break ;;
    *) warn "Opción inválida, ingrese 1 o 2." ;;
  esac
done

if [ "$MODO" == "db" ]; then
  echo ""
  echo "=============================================="
  echo "  Preparación de servidor PostgreSQL externo"
  echo "=============================================="

  if [ ! -f /etc/redhat-release ]; then
    fail "Este script requiere Red Hat Enterprise Linux 8."
  fi
  RHEL_MAJOR=$(grep -oP '\d+' /etc/redhat-release | head -1)
  if [ "$RHEL_MAJOR" != "8" ]; then
    fail "Se requiere RHEL 8. Detectado: $(cat /etc/redhat-release)"
  fi
  ok "SO: $(cat /etc/redhat-release)"

  asegurar_suscripcion_redhat

  echo ""
  preguntar "IP o rango del Security Server que va a conectarse (ej: 10.20.2.6 o 10.20.2.0/24)" DB_ALLOWED_CIDR
  if [[ "$DB_ALLOWED_CIDR" != */* ]]; then
    DB_ALLOWED_CIDR="${DB_ALLOWED_CIDR}/32"
    info "Se interpretó como $DB_ALLOWED_CIDR (una sola IP)"
  fi

  PG_VERSION_EXISTENTE=$(rpm -qa 'postgresql*-server' 2>/dev/null | grep -oP '^postgresql\K[0-9]+' | sort -n | tail -1)
  if [ -n "$PG_VERSION_EXISTENTE" ]; then
    info "PostgreSQL $PG_VERSION_EXISTENTE ya está instalado acá. Solo se actualiza el acceso permitido."
    PG_VERSION="$PG_VERSION_EXISTENTE"
    PG_HBA="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
    if [ ! -f "$PG_HBA" ]; then
      fail "PostgreSQL $PG_VERSION está instalado pero no se encontró $PG_HBA. Revisá manualmente el estado de esta VM."
    fi
    if ! grep -q "$DB_ALLOWED_CIDR" "$PG_HBA" 2>/dev/null; then
      echo "host    all             all             ${DB_ALLOWED_CIDR}        md5" >> "$PG_HBA"
      restorecon -v "$PG_HBA" 2>/dev/null || true
    fi
    if ! systemctl restart "postgresql-${PG_VERSION}"; then
      diagnosticar_postgres "postgresql-${PG_VERSION}"
      rollback
    fi
    ok "Acceso permitido para $DB_ALLOWED_CIDR"

    IP_SERVIDOR=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^10\.0\.2\.' | head -1)
    if [ -z "$IP_SERVIDOR" ]; then
      IP_SERVIDOR=$(hostname -I | awk '{print $1}')
    fi
    echo ""
    echo "=============================================="
    echo -e "${GREEN}  Acceso a PostgreSQL actualizado${NC}"
    echo "=============================================="
    echo "  Host/IP         : $IP_SERVIDOR"
    echo "  Puerto          : 5432"
    echo "  Acceso permitido: $DB_ALLOWED_CIDR"
    echo "=============================================="
    exit 0
  fi

  preguntar_secreta "contraseña a definir para el superusuario postgres" DB_ROOT_PASS

  echo ""
  echo "--- Instalando PostgreSQL ---"
  PGDG_RPM_URL="https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
  dnf install -y "$PGDG_RPM_URL"
  if [ ! -f /etc/yum.repos.d/pgdg-redhat-all.repo ]; then
    dnf reinstall -y "$PGDG_RPM_URL"
  fi
  dnf -qy module disable postgresql 2>/dev/null || true

  PG_VERSION=$(dnf list available --refresh 'postgresql*-server' 2>/dev/null \
    | grep -oP '^postgresql\K[0-9]+(?=-server)' | sort -n | tail -1)
  if [ -z "$PG_VERSION" ]; then
    fail "No se encontró ningún paquete postgresqlNN-server disponible en el repo de PGDG."
  fi
  ok "Versión de PostgreSQL detectada: $PG_VERSION"

  dnf install -y "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}-contrib"
  ok "PostgreSQL $PG_VERSION instalado"

  "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb
  systemctl enable "postgresql-${PG_VERSION}"
  if ! systemctl start "postgresql-${PG_VERSION}"; then
    diagnosticar_postgres "postgresql-${PG_VERSION}"
    rollback
  fi
  ok "PostgreSQL $PG_VERSION inicializado y en ejecución"

  PG_HBA="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
  PG_CONF="/var/lib/pgsql/${PG_VERSION}/data/postgresql.conf"

  if ! grep -q "$DB_ALLOWED_CIDR" "$PG_HBA" 2>/dev/null; then
    echo "host    all             all             ${DB_ALLOWED_CIDR}        md5" >> "$PG_HBA"
  fi
  ok "Acceso remoto habilitado en pg_hba.conf para ${DB_ALLOWED_CIDR}"

  sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
  ok "listen_addresses configurado en postgresql.conf"
  restorecon -v "$PG_HBA" "$PG_CONF" 2>/dev/null || true

  if ! systemctl restart "postgresql-${PG_VERSION}"; then
    diagnosticar_postgres "postgresql-${PG_VERSION}"
    rollback
  fi
  ok "PostgreSQL reiniciado"

  sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_ROOT_PASS}';"
  ok "Contraseña de superusuario postgres configurada"

  if ! systemctl is-active firewalld &>/dev/null; then
    dnf install -y firewalld
    systemctl enable firewalld
    systemctl start firewalld
  fi
  firewall-cmd --zone=public --add-port=5432/tcp --permanent 2>/dev/null
  firewall-cmd --reload 2>/dev/null
  ok "Puerto 5432/tcp habilitado en firewall"

  IP_SERVIDOR=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^10\.0\.2\.' | head -1)
  if [ -z "$IP_SERVIDOR" ]; then
    IP_SERVIDOR=$(hostname -I | awk '{print $1}')
  fi
  echo ""
  echo "=============================================="
  echo -e "${GREEN}  Servidor de Base de Datos preparado${NC}"
  echo "=============================================="
  echo "  Host/IP         : $IP_SERVIDOR"
  echo "  Puerto          : 5432"
  echo "  Usuario         : postgres"
  echo "  Acceso permitido: $DB_ALLOWED_CIDR"
  echo ""
  echo "  Usá estos datos al instalar el Security Server"
  echo "  (opción 'Externa' de base de datos)."
  echo "  Las bases serverconf/messagelog/opmonitor las crea"
  echo "  automáticamente el instalador del Security Server"
  echo "  al conectarse por primera vez."
  echo ""
  echo "  Para probar la conexión ANTES de instalar el Security"
  echo "  Server, corré esto desde esa otra VM (no desde acá):"
  echo "    dnf install -y postgresql"
  echo "    psql -h $IP_SERVIDOR -U postgres -p 5432 -c '\\conninfo'"
  echo "=============================================="
  exit 0
fi

echo ""
echo "--- Datos del organismo ---"
info "Estos datos son provistos por el equipo de X-BA del GCBA."
echo ""

while true; do
  echo "  Seleccione el ambiente:"
  echo "  [1] QA"
  echo "  [2] HML - Homologación"
  echo "  [3] PRD - Producción"
  echo ""
  read -p "  Opción (1/2/3): " OPT </dev/tty
  case $OPT in
    1)
      AMBIENTE="qa"
      AMBIENTE_LABEL="QA"
      CENTRAL_SERVER="xroad-central-qa.gcba.gob.ar"
      MSS_SERVER="xroad-mss-qa.gcba.gob.ar"
      break ;;
    2)
      AMBIENTE="hml"
      AMBIENTE_LABEL="HML - Homologación"
      CENTRAL_SERVER="xroad-central-hml.gcba.gob.ar"
      MSS_SERVER="xroad-mss-hml.gcba.gob.ar"
      break ;;
    3)
      AMBIENTE="prd"
      AMBIENTE_LABEL="PRD - Producción"
      CENTRAL_SERVER="xroad-central.buenosaires.gob.ar"
      MSS_SERVER="xroad-mss.buenosaires.gob.ar"
      break ;;
    *) warn "Opción inválida, ingrese 1, 2 o 3." ; echo "" ;;
  esac
done
read -p "  Confirme ambiente [$AMBIENTE_LABEL] (s/n): " CONFIRM </dev/tty
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
  fail "Instalación cancelada. Volvé a ejecutar el script."
fi
ok "Ambiente: $AMBIENTE_LABEL"

preguntar "Server Code (dato provisto por X-BA, ej: PRD001JUS)" SERVER_CODE
SERVER_CODE=$(echo "$SERVER_CODE" | tr '[:lower:]' '[:upper:]')
ok "Server Code: $SERVER_CODE"

echo ""
echo "--- Base de datos ---"
info "Ver sección 4.3 del manual si vas a usar un servidor PostgreSQL externo."
echo ""
while true; do
  echo "  Seleccione el modo de base de datos:"
  echo "  [1] Interna (la crea el instalador de X-Road, en esta misma VM)"
  echo "  [2] Externa (servidor PostgreSQL ya preparado en otro host)"
  echo ""
  read -p "  Opción (1/2): " DB_OPT </dev/tty
  case $DB_OPT in
    1) DB_MODE="interna"; DB_MODE_LABEL="Interna"; break ;;
    2) DB_MODE="externa"; DB_MODE_LABEL="Externa"; break ;;
    *) warn "Opción inválida, ingrese 1 o 2." ; echo "" ;;
  esac
done

if [ "$DB_MODE" == "externa" ]; then
  preguntar "IP o host del servidor PostgreSQL externo" DB_HOST
  preguntar "puerto de PostgreSQL" DB_PORT
  preguntar "usuario superusuario de PostgreSQL (ej: postgres)" DB_SUPERUSER
  preguntar_secreta "contraseña del superusuario de PostgreSQL" DB_SUPERUSER_PASS
  DB_PREFIX=$(echo "$SERVER_CODE" | tr '[:upper:]' '[:lower:]')
  info "Se usarán bases/esquemas/usuarios con el prefijo '$DB_PREFIX' (ej: serverconf_$DB_PREFIX)"
  preguntar_secreta "contraseña para los usuarios de aplicación (serverconf_$DB_PREFIX, messagelog_$DB_PREFIX, opmonitor_$DB_PREFIX)" DB_APP_PASS
  ok "Base de datos externa: $DB_HOST:$DB_PORT"
else
  ok "Base de datos interna"
fi

echo ""
echo "=============================================="
echo "  Resumen de configuración"
echo "=============================================="
echo "  Ambiente        : $AMBIENTE_LABEL"
echo "  Central Server  : $CENTRAL_SERVER"
echo "  Server Code     : $SERVER_CODE"
echo "  Base de datos   : $DB_MODE_LABEL"
if [ "$DB_MODE" == "externa" ]; then
echo "                    ($DB_HOST:$DB_PORT)"
fi
echo "=============================================="
echo ""
read -p "¿Los datos son correctos? ¿Desea continuar? (s/n): " CONFIRM </dev/tty
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
  fail "Instalación cancelada. Volvé a ejecutar el script."
fi

echo ""
echo "--- Verificando requisitos del sistema ---"

if [ ! -f /etc/redhat-release ]; then
  fail "Este script requiere Red Hat Enterprise Linux 8."
fi
RHEL_MAJOR=$(grep -oP '\d+' /etc/redhat-release | head -1)
if [ "$RHEL_MAJOR" != "8" ]; then
  fail "Se requiere RHEL 8. Detectado: $(cat /etc/redhat-release)"
fi
ok "SO: $(cat /etc/redhat-release)"

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$RAM_MB" -lt 3900 ]; then
  fail "RAM insuficiente: ${RAM_MB} MB. Se requieren al menos 4 GB."
fi
ok "RAM: ${RAM_MB} MB"

DISK_GB=$(df / | awk 'NR==2{printf "%d", $4/1024/1024}')
if [ "$DISK_GB" -lt 2 ]; then
  fail "Espacio insuficiente: ${DISK_GB} GB libres. Se requieren al menos 60 GB."
fi
ok "Disco: ${DISK_GB} GB libres"

asegurar_suscripcion_redhat

echo ""
echo "--- Verificando conectividad ---"

if ! curl -s --max-time 10 https://artifactory.niis.org > /dev/null; then
  warn "Sin acceso al repositorio de X-Road (artifactory.niis.org). El servidor necesita salida a internet."
fi
ok "Salida a internet OK"

for PUERTO in 4001 80; do
  if nc -zw5 "$CENTRAL_SERVER" "$PUERTO" 2>/dev/null; then
    ok "Conectividad a $CENTRAL_SERVER:$PUERTO OK"
  else
    warn "Sin conectividad a $CENTRAL_SERVER:$PUERTO. Solicitá la apertura del puerto a la mesa de ayuda antes de continuar."
  fi
done

for PUERTO in 5500 5577; do
  if nc -zw5 "$MSS_SERVER" "$PUERTO" 2>/dev/null; then
    ok "Conectividad a $MSS_SERVER:$PUERTO OK"
  else
    warn "Sin conectividad a $MSS_SERVER:$PUERTO. Solicitá la apertura del puerto a la mesa de ayuda antes de continuar."
  fi
done

for PUERTO in 80 443 4000 5500 5577 8080; do
  if ss -tlnp | grep -q ":${PUERTO} "; then
    warn "Puerto ${PUERTO} ya está en uso. Puede generar conflictos."
  else
    ok "Puerto ${PUERTO} disponible"
  fi
done

echo ""
echo "--- Preparando sistema operativo ---"

if ! grep -q "LC_ALL=en_US.UTF-8" /etc/environment 2>/dev/null; then
  echo "LC_ALL=en_US.UTF-8" >> /etc/environment
fi
export LC_ALL=en_US.UTF-8
ok "Locale configurado (LC_ALL=en_US.UTF-8)"

RHEL_MAJOR_VERSION=$(source /etc/os-release; echo ${VERSION_ID%.*})

dnf install -y yum-utils nc
ok "yum-utils instalado"

echo ""
echo "--- Verificando Java 21 ---"

JAVA_VER=$(java -version 2>&1 | grep -oP '"\K[^"]+' | head -1 | cut -d. -f1)
if [ "$JAVA_VER" != "21" ]; then
  info "Java 21 no está configurado como default. Instalando..."
  if dnf install -y java-21-openjdk 2>/dev/null; then
    alternatives --set java java-21-openjdk.x86_64 2>/dev/null || true
  else
    info "java-21-openjdk no está disponible en los repos de RHEL. Instalando Eclipse Temurin 21..."
    ADOPTIUM_ID=$(. /etc/os-release; echo "$ID")
    cat > /etc/yum.repos.d/adoptium.repo << EOF
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/${ADOPTIUM_ID}/${RHEL_MAJOR}/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
    dnf install -y temurin-21-jdk
    TEMURIN_JAVA=$(rpm -ql temurin-21-jdk | grep '/bin/java$' | head -1)
    if [ -n "$TEMURIN_JAVA" ]; then
      alternatives --set java "$TEMURIN_JAVA" 2>/dev/null || true
    fi
  fi
fi
JAVA_VER=$(java -version 2>&1 | grep -oP '"\K[^"]+' | head -1 | cut -d. -f1)
if [ "$JAVA_VER" != "21" ]; then
  fail "No se pudo configurar Java 21 como versión activa. Revisá: alternatives --config java"
fi
ok "Java $(java -version 2>&1 | grep -oP '"\K[^"]+' | head -1)"

echo ""
echo "--- Configurando repositorios ---"

cat > /etc/yum.repos.d/epel.repo << 'EPELREPO'
[epel]
name=Extra Packages for Enterprise Linux 8 - x86_64
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-8&arch=x86_64&infra=$infra&content=$contentdir
enabled=1
gpgcheck=1
countme=1
gpgkey=https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-8
EPELREPO
ok "Repositorio EPEL configurado"

yum-config-manager --add-repo https://artifactory.niis.org/xroad-release-rpm/rhel/${RHEL_MAJOR_VERSION}/7.6.4/
rpm --import https://artifactory.niis.org/api/gpg/key/public
ok "Repositorio X-Road 7.6.4 configurado"

dnf makecache
ok "Caché de repositorios actualizado"

if [ "$DB_MODE" == "externa" ]; then
  echo ""
  echo "--- Configurando conexión a base de datos externa ---"

  dnf install -y xroad-database-remote
  ok "xroad-database-remote instalado"

  echo ""
  echo "--- Verificando conexión a la base de datos externa ---"
  DB_TEST_LOG=$(mktemp)
  if ! PGPASSWORD="$DB_SUPERUSER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_SUPERUSER" -c '\q' >"$DB_TEST_LOG" 2>&1; then
    cat "$DB_TEST_LOG"
    rm -f "$DB_TEST_LOG"
    MI_IP=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^10\.0\.2\.' | head -1)
    warn "No se pudo conectar a ${DB_HOST}:${DB_PORT} con el usuario ${DB_SUPERUSER}."
    warn "Revisá en ese servidor que pg_hba.conf permita la IP de ESTA VM (${MI_IP}), y que host/puerto/usuario/contraseña sean correctos."
    rollback
  fi
  rm -f "$DB_TEST_LOG"
  ok "Conexión a la base de datos externa verificada"

  touch /etc/xroad.properties
  chown root:root /etc/xroad.properties
  chmod 600 /etc/xroad.properties
  cat > /etc/xroad.properties << PROPS
postgres.connection.password = ${DB_SUPERUSER_PASS}
postgres.connection.user = ${DB_SUPERUSER}
PROPS
  ok "/etc/xroad.properties configurado"

  mkdir -p /etc/xroad
  touch /etc/xroad/db.properties
  chmod 0640 /etc/xroad/db.properties
  chown xroad:xroad /etc/xroad/db.properties 2>/dev/null || true

  cat > /etc/xroad/db.properties << DBPROPS
serverconf.hibernate.jdbc.use_streams_for_binary = true
serverconf.hibernate.dialect = ee.ria.xroad.common.db.CustomPostgreSQLDialect
serverconf.hibernate.connection.driver_class = org.postgresql.Driver
serverconf.hibernate.connection.url = jdbc:postgresql://${DB_HOST}:${DB_PORT}/serverconf_${DB_PREFIX}
serverconf.hibernate.hikari.dataSource.currentSchema = serverconf_${DB_PREFIX},public
serverconf.hibernate.connection.username = serverconf_${DB_PREFIX}
serverconf.hibernate.connection.password = ${DB_APP_PASS}

messagelog.hibernate.jdbc.use_streams_for_binary = true
messagelog.hibernate.connection.driver_class = org.postgresql.Driver
messagelog.hibernate.connection.url = jdbc:postgresql://${DB_HOST}:${DB_PORT}/messagelog_${DB_PREFIX}
messagelog.hibernate.hikari.dataSource.currentSchema = messagelog_${DB_PREFIX},public
messagelog.hibernate.connection.username = messagelog_${DB_PREFIX}
messagelog.hibernate.connection.password = ${DB_APP_PASS}

op-monitor.hibernate.jdbc.use_streams_for_binary = true
op-monitor.hibernate.connection.driver_class = org.postgresql.Driver
op-monitor.hibernate.connection.url = jdbc:postgresql://${DB_HOST}:${DB_PORT}/opmonitor_${DB_PREFIX}
op-monitor.hibernate.hikari.dataSource.currentSchema = opmonitor_${DB_PREFIX},public
op-monitor.hibernate.connection.username = opmonitor_${DB_PREFIX}
op-monitor.hibernate.connection.password = ${DB_APP_PASS}
DBPROPS
  ok "/etc/xroad/db.properties configurado (host: ${DB_HOST}:${DB_PORT})"
fi

echo ""
echo "--- Instalando X-Road Security Server ---"
echo "    (esto puede tardar varios minutos, se muestra el progreso)"
echo ""

if [ "$DB_MODE" != "externa" ]; then
  dnf install -y postgresql-server postgresql-contrib
  ok "postgresql-server instalado (requisito previo para la base interna en X-Road 7.6+)"
fi

dnf install -y xroad-securityserver
if [ "$DB_MODE" == "externa" ]; then
  ok "xroad-securityserver instalado (usando base de datos externa configurada en el paso anterior)"
else
  ok "xroad-securityserver instalado (incluye base de datos interna)"
fi

dnf install -y xroad-addon-opmonitoring
ok "xroad-addon-opmonitoring instalado"

if [ "$DB_MODE" == "externa" ]; then
  echo ""
  echo "--- Verificando que las bases de datos se hayan creado ---"
  DB_FALTANTES=""
  for DB in "serverconf_${DB_PREFIX}" "messagelog_${DB_PREFIX}" "opmonitor_${DB_PREFIX}"; do
    if ! PGPASSWORD="$DB_SUPERUSER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_SUPERUSER" -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw "$DB"; then
      DB_FALTANTES="$DB_FALTANTES $DB"
    fi
  done
  if [ -n "$DB_FALTANTES" ]; then
    warn "No se crearon estas bases en ${DB_HOST}:${DB_PORT}:${DB_FALTANTES}"
    warn "Revisá el log de arriba (buscá 'Creating database' o 'ERROR') y el pg_hba.conf del servidor de base de datos."
    warn "El Security Server NO va a funcionar hasta que esto se resuelva."
  else
    ok "Las 3 bases de datos existen en el servidor externo"
  fi
fi

dnf install -y xroad-autologin
ok "xroad-autologin instalado"

echo ""
echo "--- Creando usuario administrador de la plataforma ---"
info "Este usuario es el que se usa para entrar a la UI de X-Road."
echo ""

preguntar "nombre de usuario para la UI (ej: xroadadmin)" XROAD_USER
while true; do
  xroad-add-admin-user "$XROAD_USER" </dev/tty && break
  warn "No se pudo crear/configurar el usuario $XROAD_USER (¿la contraseña no coincidió?). Intentá de nuevo."
done
echo ""
info "Ahora definí la contraseña para el usuario $XROAD_USER:"
while true; do
  passwd "$XROAD_USER" </dev/tty && break
  warn "Las contraseñas no coincidieron. Intentá de nuevo."
done
ok "Usuario $XROAD_USER creado con permisos de administración"

echo ""
echo "--- Aplicando configuración ---"

mkdir -p /etc/xroad/conf.d

cat > /etc/xroad/conf.d/local.ini << INI
[proxy]
client-http-port=80
client-https-port=443
INI

chown xroad:xroad /etc/xroad/conf.d/local.ini
chmod 640 /etc/xroad/conf.d/local.ini
ok "local.ini configurado (puertos 80/443)"

cat > /etc/xroad/organismo.conf << CONF
AMBIENTE=$AMBIENTE
SERVER_CODE=$SERVER_CODE
CENTRAL_SERVER=$CENTRAL_SERVER
MSS_SERVER=$MSS_SERVER
DB_MODE=$DB_MODE
DB_HOST=$DB_HOST
CONF
ok "Datos del organismo guardados en /etc/xroad/organismo.conf"

echo ""
echo "--- Configurando firewall ---"

if ! systemctl is-active firewalld &>/dev/null; then
  dnf install -y firewalld
  systemctl enable firewalld
  systemctl start firewalld
fi

for PUERTO in 80/tcp 443/tcp 4000/tcp 5500/tcp 5577/tcp 8080/tcp; do
  firewall-cmd --zone=public --add-port=$PUERTO --permanent 2>/dev/null
  ok "Puerto $PUERTO habilitado en firewall"
done
firewall-cmd --reload 2>/dev/null

echo ""
echo "--- Iniciando servicios ---"

SERVICIOS=(
  xroad-signer
  xroad-base
  xroad-confclient
  xroad-proxy
  xroad-proxy-ui-api
  xroad-monitor
  xroad-addon-messagelog
)

for SERVICIO in "${SERVICIOS[@]}"; do
  systemctl enable "$SERVICIO" --now 2>/dev/null && ok "$SERVICIO" || warn "$SERVICIO no pudo iniciarse"
done

systemctl daemon-reload

sleep 5
systemctl restart xroad-proxy-ui-api
ok "xroad-proxy-ui-api reiniciado"

echo ""
echo "--- Verificando funcionamiento ---"

trap - ERR
sleep 25

HTTP_CODE=$(curl -sk --max-time 20 https://localhost:4000 -o /dev/null -w "%{http_code}")
if echo "$HTTP_CODE" | grep -qE "200|302|401"; then
  ok "UI de X-Road respondiendo en puerto 4000 (HTTP $HTTP_CODE)"
else
  warn "La UI no responde todavía en puerto 4000. Puede necesitar unos minutos más."
  warn "Verificá luego con: curl -sk https://localhost:4000 -o /dev/null -w '%{http_code}'"
fi

if ss -tlnp | grep -q ":5500 "; then
  ok "Puerto externo 5500 escuchando"
else
  warn "Puerto 5500 no está escuchando. Revisá: systemctl status xroad-proxy"
fi

echo ""
echo "--- Estado de servicios ---"
for SERVICIO in "${SERVICIOS[@]}"; do
  STATUS=$(systemctl is-active "$SERVICIO" 2>/dev/null)
  if [ "$STATUS" == "active" ]; then
    ok "$SERVICIO: activo"
  else
    warn "$SERVICIO: $STATUS"
  fi
done

IP_SERVIDOR=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^10\.0\.2\.' | head -1)
if [ -z "$IP_SERVIDOR" ]; then
  IP_SERVIDOR=$(hostname -I | awk '{print $1}')
fi
FECHA=$(date '+%d/%m/%Y %H:%M:%S')

echo ""
echo "=============================================="
echo -e "${GREEN}  Instalación completada correctamente${NC}"
echo "=============================================="
echo ""
echo "  Fecha           : $FECHA"
echo "  Hostname        : $(hostname)"
echo "  IP              : $IP_SERVIDOR"
echo "  Ambiente        : $AMBIENTE_LABEL"
echo "  Central Server  : $CENTRAL_SERVER"
echo "  Server Code     : $SERVER_CODE"
echo "  Base de datos   : $DB_MODE_LABEL"
echo "  URL de admin    : https://${IP_SERVIDOR}:4000"
echo "  Usuario UI      : $XROAD_USER"
echo ""
echo "  PASOS MANUALES PENDIENTES (desde la UI):"
echo "  1. Acceder a https://${IP_SERVIDOR}:4000"
echo "     Usuario: $XROAD_USER (contraseña definida en la instalación)"
echo "  2. Cargar el Anchor File (solicitarlo a X-BA)"
echo "  3. Ingresar los datos provistos por X-BA:"
echo "     Member Class, Member Code y Server Code"
echo "  4. Definir el PIN del Signer (guardarlo: NO se puede cambiar)"
echo "  5. Keys and Certificates → Add Key:"
echo "     - Key AUTH: label AUTH, Usage AUTHENTICATION, CSR Format DER"
echo "     - Key SIGN: label SIGN, Usage SIGNING, CSR Format DER"
echo "  6. Enviar los CSR generados a Seguridad Informática de ASI"
echo "  7. Al recibir los certificados firmados (.PEM), importarlos"
echo "     desde Keys and Certificates → Import Cert."
echo "  8. Activar los certificados y hacer Register del AUTH"
echo "     con la IP o DNS de este Security Server"
echo "  9. Configurar Timestamping: Settings → System Parameters"
echo "     Seleccionar *.buenosaires.gob.ar"
echo " 10. Esperar la aprobación del Management Request en el Central Server"
echo ""
echo "  *** Enviá el contenido completo de esta pantalla"
echo "  *** al equipo de X-BA para validar la instalación."
echo "=============================================="
