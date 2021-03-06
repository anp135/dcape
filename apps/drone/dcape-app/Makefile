## dcape app Makefile
#:
SHELL      = /bin/sh
CFG       ?= .env
CFGSAMPLE ?= $(CFG).sample
DOT       := .
DASH      := -

IMAGE_VER       ?= latest
APP_SITE        ?= lib.dev.lan
APP_TAG         ?= $(subst $(DOT),$(DASH),$(APP_SITE))
USE_TLS         ?= false
APP_ROOT        ?= $(PWD)
USER_NAME       ?= dcapeadmin
USER_EMAIL      ?= admin@$(APP_SITE)
USER_PASS       ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 | head -c14; echo)
PGDATABASE      ?= $(APP_NAME)
PGUSER          ?= $(APP_NAME)
PGPASSWORD      ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 | head -c14; echo)
PG_DUMP_SOURCE  ?=
DCAPE_TAG       ?= dcape
DCAPE_NET       ?= $(DCAPE_TAG)
PG_CONTAINER    ?= $(DCAPE_TAG)_db_1
DCAPE_COMPOSE   ?= $(DCAPE_TAG)-compose
DCAPE_DC_YML    ?= /opt/dcape-app/docker-compose.yml
DCAPE_APP_DC_YML?= docker-compose.yml
DCAPE_DC_USED   ?= true
DB_INIT_SQL     ?= schema.sql
PERSIST_FILES   ?=
# Empty or 'keep'
SETUP_ROOT_OPTS ?=

# ------------------------------------------------------------------------------
# .env template
define CONFIG_DEF
# app config file, generated by make config

# website host
APP_SITE=$(APP_SITE)

# Unique traefik router name
# Container name prefix
# Value is optional, derived from APP_SITE if empty
# APP_TAG=$(APP_TAG)

# Enable tls in traefik
# Values: [false]|true
USE_TLS=$(USE_TLS)
# app image name
IMAGE=$(IMAGE)
# app image version
IMAGE_VER=$(IMAGE_VER)
#
endef
#export CONFIG_DEF

ifeq ($(ADD_USER),yes)

define CONFIG_USER

# ------------------------------------------------------------------------------
# Admin user name
USER_NAME=$(USER_NAME)
# Admin user email
USER_EMAIL=$(USER_EMAIL)
# Admin user password
USER_PASS=$(USER_PASS)
#
endef
export CONFIG_USER

endif
# -----------------------------------------------------------------------------

-include $(CFG).bak
export

-include $(CFG)
export

.PHONY: all up down dc .docker-wait db-create db-drop psql init config .drone-default help

all: help

# -----------------------------------------------------------------------------
## Docker-compose commands
#:

## (re)start container
up:
up: CMD=up --force-recreate -d
up: dc

## stop (and remove) container
down:
down: CMD=rm -f -s
down: dc

# $$PWD usage allows host directory mounts in child containers
# Thish works if path is the same for host, docker, docker-compose and child container
## run $(CMD) via docker-compose
dc: $(DCAPE_APP_DC_YML)
	@echo $(APP_TAG)
	@[ "$(DCAPE_DC_USED)" != true ] || args="-f $(DCAPE_DC_YML)" ; \
  docker run --rm  -t -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $$PWD:$$PWD -w $$PWD \
  -e DCAPE_TAG -e DCAPE_NET -e APP_ROOT -e APP_TAG \
  $(DCAPE_COMPOSE) \
  -p $$APP_TAG --env-file $(CFG) \
  $$args -f $(DCAPE_APP_DC_YML) $(CMD)

# ------------------------------------------------------------------------------
## DB operations
#:

ifeq ($(USE_DB),yes)

define CONFIG_DB

# ------------------------------------------------------------------------------
# Database name
PGDATABASE=$(PGDATABASE)
# Database user name
PGUSER=$(PGUSER)
# Database user password
PGPASSWORD=$(PGPASSWORD)
# Database dump for import on create
# Used as ${PG_DUMP_SOURCE}.{tar|tgz}
PG_DUMP_SOURCE=$(PG_DUMP_SOURCE)
#
endef
endif

# Database import script
# DCAPE_DB_DUMP_DEST must be set in pg container
# zcat pipe may cause "terminated by signal 13" error, so .tar is also supported
define IMPORT_SCRIPT
[ "$$DCAPE_DB_DUMP_DEST" ] || { echo "DCAPE_DB_DUMP_DEST not set. Exiting" ; exit 1 ; } ; \
DB_NAME="$$1" ; DB_USER="$$2" ; DB_PASS="$$3" ; DB_SOURCE="$$4" ; \
dbsrc=$$DCAPE_DB_DUMP_DEST/$$DB_SOURCE ; \
if [ -f $${dbsrc}.tgz ] ; then \
  echo "Dump file $${dbsrc}.tgz found, restoring database..." ; \
  zcat $${dbsrc}.tgz | PGPASSWORD=$$DB_PASS pg_restore -h localhost -U $$DB_USER -O -Ft -d $$DB_NAME || exit 1 ; \
