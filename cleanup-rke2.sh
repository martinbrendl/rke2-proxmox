#!/bin/bash
# cleanup-rke2.sh - Vyčištění RKE2 clusteru před novým spuštěním

user=ubuntu
certName=id_ed25519
master1=10.0.0.211
master2=10.0.0.212
master3=10.0.0.213
worker1=10.0.0.214
worker2=10.0.0.215

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

for node in $master1 $master2 $master3 $worker1 $worker2; do
  echo -e "${RED}Čistím $node...${NC}"
  ssh -i ~/.ssh/$certName $user@$node << 'EOF'
sudo systemctl stop rke2-server.service 2>/dev/null
sudo systemctl stop rke2-agent.service 2>/dev/null
sudo /usr/local/bin/rke2-uninstall.sh 2>/dev/null
sudo /usr/local/bin/rke2-agent-uninstall.sh 2>/dev/null
sudo rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet
sudo rm -rf /etc/systemd/system/rke2-server.service.d
sudo systemctl daemon-reload
EOF
  echo -e "${GREEN}$node vyčištěn${NC}"
done

# Vyčisti i admin node
echo -e "${RED}Čistím admin node (lokálně)...${NC}"
rm -f ~/token
rm -f ~/.kube/config ~/.kube/rke2.yaml
echo -e "${GREEN}Admin node vyčištěn${NC}"

echo -e "${GREEN}Hotovo! Můžeš spustit: bash rke2.sh${NC}"