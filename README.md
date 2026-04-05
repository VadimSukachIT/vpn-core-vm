# vpn-core-vm

Минимальный runtime-проект для схемы:

`Ubuntu VM -> k3s -> WireGuard container`

На этом этапе проект делает только базу:

- собирает контейнер с WireGuard runtime
- поднимает `wg0` через `wg-quick`
- включает `ip_forward`
- публикует UDP `51820`
- позволяет одной командой развернуть runtime на Ubuntu VM через `bootstrap`-скрипт

Что пока не делаем:

- создание VM через provider API
- генерацию пула из 1000 конфигов
- отправку конфигов в backend
- блокировку доменов
- ad-block
- metrics stack

Важно: всё это рассчитано на Linux VM. На macOS/Windows через Docker Desktop WireGuard smoke test может не работать.

## Минимальная структура

- `docker/` - контейнер WireGuard
- `config/` - входные runtime-параметры
- `generated/` - автоматически созданные файлы
- `k3s/` - три manifest-файла для VM
- `scripts/` - главный bootstrap-скрипт
- `dev/` - локальный запуск уже готового runtime, если понадобится

## Главный сценарий

### 1. Подготовить `runtime.env`

Файл [config/runtime.env](/Users/vadimsukach/VSProjects/vpn-core-vm/config/runtime.env) уже лежит в репе.

Если нужно, поменяй значения в нём перед деплоем.

### 2. Развернуть на Ubuntu VM одной командой

Сначала положи репу на VM, потом на самой VM выполни:

```bash
sudo bash scripts/bootstrap-vm.sh
```

Что делает bootstrap:

- проверяет Linux
- ставит `k3s`, если его ещё нет
- читает `config/runtime.env`
- генерирует `generated/server-private.key`
- генерирует `generated/server-public.key`
- генерирует `generated/wg0.conf`
- собирает Docker image WireGuard
- импортирует image в `k3s`
- создаёт namespace
- создаёт `Secret` из `generated/wg0.conf`
- применяет `Deployment` и `Service`
- показывает pod и статус `wg0`

### 3. Проверить, что runtime поднялся

```bash
kubectl -n vpn-core-vm get pods
kubectl -n vpn-core-vm logs deployment/wireguard
kubectl -n vpn-core-vm exec deploy/wireguard -- wg show
kubectl -n vpn-core-vm exec deploy/wireguard -- ip addr show wg0
```

## Если всё же нужен локальный запуск

Этот режим вторичный. Он нужен только если у тебя уже есть готовый `generated/wg0.conf`.

```bash
docker compose -f dev/docker-compose.yml up --build -d
docker compose -f dev/docker-compose.yml exec wireguard wg show
```

## Что за что отвечает

- [docker/Dockerfile](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/Dockerfile)
- [docker/entrypoint.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/entrypoint.sh)
- [config/runtime.env](/Users/vadimsukach/VSProjects/vpn-core-vm/config/runtime.env)
- [generated](/Users/vadimsukach/VSProjects/vpn-core-vm/generated)
- [scripts/bootstrap-vm.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/bootstrap-vm.sh)
- [k3s/namespace.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/namespace.yaml)
- [k3s/deployment.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/deployment.yaml)
- [k3s/service.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/service.yaml)