elif [ -f $${dbsrc}.tar ] ; then \
  echo "Dump file $${dbsrc}.tar found, restoring database..." ; \
  PGPASSWORD=$$DB_PASS pg_restore -h localhost -U $$DB_USER -O -d $$DB_NAME $${dbsrc}.tar || exit 1 ; \
else \
  echo "Dump file $$dbsrc not found" ; \
  exit 2 ; \
fi
endef
export IMPORT_SCRIPT

# wait for postgresql container start
.docker-wait:
ifeq ($(USE_DB),yes)
	@echo -n "Checking PG is ready..."
	@until [ `docker inspect -f "{{.State.Health.Status}}" $$PG_CONTAINER` = "healthy" ] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"
endif

## create user, db and load dump
db-create: .docker-wait
ifeq ($(USE_DB),yes)
	@echo "*** $@ ***" ; \
	sql="CREATE USER \"$$PGUSER\" WITH PASSWORD '$$PGPASSWORD'" ; \
	docker exec -i $$PG_CONTAINER psql -U postgres -c "$$sql" 2>&1 > .psql.log | grep -v "already exists" > /dev/null || true ; \
	cat .psql.log ; \
	docker exec -i $$PG_CONTAINER psql -U postgres -c "CREATE DATABASE \"$$PGDATABASE\" OWNER \"$$PGUSER\";" 2>&1 > .psql.log | grep  "already exists" > /dev/null || db_created=1 ; \
	cat .psql.log ; rm .psql.log ; \
	if [ "$$db_created" = "1" ] ; then \
	  if [ "$$PG_DUMP_SOURCE" ] ; then \
	    echo "*** db data load" ; \
	    echo "$$IMPORT_SCRIPT" | docker exec -i $$PG_CONTAINER bash -s - $$PGDATABASE $$PGUSER $$PGPASSWORD $$PG_DUMP_SOURCE \
	    && docker exec -i $$PG_CONTAINER psql -U postgres -c "COMMENT ON DATABASE \"$$PGDATABASE\" IS 'SOURCE $$PG_DUMP_SOURCE';" \
	    || true ; \
	  elif [ -f $(DB_INIT_SQL) ] ; then \
	      cat $(DB_INIT_SQL) | docker exec -i $$PG_CONTAINER psql -U postgres -d $$PGDATABASE -vPGUSER=$$PGUSER; \
	  fi \
	fi
else
	@echo "Target '$@' is disabled in app config"
endif

db-load: $(DB_INIT_SQL)
	cat $< | docker exec -i $$PG_CONTAINER psql -U postgres -d $$PGDATABASE

## drop database and user
db-drop: .docker-wait
ifeq ($(USE_DB),yes)
	@echo "*** $@ ***"
	@docker exec -it $$PG_CONTAINER psql -U postgres -c "DROP DATABASE \"$$PGDATABASE\";" || true
	@docker exec -it $$PG_CONTAINER psql -U postgres -c "DROP USER \"$$PGUSER\";" || true
else
	@echo "Target '$@' is disabled in app config"
endif

## run psql for app database
psql: .docker-wait
ifeq ($(USE_DB),yes)
	@docker exec -it $$PG_CONTAINER psql -U $$PGUSER $$PGDATABASE
else
	@echo "Target '$@' is disabled in app config"
endif

# ------------------------------------------------------------------------------
## Application setup
#:

## generate config file
## (if not exists)
init:
	@[ -f $(CFG) ] && { echo "$(CFG) already exists. Skipping" ; exit 0 ; } || true
	@echo "$$CONFIG_DEF" > $(CFG)

## generate config sample
## (if .env exists, its values will be used)
config: $(CFGSAMPLE)

$(CFGSAMPLE):
	@echo "$$CONFIG_DEF$$CONFIG_DB$$CONFIG_USER$$CONFIG_CUSTOM" > $@

# -----------------------------------------------------------------------------

## run app by drone,
## use inside .drone.yml only
.drone-default:
	@echo "*** $@ ***" ; \
	[ "$$USE_DB" != "yes" ] || $(MAKE) -s db-create ; \
	if [ ! -z "$$PERSIST_FILES" ] ; then \
	  . setup root $(SETUP_ROOT_OPTS) ; \
	  cp -r $$PERSIST_FILES $$APP_ROOT ; \
	fi ; \
	[ "$(DCAPE_DC_USED)" != true ] || args="-f $(DCAPE_DC_YML)" ; \
	  docker-compose -p $(APP_TAG) --env-file $(CFG) $$args -f $(DCAPE_APP_DC_YML) up -d --force-recreate

# ------------------------------------------------------------------------------
## Other
#:

# This code handles group header and target comment with one or two lines only
## list Makefile targets
## (this is default target)
help:
	@grep -A 1 -h "^## " $(MAKEFILE_LIST) \
  | sed -E 's/^--$$// ; /./{H;$$!d} ; x ; s/^\n## ([^\n]+)\n(## (.+)\n)*(.+):(.*)$$/"    " "\4" "\1" "\3"/' \
  | sed -E 's/^"    " "#" "(.+)" "(.*)"$$/"" "" "" ""\n"\1 \2" "" "" ""/' \
  | xargs printf "%s\033[36m%-15s\033[0m %s %s\n"
