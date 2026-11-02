# Respaldo automatizado TinyNAS

El Respaldo automatizado de mis estaciones de trabajo:

- Workstation principal: `Omarchy`, AMD Ryzen 5 5600GT (12) @ 4.67 GHz
- Laptop: `Fedora Sway Atomic`, AMD Ryzen 5 Serie 7000 (12)

## Recursos

- Montaje local via `autofs`
- Systemd + Timerd
- Gestion de respaldo: Bash script

## Especificaciones

- Servidor NFS sobre Debian

```Bash
❯ showmount -e tinynas
Export list for tinynas:
/srv/respaldos/victus 192.168.1.117,192.168.1.118
/srv/respaldos/ryzen  192.168.1.118,192.168.1.117
/srv/respaldos/prueba 192.168.1.118,192.168.1.117
```

- Networking
  Switch Gigabit 8 Puertos
