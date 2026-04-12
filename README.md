# vpn-core-vm

Минимальный runtime-проект для схемы:

`Ubuntu VM -> k3s -> WireGuard container`

На этом этапе проект делает только базу:

- использует prebuilt контейнер с WireGuard runtime из `ghcr.io`
- поднимает `wg0` через `wg-quick`
- поднимает `node_exporter` на `:9100`
- поднимает `kube-state-metrics` на `:8080`
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
- `k3s/` - три manifest-файла для VM
- `k3s/monitoring/` - monitoring exporters и RBAC
- `scripts/` - главный bootstrap-скрипт
- `scripts/cleanup-vm.sh` - teardown k3s-ресурсов на VM
- `scripts/deploy-vm.sh` - rollout конкретного wireguard image tag на VM
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
- скачивает `/conf/vpn-core-vm/peers.json`
- использует `/conf/vpn-core-vm/wg0.conf` как persistent runtime state на VM

Если нужен ручной запуск, на VM выполни:

```bash
cd /opt/vpn-core-vm
sudo bash scripts/bootstrap-vm.sh
```

Что делает bootstrap:

- проверяет Linux
- ставит `python3` и `wireguard-tools`, если их ещё нет
- ставит `k3s`, если его ещё нет
- отключает в `k3s` лишние baseline addons: `traefik`, `servicelb`, `metrics-server`, `local-storage`
- читает `/opt/vpn-core-vm/runtime.env`
- выполняет полный setup окружения
- создаёт `/conf/vpn-core-vm/`, если его ещё нет
- генерирует `/conf/vpn-core-vm/wg0.conf`
- генерирует `/conf/vpn-core-vm/peers.json`
- создаёт namespace
- применяет monitoring manifests на готовых официальных image
- создаёт `Secret` из `/conf/vpn-core-vm/wg0.conf`
- применяет `Deployment` и `Service`
- выставляет wireguard image ровно в `ghcr.io/vadimsukachit/vpn-core-vm-wireguard:<imageTag>`
- ждёт `wireguard`, `node_exporter` и `kube-state-metrics`
- показывает pod и короткий summary по runtime
- завершает provisioning с non-zero exit code при любой ошибке

Monitoring слой остаётся лёгким для VM с 1 GB RAM:

- `node_exporter` работает как host-level DaemonSet на `:9100`
- `kube-state-metrics` использует готовый image и ограниченный набор Kubernetes resources на `:8080`
- из стандартных компонентов `k3s` сохраняется `coredns`, потому что он нужен рабочему cluster networking/DNS flow

### 3. Проверить, что runtime поднялся

```bash
kubectl -n vpn-core-vm get pods
kubectl -n vpn-core-vm logs deployment/wireguard
kubectl -n vpn-core-vm exec deploy/wireguard -- wg show
kubectl -n vpn-core-vm exec deploy/wireguard -- ip addr show wg0
curl http://<vm_ip>:9100/metrics | head
curl http://<vm_ip>:8080/metrics | head
```

### 4. Cleanup

Для полного teardown manifests, включая cluster-scoped RBAC от `kube-state-metrics`, на VM выполни:

```bash
cd /opt/vpn-core-vm
sudo bash scripts/cleanup-vm.sh
```

Этот cleanup также удаляет `k3s` config из `/etc/rancher/k3s/config.yaml`, который отключает лишние baseline addons.
Persistent runtime state в `/conf/vpn-core-vm/` он тоже удаляет, потому что это сценарий полного teardown VM.

### 5. Deploy Specific Image

Если control-plane уже собрал и запушил image с конкретным tag, на VM можно раскатить его так:

```bash
cd /opt/vpn-core-vm
sudo bash scripts/deploy-vm.sh <imageTag>
```

Скрипт обновляет только wireguard deployment до `ghcr.io/vadimsukachit/vpn-core-vm-wireguard:<imageTag>`, ждёт rollout и проверяет, что monitoring workloads не сломались.

## Если всё же нужен локальный запуск

Этот режим вторичный. Он нужен только если у тебя уже есть готовый `/conf/vpn-core-vm/wg0.conf`.

```bash
docker compose -f dev/docker-compose.yml up --build -d
docker compose -f dev/docker-compose.yml exec wireguard wg show
```

## Что за что отвечает

- [docker/Dockerfile](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/Dockerfile)
- [docker/entrypoint.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/docker/entrypoint.sh)
- [config/runtime.env.example](/Users/vadimsukach/VSProjects/vpn-core-vm/config/runtime.env.example)
- [scripts/bootstrap-vm.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/bootstrap-vm.sh)
- [scripts/cleanup-vm.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/cleanup-vm.sh)
- [scripts/deploy-vm.sh](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/deploy-vm.sh)
- [scripts/generate-wireguard-artifacts.py](/Users/vadimsukach/VSProjects/vpn-core-vm/scripts/generate-wireguard-artifacts.py)
- [k3s/namespace.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/namespace.yaml)
- [k3s/deployment.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/deployment.yaml)
- [k3s/service.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/service.yaml)
- [k3s/monitoring/node-exporter.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/monitoring/node-exporter.yaml)
- [k3s/monitoring/kube-state-metrics-rbac.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/monitoring/kube-state-metrics-rbac.yaml)
- [k3s/monitoring/kube-state-metrics-deployment.yaml](/Users/vadimsukach/VSProjects/vpn-core-vm/k3s/monitoring/kube-state-metrics-deployment.yaml)
