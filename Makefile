# dcape Makefile
SHELL             = /bin/bash
CFG               = .env
CFG_BAK          ?= $(CFG).bak
DCAPE_USED        = 1

TZ               ?= $(shell cat /etc/timezone)
DCINC             = docker-compose.inc.yml

# check this files for update docker-compose.yml
DCFILES           = $(shell find apps/ -name $(DCINC) -print | sort)

PROJECT_NAME     ?= dcape
DOMAIN           ?= dev.lan
APPS_SYS         ?= db
APPS             ?= traefik portainer enfist cis

# dcape directory
PWD              ?= $(PWD)

# section env for use with pg_upgrade with tianon/docker-postgres-upgrade container
# PG version number - ATTENTION:number only from existing on docker-image tags
# https://hub.docker.com/r/tianon/postgres-upgrade/tags/
PG_VER           ?= 9.6
# number for new PG image version - also number from available in tags
PG_NEW_VER       ?= 11

# Postgresql Database image
PG_IMAGE         ?= postgres:$(PG_VER)-alpine
# Postgresql Database superuser password
PG_DB_PASS       ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 2>/dev/null | head -c14; echo)
# Postgresql Database encoding
PG_ENCODING      ?= en_US.UTF-8
# port on localhost postgresql listen on
PG_PORT_LOCAL    ?= 5433
# Dump name suffix to load on db-create
PG_SOURCE_SUFFIX ?=

# Docker-compose image tag
DC_VER           ?= 1.21.2

# Config store url
ENFIST_URL       ?= http://enfist:8080/rpc

# ------------------------------------------------------------------------------

define CONFIG_DEF
# dcape config file, generated by make $(CFG)

# General settings

# dcape directory
PWD=$(PWD)

# containers name prefix
PROJECT_NAME=$(PROJECT_NAME)

# Default domain
DOMAIN=$(DOMAIN)

# App list, for use in make only
APPS="$(shell echo $(APPS))"

# create db cluster with this timezone
# (also used by gitea container)
TZ=$(TZ)

# PG version number - ATTENTION:number only from existing on docker-image tags
# https://hub.docker.com/r/tianon/postgres-upgrade/tags/
PG_VER=$(PG_VER)
# Number for new PG image version - also number from available in tags
PG_NEW_VER=$(PG_NEW_VER)

# Postgresql Database image
PG_IMAGE=$(PG_IMAGE)
# Postgresql Database superuser password
PG_DB_PASS=$(PG_DB_PASS)
# Postgresql Database encoding
PG_ENCODING=$(PG_ENCODING)
# port on localhost postgresql listen on
PG_PORT_LOCAL=$(PG_PORT_LOCAL)

endef
export CONFIG_DEF

# ------------------------------------------------------------------------------

# if exists - load old values
-include $(CFG_BAK)
export

-include $(CFG)
export

.PHONY: deps init-master init-slave init-local init apply up reup down dc db-create db-drop env-get env-set help

# ------------------------------------------------------------------------------

all: help

