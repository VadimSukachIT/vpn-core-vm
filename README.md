# vpn-core-vm

Минимальный runtime-проект для схемы:

`Ubuntu VM -> k3s -> WireGuard container`

На этом этапе проект делает только базу:

- использует prebuilt контейнер с WireGuard runtime из `ghcr.io`
- поднимает `wg0` через `wg-quick`
- включает `ip_forward`
- публикует UDP `51820`
- позволяет одной командой развернуть runtime на Ubuntu VM через `bootstrap`-скрипт
- генерирует server config и peer pool прямо во время provisioning

Что пока не делаем:

- создание VM через provider API
- отправку конфигов в backend
- блокировку доменов
- ad-block
- metrics stack

Важно: всё это рассчитано на Linux VM. На macOS/Windows через Docker Desktop WireGuard smoke test может не работать.

## Минимальная структура

- `docker/` - контейнер WireGuard
- `config/runtime.env.example` - шаблон runtime-конфига
- `generated/` - автоматически созданные файлы
- `k3s/` - три manifest-файла для VM
- `scripts/` - главный bootstrap-скрипт
- `dev/` - локальный запуск уже готового runtime, если понадобится

## Главный сценарий

### 1. Подготовить `runtime.env`

Шаблон лежит в [config/runtime.env.example](/Users/vadimsukach/VSProjects/vpn-core-vm/config/runtime.env.example).

`vpn-core` должен копировать итоговый runtime config в:

`/opt/vpn-core-vm/runtime.env`

В публичную репу runtime-секреты не кладём.

### 2. Развернуть на Ubuntu VM одной командой

`vpn-core` уже делает такой сценарий:

- удаляет `/opt/vpn-core-vm`
- делает `git clone` репозитория в `/opt/vpn-core-vm`
- копирует runtime config в `/opt/vpn-core-vm/runtime.env`
- запускает `bash scripts/bootstrap-vm.sh`
- скачивает `/opt/vpn-core-vm/generated/peers.json`
- скачивает `/opt/vpn-core-vm/generated/wg0.conf`

Если нужен ручной запуск, на VM выполни:

```bash
cd /opt/vpn-core-vm
sudo bash scripts/bootstrap-vm.sh
```

Что делает bootstrap:

- проверяет Linux
- ставит `python3` и `wireguard-tools`, если их ещё нет
- ставит `k3s`, если его ещё нет
- читает `/opt/vpn-core-vm/runtime.env`
- выполняет полный setup окружения
- генерирует `/opt/vpn-core-vm/generated/wg0.conf`
- генерирует `/opt/vpn-core-vm/generated/peers.json`
- создаёт namespace
- создаёт `Secret` из `/opt/vpn-core-vm/generated/wg0.conf`
- применяет `Deployment` и `Service`
- даёт `k3s` самому скачать последний image `ghcr.io`
- показывает pod и короткий summary по WireGuard
- завершает provisioning с non-zero exit code при любой ошибке

### 3. Проверить, что runtime поднялся

```bash
kubectl -n vpn-core-vm get pods
kubectl -n vpn-core-vm logs deployment/wireguard
kubectl -n vpn-core-vm exec deploy/wireguard -- wg show
kubectl -n vpn-core-vm exec deploy/wireguard -- ip addr show wg0
```

## Если всё же нужен локальный запуск

Этот режим вторичный. Он нужен только если у тебя уже есть готовый `/opt/vpn-core-vm/generated/wg0.conf`.

```bash
docker compose -f dev/docker-compose.yml up --build -d
docker compose -f dev/docker-compose.yml exec wireguard wg show
```

## Что за что отвечает

- [docker/Dockerfile](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/Dockerfile)
- [docker/entrypoint.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/entrypoint.sh)
- [config/runtime.env.example](/Users/vadimsukach/VSProjects/vpn-core-vm/config/runtime.env.example)
- [generated](/Users/vadimsukach/VSProjects/vpn-core-vm/generated)
- [scripts/bootstrap-vm.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/bootstrap-vm.sh)
- [scripts/generate-wireguard-artifacts.py](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/generate-wireguard-artifacts.py)
- [k3s/namespace.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/namespace.yaml)
- [k3s/deployment.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/deployment.yaml)
- [k3s/service.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/service.yaml)
