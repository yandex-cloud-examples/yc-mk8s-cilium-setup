# Infrastructure for Yandex Cloud Managed Service for Kubernetes cluster
#
# Set the configuration of Managed Service for Kubernetes cluster:
locals {
  folder_id   = "" # Set your cloud folder ID.
  k8s_version = "" # Set the Kubernetes version.
  sa_name     = "" # Set the service account name.

  # The following settings are predefined. Change them only if necessary.
  network_name               = "k8s-network"          # Name of the network
  subnet_name                = "subnet-a"             # Name of the subnet
  zone_a_ipv4_cidr           = "10.1.0.0/16"          # CIDR for the subnet in the ru-central1-a availability zone
  cluster_ipv4_cidr          = "10.112.0.0/16"        # IP range for allocating pod addresses
  service_ipv4_cidr          = "10.96.0.0/16"         # IP range for allocating service addresses
  k8s_cluster_name           = "k8s-cluster"          # Name of the Kubernetes cluster
  k8s_node_group_name        = "k8s-node-group"       # Name of the Kubernetes node group
  main_sg_name               = "k8s-main"             # Name of the main security group for the cluster and the node groups
  master_whitelist_sg_name   = "k8s-master-whitelist" # Name of the whitelist security group for acessing Kubernetes API
  public_services_sg_name    = "k8s-public-services"  # Name of the public services security group for the node groups
  allowed_ipv4_cidr_api      = "0.0.0.0/0"            # CIDR of the network. The Kubernetes API is accessible from this network. 
  allowed_ipv4_cidr_services = "0.0.0.0/0"            # CIDR of the network. The Kubernetes services are accessible from this network.
}

resource "yandex_vpc_network" "k8s-network" {
  description = "Network for the Managed Service for Kubernetes cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k8s-network.id
  v4_cidr_blocks = [local.zone_a_ipv4_cidr]
}

resource "yandex_vpc_security_group" "k8s-main" {
  description = "Security group ensure the basic performance of the cluster. Apply it to the cluster and node groups."
  name        = local.main_sg_name
  network_id  = yandex_vpc_network.k8s-network.id

  ingress {
    description       = "The rule allows availability checks from the load balancer's range of addresses. It is required for the operation of a fault-tolerant cluster and load balancer services."
    protocol          = "TCP"
    predefined_target = "loadbalancer_healthchecks"
    from_port         = 0
    to_port           = 65535
  }

  ingress {
    description       = "The rule allows the master-node and node-node interaction within the security group"
    protocol          = "ANY"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }

  ingress {
    description    = "The rule allows the pod-pod and service-service interaction. Specify the cluster and services subnets."
    protocol       = "ANY"
    v4_cidr_blocks = [local.cluster_ipv4_cidr, local.service_ipv4_cidr]
    from_port      = 0
    to_port        = 65535
  }

  ingress {
    description    = "The rule allows receipt of debugging ICMP packets from internal subnets"
    protocol       = "ICMP"
    v4_cidr_blocks = [local.zone_a_ipv4_cidr]
  }

  egress {
    description    = "The rule allows all outgoing traffic. Nodes can connect to Yandex Container Registry, Object Storage, Docker Hub, and more."
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

resource "yandex_vpc_security_group" "k8s-master-whitelist" {
  description = "This security group limits access to the Kubernetes API. Apply it to the cluster."
  name        = local.master_whitelist_sg_name
  network_id  = yandex_vpc_network.k8s-network.id

  ingress {
    description    = "The rule allows connecting to Kubernetes API via 6443 port from the specified networks."
    protocol       = "TCP"
    v4_cidr_blocks = [local.allowed_ipv4_cidr_api]
    port           = 6443
  }

  ingress {
    description    = "The rule allows connecting to Kubernetes API via 443 port from the specified networks."
    protocol       = "TCP"
    v4_cidr_blocks = [local.allowed_ipv4_cidr_api]
    port           = 443
  }
}

resource "yandex_vpc_security_group" "k8s-public-services" {
  description = "Security group allows connections to services from the internet. Apply the rules only for node groups."
  name        = local.public_services_sg_name
  network_id  = yandex_vpc_network.k8s-network.id

  ingress {
    description    = "The rule allows incoming traffic from the internet to the NodePort port range. Add ports or change existing ones to the required ports."
    protocol       = "TCP"
    v4_cidr_blocks = [local.allowed_ipv4_cidr_services]
    from_port      = 30000
    to_port        = 32767
  }
}

resource "yandex_iam_service_account" "k8s-sa" {
  description = "Service account for Kubernetes cluster"
  name        = local.sa_name
}

# Assign "k8s.tunnelClusters.agent" role to Kubernetes service account
resource "yandex_resourcemanager_folder_iam_binding" "k8s-tunnelclusters-agent" {
  folder_id = local.folder_id
  role      = "k8s.tunnelClusters.agent"
  members = [
    "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
  ]
}

# Assign "vpc.publicAdmin" role to Kubernetes service account
resource "yandex_resourcemanager_folder_iam_binding" "vpc-publicadmin" {
  folder_id = local.folder_id
  role      = "vpc.publicAdmin"
  members = [
    "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
  ]
}

resource "yandex_kubernetes_cluster" "k8s-cluster" {
  description = "Managed Service for Kubernetes cluster"
  name        = local.k8s_cluster_name
  network_id  = yandex_vpc_network.k8s-network.id

  master {
    version = local.k8s_version
    zonal {
      zone      = yandex_vpc_subnet.subnet-a.zone
      subnet_id = yandex_vpc_subnet.subnet-a.id
    }

    public_ip = true
    security_group_ids = [yandex_vpc_security_group.k8s-main.id,
    yandex_vpc_security_group.k8s-master-whitelist.id]
  }

  network_implementation {
    cilium {}
  }

  cluster_ipv4_range = local.cluster_ipv4_cidr
  service_ipv4_range = local.service_ipv4_cidr

  service_account_id      = yandex_iam_service_account.k8s-sa.id # Cluster service account ID
  node_service_account_id = yandex_iam_service_account.k8s-sa.id # Node group service account ID

  depends_on = [
    yandex_resourcemanager_folder_iam_binding.k8s-tunnelclusters-agent,
    yandex_resourcemanager_folder_iam_binding.vpc-publicadmin
  ]
}

resource "yandex_kubernetes_node_group" "k8s-node-group" {
  description = "Node group for Managed Service for Kubernetes cluster"
  name        = local.k8s_node_group_name
  cluster_id  = yandex_kubernetes_cluster.k8s-cluster.id
  version     = local.k8s_version

  scale_policy {
    fixed_scale {
      size = 1 # Number of hosts
    }
  }

  allocation_policy {
    location {
      zone = "ru-central1-a"
    }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = true
      subnet_ids = [yandex_vpc_subnet.subnet-a.id]
      security_group_ids = [yandex_vpc_security_group.k8s-main.id,
      yandex_vpc_security_group.k8s-public-services.id]
    }

    resources {
      memory = 4 # RAM quantity in GB
      cores  = 4 # Number of CPU cores
    }

    boot_disk {
      type = "network-hdd"
      size = 64 # Disk size in GB
    }
  }
}