include apps/*/Makefile

## установка зависимостей
deps:
	@echo "*** $@ ***"
	@sudo apt-get update && sudo apt-get install -y \
	  gawk wget curl apache2-utils openssh-client docker-engine

## Init internet server with gitea
init-master: APPS = traefik-acme gitea portainer enfist cis
init-master: init

## Init internet server without gitea
init-slave: APPS = traefik-acme portainer enfist cis
init-slave: init

## Init local server
init-local: APPS = traefik gitea portainer enfist cis
init-local: init


## Initially create .enc file with defaults
init:
	@echo "*** $@ $(APPS) ***"
	@[ -d var/data ] || mkdir -p var/data
	@[ -f .env ] && { echo ".env already exists. Skipping" ; exit 1 ; } || true
	@echo "$$CONFIG_DEF" > .env
	@for f in $(shell echo $(APPS)) ; do echo $$f ; $(MAKE) -s $${f}-init ; done

## Apply config to app files & db
apply:
	@echo "*** $@ $(APPS) ***"
	@$(MAKE) -s dc CMD="up -d $(APPS_SYS)" || echo ""
	@for f in $(shell echo $(APPS)) ; do $(MAKE) -s $${f}-apply ; done

pg_upgrade:
	@echo "*** $@ *** postgresql from $(PG_VER) to $(PG_NEW_VER)"
	@echo -n "Checking PG is down..." ; \
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	docker exec -i $$DCAPE_DB psql -U postgres -V && db_run=1 ; \
	if [[ $$db_run ]] ; then \
        echo "Postgres container not stop. Exit" && exit 1 ; \
      else \
        echo "Postgres container not run. Continue" ; \
	fi
	@mkdir ./var/data/db_$$PG_NEW_VER ; \
	docker pull tianon/postgres-upgrade:$$PG_VER-to-$$PG_NEW_VER ; \
	docker run --rm \
      -v $$PWD/var/data/db_$$PG_VER:/var/lib/postgresql/$$PG_VER/data \
      -v $$PWD/var/data/db_$$PG_NEW_VER:/var/lib/postgresql/$$PG_NEW_VER/data \
      tianon/postgres-upgrade:$$PG_VER-to-$$PG_NEW_VER ; \
	@echo "If the process succeeds, change the PG_VER variable to a new version, pg_hba.conf and start dcape. For more info see https://github.com/dopos/dcape/blob/master/POSTGRES.md"


# build file from app templates
docker-compose.yml: $(DCINC) $(DCFILES)
	@echo "*** $@ ***"
	@echo "# WARNING! This file was generated by make. DO NOT EDIT" > $@
	@cat $(DCINC) >> $@
	@for f in $(shell echo $(APPS)) ; do cat apps/$$f/$(DCINC) >> $@ ; done

## старт контейнеров
up:
up: CMD=up -d $(APPS_SYS) $(shell echo $(APPS))
up: dc

## рестарт контейнеров
reup:
reup: CMD=up --force-recreate -d $(APPS_SYS) $(shell echo $(APPS))
reup: dc

## остановка и удаление всех контейнеров
down:
down: CMD=down
down: dc

# ------------------------------------------------------------------------------

# $$PWD используется для того, чтобы текущий каталог был доступен в контейнере по тому же пути
# и относительные тома новых контейнеров могли его использовать
## run docker-compose
dc: docker-compose.yml
	@docker run --rm -t -i \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $$PWD:$$PWD \
	  -w $$PWD \
	  docker/compose:$(DC_VER) \
	  -p $$PROJECT_NAME \
	  $(CMD)

# ------------------------------------------------------------------------------

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..." ; \
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	until [[ `docker inspect -f "{{.State.Health.Status}}" $$DCAPE_DB` == healthy ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"

# Database import script
# DCAPE_DB_DUMP_DEST must be set in pg container

define IMPORT_SCRIPT
[[ "$$DCAPE_DB_DUMP_DEST" ]] || { echo "DCAPE_DB_DUMP_DEST not set. Exiting" ; exit 1 ; } ; \
DB_NAME="$$1" ; DB_USER="$$2" ; DB_PASS="$$3" ; DB_SOURCE="$$4" ; \
dbsrc=$$DCAPE_DB_DUMP_DEST/$$DB_SOURCE.tgz ; \
if [ -f $$dbsrc ] ; then \
  echo "Dump file $$dbsrc found, restoring database..." ; \
  zcat $$dbsrc | PGPASSWORD=$$DB_PASS pg_restore -h localhost -U $$DB_USER -O -Ft -d $$DB_NAME || exit 1 ; \
else \
  echo "Dump file $$dbsrc not found" ; \
  exit 2 ; \
fi
endef
export IMPORT_SCRIPT

## create database and user
db-create: docker-wait
	@echo "*** $@ ***" \
	&& varname=$(NAME)_DB_PASS && pass=$${!varname} \
	&& varname=$(NAME)_DB_TAG && dbname=$${!varname} \
	&& DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE USER \"$$dbname\" WITH PASSWORD '$$pass';" \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE DATABASE \"$$dbname\" OWNER \"$$dbname\";" || db_exists=1 ; \
	if [[ ! "$$db_exists" ]] && [[ "$(PG_SOURCE_SUFFIX)" ]] ; then \
	    echo "$$IMPORT_SCRIPT" | docker exec -i $$DCAPE_DB bash -s - $$dbname $$dbname $$pass $$dbname$(PG_SOURCE_SUFFIX) \
	    && docker exec -i $$DCAPE_DB psql -U postgres -c "COMMENT ON DATABASE \"$$dbname\" IS 'SOURCE $$dbname$(PG_SOURCE_SUFFIX)';" \
	    || true ; \
	fi

## drop database and user
db-drop:
	@echo "*** $@ ***" \
	&& varname=$(NAME)_DB_TAG && dbname=$${!varname} \
	&& DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "DROP DATABASE \"$$dbname\";" \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "DROP USER \"$$dbname\";"

psql:
	@DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -it $$DCAPE_DB psql -U postgres

# ------------------------------------------------------------------------------
# .env file store

## get env tag from store, `make env-get TAG=app--config--tag`
env-get:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Getting env into $(TAG)"
	@docker exec -ti $${PROJECT_NAME}_webhook_1 curl -gs $${ENFIST_URL}/tag_vars?a_code=$(TAG) \
	  | jq -r '.result[0].tag_vars' > $(TAG).env

## set env tag in store, `make env-set TAG=app--config--tag`
env-set:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Setting $(TAG) from file" \
	&& jq -R -sc ". | {\"a_code\":\"$(TAG)\",\"a_data\":.}" < $(TAG).env | \
	  docker exec -i $${PROJECT_NAME}_webhook_1 curl -gsd @- $${ENFIST_URL}/tag_set > /dev/null

# ------------------------------------------------------------------------------

## delete unused docker images w/o name
clean-noname:
	docker rmi $$(docker images | grep "<none>" | awk "{print \$$3}")
#docker images -q -f dangling=true

## delete docker dangling volumes
clean-volume:
	docker volume rm $$(docker volume ls -qf dangling=true)

# ------------------------------------------------------------------------------

help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
