# ============================================================
# Terraform — VM de Azure con Docker + GitLab Runner
# Arquitectura: GitLab (cloud) = repo + pipeline (GitLab CI) + Container Registry
#               GitLab Runner (en Docker) en ESTA VM ejecuta los jobs
#               GitLab Container Registry = registry de imágenes (SIN JFrog)
#               La app se despliega como contenedores Docker en la VM
# Auth Terraform: se ejecuta desde Azure Cloud Shell (ya autenticado)
#                 o con un Service Principal (ver notas al final).
# ============================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"        # versión estable
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id = var.subscription_id   # opcional en 3.x si usas az login
}

# ---------------- Variables ----------------
variable "location"       { default = "centralus" }          # región de Azure
variable "rg_name"        { default = "rg-devops-lab" }
variable "vm_name"        { default = "vm-cicd" }
variable "vm_size"        { default = "standard_d2als_v7" }   # 2 vCPU (ajusta a tu cuota)
variable "admin_username" { default = "azureuser" }

variable "ssh_public_key" {                                   # tu llave PÚBLICA SSH
  description = "Contenido de tu id_rsa.pub / id_ed25519.pub"
  type        = string
}

variable "gitlab_url" {                                       # normalmente gitlab.com
  default = "https://gitlab.com"
}

variable "gitlab_runner_token" {                             # token del runner (glrt-...)
  description = "Authentication token del GitLab Runner (Settings > CI/CD > Runners)"
  type        = string
  default     = ""                                            # si va vacío, no registra runner
  sensitive   = true
}

# ---------------- Red ----------------
resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.vm_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.vm_name}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.vm_name}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NSG = firewall. Abre solo lo necesario.
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.vm_name}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name = "SSH"; priority = 100; direction = "Inbound"; access = "Allow"
    protocol = "Tcp"; source_port_range = "*"; destination_port_range = "22"
    source_address_prefix = "*"; destination_address_prefix = "*"
  }
  security_rule {
    name = "HTTP"; priority = 110; direction = "Inbound"; access = "Allow"
    protocol = "Tcp"; source_port_range = "*"; destination_port_range = "80"
    source_address_prefix = "*"; destination_address_prefix = "*"
  }
  security_rule {
    name = "HTTPS"; priority = 120; direction = "Inbound"; access = "Allow"
    protocol = "Tcp"; source_port_range = "*"; destination_port_range = "443"
    source_address_prefix = "*"; destination_address_prefix = "*"
  }
  security_rule {                                   # puerto de la app (ajústalo)
    name = "AppPort"; priority = 130; direction = "Inbound"; access = "Allow"
    protocol = "Tcp"; source_port_range = "*"; destination_port_range = "9000"
    source_address_prefix = "*"; destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "assoc" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ---------------- cloud-init: instala Docker + GitLab Runner ----------------
locals {
  cloud_init = <<-EOT
    #!/bin/bash
    set -e
    # --- Docker + plugin de compose ---
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ${var.admin_username}

    # --- GitLab Runner en Docker (para que el pipeline corra AQUÍ) ---
    docker run -d --name gitlab-runner --restart always \
      -v /srv/gitlab-runner/config:/etc/gitlab-runner \
      -v /var/run/docker.sock:/var/run/docker.sock \
      gitlab/gitlab-runner:latest

    # --- Registrar el runner SOLO si diste el token ---
    if [ -n "${var.gitlab_runner_token}" ]; then
      docker exec gitlab-runner gitlab-runner register --non-interactive \
        --url "${var.gitlab_url}" \
        --token "${var.gitlab_runner_token}" \
        --executor docker \
        --docker-image "docker:24" \
        --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"
    fi
  EOT
}

# ---------------- La VM ----------------
resource "azurerm_linux_virtual_machine" "vm" {
  name                  = var.vm_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(local.cloud_init)   # cloud-init se ejecuta al arrancar
}

# ---------------- Salidas ----------------
output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}
output "ssh_cmd" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.pip.ip_address}"
}
