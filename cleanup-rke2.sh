#!/bin/bash
# cleanup-rke2.sh - Clean up RKE2 cluster before fresh deployment

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
  echo -e "${RED}Cleaning $node...${NC}"
  ssh -i ~/.ssh/$certName $user@$node << 'EOF'
sudo systemctl stop rke2-server.service 2>/dev/null
sudo systemctl stop rke2-agent.service 2>/dev/null
sudo /usr/local/bin/rke2-uninstall.sh 2>/dev/null
sudo /usr/local/bin/rke2-agent-uninstall.sh 2>/dev/null
sudo rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet
sudo rm -rf /etc/systemd/system/rke2-server.service.d
sudo systemctl daemon-reload
EOF
  echo -e "${GREEN}$node cleaned${NC}"
done

# Clean up admin node
echo -e "${RED}Cleaning admin node (local)...${NC}"
rm -f ~/token
rm -f ~/.kube/config ~/.kube/rke2.yaml
echo -e "${GREEN}Admin node cleaned${NC}"

echo -e "${GREEN}Done! You can now run: bash rke2.sh${NC}"
