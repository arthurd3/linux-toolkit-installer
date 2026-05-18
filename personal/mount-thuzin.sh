#!/bin/bash

# Ponto de montagem
sudo mkdir -p /run/media/arthurd3/ThuzinMemoria

# Comando de montagem CORRETO
sudo mount -t ntfs-3g /dev/sda1 /run/media/arthurd3/ThuzinMemoria

echo "✅ Partição ThuzinMemoria montada com sucesso em /run/media/arthurd3/ThuzinMemoria"
