# vpn-core-vm

Минимальный runtime-проект для схемы:

`Ubuntu VM -> k3s -> WireGuard container`

На этом этапе проект делает только базу:

- собирает контейнер с WireGuard runtime
- поднимает `wg0` через `wg-quick`
- включает `ip_forward`
- публикует UDP `51820`
- позволяет одной командой развернуть runtime на Ubuntu VM через `bootstrap`-скрипт
- генерирует server config и peer pool прямо во время provisioning
